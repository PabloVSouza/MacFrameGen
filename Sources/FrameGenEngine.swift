import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CoreMedia
import VideoToolbox

struct FrameGenStats {
    var inputFPS = 0.0       // frames arriving from the source (e.g. 60 from a capture card)
    var uniqueFPS = 0.0      // real game frames after dropping repeats (e.g. 30)
    var outputFPS = 0.0      // frames put on screen
    var interpolationMs = 0.0
    var resolution = ""
    var displayHz = 0
    var latencyMs = 0.0      // capture → on screen, averaged over shown frames
    var backend = ""
    var deliveryMs = 0.0     // card timestamp → frame reaches the app
    var budgetMs = 0.0       // processing time allowed for
    var sourceFPS = 0.0
    var toneMappedHDR = false   // brightest pixels pinned at the card's HDR tone-mapping ceiling
    var missedRefreshes = 0     // refreshes with a frame due that couldn't be drawn in time
    var drawableWaitMs = 0.0    // longest wait for a drawable in the last second
    var renderResolution = ""   // estimated game render size, e.g. "1536×864", or "no upscale trace"
    var refreshes = 0        // display-link callbacks per second
    var generated = 0        // interpolations completed per second
    var lastError: String?
}

enum InterpolatorBackend: String, CaseIterable, Identifiable {
    case shader = "Fast GPU shader"
    case apple = "Apple ML"
    var id: String { rawValue }
}

/// Source frames → drop repeats → interpolate → paced presentation.
final class FrameGenEngine {
    var onStats: ((FrameGenStats) -> Void)?
    var onStopped: ((String?) -> Void)?

    /// Live A/B switch: when false, only real frames are shown.
    var interpolationEnabled: Bool {
        get { stateLock.withLock { _enabled } }
        set { stateLock.withLock { _enabled = newValue } }
    }
    /// Skip frames identical to the previous one (a 30 fps game through a 60 fps capture card
    /// repeats every frame, which would leave nothing to interpolate between).
    var dropRepeats: Bool {
        get { stateLock.withLock { _dropRepeats } }
        set { stateLock.withLock { _dropRepeats = newValue } }
    }

    private let captureQueue = DispatchQueue(label: "framegen.capture", qos: .userInteractive)
    private let stateLock = NSLock()
    private var _enabled = true
    private var _dropRepeats = true
    private var _lowLatency = true

    /// Reflex-style: schedule frames with the tightest safe margin (90th-percentile processing
    /// time) instead of the slowest recent frame. Lower delay, rare late frames.
    var lowLatency: Bool {
        get { stateLock.withLock { _lowLatency } }
        set { stateLock.withLock { _lowLatency = newValue } }
    }

    private(set) var source: FrameSource?
    private var presenter: Presenter?
    private var timers: [Timer] = []
    private var trackedWindow: (id: CGWindowID, pid: pid_t?)?

    // Capture-queue state
    private var interpolator: FrameInterpolating?
    private var backendName = ""
    private var previous: (buffer: CVPixelBuffer, pts: CMTime)?
    private var recentProcessing: [Double] = []     // last ~2 s of processing times

    // Render-resolution estimate (runs on its own low-priority queue).
    private let detectQueue = DispatchQueue(label: "framegen.resolution", qos: .utility)
    private let detector = ResolutionDetector()
    private var detectInFlight = false              // capture queue
    private var detectCounter = 0                   // capture queue
    private var renderResolution = ""               // detectQueue
    private var renderWindows: [String] = []        // detectQueue: last 3 window results
    private var lastSignature: [UInt8] = []
    private var recentPeaks: [UInt8] = []       // brightest luma of recent real frames
    private var busy = false
    private var deliveryDelay = 0.005     // capture timestamp → frame reaches us (EMA)
    private var sourceInterval = 1.0 / 30 // time between real game frames (EMA)
    private var _displayInterval = 1.0 / 60
    private var displayInterval: Double {
        get { stateLock.withLock { _displayInterval } }
        set { stateLock.withLock { _displayInterval = newValue } }
    }
    private var lastPTS: Double?
    private var inputCount = 0
    private var uniqueCount = 0
    private var processTime = 0.0
    private var processCount = 0
    private var lastError: String?

