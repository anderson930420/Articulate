import Foundation

/// `Articulate --learn-from-transcripts [--apply]`: catches up on dictionary learning for dictations made before the
/// edit learner could see edits made right before sending. Articulate's history has what it pasted; Claude Code's
/// local transcripts (~/.claude/projects) have what the user actually sent. Where a sent message contains a
/// pasted text with changes, the corrected names and terms are found as in live learning (AI, then the term
/// filter). Without `--apply` it only lists them.
@MainActor
enum TranscriptLearning {
    struct Sent {
        let date: Date
        let text: String
    }

    static func run(apply: Bool) async {
        let sent = loadSentMessages()
        let pasted = HistoryStore.shared.entries.filter {
            $0.effectiveMode == .dictation && $0.effectiveStatus == .completed && !$0.text.isEmpty
        }
        print("\(pasted.count) dictations in history, \(sent.count) messages sent in Claude Code")

        // The message sent within ten minutes after pasting that contains the pasted text, edited.
        var pairs: [(original: String, edited: String)] = []
        for entry in pasted {
            // What was pasted (the AI's version, or the raw one after switching back).
            let original = entry.revertedAI == true ? entry.raw : entry.text
            let window = sent.filter { $0.date >= entry.date && $0.date.timeIntervalSince(entry.date) < 600 }
            for message in window {
                guard let edited = EditLearner.editedVersion(of: original, in: message.text, near: nil) else { continue }
                if edited != original, EditLearner.coverage(of: original, by: edited) >= 0.5 { pairs.append((original, edited)) }
                break
            }
        }
        print("\(pairs.count) of them were edited before sending")

        guard let engine = AIEngine.current() else {
            print("no AI engine")
            return
        }
        AIEngine.prewarm()
        var learned: [String] = []
        for pair in pairs {
            let terms = (try? await AITasks.learnedTerms(original: pair.original, edited: pair.edited, with: engine)) ?? []
            for term in terms where EditLearner.isCorrection(term, original: pair.original, edited: pair.edited)
                && !learned.contains(term) && !DictionaryStore.shared.contains(term) {
                learned.append(term)
                print("  「\(term)」 ← \(pair.original.prefix(40)) → \(pair.edited.prefix(40))")
            }
        }
        // Names of the user's own projects (folder names such as "Zentrova-Quillmark"): names nobody else's speech
        // model has heard. In a 36-recording test, a project name in the dictionary fixed it being heard as three
        // unrelated English words.
        for name in projectNames() where !learned.contains(name) && !DictionaryStore.shared.contains(name) {
            learned.append(name)
            print("  「\(name)」 ← project folder")
        }
        if apply {
            let added = learned.filter { DictionaryStore.shared.add($0, source: .auto) }
            print("added \(added.count) term(s) to the dictionary: \(added)")
        } else {
            print("\(learned.count) term(s) would be added; run again with --apply to add them")
        }
    }

    /// Proper-noun-looking parts of top-level folder names in Desktop, Documents and Developer: capitalized or
    /// all-caps Latin words that are not ordinary English words (Chinese folder names are mostly everyday words).
    static func projectNames() -> [String] {
        let english = Set(((try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { $0.first?.isLowercase == true })
        func isEnglish(_ word: String) -> Bool {
            let w = word.lowercased()
            return english.contains(w) || ["s", "es", "ed", "ing"].contains { w.hasSuffix($0) && english.contains(String(w.dropLast($0.count))) }
        }
        var names: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in ["Desktop", "Documents", "Developer"] {
            let dir = home.appendingPathComponent(folder)
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                for part in item.lastPathComponent.split(whereSeparator: { "-_ .＿()（）".contains($0) }).map(String.init) {
                    guard part.count >= 3, part.first?.isUppercase == true, part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                          part.contains(where: \.isLetter), !isEnglish(part), !names.contains(part) else { continue }
                    names.append(part)
                }
            }
        }
        return names
    }

    /// What the user typed into Claude Code sessions: user messages with text, not tool results.
    private static func loadSentMessages() -> [Sent] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var messages: [Sent] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let data = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in data.split(separator: "\n") where line.contains("\"type\":\"user\"") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let stamp = object["timestamp"] as? String, let date = iso.date(from: stamp),
                      let message = object["message"] as? [String: Any], message["role"] as? String == "user" else { continue }
                let text: String
                if let string = message["content"] as? String {
                    text = string
                } else if let parts = message["content"] as? [[String: Any]] {
                    text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                } else {
                    continue
                }
                if !text.isEmpty { messages.append(Sent(date: date, text: text)) }
            }
        }
        return messages
    }
}
