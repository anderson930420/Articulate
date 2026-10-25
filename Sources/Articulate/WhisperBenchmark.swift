@preconcurrency import AVFoundation
import Foundation

enum WhisperServerError: LocalizedError {
    case notInstalled
    case portInUse(Int)
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "找不到 whisper-server（brew install whisper-cpp）"
        case .portInUse(let port): "連接埠 \(port) 已被其他程式使用，請用 ARTICULATE_WHISPER_PORT 換一個"
        case .badResponse(let status): "辨識伺服器回應 \(status)"
        }
    }
}

/// A resident whisper.cpp model (`whisper-server`), so each request only pays for inference.
final class WhisperServer: @unchecked Sendable {
    let model: URL
    let port: Int
    private var process: Process?
    private(set) var loadSeconds: Double = 0

    init(model: URL, port: Int = 8765) {
        self.model = model
        self.port = port
    }

    static var executable: URL? {
        ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Connect to a server someone else started (ARTICULATE_WHISPER_REUSE), e.g. one model shared by two runs.
    private var reused: Bool { ProcessInfo.processInfo.environment["ARTICULATE_WHISPER_REUSE"] != nil }

    func start() async throws {
        if reused {
            let started = Date()
            for _ in 0..<600 {
                if let (_, response) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!),
                   (response as? HTTPURLResponse)?.statusCode != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            loadSeconds = Date().timeIntervalSince(started)
            return
        }
        guard let executable = Self.executable else { throw WhisperServerError.notInstalled }
        // Another program on this port would answer the readiness check and swallow every request.
        if (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)) != nil {
            throw WhisperServerError.portInUse(port)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port), "-l", "zh", "-t", "8", "-nt", "-fa"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = Date()
        try process.run()
        self.process = process
        // Ready once the HTTP endpoint answers.
        for _ in 0..<600 {
            if let (_, response) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!),
               (response as? HTTPURLResponse)?.statusCode != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        loadSeconds = Date().timeIntervalSince(started)
    }

