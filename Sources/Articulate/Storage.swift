import Combine
import Foundation
import Security

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Articulate", isDirectory: true)
        // The app used to be called Murmur: its history, dictionary, recordings and speech model move over once.
        let legacy = base.appendingPathComponent("Murmur", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let recordings: URL = {
        let dir = support.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

// MARK: - Keychain

/// Stores the Anthropic API key in the login Keychain.
enum Keychain {
    private static let service = "local.articulate.dictation"
    /// Where the key was kept while the app was called Murmur; it moves over the first time it is read.
    private static let legacyService = "local.murmur.dictation"
    private static let account = "anthropic-api-key"

    private static var baseQuery: [String: Any] { query(service) }

    private static func query(_ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func apiKey() -> String? {
        if let key = read(service) { return key }
        guard let key = read(legacyService) else { return nil }
        if setAPIKey(key) { SecItemDelete(query(legacyService) as CFDictionary) }
        return key
    }

    private static func read(_ service: String) -> String? {
        var query = query(service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func setAPIKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func deleteAPIKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - History

struct HistoryEntry: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case completed, cancelled, error, empty
    }

    var id = UUID()
    var date: Date
    var raw: String
    var text: String
    var appName: String?
    var duration: TimeInterval
    var engine: String?
    // Added for mode support; optional so older history files still decode.
    var mode: DictationMode?
    var status: Status?
    var bundleID: String?
    var audioFile: String?
    var targetLanguage: String?
    var askAction: String?
    var revertedAI: Bool?
    var editedText: String?
    var errorMessage: String?

    var effectiveMode: DictationMode { mode ?? .dictation }
    var effectiveStatus: Status { status ?? .completed }
    var audioURL: URL? { audioFile.map { AppPaths.recordings.appendingPathComponent($0) } }
    /// What the user ended up with: their own edit, the raw text after undo, or the AI result.
    var finalText: String { editedText ?? (revertedAI == true ? raw : text) }
}

/// Local history in ~/Library/Application Support/Articulate/history.json, plus saved recordings.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let limit = 1000

    @Published private(set) var entries: [HistoryEntry] = []
    private let url = AppPaths.support.appendingPathComponent("history.json")

    private init() {
        if let data = try? Data(contentsOf: url) {
            entries = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
        }
        applyRetention()
    }

    var lastCompleted: HistoryEntry? {
        entries.first { $0.effectiveStatus == .completed && !$0.finalText.isEmpty }
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit {
            for old in entries[Self.limit...] { deleteAudio(old) }
            entries.removeLast(entries.count - Self.limit)
        }
        save()
    }

    func update(_ id: UUID, _ change: (inout HistoryEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
        save()
    }

    func delete(_ ids: Set<UUID>) {
        for entry in entries where ids.contains(entry.id) { deleteAudio(entry) }
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        for entry in entries { deleteAudio(entry) }
        entries.removeAll()
        save()
    }

    /// Deletes entries older than the retention setting. "Never" keeps only the latest in memory.
    func applyRetention() {
        guard let maxAge = Prefs.historyRetention.maxAge else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        let keepLatest = maxAge == 0 ? entries.first.map { [$0.id] } ?? [] : []
        let expired = entries.filter { $0.date < cutoff || maxAge == 0 }
        for entry in expired { deleteAudio(entry) }
        entries.removeAll { entry in (entry.date < cutoff || maxAge == 0) && !keepLatest.contains(entry.id) }
        if maxAge == 0 {
            for i in entries.indices { entries[i].audioFile = nil }
        }
        save()
    }

    private func deleteAudio(_ entry: HistoryEntry) {
        if let audio = entry.audioURL { try? FileManager.default.removeItem(at: audio) }
    }

    private func save() {
        if Prefs.historyRetention == .never {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Recent texts the user wrote in an app, used as style references when personalization is on.
    func styleExamples(bundleID: String?, limit: Int = 3) -> [String] {
        guard let bundleID else { return [] }
        return entries.lazy
            .filter { $0.bundleID == bundleID && $0.effectiveMode == .dictation && $0.effectiveStatus == .completed }
            .map(\.finalText)
            .filter { (8...300).contains($0.count) }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Personal dictionary

struct DictionaryWord: Codable, Identifiable, Hashable {
    enum Source: String, Codable { case manual, auto }

    var id = UUID()
    var term: String
    var source: Source
    var date = Date()
}

@MainActor
final class DictionaryStore: ObservableObject {
    static let shared = DictionaryStore()
    static let maxTermLength = 60
    static let capacity = 2000

    @Published private(set) var words: [DictionaryWord] = []
    private let url = AppPaths.support.appendingPathComponent("dictionary.json")

    private init() {
        if let data = try? Data(contentsOf: url) {
            words = (try? JSONDecoder().decode([DictionaryWord].self, from: data)) ?? []
        }
    }

    /// Terms for prompts and speech recognition hints, most recent first.
    var terms: [String] { words.map(\.term) }

    func contains(_ term: String) -> Bool {
        words.contains { $0.term.caseInsensitiveCompare(term) == .orderedSame }
    }

    @discardableResult
    func add(_ term: String, source: DictionaryWord.Source) -> Bool {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= Self.maxTermLength, !contains(term), words.count < Self.capacity else { return false }
        words.insert(DictionaryWord(term: term, source: source), at: 0)
        save()
        return true
    }

    func update(_ id: UUID, term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= Self.maxTermLength, let i = words.firstIndex(where: { $0.id == id }) else { return }
        words[i].term = term
        save()
    }

    func delete(_ ids: Set<UUID>) {
        words.removeAll { ids.contains($0.id) }
        save()
    }

    /// Takes out automatically learned entries that are bits of sentences rather than names or terms (learned
    /// before that filter existed). Words the user added are never touched. Returns what was removed.
    @discardableResult
    func removeAutoLearnedPhrases(keeping isTerm: (String) -> Bool) -> [String] {
        let phrases = words.filter { $0.source == .auto && !isTerm($0.term) }.map(\.term)
        if !phrases.isEmpty { remove(phrases) }
        return phrases
    }

    func remove(_ terms: [String]) {
        words.removeAll { word in terms.contains { $0.caseInsensitiveCompare(word.term) == .orderedSame } }
        save()
    }

    /// One-column CSV, one term per row. Returns the terms that were new.
    static func parseCSV(_ data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            var term = line.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
            term = term.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\u{FEFF}"))
            guard !term.isEmpty, term.count <= maxTermLength, seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }
    }

    func importTerms(_ terms: [String]) -> Int {
        var added = 0
        for term in terms where add(term, source: .manual) { added += 1 }
        return added
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(words) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Usage stats

/// Daily totals, kept independently of history so deleting history doesn't reset stats.
@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()
    /// Typical typing speed used for "time saved".
    static let typingWPM = 40.0

    struct Day: Codable {
        var words = 0
        var seconds = 0.0
        var sessions = 0
    }

    @Published private(set) var days: [String: Day] = [:]
    private let url = AppPaths.support.appendingPathComponent("stats.json")
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        if let data = try? Data(contentsOf: url) {
            days = (try? JSONDecoder().decode([String: Day].self, from: data)) ?? [:]
        }
    }

    static func key(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// Words as Typeless counts them for mixed text: each CJK character, plus each Latin word.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if (0x3400...0x9FFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value) {
                count += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { count += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return count
    }

    func record(text: String, seconds: TimeInterval, at date: Date = Date()) {
        var day = days[Self.key(date)] ?? Day()
        day.words += Self.wordCount(text)
        day.seconds += seconds
        day.sessions += 1
        days[Self.key(date)] = day
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: url, options: .atomic) }
    }

    func replace(_ snapshot: [String: Day]) {
        days = snapshot
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: url, options: .atomic) }
    }

    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    var totalSeconds: Double { days.values.reduce(0) { $0 + $1.seconds } }
    var averageWPM: Int { totalSeconds > 0 ? Int(Double(totalWords) / (totalSeconds / 60)) : 0 }
    var timeSavedSeconds: Double { max(0, Double(totalWords) / Self.typingWPM * 60 - totalSeconds) }

    var activeDays: Set<String> { Set(days.filter { $0.value.sessions > 0 }.keys) }

    var currentStreak: Int {
        var streak = 0
        var date = Date()
        // A streak still counts if today has no dictation yet.
        if !activeDays.contains(Self.key(date)) { date = Calendar.current.date(byAdding: .day, value: -1, to: date)! }
        while activeDays.contains(Self.key(date)) {
            streak += 1
            date = Calendar.current.date(byAdding: .day, value: -1, to: date)!
        }
        return streak
    }

    var longestStreak: Int {
        let dates = activeDays.compactMap { Self.dayFormatter.date(from: $0) }.sorted()
        var best = 0
        var run = 0
        var previous: Date?
        for date in dates {
            if let previous, Calendar.current.dateComponents([.day], from: previous, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = date
        }
        return best
    }
}
