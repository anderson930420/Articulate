import Foundation

/// A long-lived `codex app-server` child process spoken to over JSON-RPC on stdio.
///
/// Measured with gpt-6-luna on this Mac (see README "Latency"):
/// - `codex exec` per request: ~4–5 s (process start, WebSocket connect, prewarm, first-turn setup).
/// - New thread on a running app-server, turn sent immediately: ~3.7 s.
/// - Thread whose first turn already ran ("primed"): ~1.4 s, even after minutes idle.
/// So Articulate keeps a small pool of primed threads and uses each one for exactly one real request.
final class CodexAppServer: @unchecked Sendable {
    static let shared = CodexAppServer()

    enum ServerError: LocalizedError {
        case notRunning
        case rpc(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .notRunning: "Codex app-server 沒有在執行"
            case .rpc(let message): "Codex：\(message)"
            case .timeout: "Codex 回應逾時"
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var listeners: [String: (String, [String: Any]) -> Void] = [:]
    private var startTask: Task<Void, Error>?

    var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    /// Starts the server once; later calls wait for the same start.
    func start() async throws {
        let task: Task<Void, Error> = lock.withLock {
            if let startTask { return startTask }
            let task = Task { try await self.launch() }
            startTask = task
            return task
        }
        do {
            try await task.value
        } catch {
            lock.withLock { startTask = nil }
            throw error
        }
    }

    private func launch() async throws {
        guard let executable = CodexModel.executable else { throw AIError.noEngine }
        let process = Process()
        process.executableURL = executable
        var arguments = ["app-server"]
        for key in ["include_permissions_instructions", "include_apps_instructions",
                    "include_collaboration_mode_instructions", "include_environment_context"] {
            arguments += ["-c", "\(key)=false"]
        }
        for feature in CodexModel.disabledFeatures { arguments += ["--disable", feature] }
        // No MCP servers: polishing needs no tools, and Codex starts every configured server (e.g. a Node process)
        // for each thread, piling them up and delaying the thread, which also triggers hedging. `mcp_servers={}` is
        // merged into the config rather than replacing it, so each server is switched off by name.
        for name in CodexModel.configuredMCPServers() { arguments += ["-c", "mcp_servers.\(name).enabled=false"] }
        // A thread nobody is subscribed to is unloaded after this many seconds (Codex's default is 30 minutes).
        // Every dictation uses a fresh thread and lets go of it (`release(thread:)`), so a short delay keeps the
        // app-server near its start-up size instead of growing about 2 MB per dictation. Only this process gets
        // the setting; ~/.codex/config.toml is left alone.
        arguments += ["-c", "thread_unload_delay_secs=\(Self.threadUnloadDelay)"]
        process.arguments = arguments
        let workdir = FileManager.default.temporaryDirectory.appendingPathComponent("articulate-codex-server", isDirectory: true)
        try? FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        process.currentDirectoryURL = workdir
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in self?.handleExit() }
        try process.run()
        lock.withLock {
            self.process = process
            self.input = stdinPipe.fileHandleForWriting
        }
        _ = try await call("initialize", ["clientInfo": ["name": "articulate", "title": "Articulate", "version": "0.2"], "capabilities": NSNull()], timeout: 15)
        send(["method": "initialized"])
    }

    private func handleExit() {
        let waiting: [CheckedContinuation<[String: Any], Error>] = lock.withLock {
            let all = Array(pending.values)
            pending.removeAll()
            process = nil
            input = nil
            startTask = nil
            return all
        }
        for continuation in waiting { continuation.resume(throwing: ServerError.notRunning) }
    }

    func stop() {
        lock.withLock { process }?.terminate()
    }

    // MARK: - JSON-RPC

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let handle = lock.withLock { input }
        handle?.write(data + Data([0x0A]))
    }