    /// Resident memory of the server in MB.
    var residentMB: Double {
        guard let pid = process?.processIdentifier else { return 0 }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "rss=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        ps.waitUntilExit()
        let kb = Double(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return kb / 1024
    }

    func stop() {
        if !reused { process?.terminate() }
    }

    /// Transcribes 16 kHz mono samples; returns Traditional Chinese text.
    func transcribe(_ samples: [Float], prompt: String) async throws -> String {
        try await Self.inference(port: port, samples: samples, prompt: prompt, traditionalize: true)
    }

    /// One request to a server with whisper-server's /inference interface (also Articulate's TEA server).
    /// `traditionalize` converts Simplified output; leave it off for models that already write Traditional.
    static func inference(port: Int, samples: [Float], prompt: String, traditionalize: Bool) async throws -> String {
        let wav = wavData(samples)
        let boundary = "articulate-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("response_format", "json")
        field("language", "zh")
        field("temperature", "0.0")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw WhisperServerError.badResponse(status) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (object?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard traditionalize else { return text }
        return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    static func wavData(_ samples: [Float]) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(Data("RIFF".utf8)); u32(36 + bytes); data.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(bytes)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Decodes any audio file to 16 kHz mono Float samples.
    static func samples16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return [] }
        var out: [Float] = []
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        var done = false
        while !done {
            let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192)!
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                do {
                    try file.read(into: input, frameCount: 8192)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream || status == .error || output.frameLength == 0 { done = true }
        }
        return out
    }

    /// Splits speech at pauses into chunks of roughly 6–20 s (cut at a pause after 6 s, forced at 25 s).
    static func chunks(_ samples: [Float]) -> [Range<Int>] {
        let frame = 480 // 30 ms
        let count = samples.count / frame
        guard count > 0 else { return [0..<samples.count] }
        var energy = [Float](repeating: 0, count: count)
        for f in 0..<count {
            var sum: Float = 0
            for i in (f * frame)..<((f + 1) * frame) { sum += samples[i] * samples[i] }
            energy[f] = (sum / Float(frame)).squareRoot()
        }
        let sorted = energy.sorted()
        let threshold = max(sorted[count / 10] * 2.5, 0.004) // a little above the quiet floor
        var cuts: [Int] = [0]
        var silentRun = 0
        var start = 0
        for f in 0..<count {
            silentRun = energy[f] < threshold ? silentRun + 1 : 0
            let length = Double((f - start) * frame) / 16000
            if (silentRun >= 13 && length >= 6) || length >= 25 { // 0.4 s pause
                let cut = (f - silentRun / 2) * frame
                cuts.append(cut)
                start = cut / frame
                silentRun = 0
            }
        }
        cuts.append(samples.count)
        var ranges: [Range<Int>] = []
        for (a, b) in zip(cuts, cuts.dropFirst()) where b - a > 1600 { ranges.append(a..<b) }
        if ranges.isEmpty { ranges = [0..<samples.count] }
        // Fold a tiny last piece into the previous chunk.
        if ranges.count > 1, ranges.last!.count < 16000 * 2 {
            let last = ranges.removeLast()
            ranges[ranges.count - 1] = ranges.last!.lowerBound..<last.upperBound
        }
        return ranges
    }
}

extension TypelessBenchmark {
    /// Whisper-family recognizer on the same sample: quality (judge) and post-release latency.
    /// mode "whole": transcribe after release. mode "chunked": chunks are transcribed while speaking
    /// (simulated timeline from measured durations), so after release only the last chunk remains.
    @MainActor
    static func runWhisper(model: URL, label: String, mode: String, report: URL) async {
        let sessions = sample(loadSessions(), count: 36)
        let all = loadSessions()
        guard let engine = AIEngine.current() else { return }
        let port = Int(ProcessInfo.processInfo.environment["ARTICULATE_WHISPER_PORT"] ?? "") ?? 8765
        let server = WhisperServer(model: model, port: port)
        do { try await server.start() } catch { print("whisper-server failed: \(error)"); return }
        defer { server.stop() }
        // ARTICULATE_FUSE_APPLE: quality only. Apple SpeechTranscriber also recognizes each recording, and one polish
        // pass sees both versions (ARTICULATE_FUSE_PRIMARY=apple makes Apple's text the main transcript).
        let fuse = ProcessInfo.processInfo.environment["ARTICULATE_FUSE_APPLE"] != nil
        let applePrimary = ProcessInfo.processInfo.environment["ARTICULATE_FUSE_PRIMARY"] == "apple"
        let locale = Locale(identifier: Prefs.language.rawValue)
        if fuse { try? await LiveTranscriber.prepareAssets(for: locale, config: "speech") }
        AIEngine.prewarm()
        print(String(format: "[%@] model loaded in %.1fs, resident %.0f MB", label, server.loadSeconds, server.residentMB))
        print("[\(label)] AI: \(engine.name) \(Prefs.codexModelSetting)\(fuse ? ", fused with Apple" : "")")
        // Warm-up so the first measured request doesn't include GPU kernel compilation.
        _ = try? await server.transcribe([Float](repeating: 0, count: 16000), prompt: "")

        var outcomes: [Outcome] = []
        var lines: [String] = []
        for (i, session) in sessions.enumerated() {
            guard let samples = try? WhisperServer.samples16k(session.audio), !samples.isEmpty else { continue }
            let minutes = Double(ProcessInfo.processInfo.environment["ARTICULATE_RECENT_CONTEXT"] ?? "120") ?? 120
            let from = session.created.addingTimeInterval(-minutes * 60)
            let recent: [Session] = all.filter { $0.created < session.created && $0.created >= from }
            let screenText = recent.sorted { $0.created < $1.created }.map(\.typelessText).joined(separator: "\n")
            let terms = ScreenVocabulary.terms(from: screenText, limit: 40)
            var ctx = PromptContext(language: Prefs.language)
            if !screenText.isEmpty { ctx.screen = ScreenContext(visibleText: String(screenText.suffix(2000))) }
            let basePrompt = "以下是台灣華語，可能夾雜英文。" + terms.joined(separator: "、")

            var raw = ""
            var asrLatency = 0.0
            var polishLatency = 0.0
            var text = ""
            if fuse {
                if mode == "whole" {
                    raw = (try? await server.transcribe(samples, prompt: basePrompt)) ?? ""
                } else {
                    var pieces: [String] = []
                    for range in WhisperServer.chunks(samples) {
                        let prompt = pieces.last.map { basePrompt + "\n" + String($0.suffix(120)) } ?? basePrompt
                        pieces.append((try? await server.transcribe(Array(samples[range]), prompt: prompt)) ?? "")
                    }
                    raw = pieces.joined()
                }
                let appleTerms = ScreenVocabulary.terms(from: screenText, limit: 120) + dictionaryTerms
                let apple = (try? await LiveTranscriber(locale: locale, contextualStrings: appleTerms, config: "speech")
                    .transcribeFile(session.audio)) ?? ""
                let versions = (applePrimary ? [apple, raw] : [raw, apple]).filter { !$0.isEmpty }
                raw = versions.first ?? ""
                var fused = ctx
                fused.hypotheses = versions
                text = raw.count >= 4 ? ((try? await AITasks.polish(raw, ctx: fused, with: engine)) ?? raw) : raw
            } else if mode == "whole" {
                let t0 = Date()
                raw = (try? await server.transcribe(samples, prompt: basePrompt)) ?? ""
                asrLatency = Date().timeIntervalSince(t0)
                let p0 = Date()
                text = raw.count >= 4 ? ((try? await AITasks.polish(raw, ctx: ctx, with: engine)) ?? raw) : raw
                polishLatency = raw.count >= 4 ? Date().timeIntervalSince(p0) : 0
            } else {
                // Measure each chunk, then replay the timeline: chunk k is available at its end time,
                // the recognizer handles chunks one after another, and release happens at the audio end.
                let ranges = WhisperServer.chunks(samples)
                var pieces: [String] = []
                var durations: [Double] = []
                for range in ranges {
                    let prompt = pieces.last.map { basePrompt + "\n" + String($0.suffix(120)) } ?? basePrompt
                    let t0 = Date()
                    let piece = (try? await server.transcribe(Array(samples[range]), prompt: prompt)) ?? ""
                    durations.append(Date().timeIntervalSince(t0))
                    pieces.append(piece)
                }
                raw = pieces.joined()
                let audioEnd = Double(samples.count) / 16000
                var busyUntil = 0.0
                var finishPrefix = 0.0
                for (k, range) in ranges.enumerated() {
                    let available = Double(range.upperBound) / 16000
                    busyUntil = max(busyUntil, available) + durations[k]
                    if k == ranges.count - 2 { finishPrefix = busyUntil }
                }
                asrLatency = max(0, busyUntil - audioEnd)
                // Speculative polish of everything but the last chunk starts as soon as that text exists.
                if ranges.count > 1, raw.count >= 4 {
                    let prefix = pieces.dropLast().joined()
                    let tail = pieces.last ?? ""
                    let p0 = Date()
                    let polishedPrefix = (try? await AITasks.polish(prefix, ctx: ctx, with: engine)) ?? prefix
                    let prefixTime = Date().timeIntervalSince(p0)
                    let t1 = Date()
                    let polishedTail = tail.isEmpty ? "" :
                        ((try? await AITasks.polishContinuation(tail, previous: polishedPrefix, ctx: ctx, with: engine)) ?? tail)
                    let tailTime = Date().timeIntervalSince(t1)
                    text = polishedPrefix + polishedTail
                    let prefixDoneAfterRelease = max(0, finishPrefix + prefixTime - audioEnd)
                    polishLatency = max(asrLatency, prefixDoneAfterRelease) - asrLatency + tailTime
                } else {
                    let p0 = Date()
                    text = raw.count >= 4 ? ((try? await AITasks.polish(raw, ctx: ctx, with: engine)) ?? raw) : raw
                    polishLatency = raw.count >= 4 ? Date().timeIntervalSince(p0) : 0
                }
            }
            let outcome = Outcome(session: session, raw: raw, text: text, asr: asrLatency, polish: polishLatency,
                                  cer: cer(text, reference: session.typelessText), rawCER: cer(raw, reference: session.typelessText))
            outcomes.append(outcome)
            print(String(format: "%2d/%d %5.1fs audio %3d字  Typeless %.2fs  %@ %.2fs (asr %.2f + ai %.2f)", i + 1, sessions.count,
                         session.duration, session.typelessText.count, session.typelessLatency, label, outcome.total, outcome.asr, outcome.polish))
        }

        lines.append("\(label) [\(mode)] vs Typeless — \(Date())")
        lines.append(String(format: "model load %.1fs, resident memory %.0f MB", server.loadSeconds, server.residentMB))
        lines.append("字數        n   Typeless中位  \(label)中位(辨識+AI)  差距")
        var allWithin = true
        for bucket in buckets {
            let group = outcomes.filter { (bucket.lower..<bucket.upper).contains($0.session.typelessText.count) }
            guard !group.isEmpty else { continue }
            let t = median(group.map(\.session.typelessLatency))
            let m = median(group.map(\.total))
            if m - t > 0.5 { allWithin = false }
            lines.append(String(format: "%-10@ %2d   %6.2fs      %6.2fs (%.2f+%.2f)   %+.2fs",
                                "\(bucket.lower)-\(bucket.upper == Int.max ? "" : String(bucket.upper))" as NSString, group.count, t, m,
                                median(group.map(\.asr)), median(group.map(\.polish)), m - t))
        }
        lines.append(allWithin ? "所有字數區間都在 Typeless +0.5 秒以內" : "有字數區間超過 Typeless +0.5 秒")
        saveOutcomes(outcomes, to: report.appendingPathExtension("json"))
        if ProcessInfo.processInfo.environment["ARTICULATE_SKIP_JUDGE"] == nil { lines += await judge(outcomes) }
        lines.append(String(format: "原始辨識 CER 中位數 %.1f%%", median(outcomes.map(\.rawCER)) * 100))
        let text = lines.joined(separator: "\n")
        print(text)
        try? text.write(to: report, atomically: true, encoding: .utf8)
        CodexAppServer.shared.stop()
    }
}

/// Recognition and polishing as separate steps, so several polishing setups can be compared on the
/// same transcripts without keeping a local recognition model loaded the whole time.
extension TypelessBenchmark {
    /// What the user dictated in the preceding minutes, shown on screen as context (ARTICULATE_RECENT_CONTEXT, default 120).
    static func recentText(before session: Session, in all: [Session]) -> String {
        let minutes = Double(ProcessInfo.processInfo.environment["ARTICULATE_RECENT_CONTEXT"] ?? "120") ?? 120
        let from = session.created.addingTimeInterval(-minutes * 60)
        return all.filter { $0.created < session.created && $0.created >= from }
            .sorted { $0.created < $1.created }.map(\.typelessText).joined(separator: "\n")
    }

