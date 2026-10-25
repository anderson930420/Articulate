import AppKit
import AVFoundation

// Command-line self-tests run without the menu bar UI:
//   Articulate --transcribe-file <audio> [locale]   on-device transcription of an audio file
//   Articulate --ai-test                            polish / translate / ask / term learning with the current AI engine
//   Articulate --polish-file <lines.txt> [pause]    polish each line and print the result with its time
//   Articulate --polish-eval <cases.json> <runs> <report.json>   how far polishing drifts (judge: ARTICULATE_JUDGE_MODEL)
//   Articulate --selftest-hotkeys                   check the shortcut state machine
//   Articulate --selftest-codex-cancel              a Codex request given up on ends at once
//   Articulate --selftest-codex-memory              Codex lets go of threads after use
//   Articulate --selftest-setup                     first-run setup: Codex, uv, checksum, downloader
//   Articulate --selftest-updater                   update: latest release, download, signature, swap
//   Articulate --selftest-learner                   replay edits after inserting and check what the dictionary learns
//   Articulate --learn-from-transcripts [--apply]   learn terms the user fixed before sending, from Claude Code transcripts
//   Articulate --render-previews <dir>              render UI screenshots
//   Articulate --render-icon <dir.iconset>          render the app icon (used by build.sh)
//   Articulate --check-bar regular|accessory [seconds] [reuse|static|thinking]   show the floating bar; report Space, frames, CPU
// End-to-end (needs Accessibility; launch with `open Articulate.app --args --e2e <audio-dir> <report>`).
let arguments = CommandLine.arguments

func runAsync(_ body: @escaping () async -> Int32) -> Never {
    Task { exit(await body()) }
    dispatchMain()
}

