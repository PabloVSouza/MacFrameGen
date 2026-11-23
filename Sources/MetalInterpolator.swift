import CoreMedia
import CoreVideo
import Metal
import VideoToolbox

/// Fast frame generation written as Metal compute shaders (no ML model):
///  1. luma pyramids of both frames (1/2 … 1/16 resolution),
///  2. coarse-to-fine *bilateral* block matching: for each 8×8 block of the in-between frame, find
///     the motion v that best matches frame A at p − v/2 with frame B at p + v/2 (so every output
///     pixel has a vector, no holes), smoothed with a vector median at each level,
///  3. per output pixel, pick the best of a few candidate vectors (smooth field, the 4 nearest
///     blocks, or "not moving" for static HUD) using a 3×3 patch match, then blend A and B along
///     that path and convert straight to BGRA for display.
final class MetalInterpolator: FrameInterpolating {
    let width: Int
    let height: Int
    let multiplier: Int

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let downsamplePSO, searchPSO, medianPSO, selectPSO, synthPSO, convertPSO: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private let sourcePool: CVPixelBufferPool
    private let outputPool: CVPixelBufferPool
    private var copySession: VTPixelTransferSession?

    private struct Level { let width: Int; let height: Int; let blocksX: Int; let blocksY: Int }
    private let levels: [Level]                 // index 0 = full res … last = coarsest
    private let pyramidA: [MTLTexture]          // levels 1…n (level 0 is the Y plane itself)
    private let pyramidB: [MTLTexture]
    private let vectors: [MTLTexture]           // per level 1…n, rg32Float, full-res pixel units
    private let vectorsTemp: [MTLTexture]
    private let selected: MTLTexture            // per-pixel vector at half resolution
    private let finestLevel = 1                 // motion field resolution: 16×16 px blocks
    private let blockSize = 8

    static var isSupported: Bool { MTLCreateSystemDefaultDevice() != nil }

    /// Brightness/saturation applied when converting to RGB (both real and generated frames).
    var color: ColorAdjust {
        get { colorLock.withLock { _color } }
        set { colorLock.withLock { _color = newValue } }
    }
    private var _color = ColorAdjust()
    private let colorLock = NSLock()

    init(width: Int, height: Int, multiplier: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw FrameGenError.process("Metal isn't available.")
        }
        self.device = device
        self.queue = queue
        self.width = width
        self.height = height
        self.multiplier = multiplier

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        func pso(_ name: String) throws -> MTLComputePipelineState {
            try device.makeComputePipelineState(function: library.makeFunction(name: name)!)
        }
        downsamplePSO = try pso("downsample")
        searchPSO = try pso("motionSearch")
        medianPSO = try pso("vectorMedian")
        selectPSO = try pso("selectVectors")
        synthPSO = try pso("synthesize")
        convertPSO = try pso("convert")
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        // Pyramid down to roughly 120 px wide.
        var lv: [Level] = []
        var w = width, h = height
        while true {
            lv.append(Level(width: w, height: h, blocksX: (w + 7) / 8, blocksY: (h + 7) / 8))
            if w <= 128 || lv.count == 6 { break }
            w = (w + 1) / 2
            h = (h + 1) / 2
        }
        levels = lv

