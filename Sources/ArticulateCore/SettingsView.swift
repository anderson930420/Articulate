import ServiceManagement
import SwiftUI

extension Notification.Name {
    static let articulateAppearanceChanged = Notification.Name("articulateAppearanceChanged")
    static let articulateLogoChanged = Notification.Name("articulateLogoChanged")
    /// Opens the setup window; the object, if any, is the `SetupModel.Step` to show.
    static let articulateOpenSetup = Notification.Name("articulateOpenSetup")
    static let articulateCheckUpdates = Notification.Name("articulateCheckUpdates")
}

struct SettingsView: View {
    @AppStorage("triggerKey") private var trigger = TriggerKey.rightCommand.rawValue
    @AppStorage("pressMode") private var pressMode = PressMode.both.rawValue
    @AppStorage("language") private var language = DictationLanguage.zhTW.rawValue
    @AppStorage("recognizer") private var recognizer = Recognizer.speech.rawValue
    @AppStorage("polishEngine") private var engine = PolishEngine.auto.rawValue
    @AppStorage("claudeModel") private var claudeModel = "claude-opus-5-5"
    @AppStorage("codexModel") private var codexModel = Prefs.autoCodexModel
    @AppStorage("codexFast") private var codexFast = true
    @AppStorage("muteBackgroundAudio") private var muteBackgroundAudio = true
    @AppStorage("showLivePreview") private var showLivePreview = false
    @AppStorage("interactionSounds") private var interactionSounds = true
    @AppStorage("showIdleBar") private var showIdleBar = false
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("logoStyle") private var logoStyle = LogoStyle.handwritten.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("waveStyle") private var waveStyle = WaveStyle.bars.rawValue
    @AppStorage("sendScreenContext") private var sendScreenContext = true
    @AppStorage("aiEditsBarSeconds") private var aiEditsBarSeconds = 5.0
    @AppStorage("personalization") private var personalization = false
    @AppStorage("autoLearnDictionary") private var autoLearnDictionary = true
    @AppStorage("microphoneUID") private var microphoneUID = ""

