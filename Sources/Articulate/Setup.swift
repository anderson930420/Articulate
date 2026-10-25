import AppKit
@preconcurrency import AVFoundation
import CryptoKit
import Foundation

// First-run setup: what it checks and the actions behind its buttons (SetupView draws it).
// Required: microphone and Accessibility. AI polishing uses the user's own Codex when it is already
// installed (nothing is downloaded); the extra recognizer (TEA-ASR) is offered, and only downloaded after
// the user agrees.

/// Runs a program to the end and collects what it printed.
enum Shell {
    struct Output {
        let status: Int32
        let text: String
    }

    static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:],
                    started: (@Sendable (Process) -> Void)? = nil) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let buffer = Collected()
            // Read as it comes, so a chatty installer can't fill the pipe and stall.
            pipe.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: Output(status: finished.terminationStatus, text: buffer.text))
            }
            do {
                try process.run()
                started?(process)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.withLock { data.append(more) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}

// MARK: - Codex

/// Finds the user's own Codex CLI and whether it is signed in. Articulate never installs or updates it.
enum CodexCLI {
    struct Found: Equatable {
        let url: URL
        let version: String
    }

    /// The known install locations first, then the user's login shell (custom npm prefixes, version managers).
    /// A path found through the shell is remembered so the app finds it again without asking the shell.
    static func find() async -> URL? {
        if let known = CodexModel.executable { return known }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = try? await Shell.run(URL(fileURLWithPath: shell), ["-lc", "command -v codex"]),
              output.status == 0 else { return nil }
        let path = output.text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        UserDefaults.standard.set(path, forKey: "codexPath")
        return URL(fileURLWithPath: path)
    }

    static func version(_ codex: URL) async -> String {
        let output = try? await Shell.run(codex, ["--version"])
        return output?.text.split(separator: "\n").first.map(String.init)?.replacingOccurrences(of: "codex-cli ", with: "") ?? ""
    }

    /// `codex login status` exits 0 when signed in.
    static func isSignedIn(_ codex: URL) async -> Bool {
        (try? await Shell.run(codex, ["login", "status"]))?.status == 0
    }
}

// MARK: - Setup model

@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, microphone, accessibility, ai, recognition, done

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: "歡迎"
            case .microphone: "麥克風"
            case .accessibility: "輔助使用"
            case .ai: "AI 潤稿"
            case .recognition: "加強辨識"
            case .done: "完成"
            }
        }

        var symbol: String {
            switch self {
            case .welcome: "hand.wave"
            case .microphone: "mic"
            case .accessibility: "hand.point.up.left"
            case .ai: "sparkles"
            case .recognition: "waveform.badge.plus"
            case .done: "checkmark.seal"
            }
        }
    }

    enum CodexState: Equatable {
        case checking
        case missing
        case signedOut(CodexCLI.Found)
        case signingIn(CodexCLI.Found)
        case ready(CodexCLI.Found)
    }

    @Published var step: Step = .welcome
    @Published var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var accessibility = AXIsProcessTrusted()
    @Published var codex: CodexState = .checking
    let installer: TEAInstaller

    private var timer: Timer?
    private var login: Process?
    private var installerWatch: NSObjectProtocol?

    init(installer: TEAInstaller) {
        self.installer = installer
    }

    var permissionsGranted: Bool { microphone == .authorized && accessibility }

    /// Whether a step still needs the user: required steps not done, or the AI step without any engine.
    func needsAttention(_ step: Step) -> Bool {
        switch step {
        case .microphone: microphone != .authorized
        case .accessibility: !accessibility
        case .ai: if case .ready = codex { false } else { AIEngine.current() == nil }
        default: false
        }
    }

    func isComplete(_ step: Step) -> Bool {
        switch step {
        case .welcome: true
        case .microphone: microphone == .authorized
        case .accessibility: accessibility
        case .ai: if case .ready = codex { true } else { false }
        case .recognition: installer.state == .installed
        case .done: permissionsGranted
        }
    }

    /// Starts watching permissions (they change in System Settings, outside the app) and checks Codex.
    func start() {
        refreshPermissions()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        Task { await checkCodex() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphone { microphone = mic }
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility { accessibility = trusted }
    }

    func requestMicrophone() {
        if microphone == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refreshPermissions() }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    func openAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func checkCodex() async {
        if case .signingIn = codex {} else { codex = .checking }
        guard let url = await CodexCLI.find() else {
            codex = .missing
            return
        }
        let found = CodexCLI.Found(url: url, version: await CodexCLI.version(url))
        if await CodexCLI.isSignedIn(url) {
            codex = .ready(found)
            login?.terminate()
            login = nil
            AIEngine.prewarm()
        } else if case .signingIn = codex {
            // Still waiting for the browser.
        } else {
            codex = .signedOut(found)
        }
    }

    /// `codex login` opens the browser for the ChatGPT sign-in; Articulate only waits for it to finish.
    func signInCodex() {
        guard case .signedOut(let found) = codex else { return }
        codex = .signingIn(found)
        Task {
            _ = try? await Shell.run(found.url, ["login"]) { process in
                Task { @MainActor in self.login = process }
            }
        }
        Task {
            for _ in 0..<150 {
                try? await Task.sleep(for: .seconds(2))
                guard case .signingIn = codex else { return }
                await checkCodex()
            }
            if case .signingIn(let found) = codex { codex = .signedOut(found) }
        }
    }

    func cancelSignIn() {
        login?.terminate()
        login = nil
        if case .signingIn(let found) = codex { codex = .signedOut(found) }
    }
}

