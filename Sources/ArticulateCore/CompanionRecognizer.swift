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
    private var start = 0  // first frame of the current piece
    private var silentRun = 0

    /// Feeds all samples recorded so far; returns the pieces that just ended.
    mutating func update(_ samples: [Float]) -> [Range<Int>] {
        var ended: [Range<Int>] = []
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
            let length = Double((f - start) * Self.frame) / 16000
            if (silentRun >= 13 && length >= 6) || length >= 25 {
                let cut = f - silentRun / 2
                ended.append((start * Self.frame)..<(cut * Self.frame))
                start = cut
                silentRun = 0
            }
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
        let ended: [Range<Int>] = lock.withLock {
            samples.append(contentsOf: converted)
            return chunker.update(samples)
        }
        for range in ended { enqueue(range) }
    }

    /// The whole recording's text once every piece is recognized; nil if a piece failed or took longer than `timeout`.
    func finish(timeout: Double) async -> String? {
        let rest: Range<Int>? = lock.withLock { chunker.remainder(total: samples.count) }
        if let rest { enqueue(rest) }
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

    private func enqueue(_ range: Range<Int>) {
        lock.withLock {
            let piece = Array(samples[range])
            let context = context
            let previous = chain
            let progress = progress
            chain = Task {
                var texts = await previous.value
                guard await CompanionServer.shared.ensureRunning() else { return texts + [nil] }
                let prompt = (texts.last ?? nil).map { context + "\n" + String($0.suffix(120)) } ?? context
                texts.append(try? await CompanionServer.transcribe(piece, prompt: prompt))
                if let progress, !texts.contains(where: { $0 == nil }) {
                    let soFar = texts.compactMap { $0 }.joined()
                    Task { @MainActor in progress(soFar) }
                }
                return texts
            }
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
