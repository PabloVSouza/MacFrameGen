import AppKit
import CoreVideo
import Metal
import QuartzCore

/// Shows paced output frames, either in a normal resizable window (capture card) or as a
/// borderless click-through overlay sitting on top of a game window (screen capture).
///
/// Frames are drawn with Metal straight into a CAMetalLayer on each display refresh, with only two
/// drawables in flight, so nothing queues up between "frame is due" and "frame is on screen". In
/// full screen this also lets macOS send the layer directly to the display, skipping a compositor pass.
final class Presenter: NSObject, NSWindowDelegate {
    enum Mode { case window, overlay }
    private struct Item { let time: CFTimeInterval; let buffer: CVPixelBuffer; let captured: CFTimeInterval }

    let window: NSWindow
    let mode: Mode
    var onClose: (() -> Void)?

    private let view = MetalView()
    private var displayLink: CADisplayLink?
    private let lock = NSLock()
    private var queue: [Item] = []
    private var onScreen: CVPixelBuffer?   // keep the shown buffer alive while the GPU reads it
    private var shownCount = 0
    private var tickCount = 0
    private var behindTicks = 0
    private var lastTickTarget: CFTimeInterval = 0
    private var missedRefreshes = 0
    private var maxDrawableWait = 0.0
    private var latencySum = 0.0
    private var latencyCount = 0
    private var closing = false
    private let fpsLabel = NSTextField(labelWithString: "")

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let blitPSO: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    init(mode: Mode, frame: NSRect, title: String) {
        self.mode = mode
        switch mode {
        case .overlay:
            window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.sharingType = .none   // the overlay sits on the captured game window: hide it or we capture ourselves
        case .window:
            window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
            window.title = title
            window.contentAspectRatio = frame.size
            window.collectionBehavior = [.fullScreenPrimary]
            window.sharingType = .readOnly   // recordable (⌘⇧5, QuickTime, OBS); only the overlay must hide
        }
        window.isOpaque = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false

        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        let library = try! device.makeLibrary(source: Self.shader, options: nil)
        blitPSO = try! device.makeComputePipelineState(function: library.makeFunction(name: "fitBlit")!)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        let layer = view.metalLayer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false        // written by a compute shader
        // 3, not 2: in full screen the display keeps a drawable until its refresh is over, and with
        // only 2 the next one wasn't free in time (measured 15–23 ms waits → missed refreshes). We
        // still present exactly one frame per refresh, so the third adds no queueing.
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        window.contentView = view

        // FPS / latency readout in the top-left corner.
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        fpsLabel.textColor = .white
        fpsLabel.wantsLayer = true
        fpsLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        fpsLabel.layer?.cornerRadius = 6
        fpsLabel.isHidden = true
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fpsLabel)
        NSLayoutConstraint.activate([
            fpsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            fpsLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
        ])
        super.init()
        window.delegate = self
    }

    /// Presentation runs on its own high-priority thread: on the main thread, UI updates and window
    /// work occasionally delayed a refresh callback long enough to miss it.
    private var renderThread: Thread?

    func show() {
        if mode == .window { window.center(); window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
        updateDrawableSize()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        displayLink = link
        let thread = Thread {
            link.add(to: .current, forMode: .common)
            while !Thread.current.isCancelled { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        thread.name = "MacFrameGen presenter"
        thread.qualityOfService = .userInteractive
        thread.start()
        renderThread = thread
    }

    /// Drawable size follows the view; set on the main thread whenever the window changes.
    private func updateDrawableSize() {
        let scale = window.backingScaleFactor
        let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        if size.width >= 1, size.height >= 1, view.metalLayer.drawableSize != size { view.metalLayer.drawableSize = size }
    }

    func windowDidResize(_ notification: Notification) { updateDrawableSize() }
    func windowDidChangeBackingProperties(_ notification: Notification) { updateDrawableSize() }
    func windowDidExitFullScreen(_ notification: Notification) { updateDrawableSize() }

    func close() {
        closing = true
        displayLink?.invalidate()   // safe from any thread
        displayLink = nil
        renderThread?.cancel()
        renderThread = nil
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        window.orderOut(nil)
        lock.withLock { queue.removeAll() }
        onScreen = nil
    }

    /// Text for the corner readout; nil hides it.
    func setStatsText(_ text: String?) {
        fpsLabel.isHidden = text == nil
        fpsLabel.stringValue = text.map { " \($0) " } ?? ""
    }

    func windowWillClose(_ notification: Notification) {
        if !closing { onClose?() }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        updateDrawableSize()
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func setFrame(_ rect: NSRect) {
        if window.frame != rect { window.setFrame(rect, display: false); updateDrawableSize() }
    }

    /// Refresh rate of the screen the output is on (60 on most external monitors, 120 on ProMotion).
    var refreshRate: Int { window.screen?.maximumFramesPerSecond ?? 60 }

    /// Schedule frames: (display time, BGRA buffer, capture time). Frames can arrive out of order
    /// (a real frame may be queued while the previous interpolation is still running), so keep
    /// the queue sorted.
    func enqueue(_ batch: [(CFTimeInterval, CVPixelBuffer, CFTimeInterval)]) {
        lock.withLock {
            for (time, buffer, captured) in batch {
                let idx = queue.firstIndex { $0.time > time } ?? queue.count
                queue.insert(Item(time: time, buffer: buffer, captured: captured), at: idx)
            }
            // Safety valve: never hold more than ~half a second of frames.
            if queue.count > 60 { queue.removeFirst(queue.count - 60) }
        }
    }

    /// Frames actually put on screen since the last call.
    func takeShownCount() -> Int {
        lock.withLock { defer { shownCount = 0 }; return shownCount }
    }

    /// Display refreshes since the last call (should match the screen's Hz).
    func takeTickCount() -> Int {
        lock.withLock { defer { tickCount = 0 }; return tickCount }
    }

    /// Refreshes the display link skipped (callback arrived a refresh or more late), and the longest
    /// wait for a drawable, since the last call.
    func takePacingStats() -> (Int, Double) {
        lock.withLock {
            defer { missedRefreshes = 0; maxDrawableWait = 0 }
            return (missedRefreshes, maxDrawableWait * 1000)
        }
    }

    /// Average time from capture to the refresh that shows the frame, since the last call.
    func takeAverageLatency() -> Double {
        lock.withLock {
            defer { latencySum = 0; latencyCount = 0 }
            return latencyCount > 0 ? latencySum / Double(latencyCount) : 0
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        // One frame per refresh, oldest first, so a generated frame and the real frame that
        // follows it land on consecutive refreshes. Frames are only skipped when we've fallen
        // well behind (e.g. after a hitch), never just because the next one is also due.
        let deadline = link.targetTimestamp
        let refresh = max(link.targetTimestamp - link.timestamp, 1.0 / 240)
        let next: Item? = lock.withLock {
            tickCount += 1
            if lastTickTarget > 0, deadline - lastTickTarget > refresh * 1.5 {
                missedRefreshes += Int(((deadline - lastTickTarget) / refresh).rounded()) - 1
            }
            lastTickTarget = deadline
            // A big hitch (≥ 2.5 refreshes behind): catch up at once.
            while queue.count >= 2, queue[1].time <= deadline, queue[0].time < deadline - 2.5 * refresh {
                queue.removeFirst()
            }
            // A standing backlog of a frame or so would add that much latency forever, but dropping on
            // every bit of jitter stutters. Drop one frame only after ~20 refreshes in a row behind.
            if queue.count >= 2, queue[1].time <= deadline, queue[0].time <= deadline - 1.05 * refresh {
                behindTicks += 1
                if behindTicks >= 20 { queue.removeFirst(); behindTicks = 0 }
            } else {
                behindTicks = 0
            }
            guard let first = queue.first, first.time <= deadline else { return nil }
            queue.removeFirst()
            shownCount += 1
            latencySum += deadline - first.captured
            latencyCount += 1
            return first
        }
        guard let next else { return }
        draw(next.buffer)
    }

    private func draw(_ buffer: CVPixelBuffer) {
        let layer = view.metalLayer
        guard layer.drawableSize.width >= 1 else { return }   // size is kept up to date on the main thread

        guard let cache = textureCache else { return }
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTex)
        guard let cvTex, let src = CVMetalTextureGetTexture(cvTex),
              let drawable = timedNextDrawable(layer),
              let cb = commandQueue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(blitPSO)
        enc.setTexture(src, index: 0)
        enc.setTexture(drawable.texture, index: 1)
        let w = drawable.texture.width, h = drawable.texture.height
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: blitPSO.threadExecutionWidth, height: 8, depth: 1))
        enc.endEncoding()
        cb.present(drawable)
        let keep = (buffer, cvTex)
        cb.addCompletedHandler { _ in _ = keep }
        cb.commit()
        onScreen = buffer
    }

    private func timedNextDrawable(_ layer: CAMetalLayer) -> CAMetalDrawable? {
        let t0 = CACurrentMediaTime()
        let d = layer.nextDrawable()
        let waited = CACurrentMediaTime() - t0
        lock.withLock { maxDrawableWait = max(maxDrawableWait, waited) }
        return d
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    // Aspect-fit the frame into the drawable with bilinear scaling; black bars outside.
    kernel void fitBlit(texture2d<float, access::sample> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
        float dw = dst.get_width(), dh = dst.get_height();
        if (gid.x >= uint(dw) || gid.y >= uint(dh)) return;
        float sw = src.get_width(), sh = src.get_height();
        float s = min(dw / sw, dh / sh);
        float2 size = float2(sw, sh) * s;
        float2 origin = (float2(dw, dh) - size) * 0.5;
        float2 uv = (float2(gid) + 0.5 - origin) / size;
        constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_zero);
        float4 c = (any(uv < 0.0) || any(uv > 1.0)) ? float4(0, 0, 0, 1) : src.sample(lin, uv);
        dst.write(float4(c.rgb, 1), gid);
    }
    """
}

/// A layer-hosting view backed by a CAMetalLayer.
final class MetalView: NSView {
    let metalLayer = CAMetalLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = metalLayer
        wantsLayer = true
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { metalLayer }
}
