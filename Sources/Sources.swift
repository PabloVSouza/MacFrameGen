import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Something that delivers video frames to the engine.
protocol FrameSource: AnyObject {
    var width: Int { get }
    var height: Int { get }
    var name: String { get }
    /// Frames from AVFoundation pools must be copied before they're held onto.
    var mustCopyFrames: Bool { get }
    func start(queue: DispatchQueue, handler: @escaping (CVPixelBuffer, CMTime) -> Void) async throws
    func stop()
}

// MARK: - Capture card (UVC: Elgato etc.)

final class CaptureCardSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    let width: Int
    let height: Int
    let name: String
    let mustCopyFrames = true

    private let device: AVCaptureDevice
    private let audioDevice: AVCaptureDevice?
    private let format: AVCaptureDevice.Format
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "framegen.capture-session", qos: .userInitiated)
    private var audioPreview: AVCaptureAudioPreviewOutput?
    private var handler: ((CVPixelBuffer, CMTime) -> Void)?

    static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
    }

    static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    /// The card's audio input usually shares the video device's name.
    static func matchingAudio(for video: AVCaptureDevice) -> AVCaptureDevice? {
        audioDevices().first { $0.localizedName == video.localizedName }
            ?? audioDevices().first { $0.manufacturer == video.manufacturer && !video.manufacturer.isEmpty }
    }

    init(device: AVCaptureDevice, audioDevice: AVCaptureDevice?, maxLongEdge: Int) throws {
        self.device = device
        self.audioDevice = audioDevice
        name = device.localizedName

        // Prefer the largest format that fits the interpolator, at the highest frame rate, in 420v.
        let limit = min(maxLongEdge, Interpolator.maxSize().dimension)
        let candidates = device.formats.filter {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return Int(max(d.width, d.height)) <= limit
        }
        func score(_ f: AVCaptureDevice.Format) -> (Int, Double, Int) {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let fps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let is420v = CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            return (Int(d.width) * Int(d.height), fps, is420v ? 1 : 0)
        }
        guard let best = candidates.max(by: { score($0) < score($1) }) else {
            throw FrameGenError.process("\(device.localizedName) has no video format up to \(limit) px wide.")
        }
        format = best
        let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        width = Int(dims.width)
        height = Int(dims.height)
    }

    func start(queue: DispatchQueue, handler: @escaping (CVPixelBuffer, CMTime) -> Void) async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw FrameGenError.process("Camera access is off. Allow MacFrameGen in System Settings › Privacy & Security › Camera.")
        }
        // Ask before configuring: nothing may wait between beginConfiguration and commitConfiguration.
        let audioAllowed = audioDevice != nil ? await AVCaptureDevice.requestAccess(for: .audio) : false
        self.handler = handler

        try configure(queue: queue, audio: audioAllowed)

        let session = self.session
        await withCheckedContinuation { cont in
            sessionQueue.async { session.startRunning(); cont.resume() }
        }
        guard session.isRunning else {
            throw FrameGenError.process("\(name) didn't start. If OBS or another app is using it, remove it there (in OBS, capture the MacFrameGen window instead), or unplug and replug the card.")
        }
        // macOS can reset the format/frame rate when the session starts, so apply it again.
        if !sharedWithAnotherApp { try? applyFormat() }
    }

    /// True when another app (e.g. OBS, even with its source hidden) controls the card's format. We then
    /// read the card as it is: macOS lets several apps capture the same device, and frames of another
    /// size are rescaled on the way in.
    private(set) var sharedWithAnotherApp = false

    /// Builds the session. `commitConfiguration` always runs (even when a step fails): a session left
    /// mid-configuration makes a later `stopRunning` abort the app — that was a crash when OBS held
    /// the card and setup failed.
    private func configure(queue: DispatchQueue, audio: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let videoInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoInput) else {
            throw FrameGenError.process("Can't use \(name): another app (OBS?) may be using it. Remove it there, or in OBS capture the MacFrameGen window instead.")
        }
        session.addInput(videoInput)

        do { try applyFormat() } catch { sharedWithAnotherApp = true }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw FrameGenError.process("Can't read video from \(name).") }
        session.addOutput(output)

        // Game audio straight to the speakers.
        if audio, let audioDevice, let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
            let preview = AVCaptureAudioPreviewOutput()
            preview.volume = 1
            if session.canAddOutput(preview) { session.addOutput(preview); audioPreview = preview }
        }
    }

    private func applyFormat() throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.activeFormat != format { device.activeFormat = format }
        if let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.activeVideoMaxFrameDuration = range.minFrameDuration
        }
    }

    /// e.g. "1920×1080 420v @ 60 fps"
    var formatDescription: String {
        let f = device.activeFormat
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let t = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        let cc = String(bytes: [24, 16, 8, 0].map { UInt8((t >> $0) & 0xff) }, encoding: .ascii) ?? "?"
        let fps = device.activeVideoMinFrameDuration.seconds > 0 ? 1 / device.activeVideoMinFrameDuration.seconds : 0
        return "\(d.width)×\(d.height) \(cc) @ \(Int(fps.rounded())) fps"
    }

    var volume: Float {
        get { audioPreview?.volume ?? 0 }
        set { audioPreview?.volume = newValue }
    }

    func stop() {
        let session = self.session
        // Same serial queue as startRunning, so a stop can't overtake a start; only stop what runs.
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
        handler = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = sampleBuffer.imageBuffer else { return }
        handler?(pb, hostTime(sampleBuffer.presentationTimeStamp))
    }

    /// Frame timestamps on the host clock (the one the display link uses). They are usually on it
    /// already, but when another app (OBS) shares the card they came on a clock running ahead of it,
    /// so every frame was scheduled for a time that never came and nothing was shown.
    private func hostTime(_ pts: CMTime) -> CMTime {
        var t = pts
        if let clock = session.synchronizationClock {
            t = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        }
        // Safety net: a timestamp far from "now" can't be right; use the arrival time instead.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if !t.isValid || abs((now - t).seconds) > 0.5 { t = now }
        return t
    }
}

