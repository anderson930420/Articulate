@preconcurrency import AVFoundation
import Foundation
@testable import ArticulateCore

private final class SpeedFakeModel: LanguageModel, @unchecked Sendable {
    let name = "offline"
    struct Call: Equatable { let system: String; let user: String; let twin: Bool }
    private let lock = NSLock()
    private var stored: [Call] = []
    private var stopped = 0
    var calls: [Call] { lock.withLock { stored } }
    var cancellations: Int { lock.withLock { stopped } }
    var delay: Double = 0.01
    private func record(system: String, user: String, twin: Bool) async throws -> String {
        lock.withLock { stored.append(Call(system: system, user: user, twin: twin)) }
        do { try await Task.sleep(for: .seconds(delay)) }
        catch { lock.withLock { stopped += 1 }; throw error }
        return "這是測試文字。"
    }
    func text(system: String, user: String) async throws -> String {
        try await record(system: system, user: user, twin: false)
    }
    func shortDictationText(system: String, user: String, onWinner: (@Sendable (String) -> Void)?) async throws -> String {
        let text = try await record(system: system, user: user, twin: true)
        onWinner?("twin")
        return text
    }
    func json(system: String, user: String, schema: [String: Any]) async throws -> [String: Any] { [:] }
}

private actor SpeedFakeTEA {
    struct Call { let count: Int; let prompt: String }
    var calls: [Call] = []
    let delay: Double
    init(delay: Double = 0.005) { self.delay = delay }
    func transcribe(_ samples: [Float], prompt: String) async -> String? {
        calls.append(Call(count: samples.count, prompt: prompt))
        do { try await Task.sleep(for: .seconds(delay)) } catch { return nil }
        return "第\(calls.count)段文字"
    }
}

private actor SpeedFakeTurns {
    var messages: [String] = []
    var copies: [String] = []
    var stopped = 0
    func run(copy: String, message: String, token: @escaping @Sendable () -> Void) async throws -> String {
        messages.append(message); copies.append(copy)
        do {
            try await Task.sleep(for: .milliseconds(copy == "twin" ? 5 : 30))
            token()
            try await Task.sleep(for: .milliseconds(10))
            return "這是測試文字。"
        } catch { stopped += 1; throw error }
    }
}

private final class SpeedRaceProbe: @unchecked Sendable {
    let lock = NSLock()
    var stopped = Set<Int>()
    func stop(_ copy: Int) { lock.withLock { _ = stopped.insert(copy) } }
    var count: Int { lock.withLock { stopped.count } }
}

@MainActor
enum DictationSpeedSelfTest {
    private static func buffer(_ energies: [(Float, Int)]) -> AVAudioPCMBuffer {
        let count = energies.reduce(0) { $0 + $1.1 * SpeechChunker.frame }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        var index = 0
        for (value, frames) in energies {
            for _ in 0..<(frames * SpeechChunker.frame) { buffer.floatChannelData![0][index] = value; index += 1 }
        }
        return buffer
    }

