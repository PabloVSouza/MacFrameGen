import AVFoundation
import ScreenCaptureKit
import SwiftUI

@main
struct MacFrameGenApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("MacFrameGen", id: "main") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Frame Gen") {
                Button(model.running ? "Stop" : "Start") { model.toggleRunning() }
                    .keyboardShortcut(.return, modifiers: .command)
                Toggle("Frame Generation", isOn: $model.interpolationEnabled)
                    .keyboardShortcut("g", modifiers: .command)
                Toggle("Show FPS", isOn: $model.showFPSOverlay)
                    .keyboardShortcut("f", modifiers: .command)
            }
        }

        MenuBarExtra("MacFrameGen", systemImage: "film.stack") {
            Button(model.running ? "Stop" : "Start") { model.toggleRunning() }
            Toggle("Frame Generation", isOn: $model.interpolationEnabled)
            Divider()
            Text("Version \(AppVersion.display)")
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum SourceKind: String, CaseIterable, Identifiable {
        case captureCard = "Capture card"
        case window = "Game window"
        var id: String { rawValue }
    }

    @Published var sourceKind: SourceKind = .captureCard
    @Published var cards: [AVCaptureDevice] = []
    @Published var audioInputs: [AVCaptureDevice] = []
    @Published var cardID = ""
    @Published var audioID = ""          // "" = no audio
    @Published var windows: [SCWindow] = []
    @Published var windowID: CGWindowID = 0
    @Published var multiplier = 2
    @Published var backend: InterpolatorBackend = .shader
    @Published var lowLatency = true { didSet { engine.lowLatency = lowLatency } }
    /// With console HDR on, the Elgato Game Capture Neo tone-maps to SDR itself and the picture comes
    /// out dark and dull. This applies a correction fitted from the same PS5 screen captured with HDR
    /// off and on. Live-adjustable and remembered between launches.
    @Published var brightenHDR = UserDefaults.standard.bool(forKey: "brightenHDR") {
        didSet { UserDefaults.standard.set(brightenHDR, forKey: "brightenHDR"); applyColor() }
    }
    /// 0…1 blend between the card's picture and the fully corrected one.
    @Published var brightenStrength = UserDefaults.standard.object(forKey: "fixStrength") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(brightenStrength, forKey: "fixStrength"); applyColor() }
    }

    /// Testing aid: `--fullscreen` puts the output window into full screen on start.
    private var fullscreenOnStart = false

    private func applyColor() {
        engine.color = ColorAdjust(strength: brightenHDR ? Float(brightenStrength) : 0)
    }
    /// Measured on an M3 Pro: Apple's interpolator takes ~14 ms at 1080p for 2× but ~37 ms for 4×,
    /// so its 4× mode runs at 720p. The shader does 1080p at both (~4 ms).
    var maxLongEdge: Int { backend == .apple && multiplier >= 4 ? 1280 : 1920 }
    @Published var volume: Float = 1 { didSet { (engine.source as? CaptureCardSource)?.volume = volume } }
    @Published var running = false
    @Published var starting = false
    @Published var stats = FrameGenStats()
    @Published var message: String?
    @Published var interpolationEnabled = true { didSet { engine.interpolationEnabled = interpolationEnabled } }
    @Published var dropRepeats = true { didSet { engine.dropRepeats = dropRepeats } }
    @Published var showFPSOverlay = true { didSet { engine.showFPSOverlay = showFPSOverlay } }

    private let engine = FrameGenEngine()

    init() {
        // Testing aid: `--autostart [--log <file>]` starts the capture card right away and logs stats.
        let args = ProcessInfo.processInfo.arguments
        let logPath = args.firstIndex(of: "--log").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        engine.onStats = { [weak self] s in
            self?.stats = s
            if let logPath {
                let line = "in \(String(format: "%.1f", s.inputFPS)) unique \(String(format: "%.1f", s.uniqueFPS)) out \(String(format: "%.1f", s.outputFPS)) interp \(String(format: "%.1f", s.interpolationMs))ms \(s.resolution) \(s.displayHz)Hz ticks \(s.refreshes) gen \(s.generated) missed \(s.missedRefreshes) drawableWait \(String(format: "%.1f", s.drawableWaitMs))ms latency \(String(format: "%.1f", s.latencyMs))ms (delivery \(String(format: "%.1f", s.deliveryMs)) budget \(String(format: "%.1f", s.budgetMs))) \(s.backend) render \(s.renderResolution) toneMappedHDR \(s.toneMappedHDR) \(s.lastError ?? "")\n"
                Self.append(line, to: logPath)
            }
        }
        if args.contains("--autostart") {
            if args.contains("--4x") { multiplier = 4 }
            if args.contains("--apple") { backend = .apple }
            if args.contains("--brighten") { brightenHDR = true }
            fullscreenOnStart = args.contains("--fullscreen")
            if args.contains("--no-brighten") { brightenHDR = false }
            if args.contains("--safe-timing") { lowLatency = false }
            if let i = args.firstIndex(of: "--record"), args.indices.contains(i + 2) {
                engine.recordDir = args[i + 1]; engine.recordCount = Int(args[i + 2]) ?? 60
            }
            if let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) { engine.snapshotPath = args[i + 1] }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                await self.start()
                if let logPath { Self.append("started running=\(self.running) message=\(self.message ?? "-") format=\((self.engine.source as? CaptureCardSource)?.formatDescription ?? "-")\n", to: logPath) }
            }
        }
        engine.onStopped = { [weak self] reason in
            self?.running = false
            self?.stats = FrameGenStats()
            if let reason { self?.message = reason }
        }
        refreshDevices()
        if !Interpolator.isSupported { message = FrameGenError.unsupported.localizedDescription }
    }

    func refreshDevices() {
        cards = CaptureCardSource.videoDevices()
        audioInputs = CaptureCardSource.audioDevices()
        if !cards.contains(where: { $0.uniqueID == cardID }) {
            let card = cards.first { $0.localizedName.localizedCaseInsensitiveContains("capture") } ?? cards.first
            cardID = card?.uniqueID ?? ""
            audioID = card.flatMap(CaptureCardSource.matchingAudio(for:))?.uniqueID ?? ""
        }
    }

    func cardChanged() {
        if let card = cards.first(where: { $0.uniqueID == cardID }) {
            audioID = CaptureCardSource.matchingAudio(for: card)?.uniqueID ?? ""
        }
    }

    func refreshWindows() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let me = ProcessInfo.processInfo.processIdentifier
            windows = content.windows
                .filter { $0.windowLayer == 0 && $0.frame.width >= 320 && $0.frame.height >= 200 }
                .filter { $0.owningApplication?.processID != me }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            if !windows.contains(where: { $0.windowID == windowID }) { windowID = windows.first?.windowID ?? 0 }
            message = nil
        } catch {
            windows = []
            message = "Screen Recording permission is needed for window capture. Allow MacFrameGen in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen the app."
        }
    }

    func toggleRunning() {
        if running { engine.stop(); return }
        Task { await start() }
    }

    private func start() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        message = nil
        engine.interpolationEnabled = interpolationEnabled
        engine.dropRepeats = dropRepeats
        engine.lowLatency = lowLatency
        applyColor()

        do {
            switch sourceKind {
            case .captureCard:
                guard let card = cards.first(where: { $0.uniqueID == cardID }) else {
                    message = "No capture card found. Plug it in and press Refresh."; return
                }
                let audio = audioInputs.first { $0.uniqueID == audioID }
                let source = try CaptureCardSource(device: card, audioDevice: audio, maxLongEdge: maxLongEdge)
                let presenter = Presenter(mode: .window, frame: Self.initialWindowFrame(width: source.width, height: source.height),
                                          title: "\(card.localizedName) — MacFrameGen")
                try await engine.start(source: source, presenter: presenter, multiplier: multiplier, backend: backend)
                if fullscreenOnStart { presenter.window.toggleFullScreen(nil) }
                source.volume = volume
                if source.sharedWithAnotherApp {
                    message = "Another app (OBS?) is also using \(card.localizedName), so its current format is kept: \(source.formatDescription). For best results the card should run at 1080p60."
                }

            case .window:
                guard let window = windows.first(where: { $0.windowID == windowID }) else {
                    message = "Pick a game window first."; return
                }
                let source = ScreenSource(window: window, maxLongEdge: maxLongEdge)
                let presenter = Presenter(mode: .overlay, frame: FrameGenEngine.cocoaRect(fromTopLeft: source.pointRect), title: "")
                source.onError = { [weak self] error in
                    Task { @MainActor in self?.engine.stop(reason: error.localizedDescription) }
                }
                try await engine.start(source: source, presenter: presenter, multiplier: multiplier, backend: backend,
                                       trackWindow: (window.windowID, window.owningApplication?.processID))
                NSRunningApplication(processIdentifier: window.owningApplication?.processID ?? 0)?.activate()
            }
            running = true
        } catch {
            message = error.localizedDescription
        }
    }

    private static func append(_ line: String, to path: String) {
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
        else { FileManager.default.createFile(atPath: path, contents: Data(line.utf8)) }
    }

    /// 16:9-ish window that fits comfortably on the current screen.
    private static func initialWindowFrame(width: Int, height: Int) -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = min(visible.width * 0.8 / Double(width), visible.height * 0.8 / Double(height), 1)
        return NSRect(x: 0, y: 0, width: Double(width) * scale, height: Double(height) * scale)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Source", selection: $model.sourceKind) {
                ForEach(AppModel.SourceKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.running)

            Group {
                switch model.sourceKind {
                case .captureCard: cardSection
                case .window: windowSection
                }
            }
            .disabled(model.running)

            Divider()

            Form {
                Picker("Method", selection: $model.backend) {
                    Text("Fast GPU shader (~4 ms, lowest latency)").tag(InterpolatorBackend.shader)
                    Text("Apple ML (~14 ms, smoother on fine detail)").tag(InterpolatorBackend.apple)
                }
                .disabled(model.running)
                Picker("Mode", selection: $model.multiplier) {
                    Text("2× · 30 → 60 fps").tag(2)
                    Text(model.backend == .apple ? "4× · 30 → 120 fps · 720p (120 Hz screen)" : "4× · 30 → 120 fps (120 Hz screen)").tag(4)
                }
                .disabled(model.running)
                Toggle("Low latency (tighter timing, rare late frame)", isOn: $model.lowLatency)
                Toggle("Fix console HDR (the card tone-maps it dark)", isOn: $model.brightenHDR)
                if model.brightenHDR {
                    Slider(value: $model.brightenStrength, in: 0...1) {
                        Text("Strength \(Int((model.brightenStrength * 100).rounded()))%")
                    }
                }
                if model.stats.toneMappedHDR && !model.brightenHDR {
                    Text("The picture tops out at the card's HDR tone-mapping level. Console HDR looks on: turn on Fix console HDR.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Generate frames (⌘G to compare on/off)", isOn: $model.interpolationEnabled)
                Toggle("Show FPS on the output (⌘F)", isOn: $model.showFPSOverlay)
                Toggle("Drop repeated frames (needed for 30 fps games on a 60 fps card)", isOn: $model.dropRepeats)
                if model.sourceKind == .captureCard {
                    Slider(value: $model.volume, in: 0...1) { Text("Game volume") }
                }
            }

            HStack {
                Button(model.running ? "Stop" : "Start") { model.toggleRunning() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.starting)
                if model.starting { ProgressView().controlSize(.small) }
                Spacer()
            }

            if model.running { statsView }

            if let message = model.message {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460)
        // Only touch ScreenCaptureKit when window capture is chosen; listing windows triggers the
        // Screen Recording prompt, which capture-card users don't need.
        .task(id: model.sourceKind) { if model.sourceKind == .window { await model.refreshWindows() } }
    }

    private var cardSection: some View {
        Form {
            HStack {
                Picker("Device", selection: $model.cardID) {
                    if model.cards.isEmpty { Text("No capture devices").tag("") }
                    ForEach(model.cards, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .onChange(of: model.cardID) { model.cardChanged() }
                Button("Refresh") { model.refreshDevices() }
            }
            Picker("Audio", selection: $model.audioID) {
                Text("None").tag("")
                ForEach(model.audioInputs, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
        }
    }

    private var windowSection: some View {
        Form {
            HStack {
                Picker("Window", selection: $model.windowID) {
                    if model.windows.isEmpty { Text("No windows").tag(CGWindowID(0)) }
                    ForEach(model.windows, id: \.windowID) { w in
                        Text("\(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "")").tag(w.windowID)
                    }
                }
                Button("Refresh") { Task { await model.refreshWindows() } }
            }
        }
    }

    private var statsView: some View {
        let s = model.stats
        return VStack(alignment: .leading, spacing: 4) {
            Text("Input \(Int(s.inputFPS.rounded())) fps · game \(Int(s.uniqueFPS.rounded())) fps → output **\(Int(s.outputFPS.rounded())) fps**")
            Text("Capture → screen **\(Int(s.latencyMs.rounded())) ms** · \(s.backend) \(String(format: "%.1f", s.interpolationMs)) ms")
            Text("Output \(s.resolution) · game renders \(s.renderResolution.isEmpty ? "…" : (s.renderResolution.first?.isNumber == true ? "≈" + s.renderResolution : s.renderResolution)) · display \(s.displayHz) Hz")
                .foregroundStyle(.secondary)
            if let err = s.lastError { Text(err).foregroundStyle(.orange) }
        }
        .font(.callout.monospacedDigit())
    }

    private var hint: String {
        switch model.sourceKind {
        case .captureCard:
            return "The output window can go full screen (green button). Your MacBook screen runs at 120 Hz and fits 4×; a 60 Hz monitor tops out at 2×. Frame generation adds roughly one game frame of delay (~33 ms at 30 fps), so keep the console on the TV for twitchy games."
        case .window:
            return "Run the game windowed, capped at 30 fps. MacFrameGen covers the window with the smoothed picture; your clicks and keys still go to the game."
        }
    }
}

/// The version build.sh stamps into Info.plist from the VERSION file.
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