    /// Saves Apple SpeechTranscriber's transcript of every sample recording and, when a Whisper-compatible
    /// server is already running (ARTICULATE_WHISPER_PORT), that model's transcript in chunked mode.
    @MainActor
    static func dumpRecognition(to output: URL) async {
        let all = loadSessions()
        let sessions = sample(all, count: 36)
        let locale = Locale(identifier: Prefs.language.rawValue)
        try? await LiveTranscriber.prepareAssets(for: locale, config: "speech")
        var server: WhisperServer?
        if let port = Int(ProcessInfo.processInfo.environment["ARTICULATE_WHISPER_PORT"] ?? "") {
            setenv("ARTICULATE_WHISPER_REUSE", "1", 1)
            let s = WhisperServer(model: URL(fileURLWithPath: "/dev/null"), port: port)
            do { try await s.start() } catch { print("server not reachable: \(error)"); return }
            _ = try? await s.transcribe([Float](repeating: 0, count: 16000), prompt: "")
            server = s
        }
        var rows: [[String: Any]] = []
        for (i, session) in sessions.enumerated() {
            let screenText = recentText(before: session, in: all)
            var row: [String: Any] = ["audio": session.audio.path]
            let appleTerms = ScreenVocabulary.terms(from: screenText, limit: 120) + dictionaryTerms
            row["apple"] = (try? await LiveTranscriber(locale: locale, contextualStrings: appleTerms, config: "speech")
                .transcribeFile(session.audio)) ?? ""
            if let server, let samples = try? WhisperServer.samples16k(session.audio), !samples.isEmpty {
                let basePrompt = "以下是台灣華語，可能夾雜英文。" + ScreenVocabulary.terms(from: screenText, limit: 40).joined(separator: "、")
                var pieces: [String] = []
                var seconds: [Double] = []
                for range in WhisperServer.chunks(samples) {
                    let prompt = pieces.last.map { basePrompt + "\n" + String($0.suffix(120)) } ?? basePrompt
                    let start = Date()
                    pieces.append((try? await server.transcribe(Array(samples[range]), prompt: prompt)) ?? "")
                    seconds.append(Date().timeIntervalSince(start))
                }
                row["other"] = pieces.joined()
                row["chunkSeconds"] = seconds
                // After release only the last chunk is left to recognize.
                print(String(format: "%2d/%d %5.1fs audio, %d chunks, last chunk %.2fs", i + 1, sessions.count, session.duration,
                             seconds.count, seconds.last ?? 0))
            } else {
                print("\(i + 1)/\(sessions.count)")
            }
            rows.append(row)
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) { try? data.write(to: output) }
        print("saved \(rows.count) transcripts to \(output.path)")
    }

