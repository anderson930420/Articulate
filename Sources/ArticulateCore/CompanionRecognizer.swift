@preconcurrency import AVFoundation
import Foundation

/// The second recognizer of "Apple＋TEA 融合": TEA-ASR (a Taiwan-tuned Qwen3-ASR) on MLX, run by a small
/// Python HTTP server that setup-tea.sh installs. It starts on the first dictation and stops after sitting
/// idle, so its ~2.6 GB of memory is only taken while the user is dictating.
@MainActor
final class CompanionServer {
    static let shared = CompanionServer()
    static let port = 47615
    /// Stop the server after this long without a dictation.
    static let idleTimeout: TimeInterval = 600

    static var directory: URL { AppPaths.support.appendingPathComponent("ASR", isDirectory: true) }
    static var python: URL { directory.appendingPathComponent("venv/bin/python") }
    static var script: URL { directory.appendingPathComponent("asr_server.py") }
    static var model: URL { AppPaths.support.appendingPathComponent("Models/tea-asr-1.1-8bit", isDirectory: true) }

    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: python.path) && fm.fileExists(atPath: script.path)
            && fm.fileExists(atPath: model.appendingPathComponent("model.safetensors").path)
    }

    private var process: Process?
    private var starting: Task<Bool, Never>?
    private var idleTimer: Timer?
    /// The model is loaded and answering (it takes ~1.5 s to load after sitting idle).
    private(set) var isReady = false

    /// Starts the server if needed; true once it answers.
    func ensureRunning() async -> Bool {
        restartIdleTimer()
        // Already up, still coming up, or reused from an earlier run; a crashed server is started again.
        if let starting, process?.isRunning ?? true { return await starting.value }
        let task = Task { await launch() }
        starting = task
        let ready = await task.value
        isReady = ready
        if !ready { starting = nil }
        return ready
    }

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        if let process, process.isRunning {
            process.terminate()
            DiagnosticLog.write("companion server stopped")
        }
        process = nil
        starting = nil
        isReady = false
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeout, repeats: false) { _ in
            Task { @MainActor in CompanionServer.shared.stop() }
        }
    }

    private func launch() async -> Bool {
        guard Self.isInstalled else { return false }
        switch await Self.ping() {
        case .ours:
            return true  // left over from an earlier run of Articulate
        case .foreign:
            DiagnosticLog.write("companion server: port \(Self.port) is used by another program")
            return false
        case .none:
            break
        }
        let started = Date()
        let process = Process()
        process.executableURL = Self.python
        process.arguments = ["-I", Self.script.path, Self.model.path, String(Self.port)]
        let log = DiagnosticLog.url.deletingLastPathComponent().appendingPathComponent("asr-server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            DiagnosticLog.write("companion server failed to start: \(error.localizedDescription)")
            return false
        }
        self.process = process
        for _ in 0..<300 {
            if await Self.ping() == .ours {
                DiagnosticLog.write(String(format: "companion server ready in %.1fs", Date().timeIntervalSince(started)))
                return true
            }
            guard process.isRunning else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        DiagnosticLog.write("companion server did not come up")
        process.terminate()
        self.process = nil
        return false
    }

    private enum Ping { case ours, foreign, none }

    private static func ping() async -> Ping {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 0.5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return .none }
        // "murmur-asr": a server script installed before the app was renamed.
        return ["articulate-asr", "murmur-asr"].contains(String(decoding: data, as: UTF8.self)) ? .ours : .foreign
    }

    /// Recognizes 16 kHz mono samples; `prompt` carries context words and the previous piece's text.
    nonisolated static func transcribe(_ samples: [Float], prompt: String) async throws -> String {
        try await WhisperServer.inference(port: port, samples: samples, prompt: prompt, traditionalize: false)
    }
}

