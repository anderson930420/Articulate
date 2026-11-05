import AppKit
import ApplicationServices

enum Sounds {
    static func start() { play("Tink") }
    static func stop() { play("Pop") }
    static func error() { play("Basso") }

    private static func play(_ name: String) {
        guard Prefs.interactionSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

/// After text is inserted, watches the same field to see how the user edits it, Typeless style.
/// Edits feed the personal dictionary (corrected names and terms) and personalization.
///
/// The field is read every second for up to two minutes, keeping the last version in which the inserted text
/// can still be found. In chat apps the user fixes a word and presses Enter at once, emptying the field, so
/// waiting and reading once (as before) found nothing; the last version seen before sending is what counts.
@MainActor
final class EditLearner {
    struct Pending {
        var entryID: UUID
        var inserted: String
        var element: AXUIElement
        var offset: Int?
        /// The inserted text as last seen in the field, with the user's edits.
        var latest: String
        var startedAt = Date()
        /// The field's text before and after the inserted part, once it has been seen there unedited.
        var anchors: (before: String, after: String)?
    }

    static let pollInterval: TimeInterval = 1
    static let watchDuration: TimeInterval = 120

    var onLearned: (([String]) -> Void)?
    /// Reads a field's text; replaced in tests.
    var readValue: (AXUIElement) -> String? = { ScreenContextReader.value(of: $0) }
    private var pending: Pending?
    private var timer: Timer?
    /// The last edited version learned from (for the self-test).
    private(set) var lastEdited: String?

    func track(entryID: UUID, inserted: String, screen: ScreenContext?) {
        checkPending()
        guard Prefs.autoLearnDictionary, let screen, screen.focusIsEditable == true, let element = screen.focusedElement else { return }
        // Reads also happen inside the keyboard tap (on Enter), so a slow app must never hold them up.
        AXUIElementSetMessagingTimeout(element, 0.2)
        pending = Pending(entryID: entryID, inserted: inserted, element: element, offset: screen.insertionOffset, latest: inserted)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func pollIfWatching() {
        if pending != nil { poll() }
    }

    /// One look at the field: remember the current version, or finish once the text is gone (sent, cleared,
    /// field closed) or the watch time is over.
    func poll() {
        guard let started = pending?.startedAt else { return }
        if !look() || Date().timeIntervalSince(started) >= Self.watchDuration { finish() }
    }

    /// Learns from the field as it is now (or as last seen, if the text is gone). Also called before the next
    /// dictation starts, so an edit made in the last second still counts.
    @discardableResult
    func checkPending() -> String? {
        look()
        return finish()
    }

    /// Reads the field and keeps the user's version of the inserted text; false when it is no longer there.
    @discardableResult
    private func look() -> Bool {
        guard var p = pending, let value = readValue(p.element) else { return false }
        if p.anchors == nil { p.anchors = Self.anchors(of: p.inserted, in: value, near: p.offset) }
        // While the text around it is unchanged, whatever lies between is the user's version, however much a
        // fix changed it (a few misheard Chinese characters replaced by an English name). Otherwise search.
        let region: String?
        if let (before, after) = p.anchors, value.count >= before.count + after.count, value.hasPrefix(before), value.hasSuffix(after) {
            region = String(value.dropFirst(before.count).dropLast(after.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            region = Self.editedVersion(of: p.inserted, in: value, near: p.offset)
        }
        pending = p
        // Gone (sent, cleared) or replaced by something unrelated: the last version seen stands.
        guard let region, !region.isEmpty, Self.coverage(of: p.inserted, by: region) >= 0.5 else { return false }
        pending?.latest = region
        return true
    }

    /// Learns from the last version seen.
    @discardableResult
    private func finish() -> String? {
        timer?.invalidate()
        timer = nil
        guard let p = pending else { return nil }
        pending = nil
        let edited = p.latest
        guard edited != p.inserted else { return nil }
        lastEdited = edited

        HistoryStore.shared.update(p.entryID) { $0.editedText = edited }
        let original = p.inserted
        Task {
            var terms: [String]
            if let engine = AIEngine.current() {
                terms = (try? await AITasks.learnedTerms(original: original, edited: edited, with: engine)) ?? []
            } else {
                terms = Self.heuristicTerms(original: original, edited: edited)
            }
            terms = terms.filter { Self.isCorrection($0, original: original, edited: edited) && DictionaryStore.shared.add($0, source: .auto) }
            if !terms.isEmpty { onLearned?(terms) }
        }
        return edited
    }

    /// The text before and after `inserted` in `value` (the occurrence nearest the insertion point).
    static func anchors(of inserted: String, in value: String, near utf16Offset: Int?) -> (before: String, after: String)? {
        var best: Range<String.Index>?
        var searchStart = value.startIndex
        while let range = value.range(of: inserted, range: searchStart..<value.endIndex) {
            let distance = abs(value.utf16.distance(from: value.utf16.startIndex, to: range.lowerBound) - (utf16Offset ?? 0))
            if best.map({ abs(value.utf16.distance(from: value.utf16.startIndex, to: $0.lowerBound) - (utf16Offset ?? 0)) > distance }) ?? true {
                best = range
            }
            searchStart = range.upperBound
        }
        guard let best else { return nil }
        return (String(value[..<best.lowerBound]), String(value[best.upperBound...]))
    }

    /// How much of `original` survives in `edited`: LCS / |original|. Replacing a word keeps most of the sentence.
    static func coverage(of original: String, by edited: String) -> Double {
        let a = Array(original), b = Array(edited)
        guard !a.isEmpty else { return 0 }
        return similarity(a, b) * Double(a.count + b.count) / 2 / Double(a.count)
    }

    /// Finds the region of `value` that corresponds to the inserted text after the user's edits.
    static func editedVersion(of inserted: String, in value: String, near utf16Offset: Int?) -> String? {
        if value.contains(inserted) { return inserted }
        let chars = Array(value)
        let target = Array(inserted)
        guard !target.isEmpty, !chars.isEmpty else { return nil }

        // Candidate start positions: the recorded insertion point, then everywhere.
        var starts: [Int] = []
        if let utf16Offset {
            let utf16 = value.utf16
            if let idx = utf16.index(utf16.startIndex, offsetBy: min(utf16Offset, utf16.count), limitedBy: utf16.endIndex),
               let charIndex = idx.samePosition(in: value) {
                starts.append(value.distance(from: value.startIndex, to: charIndex))
            }
        }
        let step = max(1, chars.count / 200)
        starts += stride(from: 0, to: chars.count, by: step)

        var best: (score: Double, text: String)?
        let lengths = Set([0.6, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5].map { max(1, Int(Double(target.count) * $0)) })
        for start in starts.prefix(220) {
            for length in lengths where start + length <= chars.count {
                let candidate = Array(chars[start..<(start + length)])
                let score = similarity(candidate, target)
                if score > (best?.score ?? 0) { best = (score, String(candidate)) }
            }
        }
        // Fixing a name or two keeps the text very similar; a lower bar matched unrelated parts of long fields.
        guard let best, best.score >= 0.75 else { return nil }
        return best.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 2·LCS / (|a| + |b|).
    static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return 2 * Double(previous[b.count]) / Double(a.count + b.count)
    }

    /// A term the user really corrected: it looks like a name or term, is in the edited text and was not there before.
    static func isCorrection(_ term: String, original: String, edited: String) -> Bool {
        looksLikeTerm(term) && edited.range(of: term, options: .caseInsensitive) != nil
            && original.range(of: term, options: .caseInsensitive) == nil
    }

    /// The AI sometimes returns a rewritten bit of sentence ("要畫幾種圖") instead of a name or term. Names, brands
    /// and abbreviations with Latin letters or digits pass; Chinese ones must be short and free of grammar words.
    static func looksLikeTerm(_ term: String) -> Bool {
        if term.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) { return true }
        let grammar: Set<Character> = ["的", "了", "是", "我", "你", "他", "她", "要", "會", "在", "有", "嗎", "吧", "呢", "幾",
                                       "把", "被", "就", "都", "也", "還", "很", "這", "那", "個", "們", "和", "跟", "給", "讓", "不", "沒"]
        return term.count <= 8 && !term.contains(where: grammar.contains)
    }

    /// Without an AI engine: new Latin-script words that look like names or terms.
    static func heuristicTerms(original: String, edited: String) -> [String] {
        func words(_ s: String) -> Set<String> {
            Set(s.split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }.map(String.init))
        }
        let before = words(original)
        return words(edited).subtracting(before).filter { word in
            word.count >= 2 && word.unicodeScalars.allSatisfy { $0.isASCII }
                && (word.first?.isUppercase == true || word.contains { $0.isNumber } || word.dropFirst().contains { $0.isUppercase })
        }.sorted()
    }
}
