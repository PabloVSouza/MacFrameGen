// Quality/speed benchmark on frames recorded with `--record <dir> <count>`.
// For each run of three real frames (A, M, B) it generates the frame between A and B and scores it
// against the real middle frame M (PSNR, higher is better).
// Usage: scripts/bench.sh framegen <recordDir> [outDir]   (record frames with --record <dir> 90)
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let dir = URL(fileURLWithPath: args[1])
let outDir = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil

func load(_ url: URL) -> CVPixelBuffer? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let w = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) })
    let h = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
    guard let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    data.withUnsafeBytes { raw in
        var off = 8
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            for r in 0..<CVPixelBufferGetHeightOfPlane(pb, plane) {
                memcpy(base + r * stride, raw.baseAddress! + off, w)
                off += w
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    return pb
}

func psnr(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
    let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
    let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let sa = CVPixelBufferGetBytesPerRow(a), sb = CVPixelBufferGetBytesPerRow(b)
    var se = 0.0
    for r in 0..<h {
        for c in 0..<(w * 4) where c % 4 != 3 {
            let d = Double(Int(pa[r * sa + c]) - Int(pb[r * sb + c]))
            se += d * d
        }
    }
    let mse = se / Double(w * h * 3)
    return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
}

func blend(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> CVPixelBuffer {
    var out: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(a), CVPixelBufferGetHeight(a), kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
    for p in [a, b, out!] { CVPixelBufferLockBaseAddress(p, []) }
    let n = CVPixelBufferGetBytesPerRow(a) * CVPixelBufferGetHeight(a)
    let x = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
    let y = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let z = CVPixelBufferGetBaseAddress(out!)!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<n { z[i] = UInt8((Int(x[i]) + Int(y[i]) + 1) / 2) }
    for p in [a, b, out!] { CVPixelBufferUnlockBaseAddress(p, []) }
    return out!
}

func save(_ b: CVPixelBuffer, _ name: String) {
    guard let outDir else { return }
    let ci = CIImage(cvPixelBuffer: b)
    guard let cg = CIContext().createCGImage(ci, from: ci.extent),
          let d = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(d, cg, nil)
    CGImageDestinationFinalize(d)
}

func run(_ interp: FrameInterpolating, _ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (CVPixelBuffer, Double) {
    let sem = DispatchSemaphore(value: 0)
    var mid: CVPixelBuffer?
    let t0 = CACurrentMediaTime()
    var t1 = 0.0
    let a = interp.prepare(a, forceCopy: false)!, b = interp.prepare(b, forceCopy: false)!
    interp.interpolate(previous: a, previousPTS: CMTime(value: 0, timescale: 30), current: b, currentPTS: CMTime(value: 2, timescale: 30), count: 1) {
        t1 = CACurrentMediaTime()
        if case let .success(m) = $0 { mid = m.first } else { print("error", $0) }
        sem.signal()
    }
    sem.wait()
    return (mid!, (t1 - t0) * 1000)
}

let files = (try FileManager.default.contentsOfDirectory(atPath: dir.path)).filter { $0.hasSuffix(".yuv") }.sorted()
let frames = files.compactMap { load(dir.appendingPathComponent($0)) }
let w = CVPixelBufferGetWidth(frames[0]), h = CVPixelBufferGetHeight(frames[0])
print("\(frames.count) frames \(w)x\(h)")

let metal = try MetalInterpolator(width: w, height: h, multiplier: 2)
let apple = try Interpolator(width: w, height: h, multiplier: 2)
let rgb = frames.map { metal.display($0)! }

var scores: [String: [Double]] = [:]
var times: [String: [Double]] = [:]
var worst = (index: 0, psnr: 99.0)
for i in 0..<(frames.count - 2) {
    let a = frames[i], b = frames[i + 2], truth = rgb[i + 1]
    let rp = psnr(rgb[i], truth)
    scores["repeat", default: []].append(rp)
    scores["blend", default: []].append(psnr(blend(rgb[i], rgb[i + 2]), truth))
    for (name, interp) in [("apple", apple as FrameInterpolating), ("shader", metal as FrameInterpolating)] {
        let (mid, ms) = run(interp, a, b)
        scores[name, default: []].append(psnr(metal.display(mid)!, truth))
        times[name, default: []].append(ms)
    }
    if rp < worst.psnr { worst = (i, rp) }
}

func median(_ x: [Double]) -> Double { let s = x.sorted(); return s[s.count / 2] }
func mean(_ x: [Double]) -> Double { x.reduce(0, +) / Double(x.count) }
for name in ["repeat", "blend", "apple", "shader"] {
    let s = scores[name]!
    var line = String(format: "%-7@ PSNR mean %.2f dB  median %.2f  worst %.2f", name as NSString, mean(s), median(s), s.min()!)
    if let t = times[name] { line += String(format: "   time median %.1f ms  max %.1f ms", median(Array(t.dropFirst(3))), t.dropFirst(3).max()!) }
    print(line)
}

// Save the hardest case (most motion) for a visual check.
let i = worst.index
print("most motion at triple \(i): repeat PSNR \(String(format: "%.2f", worst.psnr))")
save(rgb[i + 1], "truth.png")
save(metal.display(run(apple, frames[i], frames[i + 2]).0)!, "apple.png")
save(run(metal, frames[i], frames[i + 2]).0, "shader.png")
save(blend(rgb[i], rgb[i + 2]), "blend.png")

// Synthetic pans with real game texture: windows cut from one frame at x, x + D/2 and x + D,
// so the correct in-between frame is known exactly. Tests how far motion can be tracked.
func crop(_ src: CVPixelBuffer, x: Int, y: Int, w: Int, h: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(pb!, [])
    for plane in 0..<2 {
        let sb = CVPixelBufferGetBaseAddressOfPlane(src, plane)!, db = CVPixelBufferGetBaseAddressOfPlane(pb!, plane)!
        let ss = CVPixelBufferGetBytesPerRowOfPlane(src, plane), ds = CVPixelBufferGetBytesPerRowOfPlane(pb!, plane)
        let div = plane == 0 ? 1 : 2
        for r in 0..<(h / div) { memcpy(db + r * ds, sb + (y / div + r) * ss + (x / 2) * 2, w) }
    }
    CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(pb!, [])
    CVBufferPropagateAttachments(src, pb!)   // Apple's interpolator requires colour tags
    return pb!
}

let cw = 1280, ch = 720
let panMetal = try MetalInterpolator(width: cw, height: ch, multiplier: 2)
let panApple = try Interpolator(width: cw, height: ch, multiplier: 2)
let src = frames[min(70, frames.count - 1)]
print("\nsynthetic pan (\(cw)x\(ch) window of a real frame):")
for (dx, dy) in [(16, 0), (64, 0), (120, 16), (200, 40), (280, 0)] {
    let x0 = 20, y0 = 40
    let a = crop(src, x: x0, y: y0, w: cw, h: ch)
    let b = crop(src, x: x0 + dx, y: y0 + dy, w: cw, h: ch)
    let truth = panMetal.display(crop(src, x: x0 + dx / 2, y: y0 + dy / 2, w: cw, h: ch))!
    var line = String(format: "  move %3d,%3d px: repeat %.1f  blend %.1f", dx, dy,
                      psnr(panMetal.display(a)!, truth), psnr(blend(panMetal.display(a)!, panMetal.display(b)!), truth))
    for (name, interp) in [("apple", panApple as FrameInterpolating), ("shader", panMetal as FrameInterpolating)] {
        let (mid, ms) = run(interp, a, b)
        line += String(format: "  %@ %.1f dB (%.1f ms)", name as NSString, psnr(panMetal.display(mid)!, truth), ms)
        if dx == 200 { save(panMetal.display(mid)!, "pan200_\(name).png") }
    }
    if dx == 200 { save(truth, "pan200_truth.png") }
    print(line)
}