// MARK: - TEA-ASR installer

/// Installs the extra recognizer the way setup-tea.sh does, from inside the app, with progress:
/// uv (the user's, or a pinned copy) → Python 3.12 and the pinned mlx-qwen3-asr package → the TEA-ASR-1.1
/// weights from Hugging Face at a pinned revision, SHA-256 checked → an 8-bit copy → the 4.1 GB original
/// removed. Nothing starts until the user asks for it.
@MainActor
final class TEAInstaller: ObservableObject {
    enum Phase: Int, CaseIterable, Identifiable {
        case space, tools, python, download, verify, convert, cleanup

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .space: "檢查磁碟空間"
            case .tools: "準備安裝工具"
            case .python: "安裝 Python 和辨識套件"
            case .download: "下載模型"
            case .verify: "驗證下載的檔案"
            case .convert: "轉成較省記憶體的版本"
            case .cleanup: "清除暫存檔"
            }
        }
    }

    enum State: Equatable {
        case notInstalled
        case installing(Phase)
        case installed
        case failed(Phase, String)
    }

    @Published var state: State
    /// Model download progress.
    @Published var received: Int64 = 0
    @Published var expected: Int64 = 0
    @Published var bytesPerSecond: Double = 0

    static let revision = "bda08df76d4fd6b487b4a1dd7f0bddf8541696f8"
    static let weightsSHA256 = "1e9db0943be34be1e6d13b9a895dfccfe941de045bba1b502d8449431ee79ea2"
    static let files = ["added_tokens.json", "chat_template.jinja", "config.json", "generation_config.json", "preprocessor_config.json",
                        "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
    static let package = "mlx-qwen3-asr==0.4.4"
    static let packagesBefore = "2026-09-30"
    static let uvVersion = "0.11.30"
    /// The download, the 8-bit copy and the Python environment, with room to spare.
    static let neededSpace: Int64 = 8_000_000_000
    static let downloadSize: Int64 = 4_100_000_000

    static var source: URL { AppPaths.support.appendingPathComponent("Models/tea-asr-1.1", isDirectory: true) }
    static var tools: URL { AppPaths.support.appendingPathComponent("bin", isDirectory: true) }

    private var work: Task<Void, Never>?
    private var process: Process?
    private var downloader: Downloader?
    private var speedSample: (time: Date, bytes: Int64)?

    init() {
        state = CompanionServer.isInstalled ? .installed : .notInstalled
    }

    var isInstalling: Bool { if case .installing = state { true } else { false } }

    func install() {
        guard !isInstalling else { return }
        work = Task { await run() }
    }

    func cancel() {
        work?.cancel()
        process?.terminate()
        downloader?.cancel()
        state = .notInstalled
    }

    private func run() async {
        var phase = Phase.space
        do {
            phase = .space; state = .installing(phase)
            try checkSpace()

            phase = .tools; state = .installing(phase)
            let uv = try await findOrFetchUV()

            phase = .python; state = .installing(phase)
            try await preparePython(uv: uv)

            phase = .download; state = .installing(phase)
            try await downloadModel()

            phase = .verify; state = .installing(phase)
            try await verify()

            phase = .convert; state = .installing(phase)
            try await convert()

            phase = .cleanup; state = .installing(phase)
            try? FileManager.default.removeItem(at: Self.source)

            state = .installed
            // The point of installing it: use it.
            UserDefaults.standard.set(Recognizer.fusion.rawValue, forKey: "recognizer")
            DiagnosticLog.write("TEA-ASR installed from the setup window")
        } catch is CancellationError {
            state = .notInstalled
        } catch {
            if Task.isCancelled { state = .notInstalled; return }
            DiagnosticLog.write("TEA-ASR install failed at \(phase): \(error.localizedDescription)")
            state = .failed(phase, error.localizedDescription)
        }
    }

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func checkSpace() throws {
        try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        let values = try AppPaths.support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        if free < Self.neededSpace {
            throw InstallError(message: "磁碟空間不足：需要約 \(Self.neededSpace / 1_000_000_000) GB，目前剩 \(String(format: "%.1f", Double(free) / 1e9)) GB")
        }
    }

    /// The user's own uv if there is one; otherwise a pinned release from GitHub, checked against its published SHA-256.
    private func findOrFetchUV() async throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv",
                          Self.tools.appendingPathComponent("uv").path]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }
        let name = "uv-aarch64-apple-darwin.tar.gz"
        let base = "https://github.com/astral-sh/uv/releases/download/\(Self.uvVersion)/"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("articulate-uv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let (checksum, _) = try await URLSession.shared.data(from: URL(string: base + name + ".sha256")!)
        let expectedHash = String(decoding: checksum, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        let archive = temp.appendingPathComponent(name)
        try await fetch(URL(string: base + name)!, to: archive, reportProgress: false)
        guard try await Self.sha256(of: archive) == expectedHash.lowercased() else {
            throw InstallError(message: "安裝工具 uv 的檔案驗證失敗，請再試一次")
        }
        let untar = try await Shell.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", temp.path])
        guard untar.status == 0 else { throw InstallError(message: "無法解開安裝工具 uv") }
        try FileManager.default.createDirectory(at: Self.tools, withIntermediateDirectories: true)
        let target = Self.tools.appendingPathComponent("uv")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp.appendingPathComponent("uv-aarch64-apple-darwin/uv"), to: target)
        return target
    }

    /// Python 3.12 (uv fetches its own if the Mac has none) with the speech package, pinned as setup-tea.sh pins it.
    private func preparePython(uv: URL) async throws {
        let asr = CompanionServer.directory
        try FileManager.default.createDirectory(at: asr, withIntermediateDirectories: true)
        for script in ["asr_server", "prepare_asr_model"] {
            guard let bundled = Bundle.main.url(forResource: script, withExtension: "py", subdirectory: "ASR") else {
                throw InstallError(message: "App 裡少了 \(script).py，請重新下載 Articulate")
            }
            let target = asr.appendingPathComponent("\(script).py")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: bundled, to: target)
        }
        if !FileManager.default.isExecutableFile(atPath: CompanionServer.python.path) {
            try await step(uv, ["venv", "--python", "3.12", asr.appendingPathComponent("venv").path], "建立 Python 環境失敗")
        }
        try await step(uv, ["pip", "install", "--exclude-newer", Self.packagesBefore, Self.package], "安裝辨識套件失敗",
                       environment: ["VIRTUAL_ENV": asr.appendingPathComponent("venv").path])
    }

    private func downloadModel() async throws {
        try FileManager.default.createDirectory(at: Self.source, withIntermediateDirectories: true)
        let base = "https://huggingface.co/JacobLinCool/TEA-ASR-1.1/resolve/\(Self.revision)/"
        for file in Self.files {
            try Task.checkCancellation()
            let target = Self.source.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            try await fetch(URL(string: base + file)!, to: target, reportProgress: file == "model.safetensors")
        }
    }

    private func verify() async throws {
        let weights = Self.source.appendingPathComponent("model.safetensors")
        guard try await Self.sha256(of: weights) == Self.weightsSHA256 else {
            try? FileManager.default.removeItem(at: weights)
            throw InstallError(message: "下載的模型檔驗證失敗，已刪除；請再試一次")
        }
    }

    private func convert() async throws {
        let script = CompanionServer.directory.appendingPathComponent("prepare_asr_model.py")
        try await step(CompanionServer.python, ["-I", script.path, Self.source.path, CompanionServer.model.path, "8"], "轉換模型失敗")
    }

    /// Runs one installer command; the last lines of its output explain a failure.
    private func step(_ executable: URL, _ arguments: [String], _ failure: String, environment: [String: String] = [:]) async throws {
        try Task.checkCancellation()
        let output = try await Shell.run(executable, arguments, environment: environment) { process in
            Task { @MainActor in self.process = process }
        }
        process = nil
        try Task.checkCancellation()
        guard output.status == 0 else {
            let tail = output.text.split(separator: "\n").suffix(3).joined(separator: " ")
            throw InstallError(message: "\(failure)：\(tail)")
        }
    }

    private func fetch(_ url: URL, to target: URL, reportProgress: Bool) async throws {
        let downloader = Downloader { [weak self] received, expected in
            guard reportProgress else { return }
            Task { @MainActor in self?.progress(received: received, expected: expected) }
        }
        self.downloader = downloader
        defer { self.downloader = nil }
        try await downloader.download(url, to: target)
    }

    private func progress(received: Int64, expected: Int64) {
        self.received = received
        self.expected = expected > 0 ? expected : Self.downloadSize
        let now = Date()
        if let sample = speedSample {
            let elapsed = now.timeIntervalSince(sample.time)
            guard elapsed >= 1 else { return }
            let current = Double(received - sample.bytes) / elapsed
            bytesPerSecond = bytesPerSecond == 0 ? current : bytesPerSecond * 0.7 + current * 0.3
        }
        speedSample = (now, received)
    }

    /// SHA-256 of a large file, read in pieces off the main thread.
    nonisolated static func sha256(of file: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

/// One file download with progress, picking up where it stopped when the connection drops (up to three times).
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var target: URL?
    private var task: URLSessionDownloadTask?
    private var moveError: Error?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func download(_ url: URL, to target: URL) async throws {
        self.target = target
        var resumeData: Data?
        for attempt in 0..<4 {
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        lock.withLock { self.continuation = continuation }
                        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
                        lock.withLock { self.task = task }
                        task.resume()
                    }
                } onCancel: {
                    self.cancel()
                }
                session.finishTasksAndInvalidate()
                return
            } catch {
                let partial = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                if Task.isCancelled || attempt == 3 || partial == nil {
                    session.invalidateAndCancel()
                    throw Task.isCancelled ? CancellationError() : error
                }
                resumeData = partial
            }
        }
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone once this returns, so it is moved here.
        guard let target else { return }
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            moveError = TEAInstaller.InstallError(message: "下載失敗（HTTP \(status)）")
            return
        }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let error = error ?? moveError {
            moveError = nil
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
