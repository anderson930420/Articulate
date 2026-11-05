import AppKit
import ApplicationServices
import NaturalLanguage

/// What the user is looking at when dictation starts, read through the Accessibility API.
struct ScreenContext {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var pageURL: String?
    /// Up to ~600 characters before the cursor in the focused text field.
    var textBefore: String?
    /// Up to ~200 characters after the cursor.
    var textAfter: String?
    var selectedText: String?
    /// nil when it could not be determined (then we paste anyway).
    var focusIsEditable: Bool?
    /// Accessibility role of the focused element, for diagnostics.
    var focusRole: String?
    /// The focused element, kept to read back the user's edits later.
    var focusedElement: AXUIElement?
    var insertionOffset: Int?
    /// Text visible in the focused window (messages, documents), like Typeless's visible-text capture.
    var visibleText: String?

    init(appName: String? = nil, bundleID: String? = nil, windowTitle: String? = nil, focusIsEditable: Bool? = nil, visibleText: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.focusIsEditable = focusIsEditable
        self.visibleText = visibleText
    }

    var pageDomain: String? {
        pageURL.flatMap { URL(string: $0)?.host() }
    }
}

enum ScreenContextReader {
    private static let browserBundles: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.brave.Browser", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// `includeWindowText: false` reads only the app and the focused field (fast; used right before pasting).
    static func capture(includeWindowText: Bool = true) -> ScreenContext {
        let app = NSWorkspace.shared.frontmostApplication
        var context = ScreenContext(appName: app?.localizedName, bundleID: app?.bundleIdentifier)
        guard let pid = app?.processIdentifier, AXIsProcessTrusted() else { return context }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        // Chromium/Electron only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        if includeWindowText, let window: AXUIElement = attribute(axApp, kAXFocusedWindowAttribute) {
            context.windowTitle = attribute(window, kAXTitleAttribute)
            context.visibleText = visibleText(in: window)
            if let bundle = context.bundleID, browserBundles.contains(bundle) {
                context.pageURL = findURL(in: window, depth: 0)
            }
        }

        guard let focused: AXUIElement = attribute(axApp, kAXFocusedUIElementAttribute) else { return context }
        context.focusedElement = focused
        let role: String? = attribute(focused, kAXRoleAttribute)
        context.focusRole = role
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        let editableAttr: Bool? = attribute(focused, "AXEditable")
        if settable.boolValue || editableAttr == true || role.map(textRoles.contains) == true {
            context.focusIsEditable = true
        } else if role != nil {
            context.focusIsEditable = false
        }

        let selected: String? = attribute(focused, kAXSelectedTextAttribute)
        if let selected, !selected.isEmpty { context.selectedText = selected }

        if let value: String = attribute(focused, kAXValueAttribute), context.focusIsEditable == true {
            var rangeValue: AnyObject?
            if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
               let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
                var range = CFRange()
                AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
                let utf16 = Array(value.utf16)
                let cursor = min(max(range.location, 0), utf16.count)
                let end = min(cursor + max(range.length, 0), utf16.count)
                context.insertionOffset = cursor
                context.textBefore = String(utf16CodeUnits: Array(utf16[max(0, cursor - 600)..<cursor]), count: cursor - max(0, cursor - 600))
                context.textAfter = String(utf16CodeUnits: Array(utf16[end..<min(utf16.count, end + 200)]), count: min(utf16.count, end + 200) - end)
            }
        }
        return context
    }

    /// Text shown in a window (chat messages, documents), newest last, capped in size and time.
    static func visibleText(in window: AXUIElement, maxCharacters: Int = 4000, budget: TimeInterval = 0.15) -> String? {
        let deadline = Date().addingTimeInterval(budget)
        var pieces: [String] = []
        var total = 0
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        let textRoles: Set<String> = [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, "AXHeading", "AXCell"]
        while !queue.isEmpty, total < maxCharacters * 2, Date() < deadline {
            let (element, depth) = queue.removeFirst()
            let role: String? = attribute(element, kAXRoleAttribute)
            if let role, textRoles.contains(role), let value: String = attribute(element, kAXValueAttribute) ?? attribute(element, kAXDescriptionAttribute),
               value.count >= 2 {
                pieces.append(value)
                total += value.count
            }
            guard depth < 25, let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) else { continue }
            queue += children.prefix(200).map { ($0, depth + 1) }
        }
        guard !pieces.isEmpty else { return nil }
        // Later elements are usually lower on screen, i.e. the most recent messages.
        return String(pieces.joined(separator: "\n").suffix(maxCharacters))
    }

    /// Current value of an element we inserted into, for learning from the user's edits.
    static func value(of element: AXUIElement) -> String? {
        attribute(element, kAXValueAttribute)
    }

    private static func findURL(in element: AXUIElement, depth: Int) -> String? {
        if depth > 12 { return nil }
        let role: String? = attribute(element, kAXRoleAttribute)
        if role == "AXWebArea" {
            if let url: URL = attribute(element, kAXURLAttribute) { return url.absoluteString }
            if let url: String = attribute(element, kAXURLAttribute) { return url }
        }
        if let doc: String = attribute(element, kAXDocumentAttribute), doc.hasPrefix("http") { return doc }
        guard let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) else { return nil }
        for child in children.prefix(30) {
            if let url = findURL(in: child, depth: depth + 1) { return url }
        }
        return nil
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        if T.self == [AXUIElement].self {
            return (value as? [AnyObject])?.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil } as? T
        }
        return value as? T
    }

    /// Fallback for apps that don't expose the selection: copy it with ⌘C and read the pasteboard.
    @MainActor
    static func selectedTextByCopying() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = TextInserter.snapshot(pasteboard)
        let before = pasteboard.changeCount
        TextInserter.postShortcut(keyCode: TextInserter.keyCode(forCharacter: "c") ?? 8, flags: .maskCommand)
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(25))
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        TextInserter.restore(saved, to: pasteboard)
        return text?.isEmpty == false ? text : nil
    }
}

/// Words worth biasing recognition towards, taken from text on screen: English terms and
/// multi-character Chinese words, most frequent first, skipping everyday words.
enum ScreenVocabulary {
    static let everyday: Set<String> = [
        "我們", "你們", "他們", "這個", "那個", "這些", "那些", "因為", "所以", "但是", "然後", "如果", "就是", "還是", "可以",
        "應該", "需要", "已經", "現在", "時候", "什麼", "怎麼", "為什麼", "沒有", "不是", "一個", "一下", "一些", "自己", "知道",
        "覺得", "其實", "部分", "問題", "東西", "方式", "這樣", "那樣", "還有", "或者", "以及", "另外", "同時", "之後", "之前",
        "今天", "明天", "直接", "比較", "使用", "開始", "最後", "所有", "其他", "只要", "例如", "像是", "感覺", "意思", "地方",
    ]

    static func terms(from text: String, limit: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.traditionalChinese)
        tokenizer.string = text
        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            let word = String(text[range])
            guard word.count >= 2, word.contains(where: \.isLetter), !everyday.contains(word) else { continue }
            counts[word, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key.count > $1.key.count) }.prefix(limit).map(\.key)
    }
}
