import Foundation

/// The user's own Claude Code CLI, signed in with their Claude subscription (Pro/Max). Articulate runs the
/// unmodified `claude` binary in print mode and never reads its login: `claude auth status` says whether it is
/// signed in with a subscription, and API-key variables are removed so a request can't bill an API key instead.
enum ClaudeCodeCLI {
    /// Measured with the polish prompt: Sonnet answers a short sentence in about 2 s (first token 1.1 s);
    /// Haiku took 23–45 s through the subscription, so it isn't offered.
    static let models: [(id: String, label: String)] = [("sonnet", "Sonnet（推薦）"), ("opus", "Opus（較慢）")]

    static var model: String {
        let m = UserDefaults.standard.string(forKey: "claudeCodeModel") ?? ""
        return models.contains { $0.id == m } ? m : "sonnet"
    }

    /// Where setup found it through the login shell, then the usual install locations.
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let saved = UserDefaults.standard.string(forKey: "claudePath").map { [$0] } ?? []
        return (saved + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude",
                         "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude"])
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Installed and, as last checked, signed in with a Claude subscription.
    static var isAvailable: Bool {
        executable != nil && UserDefaults.standard.string(forKey: "claudeAuthMethod") == "claude.ai"
    }

    /// Articulate's environment without the variables that would send requests to an API key or a cloud provider.
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ANTHROPIC_") && !$0.key.hasPrefix("CLAUDE_CODE_USE_") }
    }

    /// The known locations, then the user's login shell. `whence -p`/`type -P` look past aliases: a shell alias
    /// named `claude` (some tools add one) is not the CLI.
    static func find() async -> URL? {
        if let known = executable { return known }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let lookup = shell.hasSuffix("zsh") ? "whence -p claude" : "type -P claude"
        guard let output = try? await Shell.run(URL(fileURLWithPath: shell), ["-lc", lookup]), output.status == 0 else { return nil }
        let path = output.text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        UserDefaults.standard.set(path, forKey: "claudePath")
        return URL(fileURLWithPath: path)
    }

    struct Status: Equatable {
        /// "claude.ai" for a subscription; "api_key", "none", … otherwise.
        let method: String
        let plan: String?
        var isSubscription: Bool { method == "claude.ai" }
    }

    /// `claude auth status` (JSON). The result is remembered so `isAvailable` doesn't run the CLI.
    static func status(_ claude: URL) async -> Status {
        let output = try? await Shell.run(claude, ["auth", "status"], replacing: environment)
        let text = output?.text ?? ""
        var method = "none", plan: String?
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
           let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] {
            if object["loggedIn"] as? Bool == true { method = object["authMethod"] as? String ?? "none" }
            plan = object["subscriptionType"] as? String
        }
        UserDefaults.standard.set(method, forKey: "claudeAuthMethod")
        return Status(method: method, plan: plan)
    }

    static func version(_ claude: URL) async -> String {
        let output = try? await Shell.run(claude, ["--version"], replacing: environment)
        return output?.text.split(separator: " ").first.map(String.init) ?? ""
    }

    /// Refreshes the remembered sign-in in the background (at launch, so a login made in Terminal is noticed).
    static func refreshStatus() {
        Task.detached(priority: .utility) {
            guard let claude = await find() else { return }
            _ = await status(claude)
        }
    }
}

/// Claude through Claude Code. Each request gets a fresh `claude -p` process (so no earlier dictation is in its
/// context); one is started ahead, when recording begins, so the request itself only waits for the model.
struct ClaudeCodeModel: LanguageModel {
    let name = "Claude（訂閱）"

    static let instructions = """
        You are a text-processing function inside a dictation app. Each user message contains <instructions> and \
        the data to process. Follow the instructions exactly and reply with the final result only. Never use tools.
        """

    func text(system: String, user: String) async throws -> String {
        try await complete("<instructions>\n\(system)\n</instructions>\n\(user)")
    }

