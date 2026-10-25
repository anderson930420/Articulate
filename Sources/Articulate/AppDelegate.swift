import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = DictationController()
    let hotkeys = HotkeyMonitor()
    let hubState = HubState()
    private var statusItem: NSStatusItem!
    private var hubWindow: NSWindow?
    private var setupWindow: NSWindow?
    /// Lives with the app, so a model download keeps going when the setup window is closed.
    private lazy var setupModel = SetupModel(installer: TEAInstaller())
    private var appearanceObservation: NSKeyValueObservation?
    /// Set when launched with --e2e: run the end-to-end test instead of waiting for the user.
    var endToEndArguments: (audioDir: URL, report: URL)?

    static let reopenNotification = Notification.Name("local.articulate.dictation.reopen")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.migrateLegacySettings()
        // Only one Articulate at a time: a second copy (another build, `open -n`) shows the running one's window and quits.
        // The end-to-end test deliberately runs a second instance.
        let me = ProcessInfo.processInfo.processIdentifier
        if endToEndArguments == nil,
           NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
               .contains(where: { $0.processIdentifier != me }) {
            DistributedNotificationCenter.default().postNotificationName(Self.reopenNotification, object: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.reopenNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openHub(.home) }
        }
        NSApp.setActivationPolicy(Prefs.showInDock ? .regular : .accessory)
        ResourceGuard.start(isIdle: { [weak self] in self?.controller.phase == .idle })
        applyAppearance()
        NotificationCenter.default.addObserver(forName: .articulateAppearanceChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
        // A different logo chosen in settings shows in the Dock and the menu bar at once.
        NotificationCenter.default.addObserver(forName: .articulateLogoChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSApp.applicationIconImage = LogoMark.appIcon(for: NSApp.effectiveAppearance)
                self.updateIcon(self.controller.state)
            }
        }
        // The Dock icon follows light and dark mode (Articulate's own setting, or the system's).
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial]) { app, _ in
            MainActor.assumeIsolated { app.applicationIconImage = LogoMark.appIcon(for: app.effectiveAppearance) }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon(.idle)

        hubState.controller = controller
        controller.onStateChange = { [weak self] state in self?.updateIcon(state) }
        hotkeys.phase = { [weak self] in self?.controller.phase ?? .idle }
        hotkeys.onAction = { [weak self] action in self?.controller.handle(action) }
        // Read the field just before Enter sends it, so a word fixed right before sending is still learned.
        hotkeys.onReturnKey = { [weak self] in MainActor.assumeIsolated { self?.controller.learner.pollIfWatching() } }

        TextInserter.observeLayoutChanges()
        HistoryStore.shared.applyRetention()
        let phrases = DictionaryStore.shared.removeAutoLearnedPhrases(keeping: EditLearner.looksLikeTerm)
        if !phrases.isEmpty { DiagnosticLog.write("dictionary: removed \(phrases.count) learned phrase(s) that are not names or terms") }
        hotkeys.start()

        if let e2e = endToEndArguments {
            Task { await EndToEndTest.run(app: self, audioDir: e2e.audioDir, report: e2e.report) }
            return
        }

        NotificationCenter.default.addObserver(forName: .articulateOpenSetup, object: nil, queue: .main) { [weak self] note in
            let step = note.object as? SetupModel.Step
            MainActor.assumeIsolated { self?.openSetup(step) }
        }
        // First run: the setup window explains each permission before macOS asks for it. Anyone who already has
        // everything in place (permissions and an AI engine) never sees it.
        if !Prefs.setupDone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && AXIsProcessTrusted()
            && AIEngine.current() != nil {
            Prefs.setupDone = true
        }
        if Prefs.setupDone {
            requestPermissions()
        } else {
            openSetup(nil)
        }
        DiagnosticLog.write("launch: axTrusted=\(AXIsProcessTrusted()) tap=\(hotkeys.isRunning) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) engine=\(AIEngine.current()?.name ?? "none")")
        controller.bar.hide() // shows the idle pill when enabled
        if !AXIsProcessTrusted() && Prefs.setupDone {
            controller.bar.flash("請到「系統設定 › 隱私權與安全性 › 輔助使用」開啟 Articulate，才能用快捷鍵和自動貼上", seconds: 8)
        }
        let locale = Locale(identifier: Prefs.language.rawValue)
        Task.detached { try? await LiveTranscriber.prepareAssets(for: locale) }
        AIEngine.prewarm()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CodexAppServer.shared.stop()
        CompanionServer.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openHub(.home)
        return true
    }

    private func applyAppearance() {
        switch Prefs.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Permissions

    private func requestPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    // MARK: - Status item

    private func updateIcon(_ state: DictationController.State) {
        let style: LogoMark.MenuBarStyle = switch state {
        case .idle: .idle
        case .recording: .recording
        case .processing: .processing
        }
        statusItem.button?.image = LogoMark.menuBarImage(style)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let key = Prefs.triggerKey.shortLabel
        menu.addItem(disabled("按一下 \(key) 口述 · \(key)＋空白鍵 隨便問 · \(key)＋右Shift 翻譯"))
        menu.addItem(disabled(AIEngine.statusDescription))

        if !AXIsProcessTrusted() || !hotkeys.isRunning {
            menu.addItem(.separator())
            menu.addItem(action("⚠️ 需要「輔助使用」權限…", #selector(openAccessibilitySettings)))
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            menu.addItem(action("⚠️ 需要「麥克風」權限…", #selector(openMicrophoneSettings)))
        }

        menu.addItem(.separator())
        menu.addItem(action("打開 Articulate 首頁", #selector(openHome)))
        menu.addItem(action("顯示歷史紀錄", #selector(openHistory)))
        menu.addItem(action("將單字加入字典", #selector(addWordToDictionary)))
        if let last = HistoryStore.shared.lastCompleted {
            let item = action("複製上一次：\(Self.excerpt(last.finalText))", #selector(copyText(_:)))
            item.representedObject = last.finalText
            menu.addItem(item)
        }

        let micItem = NSMenuItem(title: "選擇麥克風", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        let current = Prefs.microphoneUID
        let defaultItem = action("系統預設（自動）", #selector(selectMicrophone(_:)))
        defaultItem.representedObject = ""
        defaultItem.state = current.isEmpty ? .on : .off
        micMenu.addItem(defaultItem)
        for mic in Microphones.inputDevices() {
            let item = action(mic.badge.isEmpty ? mic.name : "\(mic.name)（\(mic.badge)）", #selector(selectMicrophone(_:)))
            item.representedObject = mic.uid
            item.state = mic.uid == current ? .on : .off
            micMenu.addItem(item)
        }
        micItem.submenu = micMenu
        menu.addItem(micItem)

        menu.addItem(.separator())
        menu.addItem(action("設定精靈…", #selector(openSetupFromMenu)))
        menu.addItem(action("設定…", #selector(openSettings), key: ","))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        menu.addItem(disabled("版本 \(version)"))
        menu.addItem(action("結束 Articulate", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private static func excerpt(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 24 ? String(flat.prefix(24)) + "…" : flat
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = selector == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return item
    }

    // MARK: - Actions

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        TextInserter.copyToPasteboard(text)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String ?? "", forKey: "microphoneUID")
    }

    @objc private func addWordToDictionary() {
        // Pre-fill with whatever is selected in the frontmost app.
        hubState.pendingWord = ScreenContextReader.capture().selectedText.map { String($0.prefix(DictionaryStore.maxTermLength)) } ?? ""
        openHub(.dictionary)
    }

    @objc private func openAccessibilitySettings() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        hotkeys.start()
    }

    @objc private func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openSetupFromMenu() { openSetup(nil) }

    /// The setup window, optionally at a given step (e.g. from the speech-model setting).
    func openSetup(_ step: SetupModel.Step?) {
        if let step { setupModel.step = step }
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "設定 Articulate"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SetupView(model: setupModel) { [weak self] in
                Prefs.setupDone = true
                self?.setupWindow?.close()
            })
            window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Closing it counts as done; it is one click away in the menu.
                    Prefs.setupDone = true
                    self?.setupModel.stop()
                    self?.hotkeys.start()
                }
            }
            setupWindow = window
        }
        setupModel.start()
        NSApp.activate()
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openHome() { openHub(.home) }
    @objc private func openHistory() { openHub(.history) }
    @objc private func openSettings() { openHub(.settings) }

    func openHub(_ section: HubSection) {
        hubState.section = section
        if hubWindow == nil {
            // Most of the screen, up to 1200×840; the user's own size is remembered afterwards.
            let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
            let size = NSSize(width: min(1200, visible.width * 0.85), height: min(840, visible.height * 0.85))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Articulate"
            // The sidebar and pages draw their own backgrounds up under the window buttons.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: HubView(state: hubState))
            // Only the minimum size feeds back into the window; measuring the ideal size of the whole page on
            // every update cost time while scrolling.
            host.sizingOptions = [.minSize]
            window.contentView = host
            window.center()
            window.setFrameAutosaveName("ArticulateHub")
            hubWindow = window
        }
        NSApp.activate()
        hubWindow?.makeKeyAndOrderFront(nil)
    }
}