        func tex(_ w: Int, _ h: Int, _ f: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        pyramidA = lv.dropFirst().map { tex($0.width, $0.height, .r16Float) }
        pyramidB = lv.dropFirst().map { tex($0.width, $0.height, .r16Float) }
        vectors = lv.dropFirst().map { tex($0.blocksX, $0.blocksY, .rg32Float) }
        vectorsTemp = lv.dropFirst().map { tex($0.blocksX, $0.blocksY, .rg32Float) }
        selected = tex(lv[1].width, lv[1].height, .rg16Float)

        func pool(_ format: OSType) throws -> CVPixelBufferPool {
            var p: CVPixelBufferPool?
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 8] as CFDictionary,
                                    attrs as CFDictionary, &p)
            guard let p else { throw FrameGenError.poolFailed }
            return p
        }
        sourcePool = try pool(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        outputPool = try pool(kCVPixelFormatType_32BGRA)
    }

    // MARK: - FrameInterpolating

    func prepare(_ buffer: CVPixelBuffer, forceCopy: Bool) -> CVPixelBuffer? {
        let usable = !forceCopy
            && CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height
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

    /// Converts a real frame with the same shader math as generated frames, so colours match exactly.
    func display(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA { return buffer }
        guard let (y, c, keepIn) = planes(buffer), let (out, outTex, keepOut) = makeOutput(),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(convertPSO)
        var colorParams = color
        enc.setBytes(&colorParams, length: MemoryLayout<ColorAdjust>.stride, index: 1)
        enc.setTexture(y, index: 0)
        enc.setTexture(c, index: 1)
        enc.setTexture(outTex, index: 2)
        dispatch(enc, convertPSO, width, height)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        _ = (keepIn, keepOut)
        return out
    }

    /// Each extra in-between frame costs only the per-pixel passes (~1 ms at 1080p).
    let maxGenerated = 5

    func interpolate(previous: CVPixelBuffer, previousPTS: CMTime, current: CVPixelBuffer, currentPTS: CMTime,
                     count: Int, completion: @escaping (Result<[CVPixelBuffer], Error>) -> Void) {
        let count = min(max(count, 1), maxGenerated)
        guard let (ay, ac, keepA) = planes(previous), let (by, bc, keepB) = planes(current),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder()
        else { completion(.failure(FrameGenError.process("Couldn't map frames to Metal."))); return }

        // 1. Pyramids.
        enc.setComputePipelineState(downsamplePSO)
        for (pyr, src) in [(pyramidA, ay), (pyramidB, by)] {
            var input: MTLTexture = src
            for (i, t) in pyr.enumerated() {
                enc.setTexture(input, index: 0)
                enc.setTexture(t, index: 1)
                dispatch(enc, downsamplePSO, levels[i + 1].width, levels[i + 1].height)
                input = t
            }
        }

        // 2. Coarse-to-fine bilateral block matching, median-smoothed at every level.
        let coarsest = levels.count - 1
        for l in stride(from: coarsest, through: finestLevel, by: -1) {
            let lv = levels[l]
            var p = SearchParams(blocksX: UInt32(lv.blocksX), blocksY: UInt32(lv.blocksY),
                                 priorBlocksX: l < coarsest ? UInt32(levels[l + 1].blocksX) : 0,
                                 priorBlocksY: l < coarsest ? UInt32(levels[l + 1].blocksY) : 0,
                                 scale: Float(1 << l), radius: l == coarsest ? 12 : (l == finestLevel ? 1 : (l == coarsest - 1 ? 3 : 2)),
                                 hasPrior: l < coarsest ? 1 : 0, lambda: 0.004)
            enc.setComputePipelineState(searchPSO)
            enc.setTexture(pyramidA[l - 1], index: 0)
            enc.setTexture(pyramidB[l - 1], index: 1)
            enc.setTexture(l < coarsest ? vectors[l] : vectors[l - 1], index: 2)   // prior (coarser) field
            enc.setTexture(vectorsTemp[l - 1], index: 3)
            enc.setBytes(&p, length: MemoryLayout<SearchParams>.stride, index: 0)
            // One threadgroup per block; its threads split the candidate vectors between them.
            enc.dispatchThreadgroups(MTLSize(width: lv.blocksX, height: lv.blocksY, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: Self.searchThreads, height: 1, depth: 1))

            enc.setComputePipelineState(medianPSO)
            enc.setTexture(vectorsTemp[l - 1], index: 0)
            enc.setTexture(vectors[l - 1], index: 1)
            dispatch(enc, medianPSO, lv.blocksX, lv.blocksY)
        }

        // 3. One output per in-between phase.
        var outputs: [CVPixelBuffer] = []
        var keepOut: [Any] = []
        let fine = levels[finestLevel]
        for k in 1...count {
            guard let (out, outTex, keep) = makeOutput() else { continue }
            outputs.append(out)
            keepOut.append(keep)
            var p = SynthParams(t: Float(k) / Float(count + 1), blockSize: Float(blockSize << finestLevel),
                                blocksX: Int32(fine.blocksX), blocksY: Int32(fine.blocksY), errThreshold: 0.12)
            enc.setComputePipelineState(selectPSO)
            enc.setTexture(pyramidA[0], index: 0)
            enc.setTexture(pyramidB[0], index: 1)
            enc.setTexture(vectors[finestLevel - 1], index: 2)
            enc.setTexture(selected, index: 3)
            enc.setBytes(&p, length: MemoryLayout<SynthParams>.stride, index: 0)
            dispatch(enc, selectPSO, levels[1].width, levels[1].height)

            enc.setComputePipelineState(synthPSO)
            var colorParams = color
            enc.setBytes(&colorParams, length: MemoryLayout<ColorAdjust>.stride, index: 1)
            enc.setTexture(ay, index: 0); enc.setTexture(ac, index: 1)
            enc.setTexture(by, index: 2); enc.setTexture(bc, index: 3)
            enc.setTexture(selected, index: 4)
            enc.setTexture(outTex, index: 5)
            enc.setBytes(&p, length: MemoryLayout<SynthParams>.stride, index: 0)
            dispatch(enc, synthPSO, width, height)
        }
        enc.endEncoding()
        cb.addCompletedHandler { cb in
            _ = (keepA, keepB, keepOut)
            if let error = cb.error { completion(.failure(error)) } else { completion(.success(outputs)) }
        }
        cb.commit()
    }

    // MARK: - Helpers

    private static let searchThreads = 128

    private struct SearchParams {
        var blocksX, blocksY, priorBlocksX, priorBlocksY: UInt32
        var scale: Float
        var radius: Int32
        var hasPrior: Int32
        var lambda: Float
    }

    private struct SynthParams {
        var t: Float
        var blockSize: Float
        var blocksX, blocksY: Int32
        var errThreshold: Float
    }

    private func planes(_ buffer: CVPixelBuffer) -> (MTLTexture, MTLTexture, [CVMetalTexture])? {
        guard let cache = textureCache else { return nil }
        var y: CVMetalTexture?, c: CVMetalTexture?
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .r8Unorm, w, h, 0, &y)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .rg8Unorm,
                                                  CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 1), 1, &c)
        guard let y, let c, let yt = CVMetalTextureGetTexture(y), let ct = CVMetalTextureGetTexture(c) else { return nil }
        return (yt, ct, [y, c])
    }

    private func makeOutput() -> (CVPixelBuffer, MTLTexture, CVMetalTexture)? {
        guard let cache = textureCache else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, outputPool, &out)
        guard let out else { return nil }
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, out, nil, .bgra8Unorm, width, height, 0, &t)
        guard let t, let tex = CVMetalTextureGetTexture(t) else { return nil }
        return (out, tex, t)
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, _ w: Int, _ h: Int) {
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: min(th, 8), depth: 1))
    }

    // MARK: - Shaders

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constexpr sampler lin(coord::pixel, filter::linear, address::clamp_to_edge);

    // 2× box downsample (bilinear sample at the shared corner of 4 texels = their average).
    kernel void downsample(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        dst.write(float4(src.sample(lin, float2(gid) * 2.0 + 1.0).r), gid);
    }

    struct SearchParams { uint blocksX, blocksY, priorBlocksX, priorBlocksY; float scale; int radius; int hasPrior; float lambda; };

    // Mean absolute luma difference of an 8×8 block, A sampled at p − v/2 and B at p + v/2.
    static float blockCost(texture2d<float, access::sample> a, texture2d<float, access::sample> b, float2 origin, float2 v) {
        float s = 0;
        float2 h = 0.5 * v;
        for (int y = 0; y < 8; y += 1) {
            for (int x = 0; x < 8; x += 1) {
                float2 p = origin + float2(x, y) + 0.5;
                s += fabs(a.sample(lin, p - h).r - b.sample(lin, p + h).r);
            }
        }
        return s * (1.0 / 64.0);
    }

    #define SEARCH_THREADS 128

    kernel void motionSearch(texture2d<float, access::sample> a [[texture(0)]],
                             texture2d<float, access::sample> b [[texture(1)]],
                             texture2d<float, access::read> prior [[texture(2)]],
                             texture2d<float, access::write> dst [[texture(3)]],
                             constant SearchParams& P [[buffer(0)]],
                             uint2 block [[threadgroup_position_in_grid]],
                             uint tid [[thread_index_in_threadgroup]]) {
        threadgroup float bestCost[SEARCH_THREADS];
        threadgroup float2 bestVec[SEARCH_THREADS];
        float2 origin = float2(block) * 8.0;

        // Candidates (in this level's pixels): zero, plus the coarser field at this block and its neighbours.
        float2 cands[6];
        int n = 0;
        cands[n++] = float2(0);
        float2 pred = float2(0);
        if (P.hasPrior) {
            int2 pb = int2(block / 2);
            int2 maxB = int2(P.priorBlocksX - 1, P.priorBlocksY - 1);
            pred = prior.read(uint2(clamp(pb, int2(0), maxB))).xy / P.scale;
            cands[n++] = pred;
            cands[n++] = prior.read(uint2(clamp(pb + int2(1, 0), int2(0), maxB))).xy / P.scale;
            cands[n++] = prior.read(uint2(clamp(pb - int2(1, 0), int2(0), maxB))).xy / P.scale;
            cands[n++] = prior.read(uint2(clamp(pb + int2(0, 1), int2(0), maxB))).xy / P.scale;
            cands[n++] = prior.read(uint2(clamp(pb - int2(0, 1), int2(0), maxB))).xy / P.scale;
        }

        // Each thread tests every SEARCH_THREADS-th (candidate, offset) pair.
        int side = 2 * P.radius + 1;
        int perCand = side * side;
        int total = n * perCand;
        float best = 1e9;
        float2 bestV = float2(0);
        for (int i = int(tid); i < total; i += SEARCH_THREADS) {
            int c = i / perCand, o = i % perCand;
            float2 v = round(cands[c]) + float2(o % side - P.radius, o / side - P.radius);
            float cost = blockCost(a, b, origin, v) + P.lambda * length(v - pred);
            if (all(v == 0)) cost -= 0.002;   // tie-break toward "not moving"
            if (cost < best) { best = cost; bestV = v; }
        }
        bestCost[tid] = best;
        bestVec[tid] = bestV;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = SEARCH_THREADS / 2; stride > 0; stride /= 2) {
            if (tid < stride && bestCost[tid + stride] < bestCost[tid]) {
                bestCost[tid] = bestCost[tid + stride];
                bestVec[tid] = bestVec[tid + stride];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (tid == 0 && block.x < P.blocksX && block.y < P.blocksY) dst.write(float4(bestVec[0] * P.scale, 0, 0), block);
    }

    // 3×3 vector median: the neighbour whose summed distance to the others is smallest.
    kernel void vectorMedian(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        int w = src.get_width(), h = src.get_height();
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        float2 v[9];
        int k = 0;
        for (int dy = -1; dy <= 1; dy++)
            for (int dx = -1; dx <= 1; dx++)
                v[k++] = src.read(uint2(clamp(int2(gid) + int2(dx, dy), int2(0), int2(w - 1, h - 1)))).xy;
        float best = 1e9; float2 bv = v[4];
        for (int i = 0; i < 9; i++) {
            float s = 0;
            for (int j = 0; j < 9; j++) s += distance(v[i], v[j]);
            if (s < best) { best = s; bv = v[i]; }
        }
        dst.write(float4(bv, 0, 0), gid);
    }

    struct ColorAdjust { float strength; float saturation; };

    // Undo the Elgato Game Capture Neo's HDR → SDR tone mapping (console HDR on). The card adapts its
    // tone mapping to the content, so this was fitted on two PS5 captures, each recorded with HDR off
    // and on: the system UI and GTA VI gameplay. A smooth cubic applied to R′, G′ and B′, pinned at
    // f(0) = 0 and f(1) = 1 so highlights keep gradation up to white (an earlier binned lookup table
    // was jagged, which banded gradients, and clipped everything above 94 %). Then saturation ×0.958.
    // Held-out error (0–255): UI 19.8 vs 32.1 uncorrected, game 13.7 vs 26.7.
    static float undoToneMap(float v) {
        float x = saturate(v);
        return x * (1.7382 + x * (-1.0329 + x * 0.2947));
    }

    // Video-range BT.709 Y'CbCr → R'G'B', then (strength > 0) the tone-mapping fix above, with
    // ±½-level dither so the curve's shadow lift doesn't band smooth 8-bit gradients.
    static float4 toRGB(float y, float2 cbcr, constant ColorAdjust& C, uint2 gid) {
        float Y = (y * 255.0 - 16.0) / 219.0;
        float Cb = (cbcr.x * 255.0 - 128.0) / 224.0;
        float Cr = (cbcr.y * 255.0 - 128.0) / 224.0;
        float3 rgb = saturate(float3(Y + 1.5748 * Cr, Y - 0.1873 * Cb - 0.4681 * Cr, Y + 1.8556 * Cb));
        if (C.strength > 0.0) {
            float3 fixedRGB = float3(undoToneMap(rgb.r), undoToneMap(rgb.g), undoToneMap(rgb.b));
            float l = dot(fixedRGB, float3(0.2126, 0.7152, 0.0722));
            fixedRGB = l + (fixedRGB - l) * C.saturation;
            rgb = mix(rgb, fixedRGB, C.strength);
            float noise = fract(52.9829189 * fract(dot(float2(gid), float2(0.06711056, 0.00583715))));  // interleaved gradient noise
            rgb += (noise - 0.5) / 255.0;
        }
        return float4(saturate(rgb), 1.0);
    }

    kernel void convert(texture2d<float, access::sample> y [[texture(0)]],
                        texture2d<float, access::sample> c [[texture(1)]],
                        texture2d<float, access::write> out [[texture(2)]],
                        constant ColorAdjust& C [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float2 p = float2(gid) + 0.5;
        out.write(toRGB(y.sample(lin, p).r, c.sample(lin, p * 0.5).rg, C, gid), gid);
    }

    struct SynthParams { float t; float blockSize; int blocksX, blocksY; float errThreshold; };

    // 3×3 patch difference (half-res luma) between A at p − t·v and B at p + (1 − t)·v.
    static float patchCost(texture2d<float, access::sample> a, texture2d<float, access::sample> b, float2 p, float2 v, float t) {
        float2 pa = p - t * v, pb = p + (1.0 - t) * v;
        float s = 0;
        for (int dy = -1; dy <= 1; dy++)
            for (int dx = -1; dx <= 1; dx++) {
                float2 o = float2(dx, dy);
                s += fabs(a.sample(lin, pa + o).r - b.sample(lin, pb + o).r);
            }
        return s;
    }

    // Per pixel (at half resolution), pick the vector that best explains it: the smooth field,
    // one of the 4 nearest blocks, or "not moving" (static HUD over a moving scene).
    kernel void selectVectors(texture2d<float, access::sample> a [[texture(0)]],
                              texture2d<float, access::sample> b [[texture(1)]],
                              texture2d<float, access::read> mv [[texture(2)]],
                              texture2d<float, access::write> dst [[texture(3)]],
                              constant SynthParams& P [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 p = float2(gid) + 0.5;                 // half-res pixel
        float2 bcoord = p * 2.0 / P.blockSize - 0.5;  // block grid (block size is in full-res px)
        int2 b0 = int2(floor(bcoord));
        float2 f = bcoord - float2(b0);
        int2 maxB = int2(P.blocksX - 1, P.blocksY - 1);
        float2 v00 = mv.read(uint2(clamp(b0, int2(0), maxB))).xy;
        float2 v10 = mv.read(uint2(clamp(b0 + int2(1, 0), int2(0), maxB))).xy;
        float2 v01 = mv.read(uint2(clamp(b0 + int2(0, 1), int2(0), maxB))).xy;
        float2 v11 = mv.read(uint2(clamp(b0 + int2(1, 1), int2(0), maxB))).xy;
        float2 vs = mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y);

        float2 cands[6] = { vs, v00, v10, v01, v11, float2(0) };
        float bias[6] = { 0.0, 0.03, 0.03, 0.03, 0.03, 0.02 };
        float best = 1e9; float2 v = vs;
        for (int i = 0; i < 6; i++) {
            float cost = patchCost(a, b, p, cands[i] * 0.5, P.t) + bias[i];
            if (cost < best) { best = cost; v = cands[i]; }
        }
        dst.write(float4(v, 0, 0), gid);
    }

    kernel void synthesize(texture2d<float, access::sample> ay [[texture(0)]],
                           texture2d<float, access::sample> ac [[texture(1)]],
                           texture2d<float, access::sample> by [[texture(2)]],
                           texture2d<float, access::sample> bc [[texture(3)]],
                           texture2d<float, access::read> sel [[texture(4)]],
                           texture2d<float, access::write> out [[texture(5)]],
                           constant SynthParams& P [[buffer(0)]],
                           constant ColorAdjust& C [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float2 p = float2(gid) + 0.5;
        float t = P.t;
        float2 v = sel.read(min(gid / 2, uint2(sel.get_width() - 1, sel.get_height() - 1))).xy;

        float2 pa = p - t * v, pb = p + (1.0 - t) * v;
        float ya = ay.sample(lin, pa).r, yb = by.sample(lin, pb).r;
        float2 ca = ac.sample(lin, pa * 0.5).rg, cb = bc.sample(lin, pb * 0.5).rg;

        // Where the two sides disagree (occlusion), lean on the frame nearer in time.
        float wa = 1.0 - t;
        float k = smoothstep(P.errThreshold, 2.0 * P.errThreshold, fabs(ya - yb));
        wa = mix(wa, t < 0.5 ? 1.0 : 0.0, k);
        out.write(toRGB(mix(yb, ya, wa), mix(cb, ca, wa), C, gid), gid);
    }
    """
}
