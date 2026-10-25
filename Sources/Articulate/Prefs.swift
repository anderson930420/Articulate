import CoreGraphics
import Foundation

/// The modifier key that starts dictation while held.
enum TriggerKey: String, CaseIterable, Identifiable {
    case rightCommand, rightOption, fn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightCommand: "右 ⌘ Command"
        case .rightOption: "右 ⌥ Option"
        case .fn: "fn / 🌐"
        }
    }

    var shortLabel: String {
        switch self {
        case .rightCommand: "右⌘"
        case .rightOption: "右⌥"
        case .fn: "fn"
        }
    }

    /// Virtual key code reported in flagsChanged events.
    var keyCode: Int64 {
        switch self {
        case .rightCommand: 54
        case .rightOption: 61
        case .fn: 63
        }
    }

    /// Device-dependent flag bit that is set only while this exact key is down.
    var pressedMask: UInt64 {
        switch self {
        case .rightCommand: 0x10 // NX_DEVICERCMDKEYMASK
        case .rightOption: 0x40 // NX_DEVICERALTKEYMASK
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    /// Generic modifier class of the trigger, excluded when checking for other modifiers.
    var classMask: UInt64 {
        switch self {
        case .rightCommand: CGEventFlags.maskCommand.rawValue
        case .rightOption: CGEventFlags.maskAlternate.rawValue
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    /// Flag bit of the same modifier on the other side of the keyboard.
    var otherSideMask: UInt64 {
        switch self {
        case .rightCommand: 0x08 // NX_DEVICELCMDKEYMASK
        case .rightOption: 0x20 // NX_DEVICELALTKEYMASK
        case .fn: 0
        }
    }
}

enum PolishEngine: String, CaseIterable, Identifiable {
    case auto, apple, claude, codex, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "自動"
        case .apple: "Apple Intelligence（本機）"
        case .claude: "Claude API"
        case .codex: "Codex（用你的 ChatGPT 登入）"
        case .off: "關閉（直接輸出辨識結果）"
        }
    }
}

enum DictationLanguage: String, CaseIterable, Identifiable {
    case zhTW = "zh-TW", zhCN = "zh-CN", zhHK = "zh-HK", enUS = "en-US"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zhTW: "繁體中文（台灣）"
        case .zhCN: "简体中文（中国大陆）"
        case .zhHK: "粵語／繁體中文（香港）"
        case .enUS: "English (US)"
        }
    }
}

/// UserDefaults-backed preferences. Keys match the @AppStorage keys in SettingsView.
enum Prefs {
    private static var d: UserDefaults { .standard }

    static var triggerKey: TriggerKey {
        TriggerKey(rawValue: d.string(forKey: "triggerKey") ?? "") ?? .rightCommand
    }

    static var language: DictationLanguage {
        DictationLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .zhTW
    }

    static var polishEngine: PolishEngine {
        PolishEngine(rawValue: d.string(forKey: "polishEngine") ?? "") ?? .auto
    }

    static var claudeModel: String {
        let m = d.string(forKey: "claudeModel")?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? "claude-opus-5-5" : m
    }

    /// The Codex model setting: a model id, or `autoCodexModel`.
    static var codexModelSetting: String {
        let m = d.string(forKey: "codexModel")?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? autoCodexModel : m
    }

    /// Short dictations go to the fast model, long ones to the stronger one. On 36 Typeless recordings the stronger
    /// model made about a third fewer content errors on dictations of 100+ characters (27 vs 41) and about the same
    /// below (11 vs 13), at 0.3–1 s more per dictation (README "潤稿模型").
    static let autoCodexModel = "auto"
    static let fastCodexModel = "gpt-6-luna"
    static let strongCodexModel = "gpt-6.1-sol"
    static let strongModelFromLength = 100

    /// Codex model for AI tasks that are not routed by length (and the `codex exec` path).
    static var codexModel: String {
        let m = codexModelSetting
        return m == autoCodexModel ? fastCodexModel : m
    }