/// Cuts speech at pauses as it arrives: a piece ends at the first 0.4 s pause after 6 s of audio,
/// or at 25 s. The silence threshold follows the quiet floor of the audio heard so far.
struct SpeechChunker {
    static let frame = 480  // 30 ms at 16 kHz
    private var energies: [Float] = []
    private var threshold: Float = 0.004
    var silenceThreshold: Float { threshold }
    private var start = 0  // first frame of the current piece
    private var silentRun = 0
    /// Early passes start at a shorter pause than real cuts: the user's median silence before release is 0.46 s.
    static let earlyPauseFrames = 8
    /// Only this much continuous sound counts as more speech after an early cut; a key click is shorter.
    static let speechFrames = 4
    private var voicedRun = 0
    private var voicedSincePause = false
    /// End of the last stretch of continuous sound (absolute sample index).
    private(set) var lastSpeechEnd = 0
    private(set) var pieceStart = 0
    private(set) var pauses: [Range<Int>] = []

    /// Feeds all samples recorded so far; returns the pieces that just ended.
    mutating func update(_ samples: [Float]) -> [Range<Int>] {
        var ended: [Range<Int>] = []
        pauses.removeAll(keepingCapacity: true)
        while (energies.count + 1) * Self.frame <= samples.count {
            let f = energies.count
            var sum: Float = 0
            for i in (f * Self.frame)..<((f + 1) * Self.frame) { sum += samples[i] * samples[i] }
            energies.append((sum / Float(Self.frame)).squareRoot())
            if energies.count % 33 == 0 {
                let sorted = energies.sorted()
                threshold = max(sorted[sorted.count / 10] * 2.5, 0.004)
            }
            silentRun = energies[f] < threshold ? silentRun + 1 : 0
            voicedRun = energies[f] < threshold ? 0 : voicedRun + 1
            if voicedRun >= Self.speechFrames {
                voicedSincePause = true
                lastSpeechEnd = (f + 1) * Self.frame
            }
            let length = Double((f - start) * Self.frame) / 16000
            if (silentRun >= 13 && length >= 6) || length >= 25 {
                let cut = f - silentRun / 2
                ended.append((start * Self.frame)..<(cut * Self.frame))
                start = cut
                silentRun = 0
                voicedSincePause = false
            } else if silentRun == Self.earlyPauseFrames, voicedSincePause {
                pauses.append((start * Self.frame)..<((f - silentRun / 2) * Self.frame))
                voicedSincePause = false
            }
            pieceStart = start * Self.frame
        }
        return ended
    }

    /// Whatever follows the last cut, if it is long enough to hold a word.
    func remainder(total: Int) -> Range<Int>? {
        let lower = start * Self.frame
        return total - lower > 1600 ? lower..<total : nil
    }
}

/// Recognizes one recording a second time with the companion server while the user talks: every piece
/// is sent as soon as it ends, so after release only the last piece is left.
final class CompanionRecognizer: @unchecked Sendable {
    private let lock = NSLock()
    private let format16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var chunker = SpeechChunker()
    private var context = "以下是台灣華語，可能夾雜英文。"
    /// Requests run one after another; each adds its piece's text, or nil when it failed.
    private var chain = Task<[String?], Never> { [] }
    private var progress: (@MainActor @Sendable (String) -> Void)?
    typealias Inference = @Sendable ([Float], String) async -> String?
    private let inference: Inference
    private var earlyEnabled: Bool
    private var ended = false
    private struct Early {
        let range: Range<Int>
        let context: String
        let previous: Task<[String?], Never>
    }
    private var pendingEarly: Early?
    private var earlyWorker: Task<Void, Never>?
    private var earlyResult: (range: Range<Int>, context: String, texts: [String?])?
    private var runningEarly: Early?
    private var earlyPasses = 0
    private var earlyNote = ""
    /// Why the last finish did or did not use a pause pass, and how many passes ran (diagnostics, no text).
    var earlyDiagnostics: String { lock.withLock { "\(earlyPasses) pause passes, \(earlyNote.isEmpty ? "-" : earlyNote)" } }
    private var reusedEarly = false
    var usedEarly: Bool { lock.withLock { reusedEarly } }

