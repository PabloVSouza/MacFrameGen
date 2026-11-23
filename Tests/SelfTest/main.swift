// Self-tests that need no capture card: run with scripts/test.sh (also in CI).
// Exits with status 1 if any check fails. GPU checks are skipped when Metal isn't available.
import CoreMedia
import CoreVideo
import Foundation
import Metal

var failures = 0
func check(_ ok: Bool, _ name: String, _ detail: String) {
    print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
    if !ok { failures += 1 }
}

// A deterministic, detailed test picture: layered value noise (smooth at every scale, like a photo).
func texture(width: Int, height: Int, seed: UInt64) -> [UInt8] {
    var state = seed
    func rand() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(1 << 53) }
    var img = [Double](repeating: 0, count: width * height)
    for (cell, amp) in [(160, 60.0), (40, 40.0), (10, 25.0), (3, 12.0)] {
        let gw = width / cell + 2, gh = height / cell + 2
        let grid = (0..<(gw * gh)).map { _ in rand() }
        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x) / Double(cell), fy = Double(y) / Double(cell)
                let ix = Int(fx), iy = Int(fy), tx = fx - Double(ix), ty = fy - Double(iy)
                let a = grid[iy * gw + ix], b = grid[iy * gw + ix + 1], c = grid[(iy + 1) * gw + ix], d = grid[(iy + 1) * gw + ix + 1]
                img[y * width + x] += amp * ((a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty)
            }
        }
    }
    return img.map { UInt8(max(16, min(235, 30 + $0))) }
}

func resampleBilinear(_ src: [UInt8], _ w: Int, _ h: Int, to nw: Int, _ nh: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: nw * nh)
    for y in 0..<nh {
        for x in 0..<nw {
            let fx = max(0, (Double(x) + 0.5) * Double(w) / Double(nw) - 0.5), fy = max(0, (Double(y) + 0.5) * Double(h) / Double(nh) - 0.5)
            let ix = min(Int(fx), w - 2), iy = min(Int(fy), h - 2), tx = fx - Double(ix), ty = fy - Double(iy)
            let v = (Double(src[iy * w + ix]) * (1 - tx) + Double(src[iy * w + ix + 1]) * tx) * (1 - ty)
                + (Double(src[(iy + 1) * w + ix]) * (1 - tx) + Double(src[(iy + 1) * w + ix + 1]) * tx) * ty
            out[y * nw + x] = UInt8(v.rounded())
        }
    }
    return out
}

func buffer(_ luma: [UInt8], _ w: Int, _ h: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    luma.withUnsafeBufferPointer { src in
        for r in 0..<h { memcpy(y + r * ys, src.baseAddress! + r * w, w) }
    }
    memset(CVPixelBufferGetBaseAddressOfPlane(b, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(b, 1) * h / 2)
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

// 1. Render-resolution estimate (CPU only).
let W = 1920, H = 1080
let detector = ResolutionDetector()
for seed: UInt64 in 1...6 {   // several pictures, as the app averages ~1.5 s of frames
    let low = resampleBilinear(texture(width: W, height: H, seed: seed), W, H, to: 1280, 720)
    detector.add(buffer(resampleBilinear(low, 1280, 720, to: W, H), W, H))
}
let est = detector.estimateAccumulated()
check(est.width == 1280 && est.height == 720, "resolution: 1280×720 upscale",
      "detected \(est.width.map(String.init) ?? "–")×\(est.height.map(String.init) ?? "–")")
detector.reset()
for seed: UInt64 in 1...6 { detector.add(buffer(texture(width: W, height: H, seed: seed), W, H)) }
let est2 = detector.estimateAccumulated()
check(est2.width == nil, "resolution: native 1080p", "detected width \(est2.width.map(String.init) ?? "none")")

// GPU checks.
if MTLCreateSystemDefaultDevice() == nil {
    print("SKIP  GPU checks: no Metal device")
} else {
    // 2. Frame generation on a known pan: the generated frame must clearly beat a plain blend.
    let cw = 1280, ch = 720, shift = 64
    let big = texture(width: cw + shift, height: ch, seed: 42)
    func window(_ x0: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(cw * ch)
        for r in 0..<ch {
            let start = r * (cw + shift) + x0
            out.append(contentsOf: big[start..<(start + cw)])
        }
        return out
    }
    let a = buffer(window(0), cw, ch), b = buffer(window(shift), cw, ch), truth = window(shift / 2)
    let interp = try MetalInterpolator(width: cw, height: ch, multiplier: 2)
    let sem = DispatchSemaphore(value: 0)
    var mid: CVPixelBuffer?
    interp.interpolate(previous: a, previousPTS: CMTime(value: 0, timescale: 30), current: b,
                       currentPTS: CMTime(value: 1, timescale: 30), count: 1) { result in
        if case let .success(frames) = result { mid = frames.first }
        sem.signal()
    }
    sem.wait()
    func psnr(_ img: [Double], _ ref: [UInt8]) -> Double {
        let mse = zip(img, ref).map { ($0 - Double($1)) * ($0 - Double($1)) }.reduce(0, +) / Double(ref.count)
        return 10 * log10(255 * 255 / max(mse, 1e-9))
    }
    // Generated frame is BGRA; with neutral chroma its green channel ≈ luma mapped to full range.
    if let mid {
        CVPixelBufferLockBaseAddress(mid, .readOnly)
        let p = CVPixelBufferGetBaseAddress(mid)!.assumingMemoryBound(to: UInt8.self), st = CVPixelBufferGetBytesPerRow(mid)
        let gen = (0..<(cw * ch)).map { i in Double(p[(i / cw) * st + (i % cw) * 4 + 1]) * 219 / 255 + 16 }
        CVPixelBufferUnlockBaseAddress(mid, .readOnly)
        let blend = zip(window(0), window(shift)).map { (Double($0) + Double($1)) / 2 }
        let g = psnr(gen, truth), bl = psnr(blend, truth)
        check(g > bl + 5, "frame generation: 64 px pan", String(format: "%.1f dB vs %.1f dB for a blend", g, bl))
    } else {
        check(false, "frame generation: 64 px pan", "no frame produced")
    }

    // 3. Console-HDR fix: black stays black, white stays white, ramp stays monotonic.
    let ramp = (0..<cw).map { UInt8(16 + 219 * $0 / (cw - 1)) }
    let rampImg = buffer((0..<ch).flatMap { _ in ramp }, cw, ch)
    interp.color = ColorAdjust(strength: 1)
    if let out = interp.display(rampImg) {
        CVPixelBufferLockBaseAddress(out, .readOnly)
        let p = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(out) * 100
        let g = (0..<cw).map { Int(p[row + $0 * 4 + 1]) }
        CVPixelBufferUnlockBaseAddress(out, .readOnly)
        // Smooth over the ±½-level dither before checking monotonicity.
        let smooth = (0..<(cw - 8)).map { i in g[i..<(i + 8)].reduce(0, +) }
        let monotonic = zip(smooth, smooth.dropFirst()).allSatisfy { $1 >= $0 - 8 }
        check(g.first! <= 1 && g.last! >= 254 && monotonic, "HDR fix curve",
              "black \(g.first!), white \(g.last!), monotonic \(monotonic)")
    }
}

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