    func json(system: String, user: String, schema: [String: Any]) async throws -> [String: Any] {
        let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self)
        let text = try await complete("<instructions>\n\(system)\n\n只輸出一個符合這個 JSON Schema 的 JSON 物件，不要加其他文字：\n\(schemaText)\n</instructions>\n\(user)")
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { throw AIError.badJSON }
        return object
    }

    private func complete(_ message: String) async throws -> String {
        let started = Date()
        let process = try await ClaudeCodePool.shared.take()
        // Claude's first token takes longer than Codex's, so the deadline starts later.
        let deadline = 9 + Double(CodexServerModel.expectedOutputLength(message)) / 100
        do {
            let reply = try await withThrowingTaskGroup(of: ClaudeCodeProcess.Reply.self) { group in
                group.addTask { try await process.ask(message) }
                group.addTask {
                    try await Task.sleep(for: .seconds(deadline))
                    throw CodexAppServer.ServerError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            process.stop()
            DiagnosticLog.write(String(format: "claude %@: done, %d chars after %.2fs; first token %.2fs", ClaudeCodeCLI.model,
                                       reply.text.count, Date().timeIntervalSince(started), reply.firstToken ?? -1))
            return reply.text
        } catch {
            process.stop()
            DiagnosticLog.write(String(format: "claude %@: failed after %.2fs: %@", ClaudeCodeCLI.model,
                                       Date().timeIntervalSince(started), error.localizedDescription))
            throw error
        }
    }
}

/// At most one `claude` process waiting for a request. It is started when recording begins and stopped after
/// a few idle minutes, so nothing runs (or takes memory) while Articulate sits unused.
actor ClaudeCodePool {
    static let shared = ClaudeCodePool()
    static let idleLifetime: TimeInterval = 180

    private var ready: ClaudeCodeProcess?
    private var lastWanted = Date.distantPast
    private var reaper: Task<Void, Never>?

    func prewarm() {
        lastWanted = Date()
        if ready?.isRunning != true { ready = try? ClaudeCodeProcess.start() }
        scheduleReap()
    }

    func take() throws -> ClaudeCodeProcess {
        let process = try (ready?.isRunning == true ? ready : nil) ?? ClaudeCodeProcess.start()
        ready = nil
        // More requests are likely soon (the rest of a long dictation, the next sentence), so start the next one.
        if Date().timeIntervalSince(lastWanted) < Self.idleLifetime { ready = try? ClaudeCodeProcess.start() }
        scheduleReap()
        return process
    }

    func stop() {
        ready?.stop()
        ready = nil
    }

    private func scheduleReap() {
        reaper?.cancel()
        reaper = Task {
            try? await Task.sleep(for: .seconds(Self.idleLifetime))
            guard !Task.isCancelled else { return }
            self.stop()
        }
    }
}

/// One `claude -p` process taking a single request over stdin (stream-json) and streaming the reply back.
final class ClaudeCodeProcess: @unchecked Sendable {
    struct Reply {
        let text: String
        let firstToken: TimeInterval?
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { "Claude：\(message)" }
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: AsyncStream<[String: Any]>.Continuation?
    private let stream: AsyncStream<[String: Any]>

    var isRunning: Bool { process.isRunning }

    static func start() throws -> ClaudeCodeProcess {
        guard let claude = ClaudeCodeCLI.executable else { throw AIError.noEngine }
        let p = ClaudeCodeProcess()
        p.process.executableURL = claude
        p.process.arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--model", ClaudeCodeCLI.model,
            // A plain text function: no tools, MCP servers, settings files (hooks, CLAUDE.md) or saved sessions.
            "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence",
            "--system-prompt", ClaudeCodeModel.instructions,
        ]
        p.process.environment = ClaudeCodeCLI.environment
        p.process.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.process.standardInput = p.input
        p.process.standardOutput = p.output
        p.process.standardError = FileHandle.nullDevice
        p.output.fileHandleForReading.readabilityHandler = { [weak p] handle in p?.receive(handle.availableData) }
        p.process.terminationHandler = { [weak p] _ in p?.finish() }
        try p.process.run()
        return p
    }

    private init() {
        var continuation: AsyncStream<[String: Any]>.Continuation?
        stream = AsyncStream { continuation = $0 }
        lines = continuation
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        let complete: [Data] = lock.withLock {
            buffer.append(data)
            var found: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                found.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return found
        }
        for line in complete {
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { lines?.yield(object) }
        }
    }

    private func finish() {
        output.fileHandleForReading.readabilityHandler = nil
        lines?.finish()
    }

    /// Sends the request and returns the reply as soon as the answer itself ends; Claude Code reports its final
    /// "result" about two seconds later, which isn't worth waiting for.
    func ask(_ message: String) async throws -> Reply {
        let sent = Date()
        let request: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": message]]]]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)

        var firstToken: TimeInterval?
        var text = ""
        for await event in stream {
            try Task.checkCancellation()
            switch event["type"] as? String {
            case "stream_event":
                let inner = event["event"] as? [String: Any]
                if inner?["type"] as? String == "content_block_delta",
                   let delta = (inner?["delta"] as? [String: Any])?["text"] as? String {
                    if firstToken == nil { firstToken = Date().timeIntervalSince(sent) }
                    text += delta
                }
            case "assistant":
                let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                let full = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                return Reply(text: full.isEmpty ? text : full, firstToken: firstToken)
            case "result":
                // Only reached without an assistant message: an error such as being signed out.
                if event["is_error"] as? Bool == true || text.isEmpty {
                    throw Failure(message: event["result"] as? String ?? "沒有回應")
                }
                return Reply(text: text, firstToken: firstToken)
            default:
                break
            }
        }
        throw Failure(message: "Claude Code 結束了，沒有回應")
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