    init(shortDictation: Bool = false, inference: Inference? = nil) {
        earlyEnabled = shortDictation && Prefs.shortDictationSpeed
        self.inference = inference ?? { samples, prompt in
            guard await CompanionServer.shared.ensureRunning() else { return nil }
            return try? await CompanionServer.transcribe(samples, prompt: prompt)
        }
    }

    /// Length and mode stops are sticky: a later recognizer revision must not restart speculation.
    func stopEarlyPasses() {
        let worker = lock.withLock {
            earlyEnabled = false
            pendingEarly = nil
            earlyResult = nil
            return earlyWorker
        }
        worker?.cancel()
    }

    /// A finished pause pass is waiting to be used (tests wait for this).
    var hasPausePass: Bool { lock.withLock { earlyResult != nil } }

    /// Called on the main thread with all text recognized so far, each time a piece is done
    /// (not after a piece failed: the text would no longer match the audio).
    func onProgress(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        lock.withLock { progress = handler }
    }

    /// Words that steer recognition (dictionary, words on screen).
    func setContext(terms: [String]) {
        lock.withLock { context = "以下是台灣華語，可能夾雜英文。" + terms.prefix(60).joined(separator: "、") }
    }

    /// Called from the audio tap with microphone buffers.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        lock.withLock {
            samples.append(contentsOf: converted)
            for range in chunker.update(samples) { enqueue(range) }
            if earlyEnabled, !ended, let range = chunker.pauses.last, range.lowerBound == chunker.pieceStart {
                // Keep ranges rather than sample copies for queued passes. Real pieces always take priority.
                pendingEarly = Early(range: range, context: context, previous: chain)
                if earlyWorker == nil {
                    earlyWorker = Task { [weak self] in await self?.workEarly() }
                }
            }
        }
    }

    private func workEarly() async {
        while !Task.isCancelled {
            guard let candidate = lock.withLock({ pendingEarly }) else { break }
            // Wait outside the real-piece chain; speculative work can never hold up the next real piece.
            let texts = await candidate.previous.value
            let work: (Early, [Float])? = lock.withLock {
                guard earlyEnabled, !ended, let latest = pendingEarly,
                      latest.range == candidate.range else { return nil }
                pendingEarly = nil
                guard latest.range.lowerBound == chunker.pieceStart else { return nil }
                runningEarly = latest
                earlyPasses += 1
                return (latest, Array(samples[latest.range]))
            }
            guard let (request, samples) = work else { continue }
            let prompt = Self.prompt(context: request.context, texts: texts)
            let text = await inference(samples, prompt)
            // A pass still running at release is kept: finish may wait for it instead of the remainder.
            lock.withLock {
                runningEarly = nil
                guard earlyEnabled, !Task.isCancelled, let text,
                      !texts.contains(where: { $0 == nil }),
                      request.range.lowerBound == chunker.pieceStart,
                      chunker.lastSpeechEnd <= request.range.upperBound,
                      request.context == context else { return }
                earlyResult = (request.range, request.context, texts + [text])
            }
        }
        lock.withLock {
            earlyWorker = nil
            if earlyEnabled, !ended, pendingEarly != nil {
                earlyWorker = Task { [weak self] in await self?.workEarly() }
            }
        }
    }

    private static func prompt(context: String, texts: [String?]) -> String {
        (texts.last ?? nil).map { context + "\n" + String($0.suffix(120)) } ?? context
    }

    /// Apple decides eligibility before a pause result can replace the final TEA request. The final request still
    /// starts right away, so a dictation that turns out long keeps today's timing; a short one drops its result.
    func finish(timeout: Double, finalTranscript: Task<String, Error>) async -> String? {
        let started = Date()
        let (ready, worker): ([String?]?, Task<Void, Never>?) = lock.withLock {
            if let texts = validEarly() { return (texts, nil) }
            guard let running = runningEarly, covers(running.range), running.context == context else {
                earlyNote = earlyPasses == 0 ? "no pause pass" : (earlyResult == nil ? "no usable pass" : "speech after pause")
                return (nil, nil)
            }
            return (nil, earlyWorker)
        }
        guard ready != nil || worker != nil else { return await finish(timeout: timeout) }
        let fallback = Task { await self.finish(timeout: timeout) }
        let raw = try? await finalTranscript.value
        guard let raw, (4..<Prefs.strongModelFromLength).contains(raw.count) else {
            lock.withLock { earlyNote = "long or empty" }
            return await fallback.value
        }
        var texts = ready
        if texts == nil, let worker {
            // The remainder queues behind this pass on the TEA server anyway, so waiting for it is never slower.
            let remaining = max(0, timeout - Date().timeIntervalSince(started))
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await worker.value }
                group.addTask { try? await Task.sleep(for: .seconds(remaining)) }
                await group.next()
                group.cancelAll()
            }
            texts = lock.withLock { validEarly() }
        }
        guard let texts else {
            lock.withLock { earlyNote = "pass failed" }
            return await fallback.value
        }
        lock.withLock {
            reusedEarly = true
            earlyNote = ready == nil ? "waited for pause pass" : "pause pass ready"
        }
        return texts.compactMap { $0 }.joined()
    }

    /// The range still covers the current piece and nothing was said after its cut. Must be called with `lock` held.
    private func covers(_ range: Range<Int>) -> Bool {
        guard earlyEnabled, range.lowerBound == chunker.pieceStart,
              chunker.lastSpeechEnd <= range.upperBound else { return false }
        // The chunker only measures whole frames; the last partial frame must be quiet too.
        let tail = samples[(samples.count / SpeechChunker.frame * SpeechChunker.frame)..<samples.count]
        let energy = tail.isEmpty ? 0 : (tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count)).squareRoot()
        return energy < chunker.silenceThreshold
    }

    /// The early pass's texts when it still covers the current piece. Must be called with `lock` held.
    private func validEarly() -> [String?]? {
        guard let result = earlyResult, result.context == context, covers(result.range) else { return nil }
        return result.texts
    }

    /// The whole recording's text once every piece is recognized; nil if a piece failed or took longer than `timeout`.
    func finish(timeout: Double, allowEarly: Bool = false) async -> String? {
        let ready: [String?]? = lock.withLock {
            let early = allowEarly ? validEarly() : nil
            ended = true
            pendingEarly = nil
            if let early {
                reusedEarly = true
                return early
            }
            if let rest = chunker.remainder(total: samples.count) { enqueue(rest) }
            return nil
        }
        if let ready { return ready.compactMap { $0 }.joined() }
        let chain = lock.withLock { self.chain }
        enum Outcome { case done([String?]), timedOut }
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask { .done(await chain.value) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        guard case .done(let texts) = outcome, !texts.contains(where: { $0 == nil }) else { return nil }
        return texts.compactMap { $0 }.joined()
    }

    /// Must be called with `lock` held.
    private func enqueue(_ range: Range<Int>) {
        // A new real piece invalidates pause passes; the final remainder at release must not stop one in flight.
        if !ended {
            earlyWorker?.cancel()
            pendingEarly = nil
            earlyResult = nil
        }
        let piece = Array(samples[range])
        let context = context
        let previous = chain
        let progress = progress
        let inference = inference
        chain = Task {
            var texts = await previous.value
            let prompt = Self.prompt(context: context, texts: texts)
            texts.append(await inference(piece, prompt))
            if let progress, !texts.contains(where: { $0 == nil }) {
                let soFar = texts.compactMap { $0 }.joined()
                Task { @MainActor in progress(soFar) }
            }
            return texts
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format16k)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * 16000 / buffer.format.sampleRate).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format16k, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
