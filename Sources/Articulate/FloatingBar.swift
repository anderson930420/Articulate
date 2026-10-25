import AppKit
import Combine
import SwiftUI

@MainActor
final class BarModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        /// After recording: recognising, polishing, translating or answering. Shows the processing animation only.
        case thinking
        case message(String)
        /// AI-edited text was inserted; offers switching between it and what was actually said.
        case inserted(original: Bool)
        /// Nowhere to type: offers copying the result.
        case copyable
        case copied
        /// Terms learned from the user's edits were added to the dictionary; offers taking them out again.
        case learned([String])
    }

    @Published var phase: Phase = .idle
    /// Not published: the waveform reads it every frame, so audio updates never re-layout the bar.
    let meter = LevelMeter()
    @Published var preview = ""
    @Published var handsFree = false
    @Published var mode: DictationMode = .dictation
    @Published var translationTarget = "en-US"
    @Published var hovering = false

    var onStart: () -> Void = {}
    var onCancel: () -> Void = {}
    var onFinish: () -> Void = {}
    var onToggleAIEdits: () -> Void = {}
    var onCopy: () -> Void = {}
    var onRemoveLearned: () -> Void = {}

    func push(level: Float) {
        meter.target = level
    }

    func resetRecording() {
        meter.reset()
        preview = ""
        handsFree = false
        mode = .dictation
    }
}

struct BarView: View {
    @ObservedObject var model: BarModel
    @AppStorage("waveStyle") private var waveStyle = WaveStyle.bars.rawValue
    private var style: WaveStyle { WaveStyle(rawValue: waveStyle) ?? .bars }

    var body: some View {
        VStack(spacing: 6) {
            if model.phase == .listening, !model.preview.isEmpty, Prefs.showLivePreview {
                Text(model.preview)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 440)
                    .background(Capsule().fill(.black.opacity(0.78)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.phase == .idle {
                idlePill
            } else {
                HStack(spacing: 10) { content }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Capsule().fill(.black.opacity(0.86)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }
        }
        .padding(4)
        .fixedSize()
    }

    private var idlePill: some View {
        Button(action: model.onStart) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 10, weight: .semibold))
                if model.hovering {
                    Text("按一下 \(Prefs.triggerKey.shortLabel) 說話，或點這裡開始")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, model.hovering ? 12 : 10)
            .frame(height: model.hovering ? 26 : 16)
            .background(Capsule().fill(.black.opacity(model.hovering ? 0.85 : 0.55)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { model.hovering = $0 }
        .help("點擊開始口述")
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .listening:
            // No text while recording: just the voice, plus a small icon for Ask and Translate.
            circleButton("xmark", help: "取消", action: model.onCancel)
            if model.mode != .dictation { modeIcon }
            Waveform(source: .meter(model.meter), style: style)
            circleButton("checkmark", help: "完成", action: model.onFinish, filled: true)
        case .thinking:
            Waveform(source: .meter(model.meter), working: true, style: style)
        case .message(let text):
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
            label(text)
        case .inserted(let original):
            if original {
                Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.white.opacity(0.8))
                // Same width as the AI state, so the button stays under the pointer while switching.
                label("已還原")
                textButton("恢復 AI 修改", action: model.onToggleAIEdits)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                label("已輸入")
                textButton("撤銷 AI 修改", action: model.onToggleAIEdits)
            }
        case .copyable:
            Image(systemName: "doc.on.clipboard").foregroundStyle(.white)
            label("這裡無法輸入文字")
            textButton("複製最後的轉錄", action: model.onCopy)
        case .copied:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            label("已複製")
        case .learned(let terms):
            Image(systemName: "character.book.closed.fill").foregroundStyle(.white)
            label("「\(terms.joined(separator: "」「"))」已加入字典")
            textButton("移除", action: model.onRemoveLearned)
        }
    }

    private var modeIcon: some View {
        let ask = model.mode == .ask
        return Image(systemName: ask ? "sparkles" : "globe")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(ask ? Color.purple.opacity(0.8) : Color.blue.opacity(0.8)))
            .help(ask ? model.mode.label : "翻譯至 \(TranslationLanguages.label(model.translationTarget))")
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void, filled: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(filled ? .black : .white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(filled ? .white : .white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white))
        }
        .buttonStyle(.plain)
    }
}

/// The microphone level behind the waveform, eased per display frame: it rises fast and falls slowly.
@MainActor
final class LevelMeter {
    var target: Float = 0
    private var value: Float = 0
    private var lastTime: Double?
    /// Frames drawn so far (diagnostics: shows whether the animation is running).
    private(set) var frames = 0

    func value(at time: Double) -> Float {
        frames += 1
        let dt = Float(min(max(time - (lastTime ?? time), 0), 0.1))
        lastTime = time
        value += (target - value) * min(1, (target > value ? 18 : 6) * dt)
        return value
    }

    /// Jumps straight to a level (previews).
    func set(_ level: Float) {
        target = level
        value = level
    }

    func reset() {
        target = 0
        value = 0
        lastTime = nil
    }
}

