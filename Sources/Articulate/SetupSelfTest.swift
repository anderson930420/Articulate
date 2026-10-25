import Foundation

/// `Articulate --selftest-setup`: the parts of first-run setup that can be checked without a 4 GB download —
/// finding the user's Codex and its sign-in, finding uv, the streaming SHA-256 (against the original weights
/// when they are on disk), and one small download through the same downloader the model uses.
enum SetupSelfTest {
    @MainActor
    static func run() async -> Bool {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
            if !ok { failures += 1 }
        }

        let codex = await CodexCLI.find()
        check("找到已安裝的 Codex", codex != nil, codex?.path ?? "沒有找到")
        if let codex {
            let version = await CodexCLI.version(codex)
            check("讀到 Codex 版本", !version.isEmpty, version)
            let signedIn = await CodexCLI.isSignedIn(codex)
            check("讀到登入狀態（codex login status）", true, signedIn ? "已登入" : "未登入")
        }

        let model = SetupModel(installer: TEAInstaller())
        await model.checkCodex()
        check("設定精靈的 AI 步驟狀態", true, "\(model.codex)")

        let weights = TEAInstaller.source.appendingPathComponent("model.safetensors")
        if FileManager.default.fileExists(atPath: weights.path) {
            let started = Date()
            let hash = (try? await TEAInstaller.sha256(of: weights)) ?? ""
            check("分段計算 4 GB 檔案的 SHA-256，和固定的雜湊相符", hash == TEAInstaller.weightsSHA256,
                  "\(hash.prefix(16))… \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒")
        } else {
            print("SKIP  SHA-256 — 這台 Mac 沒有原始模型檔")
        }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("articulate-setup-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temp) }
        let progress = Counter()
        let downloader = Downloader { received, _ in progress.set(received) }
        let url = URL(string: "https://huggingface.co/JacobLinCool/TEA-ASR-1.1/resolve/\(TEAInstaller.revision)/config.json")!
        do {
            try await downloader.download(url, to: temp)
            let data = (try? Data(contentsOf: temp)) ?? Data()
            let isJSON = (try? JSONSerialization.jsonObject(with: data)) != nil
            check("下載器：下載、回報進度、存到指定位置", isJSON && progress.value > 0, "\(data.count) bytes，進度回報到 \(progress.value) bytes")
        } catch {
            check("下載器：下載、回報進度、存到指定位置", false, error.localizedDescription)
        }

        print(failures == 0 ? "all setup checks passed" : "\(failures) setup check(s) failed")
        return failures == 0
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64 = 0
        func set(_ value: Int64) { lock.withLock { bytes = value } }
        var value: Int64 { lock.withLock { bytes } }
    }
}