    func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 60) async throws -> [String: Any] {
        let id: Int = lock.withLock {
            nextID += 1
            return nextID
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            send(["id": id, "method": method, "params": params])
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let waiting = self.lock.withLock({ self.pending.removeValue(forKey: id) }) else { return }
                waiting.resume(throwing: ServerError.timeout)
            }
        }
    }

    /// Routes notifications for one thread to `handler` until removed.
    func listen(thread: String, _ handler: @escaping (String, [String: Any]) -> Void) {
        lock.withLock { listeners[thread] = handler }
    }

    static let threadUnloadDelay = 5

    func stopListening(thread: String) {
        _ = lock.withLock { listeners.removeValue(forKey: thread) }
    }

    /// Done with a thread for good: with no client subscribed, the app-server unloads it after
    /// `threadUnloadDelay`. It otherwise kept every thread in memory, about 2 MB each, so it grew with every
    /// dictation (20 requests: 6 → 26 threads).
    func release(thread: String) {
        stopListening(thread: thread)
        Task { _ = try? await call("thread/unsubscribe", ["threadId": thread], timeout: 10) }
    }

    private func receive(_ data: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        for line in lines {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = message["id"] as? Int, message["method"] == nil {
                guard let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { continue }
                if let error = message["error"] as? [String: Any] {
                    continuation.resume(throwing: ServerError.rpc(error["message"] as? String ?? "\(error)"))
                } else {
                    continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
                }
            } else if let id = message["id"], message["method"] != nil {
                // The server asked us something (approvals etc.); Articulate never grants anything.
                send(["id": id, "error": ["code": -32601, "message": "not supported by Articulate"]])
            } else if let method = message["method"] as? String {
                let params = message["params"] as? [String: Any] ?? [:]
                guard let thread = params["threadId"] as? String,
                      let handler = lock.withLock({ listeners[thread] }) else { continue }
                handler(method, params)
            }
        }
    }

    // MARK: - Threads and turns

    static let baseInstructions = """
        You are a text-processing function inside a dictation app. Each user message contains <instructions> and the data to process. \
        Follow the instructions exactly and reply with the final result only. Never run commands or use tools.
        """

    func startThread(model: String) async throws -> String {
        var params: [String: Any] = [
            "model": model,
            "cwd": FileManager.default.temporaryDirectory.appendingPathComponent("articulate-codex-server").path,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "baseInstructions": Self.baseInstructions,
            "ephemeral": true,
        ]
        if Prefs.codexFast { params["serviceTier"] = "priority" }
        let result = try await call("thread/start", params, timeout: 20)
        guard let thread = (result["thread"] as? [String: Any])?["id"] as? String else { throw ServerError.rpc("thread/start 沒有回傳 id") }
        return thread
    }

    struct TurnResult {
        var text: String
        var firstTokenAt: Date?
    }

    /// Runs one turn and returns the final agent message. `onFirstToken` fires when output starts streaming.
    /// Cancelling the calling task ends the wait at once and asks the server to stop the turn: the request
    /// that lost a hedge, or one given up on, used to keep its caller waiting until it finished (12–26 s
    /// after giving up when Codex was stuck).
    func runTurn(thread: String, text: String, schema: [String: Any]? = nil, timeout: TimeInterval = 30,
                 onFirstToken: (@Sendable () -> Void)? = nil, onDelta: (@Sendable () -> Void)? = nil) async throws -> String {
        let state = TurnState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                guard state.attach(continuation) else { return }
                startTurn(thread: thread, text: text, schema: schema, timeout: timeout, state: state,
                          onFirstToken: onFirstToken, onDelta: onDelta)
            }
        } onCancel: {
            if let turn = state.cancel() { interrupt(thread: thread, turn: turn) }
        }
    }

    /// Stops a turn nobody is waiting for any more. Best effort: the reply doesn't matter.
    private func interrupt(thread: String, turn: String) {
        Task { _ = try? await call("turn/interrupt", ["threadId": thread, "turnId": turn], timeout: 5) }
    }

    private func startTurn(thread: String, text: String, schema: [String: Any]?, timeout: TimeInterval, state: TurnState,
                       onFirstToken: (@Sendable () -> Void)?, onDelta: (@Sendable () -> Void)?) {
        listen(thread: thread) { method, params in
            switch method {
            case "item/agentMessage/delta":
                if state.markFirstToken() { onFirstToken?() }
                onDelta?()
            case "item/completed":
                if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage" {
                    state.text = item["text"] as? String ?? ""
                }
            case "turn/completed":
                let turn = params["turn"] as? [String: Any]
                if let error = turn?["error"] as? [String: Any] {
                    state.finish(.failure(ServerError.rpc(error["message"] as? String ?? "turn failed")))
                } else {
                    state.finish(.success(state.text))
                }
            case "error":
                if params["willRetry"] as? Bool != true {
                    state.finish(.failure(ServerError.rpc("\((params["error"] as? [String: Any])?["message"] ?? "error")")))
                }
            default:
                break
            }
        }
        var params: [String: Any] = [
            "threadId": thread,
            "input": [["type": "text", "text": text, "text_elements": [Any]()]],
            "effort": "low",
        ]
        if let schema { params["outputSchema"] = schema }
        Task {
            do {
                let result = try await call("turn/start", params, timeout: 20)
                if let turn = (result["turn"] as? [String: Any])?["id"] as? String, state.started(turn) {
                    interrupt(thread: thread, turn: turn) // cancelled before the server had answered
                }
            } catch {
                state.finish(.failure(error))
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            state.finish(.failure(ServerError.timeout))
        }
    }

    private final class TurnState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?
        private var sawToken = false
        private var cancelled = false
        private var turnID: String?
        var text = ""

        /// Holds the continuation, or resumes it at once (returning false) if the task was already cancelled.
        func attach(_ continuation: CheckedContinuation<String, Error>) -> Bool {
            let wasCancelled = lock.withLock {
                if !cancelled { self.continuation = continuation }
                return cancelled
            }
            if wasCancelled { continuation.resume(throwing: CancellationError()) }
            return !wasCancelled
        }

        /// Records the server's id for the turn; true if the turn was cancelled meanwhile.
        func started(_ turn: String) -> Bool {
            lock.withLock {
                turnID = turn
                return cancelled
            }
        }

        /// Ends the wait with a cancellation; returns the turn to interrupt if it has started.
        func cancel() -> String? {
            let (pending, turn): (CheckedContinuation<String, Error>?, String?) = lock.withLock {
                cancelled = true
                defer { continuation = nil }
                return (continuation, turnID)
            }
            pending?.resume(throwing: CancellationError())
            return turn
        }

        func markFirstToken() -> Bool {
            lock.withLock {
                defer { sawToken = true }
                return !sawToken
            }
        }

        func finish(_ result: Result<String, Error>) {
            let c: CheckedContinuation<String, Error>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            c?.resume(with: result)
        }
    }
}