// MARK: - Screen / window capture (ScreenCaptureKit)

final class ScreenSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    let width: Int
    let height: Int
    let name: String
    let mustCopyFrames = false
    let filter: SCContentFilter
    /// Window position in top-left-origin global points.
    let pointRect: CGRect
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private var handler: ((CVPixelBuffer, CMTime) -> Void)?

    init(window: SCWindow, maxLongEdge: Int) {
        filter = SCContentFilter(desktopIndependentWindow: window)
        pointRect = window.frame
        name = window.title ?? window.owningApplication?.applicationName ?? "Window"
        (width, height) = Self.fit(pointRect.size, scale: Double(filter.pointPixelScale), maxLongEdge: maxLongEdge)
    }

    init(display: SCDisplay, excluding apps: [SCRunningApplication], maxLongEdge: Int) {
        filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        pointRect = display.frame
        name = "Display \(display.displayID)"
        (width, height) = Self.fit(pointRect.size, scale: Double(filter.pointPixelScale), maxLongEdge: maxLongEdge)
    }

    /// Native pixel size, shrunk to fit the user's cap and the interpolator's limits.
    static func fit(_ size: CGSize, scale: Double, maxLongEdge: Int) -> (Int, Int) {
        let (maxDim, maxPixels) = Interpolator.maxSize()
        var w = size.width * scale, h = size.height * scale
        let f = min(1, Double(min(maxLongEdge, maxDim)) / max(w, h), (Double(maxPixels) / (w * h)).squareRoot())
        w = (w * f / 2).rounded(.down) * 2
        h = (h * f / 2).rounded(.down) * 2
        return (Int(w), Int(h))
    }

    func start(queue: DispatchQueue, handler: @escaping (CVPixelBuffer, CMTime) -> Void) async throws {
        self.handler = handler
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 8
        config.showsCursor = false
        config.scalesToFit = true
        config.preservesAspectRatio = true
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        handler = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pb = sampleBuffer.imageBuffer
        else { return }
        handler?(pb, sampleBuffer.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error) }
}
