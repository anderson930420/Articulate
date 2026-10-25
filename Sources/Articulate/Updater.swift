import AppKit
import SwiftUI

/// Checks GitHub Releases for a newer Articulate and installs it. The repository is private, so everything goes
/// through the GitHub CLI signed in on this Mac (Articulate never sees the GitHub login). The new copy must carry
/// the same signature as this one, so macOS keeps the user's permissions; a small script swaps the app once this
/// copy has quit, moves the old one to the Trash and opens the new one.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        let tag: String
        let version: String
        let notes: String
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release)
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

    static var gh: URL? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
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
                if case .downloading = self.state { return }
                if case .installing = self.state { return }
                Task { await self.check() }
            }
        }
    }

    func check() async {
        state = .checking
        guard let gh = Self.gh else {
            state = .failed("需要 GitHub CLI：在終端機執行 brew install gh，再執行 gh auth login。")
            return
        }
        let output = try? await Shell.run(gh, ["release", "view", "--repo", Self.repository, "--json", "tagName,body"])
        lastChecked = Date()
        guard let output, output.status == 0,
              let object = try? JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String: Any],
              let tag = object["tagName"] as? String else {
            let text = output?.text ?? ""
            state = .failed(text.contains("auth login") || text.contains("not logged")
                ? "GitHub CLI 還沒登入：在終端機執行 gh auth login。"
                : text.contains("release not found") ? "還沒有發布任何版本。" : "無法讀取最新版本：\(text.split(separator: "\n").last ?? "")")
            return
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let release = Release(tag: tag, version: version, notes: (object["body"] as? String) ?? "")
        state = Self.isNewer(version, than: Self.currentVersion) ? .available(release) : .upToDate
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
        guard let release = available, let gh = Self.gh else { return }
        state = .downloading(release)
        do {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("articulate-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try await run(gh, ["release", "download", release.tag, "--repo", Self.repository, "--pattern", "Articulate-*.zip", "--dir", temp.path], "下載失敗")
            guard let zip = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "zip" }) else { throw Failure("Release 裡沒有 Articulate 的 zip 檔") }
            let unpacked = temp.appendingPathComponent("unpacked", isDirectory: true)
            try await run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, unpacked.path], "解壓縮失敗")
            let newApp = unpacked.appendingPathComponent("Articulate.app")
            try await run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", newApp.path], "新版的簽章驗證失敗")
            // Same signer as this copy: macOS ties the permissions (Accessibility, Microphone) to it.
            let mine = await Self.signers(of: Bundle.main.bundleURL), theirs = await Self.signers(of: newApp)
            guard !theirs.isEmpty, theirs == mine else {
                throw Failure("新版的簽章（\(theirs.first ?? "無")）和目前這版（\(mine.first ?? "無")）不同，為了保留權限沒有安裝")
            }
            state = .installing(release)
            try swap(in: newApp, version: release.version)
        } catch {
            state = .failed((error as? Failure)?.message ?? error.localizedDescription)
        }
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

    /// The signing authorities `codesign` reports, outermost first.
    private static func signers(of app: URL) async -> [String] {
        let output = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["-dvv", app.path])
        return (output?.text ?? "").split(separator: "\n").filter { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) }
    }

    /// Hands over to a script that waits for this copy to quit, puts the new one in its place, and opens it.
    private func swap(in newApp: URL, version: String) throws {
        let current = Bundle.main.bundleURL
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let trash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash/Articulate-\(Self.currentVersion)-\(stamp).app")
        func quoted(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            mv \(quoted(current)) \(quoted(trash)) && mv \(quoted(newApp)) \(quoted(current))
            xattr -dr com.apple.quarantine \(quoted(current)) 2>/dev/null
            open \(quoted(current)) || { sleep 2; open \(quoted(current)); }
            """
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
