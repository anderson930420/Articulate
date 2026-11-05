@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import Speech

enum TranscriberError: LocalizedError {
    case unsupportedLocale(String)
    case noAudioFormat
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id): "這台 Mac 不支援「\(id)」的本機語音辨識"
        case .noAudioFormat: "無法取得語音辨識需要的音訊格式"
        case .microphoneUnavailable: "找不到可用的麥克風"
        }
    }
}

/// On-device streaming dictation: microphone (or file) → gain → AVAudioConverter → SpeechAnalyzer/DictationTranscriber.
/// One instance handles one utterance. The converted audio can be saved for retrying later.
final class LiveTranscriber: @unchecked Sendable {
    /// Called on the main thread with an RMS level in 0...1.
    var onLevel: (@MainActor (Float) -> Void)?
    /// Called on the main thread with the text recognised so far.
    var onPartial: (@MainActor (String) -> Void)?
    /// Called on the main thread with all finalized text whenever a segment becomes final.
    var onFinalized: (@MainActor (String) -> Void)?
    /// Receives every microphone buffer (before gain), on the audio thread; feeds a second recognizer.
    var audioSink: ((AVAudioPCMBuffer) -> Void)?

    private let locale: Locale
    private let contextualStrings: [String]
    private let recordingURL: URL?
    private let engine = AVAudioEngine()
    /// The on-device recognizer: DictationTranscriber (default) or SpeechTranscriber (Apple's newer long-form model).
    private enum Recognizer {
        case dictation(DictationTranscriber)
        case speech(SpeechTranscriber)

        var module: any SpeechModule {
            switch self {
            case .dictation(let m): m
            case .speech(let m): m
            }
        }
    }

    private let recognizer: Recognizer
    private let analyzer: SpeechAnalyzer
    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var recordingFile: AVAudioFile?
    private var startTask: Task<Void, Error>?
    private var resultsTask: Task<Void, Never>?
    private var feederTask: Task<Void, Never>?
    private let lock = NSLock()
    private var finalized: [String] = []
    /// Other candidate transcriptions for each finalized segment (when the config asks for them).
    private var finalizedAlternatives: [[String]] = []
    private var volatile = ""
    private var micRunning = false
    /// Buffers that arrive before the analyzer format is known are kept and converted later.
    private var pending: [AVAudioPCMBuffer] = []
    private var gain: Float = 1
    /// End (seconds) of the audio covered by the latest result, used by benchmarks to let the analyzer catch up.
    private(set) var latestResultEnd: Double = 0

    private let tempo: Float?