/// Keeps a few threads whose first turn already ran, so a real request costs only the second turn. A thread keeps
/// the model it was started with, so there is a set of threads for each model in use.
actor CodexThreadPool {
    static let shared = CodexThreadPool()

    private var ready: [String: [String]] = [:]
    private var warming: [String: Int] = [:]
    /// Speculative passes during long dictations use threads too, so keep a few ready.
    private let target = 3

    /// A sample request that pays each thread's first-turn setup and doubles as an example.
    static let primingMessage = """
        <instructions>你是語音輸入法的文字整理步驟。把 <transcript> 整理成使用者想打的文字：刪除贅字、套用改口、補全形標點。只輸出結果。</instructions>
        <transcript>嗯那個我明天三點不對四點開會</transcript>
        """

    func readyCount(for model: String) -> Int { ready[model]?.count ?? 0 }

    /// Returns a primed thread for `model`, or a fresh one when none is ready yet.
    func take(model: String) async throws -> String {
        defer { Task { await self.refill(model: model) } }
        if let thread = ready[model]?.first {
            ready[model]?.removeFirst()
            return thread
        }
        try await CodexAppServer.shared.start()
        return try await CodexAppServer.shared.startThread(model: model)
    }

    /// Tops up the threads of every model in use, in the background.
    func refill() {
        for model in Prefs.codexModelsInUse { refill(model: model) }
    }

    private func refill(model: String) {
        let missing = target - readyCount(for: model) - warming[model, default: 0]
        guard missing > 0 else { return }
        warming[model, default: 0] += missing
        for _ in 0..<missing {
            Task {
                do {
                    try await CodexAppServer.shared.start()
                    let thread = try await CodexAppServer.shared.startThread(model: model)
                    _ = try await CodexAppServer.shared.runTurn(thread: thread, text: Self.primingMessage, timeout: 45)
                    CodexAppServer.shared.stopListening(thread: thread)
                    self.add(thread, model: model)
                } catch {
                    NSLog("Articulate: priming a Codex thread failed: \(error.localizedDescription)")
                    self.failedWarming(model: model)
                }
            }
        }
    }

    private func add(_ thread: String, model: String) {
        warming[model, default: 0] -= 1
        ready[model, default: []].append(thread)
    }

    private func failedWarming(model: String) {
        warming[model, default: 0] -= 1
    }

    func reset() {
        ready.removeAll()
    }
}

/// Codex through the long-lived app-server and primed thread pool.
struct CodexServerModel: LanguageModel {
    let name = "Codex"

    /// If no output has started after this long, the same request is also sent on a second primed thread.
    /// Measured over 60 real dictations: first token median 1.4 s, 90th percentile 2.65 s. At 1.6 s, 40% of requests
    /// were sent twice and the copy won only 4 of 24 times; 2.5 s still covers a stuck request.
    static let hedgeDelay: TimeInterval = 2.5
    /// Give up after this long so a stuck request never blocks dictation (the raw transcript is used instead).
    /// Longer dictations get more time because the whole text has to be generated. Measured on the transcript
    /// only: the instructions (2,000+ characters) used to count too, so even a short sentence could wait ~28 s.
    static func deadline(for message: String) -> TimeInterval { 6 + Double(expectedOutputLength(message)) / 100 }

    /// The output is about as long as the <transcript> block (or the whole message when there is none).
    static func expectedOutputLength(_ message: String) -> Int { transcriptLength(message) ?? message.count }