    /// The models to keep primed threads for.
    static var codexModelsInUse: [String] {
        codexModelSetting == autoCodexModel ? [fastCodexModel, strongCodexModel] : [codexModel]
    }

    /// The model for a request whose transcript is `length` characters; `continuation` is the later part of a long
    /// dictation polished while the user was still talking.
    static func codexModel(transcriptLength length: Int?, continuation: Bool) -> String {
        guard codexModelSetting == autoCodexModel, let length else { return codexModel }
        return continuation || length >= strongModelFromLength ? strongCodexModel : fastCodexModel
    }

    /// Settings from when the app was called Murmur (another defaults domain), copied over once. `setupDone` stays
    /// behind: the renamed app is a new app to macOS and needs its permissions again, which setup walks through.
    static func migrateLegacySettings() {
        guard !d.bool(forKey: "migratedFromMurmur") else { return }
        d.set(true, forKey: "migratedFromMurmur")
        guard let old = d.persistentDomain(forName: "local.murmur.dictation") else { return }
        for (key, value) in old where key != "setupDone" && d.object(forKey: key) == nil {
            d.set(value, forKey: key)
        }
    }

    /// The first-run setup was finished or skipped (or everything was already in place).
    static var setupDone: Bool {
        get { d.bool(forKey: "setupDone") }
        set { d.set(newValue, forKey: "setupDone") }
    }

    static var logoStyle: LogoStyle {
        LogoStyle(rawValue: d.string(forKey: "logoStyle") ?? "") ?? .handwritten
    }

    static var pressMode: PressMode {
        PressMode(rawValue: d.string(forKey: "pressMode") ?? "") ?? .both
    }

    /// Use Codex's priority ("Fast") service tier.
    static var codexFast: Bool {
        d.object(forKey: "codexFast") as? Bool ?? true
    }

    /// Which on-device recognizer to use.
    static var recognizer: Recognizer {
        // SpeechTranscriber made ~35–40% fewer content errors than DictationTranscriber on the user's recordings.
        Recognizer(rawValue: d.string(forKey: "recognizer") ?? "") ?? .speech
    }

    static var muteBackgroundAudio: Bool {
        d.object(forKey: "muteBackgroundAudio") as? Bool ?? true
    }

    static var showLivePreview: Bool {
        d.object(forKey: "showLivePreview") as? Bool ?? false
    }

    /// How long the "undo AI edits" bar stays up after inserting, and again after each switch.
    static var aiEditsBarSeconds: Double {
        d.object(forKey: "aiEditsBarSeconds") as? Double ?? 5
    }

    static var interactionSounds: Bool {
        d.object(forKey: "interactionSounds") as? Bool ?? true
    }

    static var showIdleBar: Bool {
        d.object(forKey: "showIdleBar") as? Bool ?? false
    }

    static var showInDock: Bool {
        d.object(forKey: "showInDock") as? Bool ?? false
    }

    static var appearance: AppAppearance {
        AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
    }

    /// Send app name, window title, page URL and text around the cursor to the AI.
    static var sendScreenContext: Bool {
        d.object(forKey: "sendScreenContext") as? Bool ?? true
    }

    /// Learn writing style from past dictations and include examples in prompts.
    static var personalization: Bool {
        d.object(forKey: "personalization") as? Bool ?? false
    }

    /// Learn new words from edits made after insertion.
    static var autoLearnDictionary: Bool {
        d.object(forKey: "autoLearnDictionary") as? Bool ?? true
    }

    /// Unique ID of the chosen input device, or empty for the system default.
    static var microphoneUID: String {
        d.string(forKey: "microphoneUID") ?? ""
    }

    static var historyRetention: HistoryRetention {
        HistoryRetention(rawValue: d.string(forKey: "historyRetention") ?? "") ?? .forever
    }