if arguments.count >= 3, arguments[1] == "--transcribe-file" {
    let url = URL(fileURLWithPath: arguments[2])
    let locale = Locale(identifier: arguments.count >= 4 ? arguments[3] : Prefs.language.rawValue)
    runAsync {
        do {
            let start = Date()
            let hints = ProcessInfo.processInfo.environment["ARTICULATE_CONTEXT_TERMS"]?.split(separator: ",").map(String.init) ?? []
            let text = try await LiveTranscriber(locale: locale, contextualStrings: hints).transcribeFile(url)
            print(text)
            FileHandle.standardError.write(Data(String(format: "(%.2fs)\n", Date().timeIntervalSince(start)).utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}

if arguments.count >= 3, arguments[1] == "--measure-release" {
    // Plays a file in real time like a microphone, then measures how long the transcript takes after "release".
    let url = URL(fileURLWithPath: arguments[2])
    runAsync {
        do {
            try await LiveTranscriber.prepareAssets(for: Locale(identifier: Prefs.language.rawValue))
            let transcriber = LiveTranscriber(locale: Locale(identifier: Prefs.language.rawValue))
            try transcriber.startSimulatedMicrophone(file: url)
            let file = try AVAudioFile(forReading: url)
            try await Task.sleep(for: .seconds(Double(file.length) / file.processingFormat.sampleRate + 0.2))
            let released = Date()
            let text = try await transcriber.finish()
            print(String(format: "%.2fs after release | %@", Date().timeIntervalSince(released), text))
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }
}

if arguments.count >= 3, arguments[1] == "--bench-asr" {
    let configs = arguments.count >= 4 ? arguments[3].split(separator: ",").map(String.init) : ["short", "long"]
    runAsync { await TypelessBenchmark.runASR(count: Int(arguments[2]) ?? 36, configs: configs); return 0 }
}

if arguments.count >= 5, arguments[1] == "--export-training" {
    runAsync {
        await TypelessBenchmark.exportTrainingPairs(testCount: Int(arguments[2]) ?? 36, trainCount: Int(arguments[3]) ?? 300,
                                                    output: URL(fileURLWithPath: arguments[4]))
        return 0
    }
}

if arguments.count >= 5, arguments[1] == "--mine-vocab" {
    TypelessBenchmark.mineVocabulary(testCount: Int(arguments[2]) ?? 36, limit: Int(arguments[3]) ?? 300, output: URL(fileURLWithPath: arguments[4]))
    exit(0)
}

if arguments.count >= 4, arguments[1] == "--train-lm" {
    runAsync {
        await TypelessBenchmark.trainLanguageModel(testCount: Int(arguments[2]) ?? 36, directory: URL(fileURLWithPath: arguments[3]),
                                                   extraTerms: TypelessBenchmark.dictionaryTerms)
        return 0
    }
}

if arguments.count >= 6, arguments[1] == "--bench-whisper" {
    runAsync {
        await TypelessBenchmark.runWhisper(model: URL(fileURLWithPath: arguments[2]), label: arguments[3], mode: arguments[4],
                                           report: URL(fileURLWithPath: arguments[5]))
        return 0
    }
}

if arguments.count >= 3, arguments[1] == "--asr-dump" {
    runAsync { await TypelessBenchmark.dumpRecognition(to: URL(fileURLWithPath: arguments[2])); return 0 }
}

if arguments.count >= 5, arguments[1] == "--polish-dump" {
    runAsync {
        await TypelessBenchmark.polishDump(URL(fileURLWithPath: arguments[2]), variant: arguments[3], report: URL(fileURLWithPath: arguments[4]))
        return 0
    }
}

if arguments.count >= 4, arguments[1] == "--rejudge" {
    runAsync { await TypelessBenchmark.rejudge(saved: URL(fileURLWithPath: arguments[2]), report: URL(fileURLWithPath: arguments[3])); return 0 }
}

if arguments.count >= 4, arguments[1] == "--bench-quality" {
    runAsync { await TypelessBenchmark.runQuality(count: Int(arguments[2]) ?? 36, label: arguments[3]); return 0 }
}

if arguments.count >= 4, arguments[1] == "--bench-typeless" {
    let count = Int(arguments[2]) ?? 12
    let details = arguments.count >= 5 ? URL(fileURLWithPath: arguments[4]) : nil
    runAsync { await TypelessBenchmark.run(count: count, report: URL(fileURLWithPath: arguments[3]), details: details) ? 0 : 1 }
}

if arguments.count >= 3, arguments[1] == "--polish-file" {
    // One raw transcript per line; prints the polished text and the time each took (for prompt experiments).
    // An optional pause between lines (seconds) mimics real use, where the thread pool refills between dictations.
    let pause = arguments.count >= 4 ? Double(arguments[3]) ?? 0 : 0
    // Like the app: ARTICULATE_BENCH_SCREEN=<text file> adds on-screen text, ARTICULATE_BENCH_FUSION=1 a second transcript.
    let environment = ProcessInfo.processInfo.environment
    let screenText = environment["ARTICULATE_BENCH_SCREEN"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    let fusion = environment["ARTICULATE_BENCH_FUSION"] == "1"
    let lines = ((try? String(contentsOfFile: arguments[2], encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    runAsync {
        guard let engine = AIEngine.current() else { print("no AI engine"); return 1 }
        AIEngine.prewarm()
        try? await Task.sleep(for: .seconds(3))
        for (i, line) in lines.enumerated() {
            let start = Date()
            var ctx = PromptContext(language: Prefs.language)
            if let screenText { ctx.screen = ScreenContext(appName: "Claude", visibleText: String(screenText.suffix(2000))) }
            // A second recognizer's version differs a little (here: without punctuation).
            if fusion { ctx.hypotheses = [line, line.filter { !"，。？！、".contains($0) }] }
            let text = (try? await AITasks.polish(line, ctx: ctx, with: engine)) ?? "(failed)"
            print(String(format: "### %d %.2fs\n", i + 1, Date().timeIntervalSince(start)) + text)
            if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
        }
        return 0
    }
}

if arguments.count >= 5, arguments[1] == "--polish-eval" {
    runAsync {
        await PolishEval.run(cases: URL(fileURLWithPath: arguments[2]), runs: Int(arguments[3]) ?? 5, report: URL(fileURLWithPath: arguments[4]))
        return 0
    }
}

if arguments.count >= 2, arguments[1] == "--ai-test" {
    runAsync { await AISelfTest.run() ? 0 : 1 }
}

if arguments.count >= 2, arguments[1] == "--learn-from-transcripts" {
    runAsync { await TranscriptLearning.run(apply: arguments.contains("--apply")); return 0 }
}

if arguments.count >= 2, arguments[1] == "--selftest-learner" {
    runAsync { await MainActor.run { () -> Task<Bool, Never> in Task { await LearnerSelfTest.run() } }.value ? 0 : 1 }
}

if arguments.count >= 2, arguments[1] == "--selftest-updater" {
    runAsync { await MainActor.run { () -> Task<Bool, Never> in Task { await UpdaterSelfTest.run() } }.value ? 0 : 1 }
}

if arguments.count >= 2, arguments[1] == "--selftest-setup" {
    runAsync { await MainActor.run { () -> Task<Bool, Never> in Task { await SetupSelfTest.run() } }.value ? 0 : 1 }
}

if arguments.count >= 2, arguments[1] == "--selftest-codex-memory" {
    runAsync { await CodexSelfTest.memory(requests: Int(ProcessInfo.processInfo.environment["ARTICULATE_MEMORY_REQUESTS"] ?? "") ?? 20) ? 0 : 1 }
}

if arguments.count >= 2, arguments[1] == "--selftest-codex-cancel" {
    runAsync { await CodexSelfTest.run() ? 0 : 1 }
}

if arguments.count >= 2, arguments[1] == "--selftest-hotkeys" {
    exit(HotkeySelfTest.run() ? 0 : 1)
}

if arguments.count >= 2, arguments[1] == "--bench-scroll" {
    MainActor.assumeIsolated {
        // Tests that draw windows stay out of the Dock and the app switcher, and never outlive two minutes.
        NSApplication.shared.setActivationPolicy(.prohibited)
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { exit(2) }
        ScrollBenchmark.run()
    }
    exit(0)
}

if arguments.count >= 3, arguments[1] == "--check-bar" {
    // Shows the real floating bar and reports, every half second, whether it is on the Space in front (e.g. a
    // full-screen app), how many frames the animation drew, and the CPU the process used. Runs the app's own run
    // loop, as Articulate does: driving the run loop by hand made the animation look far more expensive than it is.
    final class Probe {
        var tick = 0.0, frames = 0, relayouts = 0, cpu = 0.0
        static func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
    }
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(arguments[2] == "regular" ? .regular : .accessory)
        let bar = FloatingBar()
        // "static" shows a message without animation, "thinking" the processing animation.
        bar.show(arguments.contains("static") ? .message("static") : arguments.contains("thinking") ? .thinking : .listening)
        let seconds = arguments.count >= 4 ? Double(arguments[3]) ?? 1 : 1
        // "reuse": hide after 1 s and show again at 3 s, like two dictations in a row.
        let reuse = arguments.contains("reuse")
        let me = ProcessInfo.processInfo.processIdentifier
        let probe = Probe()
        probe.cpu = Probe.cpuSeconds()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                probe.tick += 0.5
                let drawn = bar.model.meter.frames - probe.frames
                probe.frames = bar.model.meter.frames
                let resized = bar.relayouts - probe.relayouts
                probe.relayouts = bar.relayouts
                let cpu = Probe.cpuSeconds()
                let load = (cpu - probe.cpu) / 0.5 * 100
                probe.cpu = cpu
                if reuse, probe.tick == 1 { bar.hide() }
                if reuse, probe.tick == 3 { bar.show(.listening) }
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                let onScreen = windows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == me }
                let fullScreen = windows.contains { ($0[kCGWindowName as String] as? String) == "Fullscreen Backdrop" }
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                print(String(format: "%.1fs front=%@ %@ bar on screen=%@, %d frames drawn, %d re-sizes, %.0f%% CPU", probe.tick, front,
                             fullScreen ? "(full-screen Space)" : "(desktop Space)", onScreen ? "yes" : "NO", drawn, resized, load))
                if probe.tick >= seconds {
                    bar.hide()
                    exit(0)
                }
            }
        }
        app.run()
    }
}

if arguments.count >= 3, arguments[1] == "--render-icon" {
    do {
        try LogoMark.writeIconset(to: URL(fileURLWithPath: arguments[2], isDirectory: true))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if arguments.count >= 3, arguments[1] == "--render-previews" {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        PreviewRenderer.run(into: URL(fileURLWithPath: arguments[2], isDirectory: true))
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    if let i = arguments.firstIndex(of: "--e2e"), arguments.count > i + 2 {
        delegate.endToEndArguments = (URL(fileURLWithPath: arguments[i + 1], isDirectory: true), URL(fileURLWithPath: arguments[i + 2]))
    }
    app.delegate = delegate
    app.run()
}
