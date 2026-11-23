import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum FrameGenError: LocalizedError {
    case unsupported
    case configFailed(Int, Int)
    case poolFailed
    case process(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: return "Low-latency frame interpolation isn't supported on this Mac (needs Apple Silicon and macOS 26 or later)."
        case let .configFailed(w, h): return "Couldn't create an interpolation session for \(w)×\(h)."
        case .poolFailed: return "Couldn't allocate video buffers."
        case let .process(m): return m
        }
    }
}

/// Tone-mapping fix applied in the YUV → RGB conversion (see `undoToneMap` in MetalInterpolator).
/// strength 0 = picture as the card sends it, 1 = fully corrected.
struct ColorAdjust: Equatable {
    var strength: Float = 0
    var saturation: Float = 0.958
}

/// A frame generator: turns two real frames into (multiple − 1) in-between frames.
protocol FrameInterpolating: AnyObject {
    var color: ColorAdjust { get set }
    var width: Int { get }
    var height: Int { get }
    var multiplier: Int { get }
    /// A 420v buffer of the right size that can be held as the next "previous" frame.
    func prepare(_ buffer: CVPixelBuffer, forceCopy: Bool) -> CVPixelBuffer?
    /// A BGRA IOSurface buffer the presenter can show.
    func display(_ buffer: CVPixelBuffer) -> CVPixelBuffer?
    /// Most in-between frames one call can produce.
    var maxGenerated: Int { get }
    /// Generates up to `count` evenly spaced in-between frames (a backend with a fixed count may
    /// return a different number). `completion` runs on an arbitrary queue, frames in display order.
    func interpolate(previous: CVPixelBuffer, previousPTS: CMTime, current: CVPixelBuffer, currentPTS: CMTime,
                     count: Int, completion: @escaping (Result<[CVPixelBuffer], Error>) -> Void)
}

/// Apple's machine-learning frame interpolator (VideoToolbox VTLowLatencyFrameInterpolation).
/// Best quality, but ~14 ms per 1080p frame on an M3 Pro.
final class Interpolator: FrameInterpolating {
    let width: Int
    let height: Int
    let multiplier: Int

    private let processor = VTFrameProcessor()
    private let sourcePool: CVPixelBufferPool
    private let destinationPool: CVPixelBufferPool
    private var copySession: VTPixelTransferSession?

    /// Largest frame (long edge / pixel count) Apple's interpolator accepts at 1:1 scale. Measured on an
    /// M3 Pro with macOS 27's `maximumDimension(forSpatialScaleFactor:)`: 1920 / 2 073 600. Kept as
    /// constants so the project also builds with the macOS 26 SDK (e.g. on CI runners).
    static func maxSize() -> (dimension: Int, pixels: Int) { (1920, 1920 * 1080) }

    static var isSupported: Bool { VTLowLatencyFrameInterpolationConfiguration.isSupported }

    /// Converts real and generated frames to RGB with the same shader as the GPU backend, so the
    /// brightness fix applies here too.
    private let converter: MetalInterpolator

    var color: ColorAdjust {
        get { converter.color }
        set { converter.color = newValue }
    }

    init(width: Int, height: Int, multiplier: Int) throws {
        guard Self.isSupported else { throw FrameGenError.unsupported }
        guard let config = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: multiplier - 1)
        else { throw FrameGenError.configFailed(width, height) }

        self.width = width
        self.height = height
        self.multiplier = multiplier
        try processor.startSession(configuration: config)

        func makePool(_ attrs: [String: Any]) throws -> CVPixelBufferPool {
            var pool: CVPixelBufferPool?
            let poolAttrs = [kCVPixelBufferPoolMinimumBufferCountKey as String: 8] as CFDictionary
            CVPixelBufferPoolCreate(nil, poolAttrs, attrs as CFDictionary, &pool)
            guard let pool else { throw FrameGenError.poolFailed }
            return pool
        }
        sourcePool = try makePool(config.sourcePixelBufferAttributes)
        destinationPool = try makePool(config.destinationPixelBufferAttributes)
        converter = try MetalInterpolator(width: width, height: height, multiplier: 2)
    }

    deinit { processor.endSession() }

    func prepare(_ buffer: CVPixelBuffer, forceCopy: Bool) -> CVPixelBuffer? {
        let usable = !forceCopy
            && CVPixelBufferGetWidth(buffer) == width
            && CVPixelBufferGetHeight(buffer) == height
            && CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            && CVPixelBufferGetIOSurface(buffer) != nil
        if usable { return buffer }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, sourcePool, &out)
        guard let out else { return nil }
        if copySession == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &copySession) }
        guard let copySession, VTPixelTransferSessionTransferImage(copySession, from: buffer, to: out) == noErr else { return nil }
        CVBufferPropagateAttachments(buffer, out)
        return out
    }

    func display(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA { return buffer }
        return converter.display(buffer)
    }

    /// VideoToolbox's session is configured for a fixed number of frames.
    var maxGenerated: Int { multiplier - 1 }

    func interpolate(previous: CVPixelBuffer, previousPTS: CMTime, current: CVPixelBuffer, currentPTS: CMTime,
                     count _: Int, completion: @escaping (Result<[CVPixelBuffer], Error>) -> Void) {
        guard let prevFrame = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: previousPTS),
              let curFrame = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: currentPTS)
        else { completion(.failure(FrameGenError.process("Couldn't wrap frames."))); return }

        let count = multiplier - 1
        let phases = (1...count).map { Float($0) / Float(multiplier) }
        let p0 = previousPTS.seconds, p1 = currentPTS.seconds

        var destinations: [VTFrameProcessorFrame] = []
        for phase in phases {
            var buf: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, destinationPool, &buf)
            let pts = CMTime(seconds: p0 + (p1 - p0) * Double(phase), preferredTimescale: 1_000_000)
            guard let buf, let frame = VTFrameProcessorFrame(buffer: buf, presentationTimeStamp: pts) else {
                completion(.failure(FrameGenError.poolFailed)); return
            }
            CVBufferPropagateAttachments(current, buf)
            destinations.append(frame)
        }

        guard let params = VTLowLatencyFrameInterpolationParameters(
            sourceFrame: curFrame, previousFrame: prevFrame,
            interpolationPhase: phases, destinationFrames: destinations)
        else { completion(.failure(FrameGenError.process("Couldn't build interpolation parameters."))); return }

        processor.process(parameters: params) { _, error in
            if let error { completion(.failure(error)) } else { completion(.success(destinations.map(\.buffer))) }
        }
    }
}