    private static func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    static func run() async -> Bool {
        let saved = ProcessInfo.processInfo.environment["ARTICULATE_SHORT_DICTATION_SPEED"]
        defer {
            if let saved { setenv("ARTICULATE_SHORT_DICTATION_SPEED", saved, 1) }
            else { unsetenv("ARTICULATE_SHORT_DICTATION_SPEED") }
        }
        setenv("ARTICULATE_SHORT_DICTATION_SPEED", "1", 1)
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") dictation-speed: \(name)")
        }
        let pause = buffer([(0, 20), (0.04, 20), (0, 13)])
        do {
            var chunker = SpeechChunker()
            let samples = Array(UnsafeBufferPointer(start: pause.floatChannelData![0], count: Int(pause.frameLength)))
            check(chunker.update(samples).isEmpty && chunker.pauses == [0..<(43 * SpeechChunker.frame)], "early pause after 8 silent frames cuts at f - silentRun / 2")
            let tea = SpeedFakeTEA()
            let recognizer = CompanionRecognizer(shortDictation: true, inference: { await tea.transcribe($0, prompt: $1) })
            recognizer.append(pause)
            let ready = await until { recognizer.hasPausePass }
            recognizer.append(buffer([(0, 15)]))
            let text = await recognizer.finish(timeout: 1, allowEarly: true)
            let calls = await tea.calls
            check(ready && recognizer.usedEarly && text == "第1段文字" && calls.count == 1 && calls.first?.count == 43 * SpeechChunker.frame,
                  "early TEA reused through trailing silence")
            check(calls.first?.prompt == "以下是台灣華語，可能夾雜英文。", "early TEA gets real-piece context")
        }
        do {
            let tea = SpeedFakeTEA()
            let recognizer = CompanionRecognizer(shortDictation: true, inference: { await tea.transcribe($0, prompt: $1) })
            recognizer.append(pause)
            _ = await until { recognizer.hasPausePass }
            recognizer.append(buffer([(0.04, 5)]))
            _ = await recognizer.finish(timeout: 1, allowEarly: true)
            let calls = await tea.calls
            check(!recognizer.usedEarly && calls.count == 2 && calls.last?.count == 58 * SpeechChunker.frame,
                  "speech after the cut falls back to the unchanged full remainder")
        }
        do {
            let tea = SpeedFakeTEA()
            let recognizer = CompanionRecognizer(shortDictation: true, inference: { await tea.transcribe($0, prompt: $1) })
            recognizer.stopEarlyPasses()
            recognizer.append(pause)
            try? await Task.sleep(for: .milliseconds(15))
            let before = await tea.calls.count
            _ = await recognizer.finish(timeout: 1, allowEarly: true)
            let after = await tea.calls.count
            check(before == 0 && !recognizer.usedEarly && after == 1, "length/mode stop is sticky; final real piece still runs")
        }
        do {
            let tea = SpeedFakeTEA()
            let recognizer = CompanionRecognizer(shortDictation: true, inference: { await tea.transcribe($0, prompt: $1) })
            // A real piece at six seconds, then a short piece with its own pause.
            recognizer.append(buffer([(0, 20), (0.04, 190), (0, 13)]))
            recognizer.append(buffer([(0.04, 20), (0, 13)]))
            _ = await until { recognizer.hasPausePass }
            let text = await recognizer.finish(timeout: 1, allowEarly: true)
            let calls = await tea.calls
            check(calls.count == 2 && calls[1].prompt.hasSuffix("\n第1段文字") && text == "第1段文字第2段文字", "real piece stays first; early prompt includes previous piece suffix")
        }
        do {
            let tea = SpeedFakeTEA(delay: 0.04)
            let recognizer = CompanionRecognizer(shortDictation: true, inference: { await tea.transcribe($0, prompt: $1) })
            // Queue several pauses while the previous real piece is in flight.
            recognizer.append(buffer([(0, 20), (0.04, 190), (0, 13)]))
            recognizer.append(pause)
            recognizer.append(pause)
            _ = await until { recognizer.hasPausePass }
            _ = await recognizer.finish(timeout: 1, allowEarly: true)
            let calls = await tea.calls
            check(calls.count == 2 && recognizer.usedEarly, "newer queued pause replaces the older without delaying/reordering real pieces")
        }

        do {
            let tea = SpeedFakeTEA()
            let recognizer = CompanionRecognizer(shortDictation: true, inference: { await tea.transcribe($0, prompt: $1) })
            recognizer.append(pause)
            _ = await until { recognizer.hasPausePass }
            let apple = Task<String, Error> { String(repeating: "字", count: Prefs.strongModelFromLength) }
            _ = await recognizer.finish(timeout: 1, finalTranscript: apple)
            let count = await tea.calls.count
            check(!recognizer.usedEarly && count == 2, "final Apple length at threshold rejects a ready TEA candidate")
        }
        do {
            // The key release clicks for a frame or two; that is not more speech.
            let tea = SpeedFakeTEA()
            let recognizer = CompanionRecognizer(shortDictation: true, inference: { await tea.transcribe($0, prompt: $1) })
            recognizer.append(pause)
            _ = await until { recognizer.hasPausePass }
            recognizer.append(buffer([(0.04, 2), (0, 4)]))
            let apple = Task<String, Error> { "這是測試文字" }
            _ = await recognizer.finish(timeout: 1, finalTranscript: apple)
            check(recognizer.usedEarly, "a key click after the cut keeps the pause pass")
        }
        do {
            // Released while the pause pass is still running: wait for it instead of starting over.
            let tea = SpeedFakeTEA(delay: 0.3)
            let recognizer = CompanionRecognizer(shortDictation: true, inference: { await tea.transcribe($0, prompt: $1) })
            recognizer.append(pause)
            _ = await until { await tea.calls.count == 1 }
            let apple = Task<String, Error> { "這是測試文字" }
            let text = await recognizer.finish(timeout: 2, finalTranscript: apple)
            let calls = await tea.calls
            check(recognizer.usedEarly && text?.hasSuffix("段文字") == true && calls.first?.count == 43 * SpeechChunker.frame
                    && recognizer.earlyDiagnostics.hasSuffix("waited for pause pass"),
                  "a pass still running at release is awaited and used")
        }

        let raw = "這是測試文字"
        let alternatives: [(chosen: String, others: [String])] = [(raw, ["這是測試字句"])]
        do {
            let model = SpeedFakeModel()
            let polisher = SpeculativePolisher(engine: model, ctx: PromptContext(), usesSecond: true, shortDictation: true)
            _ = try await polisher.finish(transcript: raw, alternatives: alternatives, second: "另一份文字")
            check(model.calls.count == 1 && model.calls[0].twin && polisher.lastPath == "whole (short)" && polisher.lastTwinWinner == "twin",
                  "a whole short polish asks for twin requests")
        } catch { check(false, "short polish: \(error)") }
        do {
            let model = SpeedFakeModel()
            let polisher = SpeculativePolisher(engine: model, ctx: PromptContext(), shortDictation: true)
            let long = String(repeating: "字", count: SpeculativePolisher.firstPiece) + "。"
            polisher.update(finalized: long)
            _ = await until { !model.calls.isEmpty }
            _ = try await polisher.finish(transcript: long)
            check(model.calls.count == 1 && !model.calls[0].twin, "piece polishing stays a single request")
            _ = try await AITasks.translate(raw, to: "en-US", ctx: PromptContext(), with: model)
            _ = try await AITasks.polishContinuation(raw, previous: raw, ctx: PromptContext(), with: model)
            _ = try await AITasks.polish(raw, ctx: PromptContext(), with: model)
            check(model.calls.dropFirst().allSatisfy { !$0.twin }, "translation, continuation and ordinary non-dictation polish remain single")
        } catch { check(false, "single requests: \(error)") }
        for fast in 0..<2 {
            do {
                let probe = SpeedRaceProbe()
                let result = try await FirstTokenRace().run { copy, token in
                    do {
                        try await Task.sleep(for: .milliseconds(copy == fast ? 5 : 60))
                        token()
                        // The first token wins even if that copy takes longer to complete.
                        try await Task.sleep(for: .milliseconds(copy == fast ? 80 : 1))
                        return "copy\(copy)"
                    } catch { probe.stop(copy); throw error }
                }
                _ = await until { probe.count == 1 }
                check(result.text == "copy\(fast)" && result.by == (fast == 0 ? "first" : "twin") && probe.count == 1,
                      "copy \(fast) wins on first token and stops the loser")
            } catch { check(false, "twin race: \(error)") }
        }
        for route in ["short", "boundary99", "long", "continuation", "translation", "other", "disabled"] {
            do {
                let turns = SpeedFakeTurns()
                let model = CodexServerModel(turnRunner: { copy, message, token in
                    try await turns.run(copy: copy, message: message, token: token)
                })
                setenv("ARTICULATE_SHORT_DICTATION_SPEED", route == "disabled" ? "0" : "1", 1)
                switch route {
                case "continuation":
                    _ = try await AITasks.polishContinuation(raw, previous: raw, ctx: PromptContext(), with: model)
                case "translation":
                    _ = try await AITasks.translate(raw, to: "en-US", ctx: PromptContext(), with: model)
                case "other":
                    _ = try await model.text(system: "test", user: "<transcript>\n\(raw)\n</transcript>")
                default:
                    let text = route == "long" ? String(repeating: "字", count: Prefs.strongModelFromLength)
                        : route == "boundary99" ? String(repeating: "字", count: Prefs.strongModelFromLength - 1) : raw
                    _ = try await AITasks.polish(text, ctx: PromptContext(), with: model, shortDictation: true)
                }
                let twins = route == "short" || route == "boundary99"
                if twins { _ = await until { await turns.stopped == 1 } }
                let messages = await turns.messages
                let stopped = await turns.stopped
                check(messages.count == (twins ? 2 : 1) && (!twins || (messages[0].utf8.elementsEqual(messages[1].utf8) && stopped == 1)),
                      "Codex transport \(route): \(twins ? "two identical messages, loser stopped" : "one message, original hedge")")
            } catch { check(false, "Codex transport \(route): \(error)") }
        }
        setenv("ARTICULATE_SHORT_DICTATION_SPEED", "1", 1)
        do {
            // Both copies stall: a third copy still goes out after the hedge delay, as for a single request.
            let model = CodexServerModel(turnRunner: { copy, _, token in
                if copy == "hedge" { return "這是測試文字。" }
                try await Task.sleep(for: .seconds(30))
                token()
                return "太晚了"
            })
            let winner = SpeedRaceProbe()
            let started = Date()
            let text = try await AITasks.polish(raw, ctx: PromptContext(), with: model, shortDictation: true,
                                                onWinner: { if $0 == "hedge" { winner.stop(2) } })
            let waited = Date().timeIntervalSince(started)
            check(text == "這是測試文字。" && winner.count == 1 && waited < CodexServerModel.hedgeDelay + 1,
                  "stalled twins fall back to the hedge copy")
        } catch { check(false, "stalled twins: \(error)") }
        do {
            let baseline = SpeedFakeModel(), disabled = SpeedFakeModel()
            let old = SpeculativePolisher(engine: baseline, ctx: PromptContext(), usesSecond: true)
            _ = try await old.finish(transcript: raw, alternatives: alternatives, second: "另一份文字")
            setenv("ARTICULATE_SHORT_DICTATION_SPEED", "0", 1)
            let new = SpeculativePolisher(engine: disabled, ctx: PromptContext(), usesSecond: true, shortDictation: true)
            _ = try await new.finish(transcript: raw, alternatives: alternatives, second: "另一份文字")
            check(baseline.calls == disabled.calls && old.lastPath == new.lastPath, "switch off sends byte-identical polish messages and preserves old path")
            let tea = SpeedFakeTEA()
            let recognizer = CompanionRecognizer(shortDictation: true, inference: { await tea.transcribe($0, prompt: $1) })
            recognizer.append(pause)
            _ = await recognizer.finish(timeout: 1, allowEarly: true)
            let calls = await tea.calls
            check(calls.count == 1 && calls[0].count == Int(pause.frameLength) && !recognizer.usedEarly, "switch off sends only the original full TEA remainder")
        } catch { check(false, "disabled baseline: \(error)") }
        print("dictation-speed: \(failures == 0 ? "PASS" : "FAIL") (\(failures) failures; offline fakes only)")
        return failures == 0
    }
}