    var isRunning: Bool { source != nil }

    /// Brightness fix for the capture card's tone-mapped HDR; can change while running.
    var color = ColorAdjust() {
        didSet { let c = color; captureQueue.async { self.interpolator?.color = c } }
    }

    /// Show the game/output FPS in the corner of the output window.
    var showFPSOverlay = true {
        didSet { if !showFPSOverlay { presenter?.setStatsText(nil) } }
    }

    /// Testing aid: write the next `recordCount` real frames as raw 420v files
    /// (header: width, height as UInt32; then the Y plane, then the CbCr plane, rows unpadded).
    var recordDir: String?
    var recordCount = 0
    private var recorded = 0

    private func record(_ buffer: CVPixelBuffer) {
        guard let dir = recordDir, recorded < recordCount,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var data = Data()
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        withUnsafeBytes(of: UInt32(w)) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(h)) { data.append(contentsOf: $0) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rowBytes = plane == 0 ? w : w   // CbCr: w/2 pairs × 2 bytes
            for r in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) { data.append(base + r * stride, count: rowBytes) }
        }
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "frame_%03d.yuv", recorded)))
        recorded += 1
        if recorded >= recordCount { recordDir = nil }
    }

    /// Testing aid: save one incoming frame as a PNG.
    var snapshotPath: String?

    static func savePNG(_ buffer: CVPixelBuffer, to path: String) {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(image, from: image.extent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Start / stop (main thread)

    @MainActor
    func start(source: FrameSource, presenter: Presenter, multiplier: Int, backend: InterpolatorBackend,
               trackWindow: (id: CGWindowID, pid: pid_t?)? = nil) async throws {
        stop()

        let width = source.width, height = source.height
        let interp: FrameInterpolating = switch backend {
        case .shader: try MetalInterpolator(width: width, height: height, multiplier: multiplier)
        case .apple: try Interpolator(width: width, height: height, multiplier: multiplier)
        }
        interp.color = color

        captureQueue.sync {
            interpolator = interp
            backendName = backend == .shader ? "shader" : "Apple ML"
            previous = nil
            lastSignature = []
            busy = false
            lastPTS = nil
            deliveryDelay = 0.005
            sourceInterval = 1.0 / 30
            recentProcessing = []
            recentPeaks = []
            detectInFlight = false
            detectCounter = 0
            inputCount = 0; uniqueCount = 0; processTime = 0; processCount = 0
            lastError = nil
        }
        detectQueue.sync {
            detector.reset()
            renderWindows = []
            renderResolution = ""
        }
        self.source = source
        self.presenter = presenter
        trackedWindow = trackWindow
        presenter.onClose = { [weak self] in self?.stop() }
        presenter.show()
        displayInterval = 1 / Double(presenter.refreshRate)

        do {
            try await source.start(queue: captureQueue) { [weak self] pb, pts in self?.handle(pb, pts) }
        } catch {
            stop()
            throw error
        }

        let resolution = "\(width)×\(height)"
        timers = [Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportStats(resolution) }
        }]
        if trackWindow != nil {
            timers.append(Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackWindow() }
            })
        }
    }

    @MainActor
    func stop(reason: String? = nil) {
        let wasRunning = source != nil
        timers.forEach { $0.invalidate() }
        timers = []
        source?.stop()
        source = nil
        presenter?.close()
        presenter = nil
        captureQueue.async {
            self.interpolator = nil
            self.previous = nil
        }
        if wasRunning { onStopped?(reason) }
    }

    // MARK: - Overlay tracking & stats (main thread)

    @MainActor
    private func trackWindow() {
        guard let presenter, let (windowID, pid) = trackedWindow else { return }
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else { stop(reason: "The game window closed."); return }
        presenter.setFrame(Self.cocoaRect(fromTopLeft: bounds))

        // Only cover the game while it's the active app, so other windows stay usable.
        let gameActive = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        if gameActive != presenter.window.isVisible {
            if gameActive { presenter.window.orderFrontRegardless() } else { presenter.window.orderOut(nil) }
        }
    }

    private var lastReport = CACurrentMediaTime()
    private var previousRates: (game: Double, output: Double)?

    @MainActor
    private func reportStats(_ resolution: String) {
        guard let presenter else { return }
        // Divide by the real elapsed time: the 1 s timer drifts, which made a steady 60 read 59.
        let now = CACurrentMediaTime(), elapsed = max(now - lastReport, 0.1)
        lastReport = now
        var stats = FrameGenStats(outputFPS: Double(presenter.takeShownCount()) / elapsed,
                                  resolution: resolution, displayHz: presenter.refreshRate)
        stats.refreshes = presenter.takeTickCount()
        (stats.missedRefreshes, stats.drawableWaitMs) = presenter.takePacingStats()
        stats.latencyMs = presenter.takeAverageLatency() * 1000
        stats.renderResolution = detectQueue.sync {
            if detector.accumulatedFrames >= 20 {
                let e = detector.estimateAccumulated()
                detector.reset()
                let result: String
                if let w = e.width, let h = e.height { result = "\(w)×\(h)" }
                else if let w = e.width { result = "\(w) wide" }
                else { result = "no upscale trace" }
                // Only show a value that at least 2 of the last 3 windows (~1.5 s each) agree on;
                // stylised scenes (halftone patterns, video cutscenes) otherwise make it jump around.
                renderWindows.append(result)
                if renderWindows.count > 3 { renderWindows.removeFirst() }
                let counts = Dictionary(renderWindows.map { ($0, 1) }, uniquingKeysWith: +)
                if let (value, n) = counts.max(by: { $0.value < $1.value }), n >= 2 { renderResolution = value }
                else if renderWindows.count >= 3 { renderResolution = "?" }
            }
            return renderResolution
        }
        displayInterval = 1 / Double(max(presenter.refreshRate, 30))
        captureQueue.sync {
            stats.inputFPS = Double(inputCount) / elapsed
            stats.uniqueFPS = Double(uniqueCount) / elapsed
            stats.generated = processCount
            stats.interpolationMs = processCount > 0 ? processTime / Double(processCount) * 1000 : 0
            stats.lastError = lastError
            stats.backend = backendName
            // With console HDR on, the Elgato Game Capture Neo tone-maps to SDR with white pinned at
            // luma ≈ 165 (of 235): every frame's peak sits right there. SDR content regularly goes higher.
            let pinned = recentPeaks.filter { (158...172).contains($0) }.count
            stats.toneMappedHDR = recentPeaks.count >= 45 && recentPeaks.allSatisfy { $0 <= 175 }
                && pinned * 10 >= recentPeaks.count * 8
            stats.deliveryMs = deliveryDelay * 1000
            stats.budgetMs = processingBudget() * 1000
            stats.sourceFPS = 1 / sourceInterval
            inputCount = 0; uniqueCount = 0; processTime = 0; processCount = 0
        }
        if showFPSOverlay {
            let mode = interpolationEnabled ? "" : "  (frame gen off)"
            let r = stats.renderResolution
            let render = r.isEmpty ? "" : (r.first?.isNumber == true ? " · render ≈\(r)" : " · render: \(r)")
            // Average over 2 s: a 1 s window can split a real/generated pair and read 59 or 61.
            let game = (stats.uniqueFPS + (previousRates?.game ?? stats.uniqueFPS)) / 2
            let output = (stats.outputFPS + (previousRates?.output ?? stats.outputFPS)) / 2
            previousRates = (stats.uniqueFPS, stats.outputFPS)
            presenter.setStatsText("Game \(Int(game.rounded())) fps → \(Int(output.rounded())) fps · \(Int(stats.latencyMs.rounded())) ms\(render)\(mode)")
        }
        onStats?(stats)
    }

    static func cocoaRect(fromTopLeft r: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? r.maxY
        return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    // MARK: - Frame pipeline (capture queue)

    private func handle(_ pixelBuffer: CVPixelBuffer, _ ptsTime: CMTime) {
        guard let interpolator, let presenter, let source else { return }
        inputCount += 1
        if let path = snapshotPath, inputCount == 30 {
            Self.savePNG(pixelBuffer, to: path)
            // Testing aid: record the colour tags the source puts on its frames.
            let keys = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey]
            let tags = keys.map { "\($0)=\(CVBufferCopyAttachment(pixelBuffer, $0, nil).map { "\($0)" } ?? "none")" }
            let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let cc = String(bytes: [24, 16, 8, 0].map { UInt8((fmt >> $0) & 0xff) }, encoding: .ascii) ?? "?"
            try? (tags.joined(separator: "\n") + "\nformat=\(cc)\n").write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            snapshotPath = nil
        }

        if dropRepeats, isRepeat(pixelBuffer) { return }
        uniqueCount += 1
        recentPeaks.append(peakLuma(pixelBuffer))
        if recentPeaks.count > 90 { recentPeaks.removeFirst() }
        if recordDir != nil { record(pixelBuffer) }

        // Capture timestamps are on the host clock, the same one the display link uses.
        let pts = ptsTime.seconds
        let arrived = CACurrentMediaTime()
        deliveryDelay = deliveryDelay * 0.9 + max(0, arrived - pts) * 0.1
        let gap = lastPTS.map { pts - $0 } ?? 0
        lastPTS = pts
        if gap > 0.004, gap < 0.1 { sourceInterval = sourceInterval * 0.8 + gap * 0.2 }

        guard let current = interpolator.prepare(pixelBuffer, forceCopy: source.mustCopyFrames),
              let real = interpolator.display(current) else { return }
        let prev = previous
        previous = (current, ptsTime)

        // Feed every 2nd real frame to the render-resolution estimator, skipping if it's behind.
        detectCounter += 1
        if detectCounter % 2 == 0, !detectInFlight {
            detectInFlight = true
            detectQueue.async { [weak self] in
                self?.detector.add(current)
                self?.captureQueue.async { self?.detectInFlight = false }
            }
        }

        // Output spacing to aim for: the screen's refresh, or the chosen multiple of the game's
        // frame rate if that's slower (2× of 30 fps on a 120 Hz screen = 60 fps).
        let multiplier = interpolator.multiplier
        let target = max(displayInterval, sourceInterval / Double(multiplier))

        // Every frame is shown a fixed delay after it was captured, so real and generated frames
        // stay evenly spaced whether or not this particular frame gets interpolated. The delay is
        // one typical game frame minus one output frame (unavoidable: in-between frames need the next
        // real one) plus a processing budget learned from recent frames.
        let showAt = pts + deliveryDelay + processingBudget() + max(0, sourceInterval - target)

        // As many in-between frames as this gap needs to fill the output: 1 for a steady 30 fps game
        // at 60, 2 when the game hitches and a frame takes 50 ms, so the output stays at 60.
        let count = min(Int((gap / target).rounded()) - 1, interpolator.maxGenerated)

        // Generate only when it adds frames the screen can actually show: not for the first frame,
        // after a pause (static menus, loading), when the source is already as fast as the target
        // (60 fps menus on a 60 Hz screen), or while the previous interpolation is still running.
        guard interpolationEnabled, let prev, !busy, gap > 0.004, gap < 0.2, count >= 1 else {
            presenter.enqueue([(showAt, real, pts)])
            return
        }

        busy = true
        interpolator.interpolate(previous: prev.buffer, previousPTS: prev.pts, current: current, currentPTS: ptsTime,
                                 count: count) { [weak self] result in
            guard let self else { return }
            self.captureQueue.async {
                self.busy = false
                guard let presenter = self.presenter, let interpolator = self.interpolator else { return }
                var batch: [(CFTimeInterval, CVPixelBuffer, CFTimeInterval)] = []
                switch result {
                case let .success(mids):
                    // In-between frames go evenly between the previous real frame and this one.
                    let step = gap / Double(mids.count + 1)
                    for (i, mid) in mids.enumerated() {
                        if let shown = interpolator.display(mid) {
                            let offset = step * Double(mids.count - i)
                            batch.append((showAt - offset, shown, pts - offset))
                        }
                    }
                case let .failure(error):
                    self.lastError = error.localizedDescription
                }
                batch.append((showAt, real, pts))
                presenter.enqueue(batch)

                let took = CACurrentMediaTime() - arrived
                self.recentProcessing.append(took)
                if self.recentProcessing.count > 60 { self.recentProcessing.removeFirst() }
                self.processTime += took
                self.processCount += 1
            }
        }
    }

    /// Time to allow for interpolation: the slowest recent frame (+3 ms), or in low-latency mode
    /// the 90th percentile (+1 ms), accepting the odd late frame for a shorter delay.
    private func processingBudget() -> Double {
        guard recentProcessing.count >= 10 else { return 0.02 }
        let sorted = recentProcessing.sorted()
        return lowLatency ? sorted[sorted.count * 9 / 10] + 0.001 : sorted.last! + 0.003
    }

    /// Brightest luma value, sampled on a sparse grid (enough to find the white level).
    private func peakLuma(_ buffer: CVPixelBuffer) -> UInt8 {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return 0 }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        var peak: UInt8 = 0
        for r in Swift.stride(from: 0, to: h, by: 4) {
            let row = luma + r * stride
            for c in Swift.stride(from: 0, to: w, by: 4) where row[c] > peak { peak = row[c] }
        }
        return peak
    }

    /// Compares the whole luma plane with the last real frame. Measured on an Elgato Game Capture Neo
    /// with a PS5: with console HDR on, a repeated frame is bit-identical; with HDR off, repeats carry
    /// dither noise (~25 % of pixels differ, but by at most 3 levels) while new frames differ by
    /// 130+ levels in over 1 % of pixels. So a frame counts as new once more than a handful of
    /// pixels change by more than `repeatTolerance` — immune to the noise, and still caught by a
    /// one-pixel cursor move.
    private func isRepeat(_ buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferIsPlanar(buffer), CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return false }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        var repeated = lastSignature.count == w * h
        if repeated {
            let tolerance = SIMD16<UInt8>(repeating: Self.repeatTolerance)
            var changed = 0
            lastSignature.withUnsafeBufferPointer { ref in
                rows: for r in 0..<h {
                    let row = luma + r * stride, refRow = ref.baseAddress! + r * w
                    if memcmp(row, refRow, w) == 0 { continue }            // identical row: fast path
                    var c = 0
                    while c + 16 <= w {
                        let a = UnsafeRawPointer(row + c).loadUnaligned(as: SIMD16<UInt8>.self)
                        let b = UnsafeRawPointer(refRow + c).loadUnaligned(as: SIMD16<UInt8>.self)
                        let diff = pointwiseMax(a, b) &- pointwiseMin(a, b)
                        let over = diff .> tolerance
                        if any(over) {
                            for i in 0..<16 where over[i] { changed += 1 }
                            if changed > Self.repeatMaxChangedPixels { repeated = false; break rows }
                        }
                        c += 16
                    }
                    while c < w {
                        if abs(Int(row[c]) - Int(refRow[c])) > Int(Self.repeatTolerance) { changed += 1 }
                        c += 1
                    }
                    if changed > Self.repeatMaxChangedPixels { repeated = false; break rows }
                }
            }
        }
        // Only a real new frame becomes the reference, so slow fades still register once they add up.
        if !repeated {
            if lastSignature.count != w * h { lastSignature = [UInt8](repeating: 0, count: w * h) }
            lastSignature.withUnsafeMutableBufferPointer { dst in
                for r in 0..<h { memcpy(dst.baseAddress! + r * w, luma + r * stride, w) }
            }
        }
        return repeated
    }

    /// Luma difference that counts as a real change (noise peaks at 3), and how many such pixels
    /// a frame may have and still be a repeat.
    static let repeatTolerance: UInt8 = 6
    static let repeatMaxChangedPixels = 16

}