/// Clicks reach the SwiftUI buttons without first activating Articulate.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Non-activating panel near the bottom of the screen, so the target app keeps keyboard focus.
/// The panel is resized to its content so it never blocks clicks around it.
@MainActor
final class FloatingBar {
    let model = BarModel()
    private var panel: NSPanel?
    private var host: ClickThroughHostingView<BarView>?
    private var hideWorkItem: DispatchWorkItem?
    private var outsideInputMonitor: Any?
    private var observer: AnyCancellable?

    private var defaultsObserver: AnyCancellable?
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        observer = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.relayout() }
        }
        // Turning the idle bar on or off in Settings takes effect right away.
        defaultsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.model.phase == .idle else { return }
                if Prefs.showIdleBar { self.hide() } else { self.panel?.orderOut(nil) }
            }
        // Like Typeless, the bar follows the user to other apps, Spaces and full-screen apps.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.panel?.isVisible == true else { return }
                    self.bringToFront()
                }
            })
        }
    }

    func show(_ phase: BarModel.Phase) {
        hideWorkItem?.cancel()
        stopOutsideInputMonitor()
        model.phase = phase
        bringToFront()
    }

    /// Shows a phase briefly, then returns to idle. With `untilOutsideInput`, a click or key press
    /// anywhere else dismisses it sooner.
    func flash(_ phase: BarModel.Phase, seconds: TimeInterval = 2.5, untilOutsideInput: Bool = false) {
        show(phase)
        if untilOutsideInput {
            outsideInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                // Articulate's own ⌘Z / ⌘V while switching versions don't count.
                guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != TextInserter.syntheticMarker else { return }
                MainActor.assumeIsolated { self?.hide() }
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func flash(_ message: String, seconds: TimeInterval = 2.5) {
        flash(.message(message), seconds: seconds)
    }

    /// Back to the idle pill (or hidden when the idle pill is turned off).
    func hide() {
        hideWorkItem?.cancel()
        stopOutsideInputMonitor()
        model.resetRecording()
        model.phase = .idle
        if Prefs.showIdleBar {
            bringToFront()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func stopOutsideInputMonitor() {
        if let outsideInputMonitor { NSEvent.removeMonitor(outsideInputMonitor) }
        outsideInputMonitor = nil
    }

    /// Shows the bar on the Space in front. A panel that was ordered in on another Space can stay off a
    /// full-screen app's Space even though it may join all Spaces; a freshly made one always shows, so rebuild it.
    private func bringToFront() {
        ensurePanel()
        relayout()
        panel?.orderFrontRegardless()
        if panel?.isOnActiveSpace == false {
            DiagnosticLog.write("bar: not on the Space in front, rebuilding the panel")
            panel?.orderOut(nil)
            panel = nil
            host = nil
            ensurePanel()
            relayout()
            panel?.orderFrontRegardless()
        }
        if model.phase == .listening { logVisibility() }
    }

    /// For "the bar didn't show" reports: where it is and whether it is visible and animating half a second later.
    private func logVisibility() {
        let frames = model.meter.frames
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let panel = self.panel else { return }
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            DiagnosticLog.write("bar: front=\(front) frame=\(NSStringFromRect(panel.frame)) visible=\(panel.isVisible) "
                + "onActiveSpace=\(panel.isOnActiveSpace) unoccluded=\(panel.occlusionState.contains(.visible)) "
                + "frames=\(self.model.meter.frames - frames)/0.5s")
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = ClickThroughHostingView(rootView: BarView(model: model))
        panel.contentView = host
        self.panel = panel
        self.host = host
    }

    /// How many times the panel was re-sized (diagnostics).
    private(set) var relayouts = 0

    private func relayout() {
        relayouts += 1
        guard let panel, let host else { return }
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 14, width: size.width, height: size.height), display: true)
    }
}

// MARK: - Ask Anything answer card

@MainActor
final class AnswerModel: ObservableObject {
    @Published var question = ""
    @Published var answer = ""
    @Published var expanded = false
    @Published var copied = false
    var onClose: () -> Void = {}
}

struct AnswerView: View {
    @ObservedObject var model: AnswerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("回答", systemImage: "sparkles").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.answer, forType: .string)
                    model.copied = true
                } label: {
                    Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(model.copied ? "已複製" : "複製")
                Button(action: model.onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("關閉")
            }
            if !model.question.isEmpty {
                Text(model.question).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            ScrollView {
                Text(model.answer)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: model.expanded ? 420 : 150)
            if model.answer.count > 160 {
                Button(model.expanded ? "顯示較少" : "⋯更多") { model.expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15)))
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class AnswerCard {
    let model = AnswerModel()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(question: String, answer: String) {
        model.question = question
        model.answer = answer
        model.expanded = false
        model.copied = false
        model.onClose = { [weak self] in self?.hide() }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = ClickThroughHostingView(rootView: AnswerView(model: model))
            self.panel = panel
        }
        guard let panel, let host = panel.contentView else { return }
        let size = host.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + 70, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