    /// Polishes saved transcripts one way and judges the result. Variants: apple, other,
    /// fuse-apple (Apple's text as the transcript, the other model's as a second version), fuse-other.
    @MainActor
    /// Feeds `raw` sentence by sentence to the speculative polisher, waiting for each piece, then finishes it.
    /// TEA's whole transcript is known from the start, as if it kept up with the speaker.
    static func polishInPieces(_ raw: String, second: String?, ctx: PromptContext, with engine: LanguageModel) async throws -> String {
        let polisher = SpeculativePolisher(engine: engine, ctx: ctx, usesSecond: second != nil)
        if let second { polisher.update(second: second) }
        let chars = Array(raw)
        for (i, c) in chars.enumerated() where "。？！?!".contains(c) {
            polisher.update(finalized: String(chars[...i]))
            while !polisher.isIdle { try await Task.sleep(for: .milliseconds(100)) }
        }
        let text = try await polisher.finish(transcript: raw, alternatives: [], second: second)
        print("  pieces: \(polisher.speculativeRequests) while speaking, \(polisher.lastPath)")
        return text
    }

    static func polishDump(_ dump: URL, variant: String, report: URL) async {
        guard let data = try? Data(contentsOf: dump),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("cannot read \(dump.path)")
            return
        }
        guard let engine = AIEngine.current() else { return }
        let dictionary = ProcessInfo.processInfo.environment["ARTICULATE_BENCH_DICTIONARY"]
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?.split(separator: "\n").map(String.init) ?? []
        let all = loadSessions()
        let sessions = Dictionary(all.map { ($0.audio.path, $0) }, uniquingKeysWith: { a, _ in a })
        AIEngine.prewarm()
        var outcomes: [Outcome] = []
        for row in rows {
            guard let path = row["audio"] as? String, let session = sessions[path] else { continue }
            let apple = row["apple"] as? String ?? "", other = row["other"] as? String ?? ""
            let ordered: [String] = switch variant {
            case "apple": [apple]
            case "other": [other]
            case "fuse-other": [other, apple]
            case "apple-pieces": [apple]
            default: [apple, other]
            }
            let versions = ordered.filter { !$0.isEmpty }
            let raw = versions.first ?? ""
            let screenText = recentText(before: session, in: all)
            var ctx = PromptContext(language: Prefs.language)
            if !screenText.isEmpty { ctx.screen = ScreenContext(visibleText: String(screenText.suffix(2000))) }
            // ARTICULATE_BENCH_DICTIONARY=<file, one term per line>: the user's dictionary, as the app passes it.
            ctx.dictionary = dictionary
            let start = Date()
            let text: String
            if raw.count < 4 {
                text = raw
            } else if variant.hasSuffix("-pieces") {
                // As when polishing while the user talks: piece by piece, each with TEA's version of it.
                text = (try? await polishInPieces(raw, second: versions.count > 1 ? versions[1] : nil, ctx: ctx, with: engine)) ?? raw
            } else {
                if versions.count > 1 { ctx.hypotheses = versions }
                text = (try? await AITasks.polish(raw, ctx: ctx, with: engine)) ?? raw
            }
            outcomes.append(Outcome(session: session, raw: raw, text: text, asr: 0, polish: Date().timeIntervalSince(start),
                                    cer: cer(text, reference: session.typelessText), rawCER: cer(raw, reference: session.typelessText)))
            print(String(format: "%2d/%d polished in %.2fs", outcomes.count, rows.count, outcomes.last?.polish ?? 0))
        }
        saveOutcomes(outcomes, to: report.appendingPathExtension("json"))
        var lines = ["\(variant) from \(dump.lastPathComponent), AI: \(engine.name) \(Prefs.codexModelSetting)"]
        lines += buckets.compactMap { bucket in
            let group = outcomes.filter { (bucket.lower..<bucket.upper).contains($0.session.typelessText.count) }
            guard !group.isEmpty else { return nil }
            return String(format: "  %d-%@字 整段潤稿中位 %.2fs", bucket.lower, bucket.upper == Int.max ? "" : String(bucket.upper),
                          median(group.map(\.polish)))
        }
        lines += await judge(outcomes)
        lines.append(String(format: "原始辨識 CER 中位數 %.1f%%", median(outcomes.map(\.rawCER)) * 100))
        let text = lines.joined(separator: "\n")
        print(text)
        try? text.write(to: report, atomically: true, encoding: .utf8)
        CodexAppServer.shared.stop()
    }
}