    /// Up to three target languages for translation mode (BCP-47 codes).
    static var translationTargets: [String] {
        get {
            let stored = d.stringArray(forKey: "translationTargets") ?? []
            return stored.isEmpty ? ["en-US"] : Array(stored.prefix(3))
        }
        set { d.set(Array(newValue.prefix(3)), forKey: "translationTargets") }
    }
}

/// How the trigger key starts and ends a dictation.
enum PressMode: String, CaseIterable, Identifiable {
    /// A quick tap starts and the next tap finishes; a longer press is push-to-talk (Typeless's default).
    case both
    /// Push-to-talk only: speak while holding, release to insert. A quick tap does nothing.
    case hold
    /// Tap to start, tap again to finish, however long the first press was.
    case toggle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .both: "兩種都可以"
        case .hold: "按住說話，放開輸入"
        case .toggle: "按一下開始，再按一下結束"
        }
    }

    /// One sentence on how to dictate with `key`.
    func howTo(_ key: String) -> String {
        switch self {
        case .both: "按一下 \(key) 開始說話，說完再按一下；也可以按住說話、放開輸入。"
        case .hold: "按住 \(key) 說話，放開就輸入。"
        case .toggle: "按一下 \(key) 開始說話，說完再按一下輸入。"
        }
    }
}

/// Which Articulate logo the app icon, sidebar and menu bar show.
enum LogoStyle: String, CaseIterable, Identifiable {
    /// The hand-drawn V with a small heart.
    case handwritten
    /// The original voice wave that settles into a line of text.
    case wave

    var id: String { rawValue }

    var label: String {
        switch self {
        case .handwritten: "手寫 V"
        case .wave: "聲波"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "系統"
        case .light: "淺色"
        case .dark: "深色"
        }
    }
}

enum HistoryRetention: String, CaseIterable, Identifiable {
    case never, day, week, month, forever

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: "不保存"
        case .day: "24 小時"
        case .week: "1 週"
        case .month: "1 個月"
        case .forever: "永久"
        }
    }

    /// Entries older than this are deleted; nil keeps everything.
    var maxAge: TimeInterval? {
        switch self {
        case .never: 0
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .forever: nil
        }
    }
}

/// Target languages offered in translation mode.
enum TranslationLanguages {
    static let all: [(code: String, label: String)] = [
        ("en-US", "English"), ("zh-TW", "繁體中文"), ("zh-CN", "简体中文"), ("ja-JP", "日本語"),
        ("ko-KR", "한국어"), ("es-ES", "Español"), ("fr-FR", "Français"), ("de-DE", "Deutsch"),
        ("it-IT", "Italiano"), ("pt-BR", "Português"), ("vi-VN", "Tiếng Việt"), ("th-TH", "ไทย"),
        ("id-ID", "Bahasa Indonesia"), ("ru-RU", "Русский"), ("ar-SA", "العربية"), ("hi-IN", "हिन्दी"),
    ]

    static func label(_ code: String) -> String {
        all.first { $0.code == code }?.label ?? code
    }
}

/// What a dictation session produces.
enum DictationMode: String, Codable, CaseIterable {
    case dictation, translation, ask

    var label: String {
        switch self {
        case .dictation: "口述"
        case .translation: "翻譯"
        case .ask: "隨便問"
        }
    }
}

enum Recognizer: String, CaseIterable, Identifiable {
    case dictation, speech
    /// SpeechTranscriber plus TEA-ASR on a local server; the AI compares both transcripts.
    case fusion

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dictation: "DictationTranscriber（聽寫模型）"
        case .speech: "SpeechTranscriber（長篇轉錄模型）"
        case .fusion: "Apple＋TEA 融合（較準，錄音時多占約 2.6 GB 記憶體）"
        }
    }

    /// LiveTranscriber configuration name.
    var config: String { self == .dictation ? "long" : "speech" }
}
