import AppKit
import SwiftUI

/// Checks GitHub Releases for a newer Articulate and installs it. A public release is fetched directly; when the
/// repository is private, through the GitHub CLI signed in on this Mac (Articulate never sees the GitHub login).
/// Before swapping, the new copy is checked against this copy's designated requirement — the rule macOS uses to
/// decide whether permissions carry over. A copy signed with another certificate (say, one built on this Mac with
/// its own local signing identity) is only installed after the user agrees to grant permissions again. A small
/// script then swaps the app once this copy has quit, moves the old one to the Trash and opens the new one.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        let tag: String
        let version: String
        let notes: String
        /// Direct download for a public release; nil means it comes through the GitHub CLI.
        let zipURL: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release)
        /// Downloaded and verified, but signed with a different certificate than this copy, so macOS will ask for
        /// the permissions again once. Waits for the user.
        case differentSigner(Release, URL)
        case installing(Release)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published private(set) var lastChecked: Date?
    private var timer: Timer?

    /// Where releases come from (Info.plist `ArticulateReleases`, so a fork can point at its own).
    static var repository: String {
        Bundle.main.object(forInfoDictionaryKey: "ArticulateReleases") as? String ?? "anderson930420/Articulate"
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var available: Release? { if case .available(let release) = state { release } else { nil } }

    /// A quiet check soon after launch and then once a day; it only ever offers the update.
    func startAutomaticChecks() {
        Task {
            try? await Task.sleep(for: .seconds(20))
            await check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch self.state {
                case .downloading, .installing, .differentSigner: return
                default: Task { await self.check() }
                }
            }
        }
    }

    func check() async {
        state = .checking
        defer { lastChecked = Date() }
        let release: Release
        if let found = await Self.publicLatest() {
            release = found
        } else if let gh = await Self.findGH() {
            let output = try? await Shell.run(gh, ["release", "view", "--repo", Self.repository, "--json", "tagName,body"])
            guard let output, output.status == 0,
                  let object = try? JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String: Any],
                  let tag = object["tagName"] as? String else {
                let text = output?.text ?? ""
                state = .failed(text.contains("auth login") || text.contains("not logged")
                    ? "GitHub CLI 還沒登入：在終端機執行 gh auth login。"
                    : text.contains("release not found") ? "還沒有發布任何版本。" : "無法讀取最新版本：\(text.split(separator: "\n").last ?? "")")
                return
            }
            release = Release(tag: tag, version: Self.version(of: tag), notes: object["body"] as? String ?? "", zipURL: nil)
        } else {
            state = .failed("Release 不是公開的，要用 GitHub CLI 登入才能更新：到 https://cli.github.com 下載安裝檔（不需要 Homebrew），裝好後在終端機執行 gh auth login。")
            return
        }
        state = Self.isNewer(release.version, than: Self.currentVersion) ? .available(release) : .upToDate
    }

    private static func version(of tag: String) -> String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

    /// The latest release through GitHub's public API; nil when the repository is private or has no release.
    private static func publicLatest() async -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Articulate/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else { return nil }
        let zip = (object["assets"] as? [[String: Any]] ?? []).first {
            let name = $0["name"] as? String ?? ""
            return name.hasPrefix("Articulate-") && name.hasSuffix(".zip")
        }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        guard let zip else { return nil }
        return Release(tag: tag, version: version(of: tag), notes: object["body"] as? String ?? "", zipURL: zip)
    }

    /// The GitHub CLI: Homebrew, the official installer (cli.github.com), MacPorts, or wherever the login shell has it.
    static func findGH() async -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let known = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(home)/.local/bin/gh", "/opt/local/bin/gh"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: known)
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let lookup = shell.hasSuffix("zsh") ? "whence -p gh" : "type -P gh"
        guard let output = try? await Shell.run(URL(fileURLWithPath: shell), ["-lc", lookup]), output.status == 0 else { return nil }
        let path = output.text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// Compares dotted version numbers (0.10.0 is newer than 0.9.3).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func install() async {
        guard let release = available else { return }
        state = .downloading(release)
        do {
            let (newApp, keepsPermissions) = try await download(release, replacing: Bundle.main.bundleURL)
            if keepsPermissions {
                state = .installing(release)
                try swap(in: newApp, version: release.version)
            } else {
                state = .differentSigner(release, newApp)
            }
        } catch {
            state = .failed((error as? Failure)?.message ?? error.localizedDescription)
        }
    }

    /// After the user agreed to grant the permissions again.
    func installAnyway() {
        guard case .differentSigner(let release, let newApp) = state else { return }
        state = .installing(release)
        do {
            try swap(in: newApp, version: release.version)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancelDifferentSigner() {
        if case .differentSigner(let release, _) = state { state = .available(release) }
    }

    /// Downloads, unpacks and verifies a release; also says whether it keeps `current`'s permissions.
    func download(_ release: Release, replacing current: URL) async throws -> (app: URL, keepsPermissions: Bool) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("articulate-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let zip = temp.appendingPathComponent("Articulate.zip")
        if let url = release.zipURL {
            try await Downloader { _, _ in }.download(url, to: zip)
        } else {
            guard let gh = await Self.findGH() else { throw Failure("需要 GitHub CLI 才能下載私人 repo 的 Release") }
            try await run(gh, ["release", "download", release.tag, "--repo", Self.repository, "--pattern", "Articulate-*.zip",
                               "--output", zip.path], "下載失敗")
        }
        let unpacked = temp.appendingPathComponent("unpacked", isDirectory: true)
        try await run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, unpacked.path], "解壓縮失敗")
        let newApp = unpacked.appendingPathComponent("Articulate.app")
        try await run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", newApp.path], "新版的簽章驗證失敗")
        return (newApp, await Self.keepsPermissions(newApp, replacing: current))
    }

    /// Whether `new` meets `current`'s designated requirement: the same identifier and the same certificate (not just
    /// a certificate with the same name). That is what macOS checks before letting granted permissions carry over.
    static func keepsPermissions(_ new: URL, replacing current: URL) async -> Bool {
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        let shown = try? await Shell.run(codesign, ["-d", "-r-", current.path])
        guard let line = shown?.text.split(separator: "\n").first(where: { $0.contains("designated =>") }),
              let requirement = line.components(separatedBy: "designated =>").last?.trimmingCharacters(in: .whitespaces),
              !requirement.isEmpty else { return false }
        return (try? await Shell.run(codesign, ["--verify", "-R", "=" + requirement, new.path]))?.status == 0
    }

    /// The name of the certificate a copy is signed with, for explaining a mismatch.
    static func signer(of app: URL) async -> String {
        let output = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["-dvv", app.path])
        let authority = (output?.text ?? "").split(separator: "\n").first { $0.hasPrefix("Authority=") }
        return authority.map { String($0.dropFirst("Authority=".count)) } ?? "臨時簽章"
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func run(_ executable: URL, _ arguments: [String], _ failure: String) async throws {
        let output = try await Shell.run(executable, arguments)
        guard output.status == 0 else {
            throw Failure("\(failure)：\(output.text.split(separator: "\n").last ?? "")")
        }
    }

    /// Waits for process `waitFor` to exit, moves `current` to `trash` and `new` into its place, and opens it.
    static func swapScript(current: URL, new: URL, trash: URL, waitFor pid: Int32, open: Bool) -> String {
        func quoted(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            mv \(quoted(current)) \(quoted(trash)) && mv \(quoted(new)) \(quoted(current)) || exit 1
            xattr -dr com.apple.quarantine \(quoted(current)) 2>/dev/null
            \(open ? "open \(quoted(current)) || { sleep 2; open \(quoted(current)); }" : "true")
            """
    }

    /// Hands over to a script that waits for this copy to quit, puts the new one in its place, and opens it.
    private func swap(in newApp: URL, version: String) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let trash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash/Articulate-\(Self.currentVersion)-\(stamp).app")
        let script = Self.swapScript(current: Bundle.main.bundleURL, new: newApp, trash: trash,
                                     waitFor: ProcessInfo.processInfo.processIdentifier, open: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try process.run()
        DiagnosticLog.write("update: installing \(version); restarting")
        NSApp.terminate(nil)
    }
}

/// The update window: what's new, and the button that installs it.
struct UpdateView: View {
    @ObservedObject var updater: Updater
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: LogoMark.icon(dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))
                    .resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("目前版本 \(Updater.currentVersion)").font(Theme.caption()).foregroundStyle(Theme.secondaryInk)
                }
            }
            content
            Spacer(minLength: 0)
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(width: 460, height: 340)
        .background(Theme.canvas)
    }

    private var title: String {
        switch updater.state {
        case .idle, .checking: "正在檢查更新…"
        case .upToDate: "已經是最新版本"
        case .available(let r): "有新版本 \(r.version)"
        case .downloading(let r): "正在下載 \(r.version)…"
        case .installing: "正在安裝…"
        case .differentSigner: "新版的簽章不同"
        case .failed: "無法更新"
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case .idle, .checking, .downloading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(updater.state == .checking || updater.state == .idle ? "連到 GitHub 查看最新的 Release" : "下載完成後會驗證簽章")
                    .font(Theme.body()).foregroundStyle(Theme.secondaryInk)
            }
        case .upToDate:
            Label("Articulate \(Updater.currentVersion) 是目前最新的版本。", systemImage: "checkmark.circle.fill")
                .font(Theme.body()).foregroundStyle(Theme.ink)
                .symbolRenderingMode(.multicolor)
        case .available(let release):
            ScrollView {
                Text(Self.notes(release.notes))
                    .font(Theme.body()).foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
        case .differentSigner:
            Text("這一版是用發布者的憑證簽的，和你目前這版的憑證不同（例如你目前這版是在這台 Mac 上自己打包的）。更新後 macOS 會把它當成不同的簽章，麥克風和輔助使用要在設定精靈裡重新允許一次；之後的更新會保留權限。")
                .font(Theme.body()).foregroundStyle(Theme.ink)
                .lineSpacing(Theme.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        case .installing:
            Text("Articulate 會關閉，換上新版後自動重新打開；舊版會移到垃圾桶。")
                .font(Theme.body()).foregroundStyle(Theme.secondaryInk)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.body()).foregroundStyle(Theme.ink)
                .symbolRenderingMode(.multicolor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch updater.state {
        case .available:
            Button("稍後") { onClose() }.buttonStyle(SecondaryButtonStyle())
            Button("更新並重新開啟") { Task { await updater.install() } }.buttonStyle(PrimaryButtonStyle())
        case .failed:
            Button("關閉") { onClose() }.buttonStyle(SecondaryButtonStyle())
            Button("重試") { Task { await updater.check() } }.buttonStyle(PrimaryButtonStyle())
        case .upToDate:
            Button("好") { onClose() }.buttonStyle(PrimaryButtonStyle())
        case .differentSigner:
            Button("取消") { updater.cancelDifferentSigner(); onClose() }.buttonStyle(SecondaryButtonStyle())
            Button("仍要更新") { updater.installAnyway() }.buttonStyle(PrimaryButtonStyle())
        default:
            EmptyView()
        }
    }

    /// Release notes are Markdown: headings become bold lines and list items get bullets; links and emphasis stay.
    static func notes(_ markdown: String) -> AttributedString {
        let text = markdown.isEmpty ? "這一版沒有附上說明。" : markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            if let heading = line.firstRange(of: #/^#+ /#) { return "**\(line[heading.upperBound...])**" }
            if let item = line.firstRange(of: #/^\s*[-*] /#) { return "• " + line[item.upperBound...] }
            return String(line)
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
