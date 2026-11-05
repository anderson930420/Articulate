import AppKit

/// The app's entry point. Besides launching the menu bar app it answers two commands:
///   Articulate --render-icon <dir.iconset>          render the app icon (used by build.sh)
///   Articulate --learn-from-transcripts [--apply]   learn terms the user fixed before sending, from Claude Code transcripts
/// Tests are in Tests/ (`swift test`).
public enum ArticulateApp {
    public static func run() -> Never {
        let arguments = CommandLine.arguments
        #if ARTICULATE_LAB
        LabCommands.run(arguments)
        #endif

        if arguments.count >= 2, arguments[1] == "--learn-from-transcripts" {
            runAsync { await TranscriptLearning.run(apply: arguments.contains("--apply")); return 0 }
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

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            #if ARTICULATE_LAB
            LabCommands.prepare(delegate, arguments)
            #endif
            app.delegate = delegate
            app.run()
        }
        exit(0)
    }
}

/// Runs `body` on the main run loop and exits with its status.
func runAsync(_ body: @escaping () async -> Int32) -> Never {
    Task { exit(await body()) }
    dispatchMain()
}