    /// Length of the <transcript> block. The instructions mention the tag too, so this looks for the last one,
    /// which holds the actual transcript.
    static func transcriptLength(_ message: String) -> Int? {
        guard let close = message.range(of: "</transcript>", options: .backwards),
              let open = message.range(of: "<transcript>", options: .backwards, range: message.startIndex..<close.lowerBound)
        else { return nil }
        return message.distance(from: open.upperBound, to: close.lowerBound)
    }

    /// Dictation, translation and continuation passes are routed by transcript length; other tasks (Ask, learning
    /// terms) have no <transcript> and use the fast model.
    static func model(for message: String) -> String {
        Prefs.codexModel(transcriptLength: transcriptLength(message), continuation: message.contains("<previous>\n"))
    }

    func text(system: String, user: String) async throws -> String {
        try await complete("<instructions>\n\(system)\n</instructions>\n\(user)", schema: nil)
    }

    func json(system: String, user: String, schema: [String: Any]) async throws -> [String: Any] {
        let text = try await complete("<instructions>\n\(system)\n</instructions>\n\(user)", schema: schema)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { throw AIError.badJSON }
        return object
    }

    /// Sends the request on a primed thread; hedges on a second thread if the first is slow to start.
    private func complete(_ message: String, schema: [String: Any]?) async throws -> String {
        let server = CodexAppServer.shared
        let started = Flag()
        let model = Self.model(for: message)
        let timing = TurnTiming(model: model, ready: await CodexThreadPool.shared.readyCount(for: model), deadline: Self.deadline(for: message))
        return try await withThrowingTaskGroup(of: (text: String, by: String).self) { group in
            group.addTask {
                let thread = try await CodexThreadPool.shared.take(model: model)
                defer { server.release(thread: thread) }
                let text = try await server.runTurn(thread: thread, text: message, schema: schema,
                                                    onFirstToken: { started.set() }, onDelta: { timing.delta() })
                return (text, "first")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.hedgeDelay))
                if started.isSet { try await Task.sleep(for: .seconds(60)) }
                timing.hedged()
                let thread = try await CodexThreadPool.shared.take(model: model)
                defer { server.release(thread: thread) }
                NSLog("Articulate: Codex slow to start, hedging on a second thread")
                let text = try await server.runTurn(thread: thread, text: message, schema: schema, onDelta: { timing.delta() })
                return (text, "hedge")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timing.deadline))
                throw CodexAppServer.ServerError.timeout
            }
            var lastError: Error?
            while let result = await group.nextResult() {
                switch result {
                case .success(let (text, by)):
                    group.cancelAll()
                    DiagnosticLog.write(timing.summary("done by \(by), \(text.count) chars"))
                    return text
                case .failure(let error):
                    if case CodexAppServer.ServerError.timeout = error {
                        group.cancelAll()
                        DiagnosticLog.write(timing.summary("gave up (raw transcript used)"))
                        throw error
                    }
                    if !(error is CancellationError) { lastError = error }
                }
            }
            if Task.isCancelled {
                DiagnosticLog.write(timing.summary("cancelled"))
                throw CancellationError()
            }
            DiagnosticLog.write(timing.summary("failed: \(lastError?.localizedDescription ?? "?")"))
            throw lastError ?? CodexAppServer.ServerError.timeout
        }
    }

    /// Where a request's time went, for the diagnostic log (no text, only timings and lengths).
    final class TurnTiming: @unchecked Sendable {
        private let lock = NSLock()
        private let start = Date()
        private let model: String
        private let ready: Int
        let deadline: TimeInterval
        private var first: TimeInterval?
        private var last: TimeInterval?
        private var longestPause: TimeInterval = 0
        private var hedgedAt: TimeInterval?

        init(model: String, ready: Int, deadline: TimeInterval) {
            self.model = model
            self.ready = ready
            self.deadline = deadline
        }

        func delta() {
            let now = Date().timeIntervalSince(start)
            lock.withLock {
                if first == nil { first = now }
                if let last { longestPause = max(longestPause, now - last) }
                last = now
            }
        }

        func hedged() {
            lock.withLock { hedgedAt = Date().timeIntervalSince(start) }
        }

        func summary(_ outcome: String) -> String {
            lock.withLock {
                let f = { (t: TimeInterval?) in t.map { String(format: "%.2fs", $0) } ?? "-" }
                return "codex \(model): \(outcome) after \(f(Date().timeIntervalSince(start))); ready threads \(ready), first token \(f(first)), "
                    + "longest pause \(String(format: "%.2fs", longestPause)), hedge \(f(hedgedAt)), deadline \(String(format: "%.0fs", deadline))"
            }
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
