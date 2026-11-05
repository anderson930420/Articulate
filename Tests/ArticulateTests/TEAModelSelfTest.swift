import Foundation
@testable import ArticulateCore

/// Which TEA model folder the server loads — the 6-bit copy when it is
/// complete, otherwise the 8-bit copy older installs made, otherwise nothing (setup then makes the 6-bit one).
enum TEAModelSelfTest {
    static func run() -> Bool {
        var passed = true
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "PASS" : "FAIL")  \(name)  — \(detail)")
            passed = passed && ok
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("articulate-tea-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        func install(_ folder: String, weights: Bool = true) {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            if weights { _ = fm.createFile(atPath: url.appendingPathComponent("model.safetensors").path, contents: Data()) }
        }
        func picked() -> String { CompanionServer.installedModel(in: root)?.lastPathComponent ?? "none" }

        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        check("沒有模型時不選任何資料夾", picked() == "none", picked())
        install("tea-asr-1.1-8bit")
        check("只有 8 位元時用 8 位元", picked() == "tea-asr-1.1-8bit", picked())
        install("tea-asr-1.1-6bit.partial")
        check("轉檔到一半的 6 位元不算數", picked() == "tea-asr-1.1-8bit", picked())
        install("tea-asr-1.1-6bit", weights: false)
        check("6 位元資料夾沒有權重檔時仍用 8 位元", picked() == "tea-asr-1.1-8bit", picked())
        install("tea-asr-1.1-6bit")
        check("6 位元完整時優先用 6 位元", picked() == "tea-asr-1.1-6bit", picked())
        try? fm.removeItem(at: root.appendingPathComponent("tea-asr-1.1-8bit"))
        check("只有 6 位元時用 6 位元", picked() == "tea-asr-1.1-6bit", picked())
        // preferredModel resolves AppPaths.support, which creates the user's real support directory.
        // Check its folder choice directly so this test only touches its temporary fixtures.
        let preferred = CompanionServer.modelFolders[0]
        check("新安裝轉成 6 位元", preferred == "tea-asr-1.1-6bit", preferred)
        print(passed ? "ALL PASS" : "SOME FAILED")
        return passed
    }
}