    @AppStorage("claudeCodeModel") private var claudeCodeModel = "sonnet"
    @State private var claudeStatus = "檢查中…"
    @State private var apiKeyInput = ""
    @State private var hasAPIKey = Keychain.apiKey() != nil
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var modelStatus = ""
    @State private var targets = Prefs.translationTargets
    @State private var microphones = Microphones.inputDevices()
    @StateObject private var tester = MicrophoneTester()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "設定", subtitle: "說話鍵、麥克風、語言和 AI。改了馬上生效。")
                    .padding(.bottom, 2)
                general
                shortcuts
                audio
                languages
                ai
                personal
            }
            .frame(maxWidth: 760, alignment: .leading)
            .page()
        }
        .scrollContentBackground(.hidden)
        .frame(minWidth: 560)
        .onDisappear { tester.stop() }
    }

    private var general: some View {
        SettingsSection(title: "一般", symbol: "gearshape") {
            SettingRow("登入時自動開啟", divider: false) {
                switchToggle($launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("Articulate: launch at login change failed: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            SettingRow("在 Dock 中顯示") {
                switchToggle($showInDock)
                    .onChange(of: showInDock) { _, show in NSApp.setActivationPolicy(show ? .regular : .accessory) }
            }
            SettingRow("外觀") {
                menu($appearance) { ForEach(AppAppearance.allCases) { Text($0.label).tag($0.rawValue) } }
                    .onChange(of: appearance) { _, _ in NotificationCenter.default.post(name: .articulateAppearanceChanged, object: nil) }
            }
            SettingRow("版本", detail: "Articulate \(Updater.currentVersion)") {
                Button("檢查更新") { NotificationCenter.default.post(name: .articulateCheckUpdates, object: nil) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            SettingRow("設定精靈", detail: "檢查麥克風、輔助使用、AI 潤稿和加強辨識") {
                Button("打開") { NotificationCenter.default.post(name: .articulateOpenSetup, object: nil) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            SettingRow("App 圖示", detail: "Dock、選單列和側邊欄的 logo") {
                HStack(spacing: 10) {
                    ForEach(LogoStyle.allCases) { style in logoOption(style) }
                }
            }
            SettingRow("錄音動畫") {
                menu($waveStyle) { ForEach(WaveStyle.allCases) { Text($0.label).tag($0.rawValue) } }
            }
            SettingBlock {
                HStack(spacing: 16) {
                    Spacer()
                    barPreview(caption: "錄音中") { Waveform(source: .demo, style: WaveStyle(rawValue: waveStyle) ?? .bars) }
                    barPreview(caption: "處理中") { Waveform(source: .demo, working: true, style: WaveStyle(rawValue: waveStyle) ?? .bars) }
                    Spacer()
                }
            }
            SettingRow("待機時在螢幕下方顯示小工具列") { switchToggle($showIdleBar) }
        }
    }

    private var shortcuts: some View {
        SettingsSection(title: "快捷鍵", symbol: "keyboard") {
            let key = TriggerKey(rawValue: trigger)?.shortLabel ?? "右⌘"
            SettingRow("說話鍵", detail: "隨便問：\(key)＋空白鍵。翻譯：\(key)＋右 Shift。Esc 取消，⌃⌘V 貼上上一次的結果。", divider: false) {
                menu($trigger) { ForEach(TriggerKey.allCases) { Text($0.label).tag($0.rawValue) } }
            }
            SettingRow("說話方式", detail: (PressMode(rawValue: pressMode) ?? .both).howTo(key)
                       + (PressMode(rawValue: pressMode) == .hold ? "不小心輕按一下會直接取消，不會輸入東西。" : "")) {
                menu($pressMode) { ForEach(PressMode.allCases) { Text($0.label).tag($0.rawValue) } }
            }
        }
    }

    private var audio: some View {
        SettingsSection(title: "音訊", symbol: "mic") {
            SettingRow("麥克風", divider: false) {
                menu($microphoneUID) {
                    Text("系統預設（自動）").tag("")
                    ForEach(microphones) { mic in
                        Text(mic.badge.isEmpty ? mic.name : "\(mic.name)（\(mic.badge)）").tag(mic.uid)
                    }
                }
            }
            SettingRow("測試麥克風", detail: tester.running ? "說話時音量條應該會動" : nil) {
                HStack(spacing: 10) {
                    ProgressView(value: Double(tester.level)).frame(width: 140).tint(Theme.accent)
                    Button(tester.running ? "停止" : "開始測試") {
                        tester.running ? tester.stop() : tester.start(deviceUID: microphoneUID)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            SettingRow("互動聲音", detail: "開始和結束時播放音效") { switchToggle($interactionSounds) }
            SettingRow("語音輸入時把其他聲音靜音") { switchToggle($muteBackgroundAudio) }
            SettingRow("錄音時顯示即時文字") { switchToggle($showLivePreview) }
        }
    }

    private var languages: some View {
        SettingsSection(title: "語言", symbol: "globe") {
            SettingRow("口述語言", divider: false) {
                menu($language) { ForEach(DictationLanguage.allCases) { Text($0.label).tag($0.rawValue) } }
            }
            SettingRow("辨識模型", detail: recognizer == Recognizer.fusion.rawValue
                       ? (CompanionServer.isInstalled
                          ? "TEA-ASR 已安裝。錄音時自動啟動，閒置 10 分鐘後關閉，釋放記憶體。"
                          : "還沒安裝 TEA-ASR，安裝好之前先只用 Apple 辨識。")
                       : nil) {
                HStack(spacing: 8) {
                    if recognizer == Recognizer.fusion.rawValue && !CompanionServer.isInstalled {
                        Button("安裝…") { NotificationCenter.default.post(name: .articulateOpenSetup, object: SetupModel.Step.recognition) }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    menu($recognizer) { ForEach(Recognizer.allCases) { Text($0.label).tag($0.rawValue) } }
                }
            }
            SettingRow("語音模型", detail: modelStatus.isEmpty ? nil : modelStatus) {
                Button("下載／檢查") { prepareModel() }.buttonStyle(SecondaryButtonStyle())
            }
            SettingBlock {
                VStack(alignment: .leading, spacing: 8) {
                    Text("翻譯目標").font(.system(size: 14)).foregroundStyle(Theme.ink)
                    Text("最多 3 種，第一個是預設；錄音中按右 Shift 切換。").font(.system(size: 12)).foregroundStyle(Theme.secondaryInk)
                    ForEach(targets.indices, id: \.self) { i in
                        HStack {
                            Text("\(i + 1)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.tertiaryInk).frame(width: 14)
                            Picker("目標 \(i + 1)", selection: Binding(get: { targets[i] }, set: { targets[i] = $0; Prefs.translationTargets = targets })) {
                                ForEach(TranslationLanguages.all, id: \.code) { Text($0.label).tag($0.code) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            if targets.count > 1 {
                                Button { targets.remove(at: i); Prefs.translationTargets = targets } label: {
                                    Image(systemName: "minus.circle").foregroundStyle(Theme.secondaryInk)
                                }
                                .buttonStyle(.plain)
                                .help("移除")
                            }
                        }
                    }
                    if targets.count < 3 {
                        Button {
                            targets.append(TranslationLanguages.all.first { !targets.contains($0.code) }?.code ?? "en-US")
                            Prefs.translationTargets = targets
                        } label: { Label("新增語言", systemImage: "plus") }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
    }

    private var ai: some View {
        SettingsSection(title: "AI", symbol: "sparkles") {
            SettingRow("AI 引擎", detail: "目前使用：\(AIEngine.current()?.name ?? "無（輸出原始辨識結果）")", divider: false) {
                menu($engine) {
                    // Engines that can't be used yet stay out of the menu until they can.
                    ForEach(PolishEngine.allCases.filter { $0.isAvailable || $0.rawValue == engine }) {
                        Text($0.menuLabel).tag($0.rawValue)
                    }
                }
            }
            SettingRow("Codex", detail: CodexModel.isAvailable ? "已登入，可以使用" : "未安裝或未登入（終端機執行 codex login）") {
                menu($codexModel) { ForEach(CodexModel.models, id: \.id) { Text($0.label).tag($0.id) } }
            }
            SettingRow("Codex 快速模式", detail: "優先處理，約快 1.5–2 倍") { switchToggle($codexFast) }
            SettingRow("Claude 訂閱", detail: claudeStatus) {
                menu($claudeCodeModel) { ForEach(ClaudeCodeCLI.models, id: \.id) { Text($0.label).tag($0.id) } }
            }
            .task { await refreshClaudeStatus() }
            SettingRow("Apple Intelligence") {
                Text(AppleModel.statusDescription).font(.system(size: 14)).foregroundStyle(Theme.secondaryInk)
            }
            SettingRow("Claude API 模型", detail: "只有選「Claude API（金鑰）」時使用") {
                TextField("", text: $claudeModel).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            SettingRow("Claude API Key", detail: hasAPIKey ? "已儲存在鑰匙圈；輸入新的可以取代" : nil) {
                HStack(spacing: 8) {
                    SecureField("貼上金鑰", text: $apiKeyInput).textFieldStyle(.roundedBorder).frame(width: 180)
                    Button("儲存") {
                        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { return }
                        hasAPIKey = Keychain.setAPIKey(key)
                        apiKeyInput = ""
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasAPIKey {
                        Button("刪除") {
                            Keychain.deleteAPIKey()
                            hasAPIKey = false
                        }
                        .buttonStyle(SecondaryButtonStyle(tint: .red))
                    }
                }
            }
            SettingRow("「撤銷 AI 修改」顯示時間", detail: "每次切換原文／AI 版本都會重新計時；點別的地方或打字會提早收起。") {
                Stepper("\(Int(aiEditsBarSeconds)) 秒", value: $aiEditsBarSeconds, in: 2...30, step: 1).fixedSize()
            }
            SettingRow("傳送畫面上下文給 AI", detail: "app、視窗標題、網址、游標前後的文字。使用 Claude 或 Codex 時，辨識出的文字和這些上下文會送到該服務；Apple Intelligence 完全在本機執行。") {
                switchToggle($sendScreenContext)
            }
        }
    }

    private var personal: some View {
        SettingsSection(title: "個性化", symbol: "person.crop.circle") {
            SettingRow("啟用個性化", detail: "參考你在各 app 過去的寫法調整語氣與用字", divider: false) { switchToggle($personalization) }
            SettingRow("從你的修改自動學習新單字", detail: "加入字典，學到時錄音條會告訴你，可以一鍵移除") { switchToggle($autoLearnDictionary) }
            if personalization {
                let report = personalizationReport
                if report.isEmpty {
                    SettingRow("範例") { Text("資料不足").font(.system(size: 14)).foregroundStyle(Theme.secondaryInk) }
                } else {
                    ForEach(report, id: \.app) { row in
                        SettingRow(row.app) { Text("\(row.count) 筆範例").font(.system(size: 14)).foregroundStyle(Theme.secondaryInk) }
                    }
                }
            }
        }
    }

    /// One logo choice: its icon, its name, and a ring when chosen.
    private func logoOption(_ style: LogoStyle) -> some View {
        let selected = logoStyle == style.rawValue
        return Button {
            logoStyle = style.rawValue
            NotificationCenter.default.post(name: .articulateLogoChanged, object: nil)
        } label: {
            VStack(spacing: 5) {
                Image(nsImage: LogoMark.icon(dark: colorScheme == .dark, style: style))
                    .resizable()
                    .frame(width: 44, height: 44)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
                Text(style.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.secondaryInk)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(style == .handwritten ? "手寫的 V，右上角一顆小愛心" : "原本的聲波 logo")
    }

    /// Claude Code's sign-in, as `claude auth status` reports it (the login itself is never read).
    private func refreshClaudeStatus() async {
        guard let claude = await ClaudeCodeCLI.find() else {
            claudeStatus = "沒有找到 Claude Code（可以在設定精靈裡看安裝方式）"
            return
        }
        let status = await ClaudeCodeCLI.status(claude)
        claudeStatus = status.isSubscription
            ? "已用 Claude \(status.plan.map { $0.capitalized } ?? "訂閱")登入，用你的 Claude Code 處理"
            : "還沒用 Claude 訂閱登入（終端機執行 claude auth login，或用設定精靈）"
    }

    private func switchToggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.accent)
    }

    private func menu<Content: View>(_ selection: Binding<String>, @ViewBuilder content: () -> Content) -> some View {
        Picker("", selection: selection, content: content).labelsHidden().pickerStyle(.menu).fixedSize()
    }

    private func barPreview<Content: View>(caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 4) {
            content()
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Capsule().fill(.black.opacity(0.86)))
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var personalizationReport: [(app: String, count: Int)] {
        let entries = HistoryStore.shared.entries.filter { $0.effectiveMode == .dictation && $0.effectiveStatus == .completed }
        let grouped = Dictionary(grouping: entries) { $0.appName ?? "其他" }
        return grouped.map { (app: $0.key, count: $0.value.count) }.sorted { $0.count > $1.count }.prefix(8).map { $0 }
    }

    private func prepareModel() {
        modelStatus = "檢查中…"
        let locale = Locale(identifier: language)
        Task {
            do {
                try await LiveTranscriber.prepareAssets(for: locale)
                modelStatus = "已就緒"
            } catch {
                modelStatus = error.localizedDescription
            }
        }
    }
}

/// A titled group of settings on a card.
private struct SettingsSection<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            } icon: {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .card(padding: 0)
        }
    }
}

/// One setting: its name (and an explanation) on the left, the control on the right.
private struct SettingRow<Control: View>: View {
    var title: String
    var detail: String?
    var divider: Bool
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, divider: Bool = true, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.divider = divider
        self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 18) }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14)).foregroundStyle(Theme.ink)
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }
}

/// Free-form content inside a settings card, separated like a row.
private struct SettingBlock<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 18)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
    }
}
