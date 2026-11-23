import Accelerate
import CoreVideo
import Foundation

/// Estimates the resolution a game rendered at before the console upscaled it to the HDMI output.
///
/// Method (after the open-source `resdet` tool): resampling an image from n to N pixels leaves
/// narrow lines in its averaged DCT spectrum: at index n, and at multiples of 2N/p where N/n = p/q
/// in lowest terms (the resampling pattern repeats every p pixels). We average |DCT| over rows
/// (width) and columns (height) across ~1.5 s of frames, then pick the size whose family of lines
/// best matches.
///
/// Games often draw their HUD at full output resolution on top of a lower-resolution 3D scene,
/// and that crisp HUD swamps the traces when the whole frame is averaged (Persona 5 Royal: no
/// trace over the full frame, a very strong 1440×810 trace in the HUD-free middle). So the frame
/// is also split into 5 horizontal bands (for the width) and 5 vertical bands (for the height),
/// and the band with the clearest trace wins.
///
/// When no trace is found we don't know the render size: the game may render at the output size,
/// or use an upscaler that hides the traces (FSR 2, DLSS, heavy sharpening).
final class ResolutionDetector {
    struct Estimate: Equatable { var width: Int?; var height: Int? }

    static let bands = 5

    private var rowDCT: vDSP.DCT?
    private var colDCT: vDSP.DCT?
    private var rowLength = 0
    private var colLength = 0

    private var rowSums: [[Float]] = []   // per horizontal band
    private var colSums: [[Float]] = []   // per vertical band
    private var frameCount = 0
    private var size = (w: 0, h: 0)

    /// Analyse one frame on its own.
    func estimate(_ buffer: CVPixelBuffer) -> Estimate {
        reset()
        add(buffer)
        return estimateAccumulated()
    }

    /// Add a frame's spectra to the running averages. Image content differs from frame to frame
    /// while upscaling traces stay put, so averaging makes faint traces (e.g. 1600 → 1920) stand out.
    func add(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        if size != (w, h) { reset(); size = (w, h) }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let rows = rowSpectra(luma, w, h, stride), cols = colSpectra(luma, w, h, stride)
        rowSums = rowSums.isEmpty ? rows : zip(rowSums, rows).map { vDSP.add($0, $1) }
        colSums = colSums.isEmpty ? cols : zip(colSums, cols).map { vDSP.add($0, $1) }
        frameCount += 1
    }

    var accumulatedFrames: Int { frameCount }

    func reset() { rowSums = []; colSums = []; frameCount = 0 }

    /// Estimate from everything added since the last reset.
    func estimateAccumulated() -> Estimate {
        guard frameCount > 0, size.w > 0, !rowSums.isEmpty, !colSums.isEmpty else { return Estimate() }
        // Each band on its own, plus the whole frame (best for faint traces in HUD-free games).
        let rowCandidates = rowSums + [rowSums.dropFirst().reduce(rowSums[0]) { vDSP.add($0, $1) }]
        let colCandidates = colSums + [colSums.dropFirst().reduce(colSums[0]) { vDSP.add($0, $1) }]
        let rowLen = rowSums[0].count, colLen = colSums[0].count

        let w = rowCandidates.compactMap(findTrace).max { $0.score < $1.score }
            .map { Int((Double($0.index) * Double(size.w) / Double(rowLen)).rounded()) }
        var h = colCandidates.compactMap(findTrace).max { $0.score < $1.score }
            .map { Int((Double($0.index) * Double(size.h) / Double(colLen)).rounded()) }

        if let w {
            // Same aspect as the output: prefer the height the (more precise) width implies, as long
            // as some column band shows a trace there too.
            let fromWidth = Int((Double(w) * Double(size.h) / Double(size.w)).rounded())
            let index = Int((Double(fromWidth) * Double(colLen) / Double(size.h)).rounded())
            if let hh = h, abs(hh - fromWidth) <= max(4, fromWidth / 50) {
                h = fromWidth
            } else if colCandidates.contains(where: { hasTrace($0, near: index) }) {
                h = fromWidth
            }
        }
        return Estimate(width: w, height: h)
    }

    /// vDSP's DCT supports lengths f·2ⁿ (f ∈ {1, 3, 5, 15}, n ≥ 4); pick the longest that fits.
    static func dctLength(atMost n: Int) -> Int {
        var best = 16
        for f in [1, 3, 5, 15] {
            var len = f * 16
            while len * 2 <= n { len *= 2 }
            if len <= n { best = max(best, len) }
        }
        return best
    }

