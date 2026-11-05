import AppKit
import SwiftUI

/// The first-run setup window: steps on the left, one step at a time on the right.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var installer: TEAInstaller
    var onFinish: () -> Void = {}

    init(model: SetupModel, onFinish: @escaping () -> Void = {}) {
        self.model = model
        self.installer = model.installer
        self.onFinish = onFinish
    }

    var body: some View {
        HStack(spacing: 0) {
            steps
            Rectangle().fill(Theme.separator).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 40)
                        .padding(.top, 48)
                        .padding(.bottom, 24)
                }
                .scrollContentBackground(.hidden)
                footer
            }
            .background(Theme.canvas)
        }
        .ignoresSafeArea()
        .frame(width: 820, height: 600)
    }

    // MARK: Step list

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            LogoHeader()
                .padding(.top, 46)
                .padding(.bottom, 22)
            VStack(spacing: 2) {
                ForEach(SetupModel.Step.allCases) { step in
                    Button { model.step = step } label: { stepRow(step) }
                        .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(width: 216)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    private func stepRow(_ step: SetupModel.Step) -> some View {
        let selected = model.step == step
        return HStack(spacing: 10) {
            ZStack {
                if model.isComplete(step) && step != .welcome && step != .done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if model.needsAttention(step) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                } else {
                    Image(systemName: step.symbol).foregroundStyle(selected ? Theme.ink : Theme.secondaryInk)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .frame(width: 18)
            Text(step.title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.ink : Theme.secondaryInk)
            if step == .recognition {
                Text("選用").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiaryInk)
                    .padding(.horizontal, 5).frame(height: 16)
                    .background(Capsule().fill(Theme.fill))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.selection)
                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .microphone: microphone
        case .accessibility: accessibility
        case .ai: ai
        case .recognition: recognition
        case .done: done
        }
    }

    private func header(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.pageTitle()).foregroundStyle(Theme.ink)
            Text(text).font(Theme.body()).foregroundStyle(Theme.secondaryInk)
                .lineSpacing(Theme.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 24)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: LogoMark.icon(dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))
                .resizable().frame(width: 72, height: 72)
                .padding(.bottom, 20)
            header("歡迎使用 Articulate", "用說的打字：按一下說話鍵開始說，說完再按一下，整理好的文字就出現在游標的位置。接下來花一分鐘把它設定好。")
            VStack(alignment: .leading, spacing: 14) {
                plan("mic", "允許麥克風", "只在你按下說話鍵時錄音")
                plan("hand.point.up.left", "允許輔助使用", "偵測說話鍵、把文字貼到游標的位置")
                plan("sparkles", "AI 潤稿", "使用你電腦上已有的 Codex，不用另外下載")
                plan("waveform.badge.plus", "加強辨識（選用）", "要下載時會先問你")
            }
            .card()
        }
    }

    private func plan(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                Text(text).font(Theme.caption()).foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("允許使用麥克風", "Articulate 只在你按下說話鍵時錄音，錄音在這台 Mac 上辨識，不會上傳。")
            statusCard {
                switch model.microphone {
                case .authorized:
                    status(.ok, "已允許麥克風")
                case .notDetermined:
                    status(.todo, "還沒允許")
                    Spacer()
                    Button("允許麥克風") { model.requestMicrophone() }.buttonStyle(PrimaryButtonStyle())
                default:
                    status(.warning, "麥克風被關閉了", detail: "到系統設定 › 隱私權與安全性 › 麥克風，打開 Articulate。")
                    Spacer()
                    Button("打開系統設定") { model.requestMicrophone() }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("允許「輔助使用」", "macOS 要這個權限，Articulate 才能偵測說話鍵、把文字貼到游標的位置，並讀取游標前後的文字讓潤稿更準確。")
            statusCard {
                if model.accessibility {
                    status(.ok, "已允許輔助使用")
                } else {
                    status(.todo, "還沒允許", detail: "按右邊的按鈕打開系統設定，在清單裡打開 Articulate。打開後這裡會自動打勾。")
                    Spacer()
                    Button("打開系統設定") { model.openAccessibility() }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    private var ai: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("AI 潤稿", "刪除贅字、套用改口、排成條列。選一個用你自己帳號的 AI 來處理，不需要 API 金鑰。")
                .padding(.bottom, -12)
            engineOption(.codex, title: "Codex", subtitle: "用你的 ChatGPT 帳號・短句約 1.2 秒")
            engineOption(.claudeCode, title: "Claude", subtitle: "用你的 Claude 訂閱（Pro／Max）・短句約 2 秒")
            if model.chosenEngine == .codex && model.codex == .missing {
                install("安裝 Codex（擇一，在終端機執行）", ["brew install codex", "npm install -g @openai/codex"], then: "裝好後執行 codex login 登入 ChatGPT，再按「重新檢查」。")
            }
            if model.chosenEngine == .claudeCode && model.claude == .missing {
                install("安裝 Claude Code（擇一，在終端機執行）", ["curl -fsSL https://claude.ai/install.sh | bash", "brew install --cask claude-code"],
                        then: "裝好後執行 claude auth login 登入你的 Claude 帳號，再按「重新檢查」。")
            }
        }
    }

    /// One AI choice: a radio button, what it uses, and its install or sign-in state with the next action.
    private func engineOption(_ engine: PolishEngine, title: String, subtitle: String) -> some View {
        let selected = model.chosenEngine == engine
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(selected ? Theme.accent : Theme.tertiaryInk)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(Theme.cardTitle()).foregroundStyle(Theme.ink)
                    Text(subtitle).font(Theme.caption()).foregroundStyle(Theme.secondaryInk)
                }
                engineStatus(engine)
            }
            Spacer(minLength: 8)
            engineAction(engine)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { model.choose(engine) }
    }

    @ViewBuilder private func engineStatus(_ engine: PolishEngine) -> some View {
        let line: (String, Color) = switch engine {
        case .claudeCode:
            switch model.claude {
            case .checking: ("正在檢查…", Theme.secondaryInk)
            case .missing: ("這台 Mac 沒有找到 Claude Code", .orange)
            case .signedOut(let f): ("已找到 Claude Code \(f.version)，還沒用 Claude 訂閱登入", .orange)
            case .signingIn: ("請在瀏覽器完成登入…", Theme.secondaryInk)
            case .ready(let f, let plan): ("已找到 Claude Code \(f.version)，已用 Claude \(plan.map { $0.capitalized } ?? "訂閱")登入", .green)
            }
        default:
            switch model.codex {
            case .checking: ("正在檢查…", Theme.secondaryInk)
            case .missing: ("這台 Mac 沒有找到 Codex", .orange)
            case .signedOut(let f): ("已找到 Codex \(f.version)，還沒登入 ChatGPT", .orange)
            case .signingIn: ("請在瀏覽器完成登入…", Theme.secondaryInk)
            case .ready(let f): ("已找到 Codex \(f.version)，已用 ChatGPT 登入", .green)
            }
        }
        HStack(spacing: 6) {
            Circle().fill(line.1).frame(width: 7, height: 7)
            Text(line.0).font(Theme.caption()).foregroundStyle(Theme.secondaryInk)
        }
    }

    @ViewBuilder private func engineAction(_ engine: PolishEngine) -> some View {
        switch engine {
        case .claudeCode:
            switch model.claude {
            case .checking: ProgressView().controlSize(.small)
            case .missing: Button("重新檢查") { Task { await model.checkClaude() } }.buttonStyle(SecondaryButtonStyle())
            case .signedOut: Button("登入 Claude") { model.choose(.claudeCode); model.signInClaude() }.buttonStyle(PrimaryButtonStyle())
            case .signingIn: Button("取消") { model.cancelClaudeSignIn() }.buttonStyle(SecondaryButtonStyle())
            case .ready: EmptyView()
            }
        default:
            switch model.codex {
            case .checking: ProgressView().controlSize(.small)
            case .missing: Button("重新檢查") { Task { await model.checkCodex() } }.buttonStyle(SecondaryButtonStyle())
            case .signedOut: Button("登入 ChatGPT") { model.choose(.codex); model.signInCodex() }.buttonStyle(PrimaryButtonStyle())
            case .signingIn: Button("取消") { model.cancelSignIn() }.buttonStyle(SecondaryButtonStyle())
            case .ready: EmptyView()
            }
        }
    }

    private func install(_ title: String, _ commands: [String], then: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.cardTitle()).foregroundStyle(Theme.ink)
            ForEach(commands, id: \.self) { command($0) }
            Text(then).font(Theme.caption()).foregroundStyle(Theme.secondaryInk)
        }
        .card()
    }

    private func command(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.ink).textSelection(.enabled)
            Spacer()
            Button {
                TextInserter.copyToPasteboard(text)
            } label: {
                Label("複製", systemImage: "doc.on.doc").font(Theme.caption())
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill))
    }

    private var recognition: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("加強辨識（選用）", "在這台 Mac 上多跑一個台灣華語辨識模型（TEA-ASR），和 Apple 的辨識結果互相比對，同音字和中英夾雜更準。不裝也能正常使用。")
                .padding(.bottom, -8)
            // What it costs, before the user decides; once it is installing, the progress needs the room.
            if installer.state == .notInstalled {
                HStack(spacing: 12) {
                    fact("arrow.down.circle", "下載", "約 4.1 GB")
                    fact("internaldrive", "安裝後佔用", "約 2.5 GB")
                    fact("memorychip", "使用時記憶體", "約 2.5 GB")
                }
                Text("說話時才載入模型，閒置 10 分鐘後自動釋放記憶體。模型來自 Hugging Face（JacobLinCool/TEA-ASR-1.1，MIT 授權），下載後會驗證檔案。")
                    .font(Theme.caption()).foregroundStyle(Theme.secondaryInk)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            installCard
        }
    }

    private func fact(_ symbol: String, _ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.caption()).foregroundStyle(Theme.secondaryInk)
                Text(value).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
            }
        }
        .card(padding: 14)
    }

    @ViewBuilder private var installCard: some View {
        switch installer.state {
        case .notInstalled:
            statusCard {
                VStack(alignment: .leading, spacing: 2) {
                    Text("要下載並安裝嗎？").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                    Text("需要約 8 GB 的可用空間；安裝時可以關掉這個視窗，會在背景繼續。").font(Theme.caption()).foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
                Button("先不要") { model.step = .done }.buttonStyle(SecondaryButtonStyle())
                Button("下載並安裝") { installer.install() }.buttonStyle(PrimaryButtonStyle())
            }
        case .installing(let phase):
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("正在安裝…").font(Theme.cardTitle()).foregroundStyle(Theme.ink)
                    Spacer()
                    Button("取消") { installer.cancel() }.buttonStyle(SecondaryButtonStyle())
                }
                ForEach(TEAInstaller.Phase.allCases) { item in
                    phaseRow(item, current: phase)
                }
            }
            .card()
        case .installed:
            statusCard { status(.ok, "已安裝，辨識模型已切換到「Apple＋TEA 融合」", detail: "之後可以在 設定 › 語言 › 辨識模型 切換。") }
        case .failed(let phase, let message):
            statusCard {
                status(.error, "「\(phase.title)」沒有成功", detail: message)
                Spacer()
                Button("重試") { installer.install() }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func phaseRow(_ item: TEAInstaller.Phase, current: TEAInstaller.Phase) -> some View {
        let done = item.rawValue < current.rawValue
        let active = item == current
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Group {
                    if done {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if active {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "circle").foregroundStyle(Theme.tertiaryInk)
                    }
                }
                .frame(width: 18)
                Text(item.title).font(.system(size: 14, weight: active ? .medium : .regular))
                    .foregroundStyle(active || done ? Theme.ink : Theme.tertiaryInk)
                Spacer()
                if active && item == .download && installer.expected > 0 {
                    Text(downloadStatus).font(Theme.caption().monospacedDigit()).foregroundStyle(Theme.secondaryInk)
                }
            }
            if active && item == .download && installer.expected > 0 {
                ProgressView(value: Double(installer.received), total: Double(installer.expected))
                    .tint(Theme.accent)
                    .padding(.leading, 28)
            }
        }
    }

    private var downloadStatus: String {
        let gb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1e9) }
        var text = "\(gb(installer.received)) / \(gb(installer.expected)) GB"
        if installer.bytesPerSecond > 0 {
            let remaining = Double(installer.expected - installer.received) / installer.bytesPerSecond
            text += String(format: "・%.0f MB/s・剩約 %@", installer.bytesPerSecond / 1e6,
                           remaining > 90 ? "\(Int(remaining / 60)) 分鐘" : "\(Int(remaining)) 秒")
        }
        return text
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(model.permissionsGranted ? "設定完成" : "還差一點",
                   model.permissionsGranted ? "可以開始用了。之後隨時可以從選單列的 Articulate 圖示打開這個視窗。" : "麥克風和輔助使用是必要的，沒有它們 Articulate 無法錄音或貼上文字。")
                .padding(.bottom, -8)
            VStack(alignment: .leading, spacing: 12) {
                summary("麥克風", model.isComplete(.microphone), required: true, step: .microphone)
                summary("輔助使用", model.isComplete(.accessibility), required: true, step: .accessibility)
                summary("AI 潤稿", model.isComplete(.ai), required: false, step: .ai)
                summary("加強辨識", installer.state == .installed, required: false, step: .recognition)
            }
            .card()
            VStack(alignment: .leading, spacing: 10) {
                Text("試試看").font(Theme.cardTitle()).foregroundStyle(Theme.ink)
                HStack(spacing: 6) {
                    Text("點任何輸入框，按一下").font(Theme.body()).foregroundStyle(Theme.secondaryInk)
                    KeyCap(label: Prefs.triggerKey.shortLabel)
                    Text("開始說話，說完再按一下。").font(Theme.body()).foregroundStyle(Theme.secondaryInk)
                }
            }
            .card()
        }
    }

    private func summary(_ title: String, _ ok: Bool, required: Bool, step: SetupModel.Step) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : (required ? "exclamationmark.circle.fill" : "minus.circle"))
                .foregroundStyle(ok ? .green : (required ? .orange : Theme.tertiaryInk))
                .font(.system(size: 14))
            Text(title).font(Theme.body()).foregroundStyle(Theme.ink)
            Spacer()
            if !ok {
                Button(required ? "去設定" : "設定") { model.step = step }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent)
            } else {
                Text("完成").font(Theme.caption()).foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    // MARK: Pieces

    private enum StatusKind { case ok, todo, warning, error }

    private func status(_ kind: StatusKind, _ title: String, detail: String? = nil) -> some View {
        let symbol: String = switch kind {
        case .ok: "checkmark.circle.fill"
        case .todo: "circle.dashed"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
        let tint: Color = switch kind {
        case .ok: .green
        case .todo: Theme.secondaryInk
        case .warning: .orange
        case .error: .red
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail).font(Theme.caption()).foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func statusCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) { content() }.card(padding: 18)
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome {
                Button("上一步") { move(-1) }.buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            if model.step == .done {
                Button("開始使用") { onFinish() }.buttonStyle(PrimaryButtonStyle())
            } else {
                Button(model.step == .welcome ? "開始設定" : "繼續") { move(1) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 16)
        .background(Theme.canvas)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    private func move(_ delta: Int) {
        let all = SetupModel.Step.allCases
        guard let index = all.firstIndex(of: model.step) else { return }
        model.step = all[max(0, min(all.count - 1, index + delta))]
    }
}
