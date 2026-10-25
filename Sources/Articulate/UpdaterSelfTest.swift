import Foundation

/// `Articulate --selftest-updater`: the update path without touching the running app — find the latest release,
/// download and verify it against the installed copy's signature, then run the swap script in a temporary folder.
enum UpdaterSelfTest {
    @MainActor
    static func run() async -> Bool {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
            if !ok { failures += 1 }
        }
        check("版本比較", Updater.isNewer("0.10.0", than: "0.9.3") && !Updater.isNewer("0.2.0", than: "0.2.0") && Updater.isNewer("1.0", than: "0.9.9"),
              "0.10.0 > 0.9.3、0.2.0 = 0.2.0、1.0 > 0.9.9")

        let updater = Updater()
        await updater.check()
        guard let release = updater.available else {
            check("找到最新的 Release", false, "\(updater.state)")
            return false
        }
        check("找到最新的 Release", true, "\(release.tag)（這個測試程式沒有版本號，所以一定比較舊）")

        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Articulate.app")
        let newApp: URL
        do {
            let result = try await updater.download(release, replacing: installed)
            newApp = result.app
            check("下載（\(release.zipURL == nil ? "透過 GitHub CLI" : "公開下載，不需要 gh")）、解壓縮、驗證簽章，和已安裝的版本同一張憑證",
                  result.keepsPermissions, newApp.path)
        } catch {
            check("下載、解壓縮、驗證簽章，而且和已安裝的版本同一個簽章", false, error.localizedDescription)
            return false
        }

        // A copy signed with a different certificate is noticed (an ad-hoc signed copy stands in for one built elsewhere).
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("articulate-other-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: other) }
        if (try? FileManager.default.copyItem(at: newApp, to: other)) != nil,
           (try? await Shell.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", other.path]))?.status == 0 {
            let keeps = await Updater.keepsPermissions(other, replacing: installed)
            check("不同憑證簽的版本會被發現（不會靜靜換掉而讓權限被重設）", !keeps, keeps ? "誤判成相同" : "判定為不同憑證，會先問使用者")
        }

        // The swap, in a sandbox: an old copy, a process standing in for the running app, a fake Trash.
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("articulate-swap-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let current = sandbox.appendingPathComponent("Articulate.app"), trash = sandbox.appendingPathComponent("trash-old.app")
        do {
            try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: installed, to: current)
            try "old".write(to: current.appendingPathComponent("Contents/marker-old"), atomically: true, encoding: .utf8)
            let standIn = Process()
            standIn.executableURL = URL(fileURLWithPath: "/bin/sleep")
            standIn.arguments = ["1"]
            try standIn.run()
            let script = Updater.swapScript(current: current, new: newApp, trash: trash, waitFor: standIn.processIdentifier, open: false)
            let started = Date()
            let output = try await Shell.run(URL(fileURLWithPath: "/bin/bash"), ["-c", script])
            let waited = Date().timeIntervalSince(started)
            let version = (NSDictionary(contentsOf: current.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? "?"
            let oldKept = FileManager.default.fileExists(atPath: trash.appendingPathComponent("Contents/marker-old").path)
            check("替換：等原本的程式結束，舊版移走、新版放到原位", output.status == 0 && waited >= 0.8 && version == release.version && oldKept,
                  "等了 \(String(format: "%.1f", waited)) 秒；原位是 \(version)；舊版\(oldKept ? "已移到垃圾桶位置" : "不見了")")
        } catch {
            check("替換：等原本的程式結束，舊版移走、新版放到原位", false, error.localizedDescription)
        }
        print(failures == 0 ? "all updater checks passed" : "\(failures) updater check(s) failed")
        return failures == 0
    }
}
