// Validates ResolutionDetector. Usage: scripts/bench.sh resolution <recordDir> [clean]
// 1) Synthetic: real frames downscaled to a known size, then upscaled back (bilinear or bicubic),
//    must be detected at that size.  2) Raw: what the detector says about the recorded gameplay.
import Accelerate
import CoreVideo
import Foundation

func loadLuma(_ url: URL) -> (w: Int, h: Int, y: [UInt8]) {
    let data = try! Data(contentsOf: url)
    let w = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) })
    let h = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
    return (w, h, [UInt8](data[8..<(8 + w * h)]))
}

func makeBuffer(_ w: Int, _ h: Int, _ y: [UInt8]) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddressOfPlane(pb!, 0)!.assumingMemoryBound(to: UInt8.self)
    let st = CVPixelBufferGetBytesPerRowOfPlane(pb!, 0)
    for r in 0..<h { y.withUnsafeBufferPointer { memcpy(base + r * st, $0.baseAddress! + r * w, w) } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

/// Area-average downscale (what a renderer effectively produces), then upscale with a kernel.
func resample(_ y: [UInt8], _ w: Int, _ h: Int, to sw: Int, _ sh: Int, upscale: String) -> [UInt8] {
    // Smooth (Lanczos) downscale: like rendering at the low size, without adding periodic patterns.
    var small = [UInt8](repeating: 0, count: sw * sh)
    var src = y
    src.withUnsafeMutableBytes { sp in
        small.withUnsafeMutableBytes { dp in
            var s = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            var d = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(sh), width: vImagePixelCount(sw), rowBytes: sw)
            vImageScale_Planar8(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling))
        }
    }
    func at(_ x: Int, _ yy: Int) -> Double { Double(small[min(max(yy, 0), sh - 1) * sw + min(max(x, 0), sw - 1)]) }
    func cubic(_ t: Double) -> [Double] {   // Catmull-Rom
        let t2 = t * t, t3 = t2 * t
        return [(-t3 + 2 * t2 - t) / 2, (3 * t3 - 5 * t2 + 2) / 2, (-3 * t3 + 4 * t2 + t) / 2, (t3 - t2) / 2]
    }
    var out = [UInt8](repeating: 0, count: w * h)
    for r in 0..<h { for c in 0..<w {
        let fx = (Double(c) + 0.5) * Double(sw) / Double(w) - 0.5, fy = (Double(r) + 0.5) * Double(sh) / Double(h) - 0.5
        let ix = Int(floor(fx)), iy = Int(floor(fy)), tx = fx - floor(fx), ty = fy - floor(fy)
        var v = 0.0
        if upscale == "bilinear" {
            v = (at(ix, iy) * (1 - tx) + at(ix + 1, iy) * tx) * (1 - ty) + (at(ix, iy + 1) * (1 - tx) + at(ix + 1, iy + 1) * tx) * ty
        } else {
            let wx = cubic(tx), wy = cubic(ty)
            for j in 0..<4 { for i in 0..<4 { v += at(ix - 1 + i, iy - 1 + j) * wx[i] * wy[j] } }
        }
        out[r * w + c] = UInt8(max(0, min(255, v.rounded())))
    } }
    return out
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try! FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".yuv") }.sorted()
let det = ResolutionDetector()
func fmt(_ e: ResolutionDetector.Estimate) -> String { "\(e.width.map(String.init) ?? "—")×\(e.height.map(String.init) ?? "—")" }

print("raw gameplay frames:")
var raw: [String: Int] = [:]
for f in files.enumerated().filter({ $0.offset % 6 == 0 }).map(\.element) {
    let (w, h, y) = loadLuma(dir.appendingPathComponent(f))
    let t0 = Date()
    let e = det.estimate(makeBuffer(w, h, y))
    raw[fmt(e), default: 0] += 1
    if f == files[0] { print(String(format: "  (analysis time %.1f ms)", Date().timeIntervalSince(t0) * 1000)) }
}
for (k, v) in raw.sorted(by: { $0.value > $1.value }) { print("  \(k): \(v) frames") }

print("synthetic (known render size → detected):")
for idx in (CommandLine.arguments.count > 2 ? [0, 1, 2] : [10, 40, 70].filter { $0 < files.count }) {
    let (w, h, y) = loadLuma(dir.appendingPathComponent(files[idx]))
    var line = "  frame \(idx):"
    for (sw, sh) in [(1600, 900), (1440, 810), (1280, 720), (1152, 648), (960, 540)] {
        for kernel in ["bilinear", "bicubic"] {
            let e = det.estimate(makeBuffer(w, h, resample(y, w, h, to: sw, sh, upscale: kernel)))
            line += " \(sw)x\(sh)/\(kernel.prefix(3))→\(fmt(e))"
        }
    }
    print(line)
}

// Averaged over many frames (as the app does live: ~1 s of frames).
print("averaged over all frames in the folder:")
let all = files.map { loadLuma(dir.appendingPathComponent($0)) }
if CommandLine.arguments.count > 2 {
    for (sw, sh) in [(1600, 900), (1440, 810), (1280, 720), (1152, 648), (960, 540)] {
        var line = "  \(sw)x\(sh):"
        for kernel in ["bilinear", "bicubic"] {
            det.reset()
            for (w, h, y) in all { det.add(makeBuffer(w, h, resample(y, w, h, to: sw, sh, upscale: kernel))) }
            line += " \(kernel)→\(fmt(det.estimateAccumulated()))"
        }
        print(line)
    }
    det.reset()
    for (w, h, y) in all { det.add(makeBuffer(w, h, y)) }
    print("  native 1920x1080 → \(fmt(det.estimateAccumulated()))")
} else {
    for chunk in stride(from: 0, to: all.count, by: 30) {
        det.reset()
        for (w, h, y) in all[chunk..<min(chunk + 30, all.count)] { det.add(makeBuffer(w, h, y)) }
        print("  frames \(chunk)–\(min(chunk + 30, all.count) - 1) → \(fmt(det.estimateAccumulated()))")
    }
}
