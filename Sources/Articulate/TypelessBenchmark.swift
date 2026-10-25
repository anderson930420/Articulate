import AVFoundation
import Foundation
import SQLite3
import Speech
import NaturalLanguage

/// Head-to-head with Typeless on the same audio: replays recordings Typeless saved locally through
/// Articulate's pipeline and compares post-release latency and output text
/// (`Articulate --bench-typeless <count> <report> [details]`). Everything runs locally except the AI step.
enum TypelessBenchmark {
    struct Session {
        var audio: URL
        var duration: Double
        var typelessLatency: Double
        var typelessText: String
        var created: Date
    }

    struct Outcome {
        var session: Session
        var raw: String
        var text: String
        var asr: Double
        var polish: Double
        var total: Double { asr + polish }
        var cer: Double
        var rawCER: Double
    }

    static let buckets: [(lower: Int, upper: Int)] = [(0, 20), (20, 50), (50, 100), (100, 200), (200, 400), (400, Int.max)]

    static func loadSessions() -> [Session] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent("Library/Application Support/Typeless")
        let dbPath = base.appendingPathComponent("typeless.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(dbPath)?mode=ro&immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
            select audio_local_path, duration, created_at, updated_at, refined_text from history_v2
            where status = 'completed' and mode = 'voice_transcript' and duration > 0
              and audio_local_path is not null and refined_text is not null and refined_text != ''
            order by created_at desc
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var sessions: [Session] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
            guard let path = text(0), let created = text(2).flatMap(iso.date), let updated = text(3).flatMap(iso.date),
                  let refined = text(4) else { continue }
            let duration = sqlite3_column_double(statement, 1)
            var audio = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: audio.path) {
                audio = base.appendingPathComponent("Recordings").appendingPathComponent(audio.lastPathComponent)
            }
            guard FileManager.default.fileExists(atPath: audio.path) else { continue }
            let latency = updated.timeIntervalSince(created) - duration
            guard latency > 0, latency < 30 else { continue }
            sessions.append(Session(audio: audio, duration: duration, typelessLatency: latency, typelessText: refined, created: created))
        }
        return sessions
    }

    /// Spreads the sample across output-length buckets, most recent first.
    /// With ARTICULATE_SAMPLE_FILE set, the sample is read from (or frozen into) that file so runs stay comparable.
    static func sample(_ sessions: [Session], count: Int) -> [Session] {
        if let path = ProcessInfo.processInfo.environment["ARTICULATE_SAMPLE_FILE"] {
            let url = URL(fileURLWithPath: path)
            if let data = try? Data(contentsOf: url),
               let names = try? JSONDecoder().decode([String].self, from: data) {
                let byName = Dictionary(sessions.map { ($0.audio.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
                return names.compactMap { byName[$0] }
            }
            let picked = freshSample(sessions, count: count)
            try? JSONEncoder().encode(picked.map(\.audio.lastPathComponent)).write(to: url)
            return picked
        }
        return freshSample(sessions, count: count)
    }

    static func freshSample(_ sessions: [Session], count: Int) -> [Session] {
        let perBucket = max(1, count / buckets.count)
        var picked: [Session] = []
        for bucket in buckets {
            picked += sessions.filter { (bucket.lower..<bucket.upper).contains($0.typelessText.count) && $0.duration <= 240 }.prefix(perBucket)
        }
        return picked
    }

    static func normalize(_ text: String) -> [Character] {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformFullwidthHalfwidth, false)
        return Array((mutable as String).lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func cer(_ hypothesis: String, reference: String) -> Double {
        let h = normalize(hypothesis)
        let r = normalize(reference)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var previous = Array(0...h.count)
        for i in 1...r.count {
            var current = [i] + Array(repeating: 0, count: h.count)
            for j in 1...max(h.count, 1) where j <= h.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[h.count]) / Double(r.count)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    /// Saves each recording's result, so it can be judged again later (`--rejudge`).
    static func saveOutcomes(_ outcomes: [Outcome], to url: URL) {
        let rows: [[String: Any]] = outcomes.map {
            ["audio": $0.session.audio.path, "raw": $0.raw, "text": $0.text, "asr": $0.asr, "polish": $0.polish]
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) { try? data.write(to: url) }
    }

    /// Judges saved results again, e.g. with another judge model (ARTICULATE_JUDGE_MODEL).
    static func rejudge(saved: URL, report: URL) async {
        guard let data = try? Data(contentsOf: saved),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("cannot read \(saved.path)")
            return
        }
        let sessions = Dictionary(loadSessions().map { ($0.audio.path, $0) }, uniquingKeysWith: { a, _ in a })
        let outcomes: [Outcome] = rows.compactMap { row in
            guard let path = row["audio"] as? String, let session = sessions[path] else { return nil }
            let raw = row["raw"] as? String ?? "", text = row["text"] as? String ?? ""
            return Outcome(session: session, raw: raw, text: text, asr: row["asr"] as? Double ?? 0, polish: row["polish"] as? Double ?? 0,
                           cer: cer(text, reference: session.typelessText), rawCER: cer(raw, reference: session.typelessText))
        }
        let lines = [saved.lastPathComponent] + (await judge(outcomes))
        let text = lines.joined(separator: "\n")
        print(text)
        try? text.write(to: report, atomically: true, encoding: .utf8)
        CodexAppServer.shared.stop()
    }

    /// Counts meaning-changing differences between Articulate's and Typeless's output with a larger model.
    static func judge(_ outcomes: [Outcome]) async -> [String] {
        let judgeModel = ProcessInfo.processInfo.environment["ARTICULATE_JUDGE_MODEL"] ?? "gpt-6.1-sol"
        let judge = CodexModel(model: judgeModel)
        let system = """
            你在評估語音輸入的辨識品質。<reference> 是 Typeless 對同一段錄音的輸出（當作正確答案），<candidate> 是 Articulate 的輸出。
            計算 candidate 裡「內容錯誤」的數量：聽錯的詞、錯誤的數字或名稱、漏掉或多出的實質內容，每一處算一個。
            不要計算：標點、分段或條列格式、刪掉的贅字或口頭禪、意思相同的措辭差異、全形半形、繁簡寫法。
            equivalent：candidate 傳達的內容與 reference 一致，讀者不會因此誤解（允許格式與措辭不同）。
            """
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["content_errors": ["type": "integer"], "equivalent": ["type": "boolean"], "worst": ["type": "string"]],
            "required": ["content_errors", "equivalent", "worst"],
            "additionalProperties": false,
        ]
        var errors: [Double] = []
        var equivalent = 0
        var judged = 0
        var lines: [String] = []
        // Judge in parallel, six at a time.
        var results: [Int: [String: Any]] = [:]
        await withTaskGroup(of: (Int, [String: Any]?).self) { group in
            var next = 0
            func enqueue() {
                guard next < outcomes.count else { return }
                let i = next
                next += 1
                let user = "<reference>\n\(outcomes[i].session.typelessText)\n</reference>\n<candidate>\n\(outcomes[i].text)\n</candidate>"
                group.addTask { (i, try? await judge.json(system: system, user: user, schema: schema)) }
            }
            let parallel = Int(ProcessInfo.processInfo.environment["ARTICULATE_JUDGE_PARALLEL"] ?? "") ?? 6
            for _ in 0..<parallel { enqueue() }
            while let (i, result) = await group.next() {
                results[i] = result
                enqueue()
            }
        }
        for (i, outcome) in outcomes.enumerated() {
            guard let result = results[i] else { continue }
            let count = result["content_errors"] as? Int ?? 0
            let same = result["equivalent"] as? Bool ?? false
            judged += 1
            if same { equivalent += 1 }
            errors.append(Double(count) / Double(max(outcome.session.typelessText.count, 1)) * 100)
            lines.append(String(format: "  #%d %3d字 內容錯誤 %d  一致=%@", i + 1, outcome.session.typelessText.count, count, same ? "是" : "否"))
            if let path = ProcessInfo.processInfo.environment["ARTICULATE_JUDGE_NOTES"],
               let handle = FileHandle(forWritingAtPath: path) ?? (FileManager.default.createFile(atPath: path, contents: nil) ? FileHandle(forWritingAtPath: path) : nil) {
                handle.seekToEndOfFile()
                handle.write(Data("#\(i + 1) errors=\(count) worst: \(result["worst"] as? String ?? "")\n".utf8))
                try? handle.close()
            }
        }
        lines.insert(String(format: "評審（\(judgeModel)）：%d/%d 段內容一致（%.0f%%）；內容錯誤 每100字 中位 %.1f 平均 %.1f",
                            equivalent, judged, Double(equivalent) / Double(max(judged, 1)) * 100, median(errors),
                            errors.reduce(0, +) / Double(max(errors.count, 1))), at: 0)
        return lines
    }

    /// Runs on-device recognition over older Typeless recordings (never the benchmark sample) and writes
    /// (Typeless text, Apple text) pairs as JSON lines, for mining words the recognizer keeps getting wrong.
    static func exportTrainingPairs(testCount: Int, trainCount: Int, output: URL) async {
        let all = loadSessions()
        let test = sample(all, count: testCount)
        let oldestTest = test.map(\.created).min() ?? .distantFuture
        let train = all.filter { $0.created < oldestTest }.prefix(trainCount)
        let locale = Locale(identifier: Prefs.language.rawValue)
        try? await LiveTranscriber.prepareAssets(for: locale)
        print("test sessions: \(test.count) (oldest \(oldestTest)); training on \(train.count) older sessions")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: output) else { return }
        defer { try? handle.close() }
        for (i, session) in train.enumerated() {
            guard let apple = try? await LiveTranscriber(locale: locale).transcribeFile(session.audio) else { continue }
            let line = try? JSONSerialization.data(withJSONObject: ["typeless": session.typelessText, "apple": apple])
            if let line { handle.write(line + Data([0x0A])) }
            if (i + 1) % 25 == 0 { print("\(i + 1)/\(train.count)") }
        }
    }

    /// Builds a custom language model from older Typeless text (never the benchmark sample).
    static func trainLanguageModel(testCount: Int, directory: URL, extraTerms: [String]) async {
        let all = loadSessions()
        let oldestTest = sample(all, count: testCount).map(\.created).min() ?? .distantFuture
        let texts = all.filter { $0.created < oldestTest }.map(\.typelessText)
        var phrases: [String: Int] = [:]
        for text in texts {
            let pieces = text.components(separatedBy: CharacterSet(charactersIn: "。！？!?\n；;"))
            for piece in pieces {
                let phrase = piece.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,、：:「」『』（）()-•*#")))
                if (2...60).contains(phrase.count) { phrases[phrase, default: 0] += 1 }
            }
        }
        for term in extraTerms { phrases[term, default: 0] += 5 }
        print("training texts: \(texts.count) older sessions → \(phrases.count) phrases")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = SFCustomLanguageModelData(locale: Locale(identifier: Prefs.language.rawValue), identifier: "local.articulate.lm", version: "1")
        for (phrase, count) in phrases { data.insert(phraseCount: .init(phrase: phrase, count: count)) }
        let trainingFile = directory.appendingPathComponent("training.bin")
        let start = Date()
        do {
            try await data.export(to: trainingFile)
            let configuration = LiveTranscriber.languageModelConfiguration(in: directory)
            try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: trainingFile, configuration: configuration)
            print(String(format: "custom language model ready in %.1fs at %@", Date().timeIntervalSince(start), directory.path))
        } catch {
            print("custom language model failed: \(error)")
        }
    }

    /// The user's own vocabulary: frequent nouns and English words in older Typeless text (on-device NLP).
    static func mineVocabulary(testCount: Int, limit: Int, output: URL) {
        let all = loadSessions()
        let oldestTest = sample(all, count: testCount).map(\.created).min() ?? .distantFuture
        let texts = all.filter { $0.created < oldestTest }.map(\.typelessText)
        var counts: [String: Int] = [:]
        var documents: [String: Int] = [:]
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.traditionalChinese)
        for text in texts {
            tokenizer.string = text
            var seen = Set<String>()
            for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
                let word = String(text[range])
                guard word.count >= 2, word.contains(where: { $0.isLetter }) else { continue }
                counts[word, default: 0] += 1
                seen.insert(word)
            }
            for word in seen { documents[word, default: 0] += 1 }
        }
        let n = Double(texts.count)
        let isLatin: (String) -> Bool = { $0.unicodeScalars.allSatisfy(\.isASCII) }
        // English: anything used repeatedly. Chinese: frequent but concentrated in few dictations (TF-IDF), which
        // favors topic terms (營收, 疫苗) over everyday words that appear everywhere (我們, 因為).
        let english = counts.filter { isLatin($0.key) && $0.value >= 3 }.sorted { $0.value > $1.value }.prefix(limit / 2).map(\.key)
        let chinese = counts.filter { !isLatin($0.key) && $0.value >= 3 && Double(documents[$0.key] ?? 0) / n <= 0.08 && $0.key.count <= 6 }
            .map { ($0.key, Double($0.value) * log(n / Double(documents[$0.key] ?? 1))) }
            .sorted { $0.1 > $1.1 }.prefix(limit / 2).map(\.0)
        let vocabulary = english + chinese
        print("\(texts.count) older texts → \(english.count) English + \(chinese.count) Chinese terms")
        print("English:", english.prefix(30).joined(separator: " "))
        print("Chinese:", chinese.prefix(60).joined(separator: " "))
        try? vocabulary.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }

    static func speechTranscriberText(_ url: URL, locale: Locale, terms: [String]) async throws -> String {
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await request.downloadAndInstall() }
        let collect = Task { () -> String in
            var text = ""
            for try await result in module.results where result.isFinal { text += String(result.text.characters) }
            return text
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(terms.prefix(200))
            try? await analyzer.setContext(context)
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }

    /// Terms from a file (one per line) used as recognizer hints and prompt dictionary.
    static var dictionaryTerms: [String] {
        guard let path = ProcessInfo.processInfo.environment["ARTICULATE_DICT_FILE"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Quality only: fastest recognition + full polish + judge, for comparing pipeline variants.
    @MainActor
    static func runQuality(count: Int, label: String) async {
        let sessions = sample(loadSessions(), count: count)
        guard let engine = AIEngine.current() else { return }
        let locale = Locale(identifier: Prefs.language.rawValue)
        try? await LiveTranscriber.prepareAssets(for: locale)
        let baseTerms = dictionaryTerms
        let all = loadSessions()
        let recentMinutes = ProcessInfo.processInfo.environment["ARTICULATE_RECENT_CONTEXT"].flatMap(Double.init)
        AIEngine.prewarm()
        var outcomes: [Outcome] = []
        for session in sessions {
            // Simulated screen context: what the user dictated in the preceding minutes is visible in the window.
            var screenText = ""
            if let recentMinutes {
                screenText = all.filter { $0.created < session.created && $0.created >= session.created.addingTimeInterval(-recentMinutes * 60) }
                    .sorted { $0.created < $1.created }.map(\.typelessText).joined(separator: "\n")
            }
            let terms = ScreenVocabulary.terms(from: screenText, limit: 120) + baseTerms
            let transcriber = LiveTranscriber(locale: locale, contextualStrings: terms)
            // Oracle: treat Typeless's own text as a perfect transcript to measure what polishing alone changes.
            let oracle = ProcessInfo.processInfo.environment["ARTICULATE_ORACLE"] != nil
            let raw: String
            if oracle {
                raw = session.typelessText
            } else if ProcessInfo.processInfo.environment["ARTICULATE_SPEECH_TRANSCRIBER"] != nil {
                // Reference only: Apple's other on-device model (not used by Articulate; changing models is out of scope).
                guard let text = try? await speechTranscriberText(session.audio, locale: locale, terms: terms) else { continue }
                raw = text
            } else {
                guard let text = try? await transcriber.transcribeFile(session.audio) else { continue }
                raw = text
            }
            var ctx = PromptContext(dictionary: Array(terms.prefix(150)), language: Prefs.language)
            if !screenText.isEmpty {
                ctx.screen = ScreenContext(appName: nil, visibleText: String(screenText.suffix(2000)))
            }
            ctx.alternatives = transcriber.alternatives
            if ProcessInfo.processInfo.environment["ARTICULATE_ENSEMBLE"] != nil, !oracle {
                async let far = LiveTranscriber(locale: locale, contextualStrings: terms, config: "longFar").transcribeFile(session.audio)
                async let slow = LiveTranscriber(locale: locale, contextualStrings: terms, config: "long", tempo: 0.9).transcribeFile(session.audio)
                ctx.hypotheses = [raw, (try? await far) ?? "", (try? await slow) ?? ""].filter { !$0.isEmpty }
            }
            if ProcessInfo.processInfo.environment["ARTICULATE_EN_HINTS"] != nil {
                ctx.englishHint = try? await LiveTranscriber(locale: Locale(identifier: "en-US")).transcribeFile(session.audio)
            }
            let text = raw.count >= 4 ? ((try? await AITasks.polish(raw, ctx: ctx, with: engine)) ?? raw) : raw
            outcomes.append(Outcome(session: session, raw: raw, text: text, asr: 0, polish: 0,
                                    cer: cer(text, reference: session.typelessText), rawCER: cer(raw, reference: session.typelessText)))
        }
        if let path = ProcessInfo.processInfo.environment["ARTICULATE_SAVE_OUTCOMES"] { saveOutcomes(outcomes, to: URL(fileURLWithPath: path)) }
        let judged = await judge(outcomes)
        print("[\(label)] " + judged[0] + String(format: "  CER中位 %.1f%%", median(outcomes.map(\.cer)) * 100))
        print(judged.dropFirst().joined(separator: "\n"))
        CodexAppServer.shared.stop()
    }

    /// Recognition only, as fast as possible, for several recognizer configurations.
    static func runASR(count: Int, configs: [String]) async {
        let sessions = sample(loadSessions(), count: count)
        let locale = Locale(identifier: Prefs.language.rawValue)
        try? await LiveTranscriber.prepareAssets(for: locale)
        print("ASR-only on \(sessions.count) Typeless recordings (CER of raw recognition vs Typeless output)")
        for config in configs {
            setenv("ARTICULATE_ASR_CONFIG", config, 1)
            var cers: [Double] = []
            var byBucket: [Int: [Double]] = [:]
            let start = Date()
            for session in sessions {
                guard let raw = try? await LiveTranscriber(locale: locale).transcribeFile(session.audio) else { continue }
                let value = cer(raw, reference: session.typelessText)
                cers.append(value)
                let b = buckets.firstIndex { ($0.lower..<$0.upper).contains(session.typelessText.count) } ?? 0
                byBucket[b, default: []].append(value)
            }
            let perBucket = buckets.indices.compactMap { i in byBucket[i].map { String(format: "%d-%@:%.0f%%", buckets[i].lower, buckets[i].upper == Int.max ? "" : String(buckets[i].upper), median($0) * 100) } }
            print(String(format: "%-9@ median CER %.1f%%  mean %.1f%%  (%.0fs)  ", config as NSString, median(cers) * 100,
                         cers.reduce(0, +) / Double(max(cers.count, 1)) * 100, Date().timeIntervalSince(start)) + perBucket.joined(separator: "  "))
        }
    }

    @MainActor
    static func run(count: Int, report: URL, details: URL?) async -> Bool {
        let all = loadSessions()
        let sessions = sample(all, count: count)
        guard let engine = AIEngine.current() else {
            print("沒有 AI 引擎：\(AIEngine.statusDescription)")
            return false
        }
        print("Typeless sessions with audio: \(all.count); benchmarking \(sessions.count) with \(engine.name)")
        let locale = Locale(identifier: Prefs.language.rawValue)
        try? await LiveTranscriber.prepareAssets(for: locale)
        AIEngine.prewarm()

        // ARTICULATE_POLISHERS=prefix,incremental compares speculative polishers on the same recordings, alternating
        // their order per recording so both meet the same Codex conditions. "none" polishes only after release.
        let env = ProcessInfo.processInfo.environment
        let kinds = (env["ARTICULATE_POLISHERS"] ?? (env["ARTICULATE_NO_SPECULATION"] != nil ? "none" : "incremental"))
            .split(separator: ",").map(String.init)
        // Normally only the last 3 s play in real time; ARTICULATE_FULL_REALTIME plays everything in real time,
        // so polishing while speaking gets the time it would have in real use.
        let realtimeTail: Double? = env["ARTICULATE_FULL_REALTIME"] != nil ? nil : 3.0
        var outcomes: [String: [Outcome]] = [:]
        var detailLines: [String] = []
        for (i, session) in sessions.enumerated() {
            for kind in i % 2 == 0 ? kinds : kinds.reversed() {
                // Normal use leaves time between dictations for the pool to refill; give it that time here too.
                if engine is CodexServerModel {
                    for _ in 0..<100 where await CodexThreadPool.shared.readyCount(for: Prefs.codexModel) < 1 { try? await Task.sleep(for: .milliseconds(100)) }
                }
                do {
                    // Simulated screen context, as the app now reads the visible window text.
                    var screenText = ""
                    if let minutes = env["ARTICULATE_RECENT_CONTEXT"].flatMap(Double.init) {
                        let from = session.created.addingTimeInterval(-minutes * 60)
                        let recent: [Session] = all.filter { $0.created < session.created && $0.created >= from }
                        screenText = recent.sorted { $0.created < $1.created }.map(\.typelessText).joined(separator: "\n")
                    }
                    var baseContext = PromptContext(language: Prefs.language)
                    if !screenText.isEmpty { baseContext.screen = ScreenContext(visibleText: String(screenText.suffix(2000))) }
                    let transcriber = LiveTranscriber(locale: locale, contextualStrings: ScreenVocabulary.terms(from: screenText, limit: 120))
                    // "fusion": both transcripts, polished after release; "fusion-incremental": the same, polished while
                    // speaking with each piece waiting for TEA's version of it (as in the app).
                    let speculative: (any SpeculativePolishing)? = switch kind {
                    case "none", "fusion": nil
                    case "prefix": PrefixPolisher(engine: engine, ctx: baseContext)
                    case "fusion-incremental": SpeculativePolisher(engine: engine, ctx: baseContext, usesSecond: true)
                    default: SpeculativePolisher(engine: engine, ctx: baseContext)
                    }
                    transcriber.onFinalized = { speculative?.update(finalized: $0) }
                    // TEA-ASR transcribes the same audio piece by piece, as in the app.
                    let companion: CompanionRecognizer? = kind.hasPrefix("fusion") ? CompanionRecognizer() : nil
                    if let polisher = speculative as? SpeculativePolisher {
                        companion?.onProgress { [weak polisher] text in polisher?.update(second: text) }
                    }
                    if let companion {
                        companion.setContext(terms: ScreenVocabulary.terms(from: screenText, limit: 60))
                        transcriber.audioSink = { companion.append($0) }
                        _ = await CompanionServer.shared.ensureRunning()
                    }
                    try transcriber.startSimulatedMicrophone(file: session.audio, realtimeTail: realtimeTail)
                    AIEngine.prewarm()
                    await transcriber.waitForSimulatedInput()
                    let released = Date()
                    async let secondTranscript = companion?.finish(timeout: 3)
                    let raw = try await transcriber.finish()
                    let second = await secondTranscript
                    let asr = Date().timeIntervalSince(released)
                    if companion != nil && second == nil { print("  (TEA unavailable, Apple only)") }
                    var text = raw
                    let polishStart = Date()
                    if raw.count >= 4 {
                        var ctx = baseContext
                        ctx.alternatives = transcriber.alternatives
                        if let second, !second.isEmpty, second != raw { ctx.hypotheses = [raw, second] }
                        if let speculative {
                            text = (try? await speculative.finish(transcript: raw, alternatives: transcriber.alternatives, second: second)) ?? raw
                        } else {
                            text = (try? await AITasks.polish(raw, ctx: ctx, with: engine)) ?? raw
                        }
                    }
                    let polish = raw.count >= 4 ? Date().timeIntervalSince(polishStart) : 0
                    let outcome = Outcome(session: session, raw: raw, text: text, asr: asr, polish: polish,
                                          cer: cer(text, reference: session.typelessText), rawCER: cer(raw, reference: session.typelessText))
                    outcomes[kind, default: []].append(outcome)
                    let path = speculative.map { "  \($0.speculativeRequests) while speaking, \($0.lastPath)" } ?? ""
                    print(String(format: "%2d/%d %@  %5.1fs audio  %3d字  Typeless %.2fs  Articulate %.2fs (asr %.2f + ai %.2f)  diff %+.2fs  CER %.0f%%",
                                 i + 1, sessions.count, kind as NSString, session.duration, session.typelessText.count, session.typelessLatency,
                                 outcome.total, asr, polish, outcome.total - session.typelessLatency, outcome.cer * 100) + path)
                    detailLines.append("#\(i + 1) [\(kind)] CER \(Int(outcome.cer * 100))% raw-CER \(Int(outcome.rawCER * 100))%\nTypeless: \(session.typelessText)\nArticulate:   \(text)\nRaw:      \(raw)\n")
                } catch {
                    print("\(i + 1)/\(sessions.count) \(kind)  error: \(error.localizedDescription)")
                }
            }
        }

        var lines = ["Articulate vs Typeless — same recordings, \(Date())", "AI engine: \(engine.name) (\(Prefs.codexModelSetting), fast=\(Prefs.codexFast))"]
        var allWithin = true
        for kind in kinds {
            let results = outcomes[kind] ?? []
            var within = true
            lines += ["", kinds.count > 1 ? "== 潤稿方式：\(kind)" : "", "字數        n   Typeless中位  Articulate中位(辨識+AI)  差距    CER中位"].filter { !$0.isEmpty }
            for bucket in buckets {
                let group = results.filter { (bucket.lower..<bucket.upper).contains($0.session.typelessText.count) }
                guard !group.isEmpty else { continue }
                let t = median(group.map(\.session.typelessLatency))
                let m = median(group.map(\.total))
                let diff = m - t
                if diff > 0.5 { within = false }
                lines.append(String(format: "%-10@ %2d   %6.2fs      %6.2fs (%.2f+%.2f)   %+.2fs   %4.1f%%",
                                    "\(bucket.lower)-\(bucket.upper == Int.max ? "" : String(bucket.upper))" as NSString, group.count, t, m,
                                    median(group.map(\.asr)), median(group.map(\.polish)), diff, median(group.map(\.cer)) * 100))
            }
            if env["ARTICULATE_JUDGE"] != nil {
                lines.append("")
                lines += await judge(results)
            }
            let overallDiff = median(results.map { $0.total - $0.session.typelessLatency })
            lines.append(String(format: "\n每段差距中位數 %+.2fs；CER 中位數 %.1f%%（Articulate 潤稿結果對 Typeless 結果）；原始辨識 CER 中位數 %.1f%%",
                                overallDiff, median(results.map(\.cer)) * 100, median(results.map(\.rawCER)) * 100))
            lines.append(within ? "所有字數區間都在 Typeless +0.5 秒以內" : "有字數區間超過 Typeless +0.5 秒")
            allWithin = allWithin && within
        }
        let text = lines.joined(separator: "\n")
        print(text)
        try? text.write(to: report, atomically: true, encoding: .utf8)
        for (kind, results) in outcomes {
            saveOutcomes(results, to: report.appendingPathExtension(kinds.count > 1 ? "\(kind).json" : "json"))
        }
        if let details { try? detailLines.joined(separator: "\n").write(to: details, atomically: true, encoding: .utf8) }
        CodexAppServer.shared.stop()
        CompanionServer.shared.stop()
        return allWithin
    }
}

/// The previous speculative polisher, kept for benchmark comparisons: while the user talks it polishes the
/// whole finalized prefix again and again; after release it continues from the newest finished pass.
@MainActor
final class PrefixPolisher: SpeculativePolishing {
    static let minGrowth = 60
    static let backReferences = ["上面", "前面", "剛剛那", "剛才那", "改成", "不對", "更正", "第一點", "第一個", "移到", "刪掉"]

    private let engine: LanguageModel
    private let ctx: PromptContext
    private var latest: (input: String, output: String)?
    private var inFlight: (input: String, task: Task<String?, Never>)?
    private var lastLaunchedCount = 0
    private(set) var speculativeRequests = 0
    private(set) var lastPath = ""

    init(engine: LanguageModel, ctx: PromptContext) {
        self.engine = engine
        self.ctx = ctx
    }

    func update(finalized: String) {
        let text = finalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count - lastLaunchedCount >= Self.minGrowth, inFlight == nil else { return }
        lastLaunchedCount = text.count
        speculativeRequests += 1
        let engine = engine
        let ctx = ctx
        let task = Task { try? await AITasks.polish(text, ctx: ctx, with: engine) }
        inFlight = (text, task)
        Task {
            if let output = await task.value { latest = (text, output) }
            inFlight = nil
        }
    }

    func finish(transcript: String, alternatives: [(chosen: String, others: [String])], second: String?) async throws -> String {
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var fullContext = ctx
        fullContext.alternatives = alternatives
        if let current = inFlight, current.input == transcript, let output = await current.task.value {
            lastPath = "speculated (waited for last pass)"
            return output
        }
        if let done = latest, done.input == transcript { lastPath = "speculated"; return done.output }
        guard let done = latest, transcript.hasPrefix(done.input) else {
            lastPath = latest == nil ? "whole (short)" : "whole (recognizer revised text)"
            return try await AITasks.polish(transcript, ctx: fullContext, with: engine)
        }
        let tail = String(transcript.dropFirst(done.input.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty { lastPath = "speculated"; return done.output }
        if Self.backReferences.contains(where: tail.contains) {
            lastPath = "whole (revision)"
            return try await AITasks.polish(transcript, ctx: fullContext, with: engine)
        }
        var tailContext = ctx
        tailContext.alternatives = alternatives.filter { tail.contains($0.chosen) }
        do {
            let polishedTail = try await AITasks.polishContinuation(tail, previous: done.output, ctx: tailContext, with: engine)
            lastPath = "continued \(tail.count) chars"
            return done.output + polishedTail
        } catch AIError.needsRevision {
            lastPath = "whole (revision)"
            return try await AITasks.polish(transcript, ctx: fullContext, with: engine)
        }
    }

    func cancel() {
        inFlight?.task.cancel()
    }
}