    /// |DCT| of every 2nd row, summed per horizontal band. A trace for a source n pixels wide
    /// sits at index len·n/w.
    private func rowSpectra(_ luma: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ stride: Int) -> [[Float]] {
        let len = Self.dctLength(atMost: w)
        if rowLength != len { rowDCT = vDSP.DCT(count: len, transformType: .II); rowLength = len }
        guard let dct = rowDCT else { return [] }
        let x0 = (w - len) / 2
        var spectra = [[Float]](repeating: [Float](repeating: 0, count: len), count: Self.bands)
        var input = [Float](repeating: 0, count: len)
        var output = [Float](repeating: 0, count: len)
        for r in Swift.stride(from: 0, to: h, by: 2) {
            let row = luma + r * stride + x0
            for i in 0..<len { input[i] = Float(row[i]) }
            dct.transform(input, result: &output)
            let b = min(r * Self.bands / h, Self.bands - 1)
            vDSP.add(spectra[b], vDSP.absolute(output), result: &spectra[b])
        }
        return spectra
    }

    /// |DCT| of every 2nd column (central `len` rows), summed per vertical band.
    private func colSpectra(_ luma: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ stride: Int) -> [[Float]] {
        let len = Self.dctLength(atMost: h)
        if colLength != len { colDCT = vDSP.DCT(count: len, transformType: .II); colLength = len }
        guard let dct = colDCT else { return [] }
        let y0 = (h - len) / 2
        var spectra = [[Float]](repeating: [Float](repeating: 0, count: len), count: Self.bands)
        var input = [Float](repeating: 0, count: len)
        var output = [Float](repeating: 0, count: len)
        for c in Swift.stride(from: 0, to: w, by: 2) {
            for i in 0..<len { input[i] = Float(luma[(y0 + i) * stride + c]) }
            dct.transform(input, result: &output)
            let b = min(c * Self.bands / w, Self.bands - 1)
            vDSP.add(spectra[b], vDSP.absolute(output), result: &spectra[b])
        }
        return spectra
    }

    /// The render size (as a spectrum index) that best explains the spectrum's narrow outliers,
    /// with its score. Each candidate with an outlier at its own index is scored by how many of
    /// its predicted lines are present (a 1600 → 1920 upscale also leaves a line at 1280, so the
    /// single strongest outlier isn't enough); the best-explained one wins.
    private func findTrace(_ spectrum: [Float]) -> (index: Int, score: Float)? {
        let z = outlierScores(spectrum)
        let n = spectrum.count
        func zNear(_ i: Int) -> Float { max(z[max(i - 1, 0)], z[i], z[min(i + 1, n - 1)]) }
        // Upscaling ratio n/c as a fraction with denominator p (the resampling period).
        func period(_ c: Int) -> Int { n / gcd(n, c) }
        var best: (index: Int, score: Float)?
        var seen = Set<Int>()
        for raw in 0..<n where z[raw] >= Self.threshold {
            // Snap to the neighbouring bin with the simplest ratio: real render sizes are "round".
            let c = (raw - 2...raw + 2).filter { $0 > 0 && $0 < n }.min { period($0) < period($1) } ?? raw
            guard seen.insert(c).inserted else { continue }
            var score = min(zNear(c), 30)
            let p = period(c)
            if p > 1, p <= 64 {
                for k in 1..<p {
                    let line = Int((Double(2 * n * k) / Double(p)).rounded())
                    if line >= n - 10 { break }
                    if abs(line - c) > 2, line > 10 {
                        let near = zNear(line)
                        if near >= Self.threshold { score += min(near, 30) }
                    }
                }
            }
            if score > (best?.score ?? 0) { best = (c, score) }
        }
        return best
    }

    /// Is there a trace at one specific, already-expected index? A single targeted check needs
    /// less evidence than a search over the whole spectrum, hence the lower bar.
    private func hasTrace(_ spectrum: [Float], near i: Int) -> Bool {
        let z = outlierScores(spectrum)
        return (i - 2...i + 2).contains { $0 >= 0 && $0 < z.count && z[$0] >= Self.threshold * 0.6 }
    }

    /// Robust z-score of each bin's deviation from its local median (log spectrum).
    private func outlierScores(_ spectrum: [Float]) -> [Float] {
        let n = spectrum.count
        let logS = spectrum.map { log($0 + 1e-3) }
        let lo = Int(Double(n) * 0.35), hi = Int(Double(n) * 0.97)
        var r = [Float](repeating: 0, count: n)
        for k in lo..<hi {
            let window = Array(logS[(k - 10)...(k + 10)]).sorted()
            r[k] = abs(logS[k] - window[10])
        }
        let mad = Array(r[lo..<hi]).sorted()[(hi - lo) / 2] * 1.4826
        guard mad > 0 else { return r }
        return r.map { $0 / mad }
    }

    private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    /// Outlier strength (robust z-score) needed to count as an upscaling trace.
    static var threshold: Float = 8
}