    init(locale: Locale, contextualStrings: [String] = [], recordingURL: URL? = nil, config: String? = nil, tempo: Float? = nil) {
        self.locale = locale
        self.contextualStrings = contextualStrings
        self.recordingURL = recordingURL
        self.tempo = tempo ?? ProcessInfo.processInfo.environment["ARTICULATE_TEMPO"].flatMap(Float.init)
        let chosen = config ?? ProcessInfo.processInfo.environment["ARTICULATE_ASR_CONFIG"] ?? Self.defaultConfig
        recognizer = Self.isSpeechConfig(chosen)
            ? .speech(Self.makeSpeechTranscriber(locale: locale, config: chosen))
            : .dictation(Self.makeTranscriber(locale: locale, config: chosen))
        analyzer = SpeechAnalyzer(modules: [recognizer.module])
        (inputStream, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
    }

    // MARK: - Configuration

    /// Recognizer settings from preferences; ARTICULATE_ASR_CONFIG overrides for benchmarks.
    static var defaultConfig: String { Prefs.recognizer.config }

    static func isSpeechConfig(_ config: String) -> Bool { config.hasPrefix("speech") }

    static func makeSpeechTranscriber(locale: Locale, config: String) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: config == "speechFast" ? [.volatileResults, .fastResults] : [.volatileResults],
                          attributeOptions: [])
    }

    /// Recognizer settings compared in `--bench-asr` (same on-device model, different options).
    static func makeTranscriber(locale: Locale, config: String) -> DictationTranscriber {
        switch config {
        case "long":
            DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                 reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        case "progLong":
            DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        case "longLM":
            DictationTranscriber(locale: locale,
                                 contentHints: [.customizedLanguage(modelConfiguration: languageModelConfiguration(
                                     in: URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARTICULATE_LM_DIR"] ?? "/tmp/articulate-lm")))],
                                 transcriptionOptions: [.punctuation],
                                 reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        case "longFar":
            DictationTranscriber(locale: locale, contentHints: [.farField], transcriptionOptions: [.punctuation],
                                 reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        case "longAtypical":
            DictationTranscriber(locale: locale, contentHints: [.atypicalSpeech], transcriptionOptions: [.punctuation],
                                 reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        case "longAlt":
            DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                 reportingOptions: [.volatileResults, .frequentFinalization, .alternativeTranscriptions], attributeOptions: [])
        default:
            DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                                 reportingOptions: [.volatileResults], attributeOptions: [])
        }
    }

    /// Where a custom language model (built from the user's own text) lives.
    static func languageModelConfiguration(in directory: URL) -> SFSpeechLanguageModel.Configuration {
        let weight = ProcessInfo.processInfo.environment["ARTICULATE_LM_WEIGHT"].flatMap(Double.init).map { NSNumber(value: $0) }
        return SFSpeechLanguageModel.Configuration(languageModel: directory.appendingPathComponent("lm"),
                                                   vocabulary: directory.appendingPathComponent("vocab"), weight: weight)
    }

    // MARK: - Models

    private static let preparedLock = NSLock()
    nonisolated(unsafe) private static var preparedLocales = Set<String>()

    /// Downloads the on-device speech model for a locale if it is not installed yet.
    static func prepareAssets(for locale: Locale, config: String? = nil) async throws {
        let speech = isSpeechConfig(config ?? ProcessInfo.processInfo.environment["ARTICULATE_ASR_CONFIG"] ?? defaultConfig)
        let id = locale.identifier(.bcp47) + (speech ? "#speech" : "")
        if preparedLock.withLock({ preparedLocales.contains(id) }) { return }

        let supported = speech ? await SpeechTranscriber.supportedLocales : await DictationTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw TranscriberError.unsupportedLocale(locale.identifier(.bcp47))
        }
        let probe: any SpeechModule = speech
            ? SpeechTranscriber(locale: locale, preset: .transcription)
            : DictationTranscriber(locale: locale, preset: .shortDictation)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
        preparedLock.withLock { _ = preparedLocales.insert(id) }
    }

    // MARK: - Recording

    /// Starts capturing the microphone immediately; audio is buffered until the analyzer is ready.
    func startMicrophone(deviceUID: String?) throws {
        let input = engine.inputNode
        if let deviceUID, !deviceUID.isEmpty, let device = Microphones.deviceID(forUID: deviceUID),
           let unit = input.audioUnit {
            var id = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw TranscriberError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.feed(buffer)
        }
        engine.prepare()
        try engine.start()
        micRunning = true
        startAnalyzer()
    }

    /// Plays an audio file as if it came from the microphone (end-to-end tests and benchmarks).
    /// With `realtimeTail`, everything but the last N seconds is fed as fast as the analyzer keeps up,
    /// then the tail plays in real time — so "release" latency matches a live recording.
    func startSimulatedMicrophone(file url: URL, realtimeTail: Double? = nil) throws {
        let file = try AVAudioFile(forReading: url)
        startAnalyzer()
        feederTask = Task.detached { [weak self] in
            let chunk: AVAudioFrameCount = 2048
            let rate = file.processingFormat.sampleRate
            let fastUntil = realtimeTail.map { max(0, file.length - AVAudioFramePosition($0 * rate)) } ?? 0
            while !Task.isCancelled, file.framePosition < fastUntil {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                      (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
                self?.feed(buffer, adjustGain: false)
            }
            if fastUntil > 0 {
                // Let recognition catch up with the fast-forwarded part, as it would have live.
                let target = Double(fastUntil) / rate - 1.0
                for _ in 0..<600 where (self?.latestResultEnd ?? target) < target {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            let start = ContinuousClock.now
            let tailStart = file.framePosition
            while !Task.isCancelled, file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                      (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
                self?.feed(buffer)
                // Pace against the start time so the stream doesn't drift behind real time.
                let due = start + .seconds(Double(file.framePosition - tailStart) / rate)
                try? await Task.sleep(until: due, clock: .continuous)
            }
        }
    }

    /// Waits until the simulated microphone has played everything (the moment the user "releases").
    func waitForSimulatedInput() async {
        await feederTask?.value
    }

    /// Renders `url` through a pitch-preserving time stretch (rate < 1 slows speech down).
    static func timeStretched(_ url: URL, rate: Float) throws -> URL {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let stretch = AVAudioUnitTimePitch()
        stretch.rate = rate
        engine.attach(player)
        engine.attach(stretch)
        engine.connect(player, to: stretch, format: format)
        engine.connect(stretch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleFile(source, at: nil)
        player.play()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("articulate-stretch-\(UUID().uuidString).caf")
        let output = try AVAudioFile(forWriting: out, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        let total = AVAudioFramePosition(Double(source.length) / Double(rate)) + 4096
        while engine.manualRenderingSampleTime < total {
            let frames = min(AVAudioFrameCount(total - engine.manualRenderingSampleTime), 4096)
            guard try engine.renderOffline(frames, to: buffer) == .success else { break }
            try output.write(from: buffer)
        }
        engine.stop()
        return out
    }

    /// Feeds a file through the same conversion path as the microphone (self-test, retry, restore).
    func transcribeFile(_ url: URL) async throws -> String {
        var url = url
        if let tempo, tempo != 1 {
            url = try Self.timeStretched(url, rate: tempo)
        }
        let file = try AVAudioFile(forReading: url)
        startAnalyzer()
        let chunk: AVAudioFrameCount = 4096
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            feed(buffer, adjustGain: false)
        }
        return try await finish()
    }

    private func startAnalyzer() {
        let recognizer = recognizer
        let module = recognizer.module
        let analyzer = analyzer
        let inputStream = inputStream
        let locale = locale
        let contextualStrings = contextualStrings

        resultsTask = Task { [weak self] in
            do {
                switch recognizer {
                case .dictation(let m):
                    for try await result in m.results {
                        self?.receive(text: result.text, isFinal: result.isFinal, end: result.range.end.seconds, alternatives: result.alternatives)
                    }
                case .speech(let m):
                    for try await result in m.results {
                        self?.receive(text: result.text, isFinal: result.isFinal, end: result.range.end.seconds, alternatives: result.alternatives)
                    }
                }
            } catch {
                NSLog("Articulate: transcription results ended with error: \(error)")
            }
        }

        startTask = Task { [weak self] in
            try await Self.prepareAssets(for: locale, config: { if case .speech = recognizer { "speech" } else { "long" } }())
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw TranscriberError.noAudioFormat
            }
            self?.setAnalyzerFormat(format)
            if !contextualStrings.isEmpty {
                // Personal dictionary words bias recognition towards the user's spelling.
                let context = AnalysisContext()
                context.contextualStrings[.general] = Array(contextualStrings.prefix(200))
                try? await analyzer.setContext(context)
            }
            try await analyzer.start(inputSequence: inputStream)
        }
    }

    private func receive(text: AttributedString, isFinal: Bool, end: Double, alternatives: [AttributedString]) {
        if ProcessInfo.processInfo.environment["ARTICULATE_DEBUG_RESULTS"] != nil {
            FileHandle.standardError.write(Data("[\(isFinal ? "final" : "volatile")] end=\(end) \(String(text.characters))\n".utf8))
        }
        latestResultEnd = max(latestResultEnd, end)
        handle(text: String(text.characters), isFinal: isFinal, alternatives: alternatives.map { String($0.characters) })
    }

    private func setAnalyzerFormat(_ format: AVAudioFormat) {
        lock.withLock {
            analyzerFormat = format
            if let recordingURL {
                recordingFile = try? AVAudioFile(forWriting: recordingURL, settings: format.settings,
                                                 commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            }
        }
    }

    private func feed(_ buffer: AVAudioPCMBuffer, adjustGain: Bool = true) {
        audioSink?(buffer)
        let rms = Self.rms(buffer)
        reportLevel(rms)
        let input = adjustGain && ProcessInfo.processInfo.environment["ARTICULATE_NO_AGC"] == nil ? applyAutomaticGain(buffer, rms: rms) : buffer
        lock.lock()
        defer { lock.unlock() }
        guard let outputFormat = analyzerFormat else {
            if let copy = input.copy() as? AVAudioPCMBuffer { pending.append(copy) }
            return
        }
        for queued in pending { convertAndYield(queued, to: outputFormat) }
        pending.removeAll()
        convertAndYield(input, to: outputFormat)
    }

    /// Boosts quiet input (whispering, distant mic) towards a steady speech level.
    private func applyAutomaticGain(_ buffer: AVAudioPCMBuffer, rms: Float) -> AVAudioPCMBuffer {
        let target: Float = 0.06
        if rms > 0.003 {
            let wanted = min(max(target / rms, 1), 8)
            gain = gain * 0.85 + wanted * 0.15
        }
        guard gain > 1.05, let channels = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let out = copy.floatChannelData
        else { return buffer }
        copy.frameLength = buffer.frameLength
        for c in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(buffer.frameLength) {
                out[c][i] = max(-1, min(1, channels[c][i] * gain))
            }
        }
        return copy
    }

    /// Must be called with `lock` held.
    private func convert(_ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == outputFormat { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            NSLog("Articulate: audio conversion failed: \(error)")
            return nil
        }
        return converted
    }

    /// Must be called with `lock` held.
    private func convertAndYield(_ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) {
        guard let output = convert(buffer, to: outputFormat), output.frameLength > 0 else { return }
        try? recordingFile?.write(from: output)
        inputBuilder.yield(AnalyzerInput(buffer: output))
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in 0..<n { sum += channel[i] * channel[i] }
        return (sum / Float(n)).squareRoot()
    }

    private var lastLevelReport: TimeInterval = 0

    private func reportLevel(_ rms: Float) {
        guard let onLevel else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelReport > 0.03 else { return }
        lastLevelReport = now
        // Map roughly -50 dB…-10 dB onto 0…1.
        let db = 20 * log10(max(rms, 1e-6))
        let level = max(0, min(1, (db + 50) / 40))
        Task { @MainActor in onLevel(level) }
    }

    private func handle(text: String, isFinal: Bool, alternatives: [String] = []) {
        let preview: String = lock.withLock {
            if isFinal {
                finalized.append(text)
                finalizedAlternatives.append(alternatives.filter { $0 != text })
                volatile = ""
            } else {
                volatile = text
            }
            return finalized.joined() + volatile
        }
        if let onPartial {
            Task { @MainActor in onPartial(preview) }
        }
        if isFinal, let onFinalized {
            let done = lock.withLock { finalized.joined() }
            Task { @MainActor in onFinalized(done) }
        }
    }

    /// Segments that had other plausible transcriptions: (what was chosen, the alternatives).
    var alternatives: [(chosen: String, others: [String])] {
        lock.withLock {
            zip(finalized, finalizedAlternatives).compactMap { chosen, others in
                others.isEmpty ? nil : (chosen, Array(others.prefix(3)))
            }
        }
    }

    /// Adds recognition hints once the screen has been read (the microphone is already running by then).
    func updateContext(terms: [String]) {
        guard !terms.isEmpty else { return }
        let analyzer = analyzer
        let all = Array((terms + contextualStrings).prefix(200))
        Task {
            let context = AnalysisContext()
            context.contextualStrings[.general] = all
            try? await analyzer.setContext(context)
        }
    }

    // MARK: - Finishing

    private func stopInput() {
        guard micRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micRunning = false
    }

    /// Stops recording and returns the final transcript.
    func finish() async throws -> String {
        stopInput()
        await feederTask?.value
        // Make sure the analyzer is running before closing its input.
        try await startTask?.value
        lock.withLock {
            if let format = analyzerFormat {
                for queued in pending { convertAndYield(queued, to: format) }
                pending.removeAll()
            }
            recordingFile = nil // closes the file
        }
        inputBuilder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        return lock.withLock { finalized.joined() + volatile }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops without transcribing. The recording (if any) is kept so it can be restored later.
    func cancel() async {
        stopInput()
        feederTask?.cancel()
        await feederTask?.value
        startTask?.cancel()
        lock.withLock {
            if let format = analyzerFormat {
                for queued in pending {
                    if let converted = convert(queued, to: format) { try? recordingFile?.write(from: converted) }
                }
            }
            pending.removeAll()
            recordingFile = nil
        }
        inputBuilder.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
    }
}
