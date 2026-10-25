import AppKit
import SwiftUI

/// Renders the floating bar, answer card and Hub pages to PNGs (`Articulate --render-previews <dir>`),
/// so the UI can be checked without granting permissions or speaking.
@MainActor
enum PreviewRenderer {
    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func bar(_ name: String, _ configure: (BarModel) -> Void) {
            let model = BarModel()
            model.meter.set(0.7)
            configure(model)
            save(BarView(model: model).padding(20).background(Color(white: 0.72)), name, directory)
        }
        bar("bar-idle") { $0.phase = .idle }
        bar("bar-idle-hover") { $0.phase = .idle; $0.hovering = true }
        bar("bar-listening") {
            $0.phase = .listening
            $0.preview = "我明天下午四點要跟客戶開會，請幫我準備一下報價單"
        }
        bar("bar-handsfree") { $0.phase = .listening; $0.handsFree = true }
        bar("bar-ask") { $0.phase = .listening; $0.mode = .ask }
        bar("bar-translate") { $0.phase = .listening; $0.mode = .translation; $0.translationTarget = "ja-JP" }
        bar("bar-thinking") { $0.phase = .thinking }
        for style in WaveStyle.allCases {
            let meter = LevelMeter()
            meter.set(0.7)
            for working in [false, true] {
                let pill = Waveform(source: .meter(meter), working: working, style: style)
                    .padding(.horizontal, 14).frame(height: 38)
                    .background(Capsule().fill(.black.opacity(0.86)))
                save(pill.padding(12).background(Color(white: 0.72)), "wave-\(style.rawValue)-\(working ? "working" : "listening")", directory)
            }
        }
        for (dark, scheme) in [(false, ColorScheme.light), (true, .dark)] {
            let header = LogoHeader().frame(width: 170).environment(\.colorScheme, scheme)
                .background(Color(white: dark ? 0.17 : 0.92))
            save(header, "logo-header-\(dark ? "dark" : "light")", directory)
        }
        // App icon, light and dark, at a large size and at the sizes Finder and the Dock use for small icons.
        for dark in [false, true] {
            for (style, pixels) in LogoStyle.allCases.flatMap({ s in [512, 64, 32].map { (s, $0) } }) {
                let rep = LogoMark.appIconRep(pixels: pixels, dark: dark, style: style)
                let url = directory.appendingPathComponent("app-icon-\(style.rawValue)-\(dark ? "dark" : "light")-\(pixels).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path)
            }
        }
        // Menu-bar icon in each state, on a light and a dark menu bar: once at real size, once at 4×.
        for logo in LogoStyle.allCases {
            for scale in [1.0, 4.0] {
                let states: [LogoMark.MenuBarStyle] = [.idle, .recording, .processing]
                let strip = VStack(spacing: 0) {
                    ForEach([false, true], id: \.self) { dark in
                        HStack(spacing: 18 * scale) {
                            ForEach(states.indices, id: \.self) { i in
                                let image = LogoMark.menuBarImage(states[i], style: logo)
                                Image(nsImage: image).resizable()
                                    .frame(width: image.size.width * scale, height: image.size.height * scale)
                            }
                        }
                        .foregroundStyle(dark ? .white : .black)
                        .padding(.horizontal, 12 * scale).frame(height: 24 * scale)
                        .background(dark ? Color(white: 0.15) : Color(white: 0.93))
                    }
                }
                save(strip, "menubar-\(logo.rawValue)-\(Int(scale))x", directory)
            }
        }
        bar("bar-inserted-ai") { $0.phase = .inserted(original: false) }
        bar("bar-inserted-original") { $0.phase = .inserted(original: true) }
        bar("bar-copyable") { $0.phase = .copyable }

        if let entry = HistoryStore.shared.entries.first(where: { !$0.finalText.isEmpty }) {
            let row = HistoryRow(entry: entry, hasAudio: true, working: false, canRetry: true,
                                 onRetry: {}, onDownload: {}, onDelete: {}, hovering: true)
            save(row.padding(16).frame(width: 760).background(Color(nsColor: .windowBackgroundColor)), "history-row-hover", directory)
        }

        let answer = AnswerModel()
        answer.question = "台灣最高的山是哪一座"
        answer.answer = "台灣最高的山是玉山，主峰海拔約 3,952 公尺，位於南投縣、嘉義縣與高雄市交界，也是東北亞第一高峰。"
        save(AnswerView(model: answer).padding(20).background(Color(white: 0.72)), "answer-card", directory)

        // The setup window: every step, in the states a new user meets.
        func setup(_ name: String, dark: Bool = false, _ configure: (SetupModel) -> Void) {
            let model = SetupModel(installer: TEAInstaller())
            configure(model)
            save(SetupView(model: model).environment(\.colorScheme, dark ? .dark : .light), "setup-\(name)\(dark ? "-dark" : "")", directory, dark: dark)
        }
        let codex = CodexCLI.Found(url: URL(fileURLWithPath: "/opt/homebrew/bin/codex"), version: "0.163.0")
        let claudeCode = CodexCLI.Found(url: URL(fileURLWithPath: "/opt/homebrew/bin/claude"), version: "2.1.281")
        let granted = { (m: SetupModel) in
            m.microphone = .authorized; m.accessibility = true; m.codex = .ready(codex); m.claude = .ready(claudeCode, plan: "max"); m.engine = .codex
        }
        setup("1-welcome") { $0.step = .welcome; $0.microphone = .notDetermined; $0.accessibility = false; $0.codex = .checking; $0.installer.state = .notInstalled }
        setup("2-microphone") { $0.step = .microphone; $0.microphone = .notDetermined; $0.accessibility = false }
        setup("3-accessibility") { $0.step = .accessibility; $0.microphone = .authorized; $0.accessibility = false }
        setup("4-ai-found") { granted($0); $0.step = .ai }
        setup("4-ai-claude-chosen") { granted($0); $0.step = .ai; $0.engine = .claudeCode }
        setup("4-ai-signed-out") { granted($0); $0.step = .ai; $0.codex = .signedOut(codex); $0.claude = .signedOut(claudeCode) }
        setup("4-ai-missing") { granted($0); $0.step = .ai; $0.codex = .missing; $0.claude = .missing; $0.engine = .claudeCode }
        setup("5-tea-ask") { granted($0); $0.step = .recognition; $0.installer.state = .notInstalled }
        setup("5-tea-downloading") { m in
            granted(m); m.step = .recognition
            m.installer.state = .installing(.download)
            m.installer.received = 1_560_000_000; m.installer.expected = 4_100_000_000; m.installer.bytesPerSecond = 38_000_000
        }
        setup("5-tea-converting") { granted($0); $0.step = .recognition; $0.installer.state = .installing(.convert) }
        setup("5-tea-failed") { granted($0); $0.step = .recognition; $0.installer.state = .failed(.download, "網路連線中斷（The network connection was lost.）") }
        setup("5-tea-installed") { granted($0); $0.step = .recognition; $0.installer.state = .installed }
        setup("6-done") { granted($0); $0.step = .done; $0.installer.state = .notInstalled }
        setup("6-done-missing") { $0.step = .done; $0.microphone = .authorized; $0.accessibility = false; $0.codex = .missing; $0.installer.state = .notInstalled }
        setup("1-welcome", dark: true) { $0.step = .welcome; $0.microphone = .notDetermined; $0.accessibility = false; $0.codex = .checking; $0.installer.state = .notInstalled }
        setup("5-tea-downloading", dark: true) { m in
            granted(m); m.step = .recognition
            m.installer.state = .installing(.download)
            m.installer.received = 1_560_000_000; m.installer.expected = 4_100_000_000; m.installer.bytesPerSecond = 38_000_000
        }

        // The whole window (sidebar and page), at the smallest and the default size, in light and dark mode.
        for (width, height, suffix) in [(900.0, 620.0, "small"), (1200.0, 840.0, "large")] {
            for dark in [false, true] {
                for section in HubSection.allCases {
                    let state = HubState()
                    state.section = section
                    save(HubView(state: state).frame(width: width, height: height).environment(\.colorScheme, dark ? .dark : .light),
                         "hub-\(section.rawValue)-\(suffix)\(dark ? "-dark" : "")", directory, dark: dark)
                }
            }
        }
    }

    /// Renders through a real view hierarchy so AppKit-backed controls (Form, List, Picker) draw.
    private static func save<V: View>(_ view: V, _ name: String, _ directory: URL, dark: Bool = false) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = directory.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }
}
