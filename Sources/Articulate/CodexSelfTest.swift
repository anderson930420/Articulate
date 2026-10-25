import Foundation

/// `Articulate --selftest-codex-cancel`: a request whose caller stops waiting (a hedge that lost, or one given up on)
/// must end at once instead of keeping the dictation waiting until Codex finishes writing.
enum CodexSelfTest {
    static func run() async -> Bool {
        let model = CodexServerModel()
        // Warm up so the timing below is about cancelling, not starting the server.
        _ = try? await model.text(system: "原樣輸出。", user: "<transcript>你好</transcript>")

        // Long enough that Codex is still writing when the caller gives up.
        let long = String(repeating: "今天我們討論了專案的時程、預算和人力安排，", count: 40)
        let task = Task { try await model.text(system: "把 <transcript> 原樣抄寫三遍。", user: "<transcript>\(long)</transcript>") }
        try? await Task.sleep(for: .seconds(0.8))
        let cancelledAt = Date()
        task.cancel()
        let outcome: String
        do {
            _ = try await task.value
            outcome = "finished anyway"
        } catch is CancellationError {
            outcome = "cancelled"
        } catch {
            outcome = "error: \(error.localizedDescription)"
        }
        let waited = Date().timeIntervalSince(cancelledAt)
        let ok = waited < 0.5
        print("\(ok ? "PASS" : "FAIL")  cancelling a request ends it at once — \(outcome) \(String(format: "%.2f", waited)) s after cancelling")

        // The server must still answer the next request normally.
        let started = Date()
        let next = (try? await model.text(system: "原樣輸出。", user: "<transcript>收到</transcript>")) ?? ""
        let nextOK = !next.isEmpty
        print("\(nextOK ? "PASS" : "FAIL")  the next request still works — 「\(next)」 in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        return ok && nextOK
    }

    /// `Articulate --selftest-codex-memory`: threads must be let go of after use, or the app-server keeps every one
    /// in memory and grows by a few MB per dictation until the resource guard restarts it.
    static func memory(requests: Int = 20) async -> Bool {
        let model = CodexServerModel()
        await CodexThreadPool.shared.refill()
        for _ in 0..<150 {
            var ready = 0
            for name in Prefs.codexModelsInUse { ready += await CodexThreadPool.shared.readyCount(for: name) }
            if ready >= 3 * Prefs.codexModelsInUse.count { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        func loaded() async -> Int {
            let result = try? await CodexAppServer.shared.call("thread/loaded/list", [:], timeout: 10)
            return (result?["data"] as? [Any])?.count ?? -1
        }
        func footprint() -> UInt64 { ResourceGuard.helpers().first { $0.name == "codex" }?.footprint ?? 0 }
        let loadedBefore = await loaded(), memoryBefore = footprint()
        var failures = 0
        for i in 0..<requests {
            let text = (try? await model.text(system: "整理成通順的句子，只輸出結果。", user: "<transcript>第 \(i + 1) 句，嗯，我們明天下午開會</transcript>")) ?? ""
            if text.isEmpty { failures += 1 }
            if (i + 1) % 20 == 0 { print("  after \(i + 1) requests: \(ResourceGuard.megabytes(footprint()))") }
        }
        // Released threads are unloaded once nobody has been subscribed for `threadUnloadDelay`.
        try? await Task.sleep(for: .seconds(Double(CodexAppServer.threadUnloadDelay) + 3))
        let loadedAfter = await loaded(), memoryAfter = footprint()
        let perRequest = (Double(memoryAfter) - Double(memoryBefore)) / Double(requests) / 1_048_576
        print("loaded threads \(loadedBefore) → \(loadedAfter); Codex memory \(ResourceGuard.megabytes(memoryBefore)) → \(ResourceGuard.megabytes(memoryAfter)) "
              + "(\(String(format: "%+.2f", perRequest)) MB per request), \(failures) of \(requests) requests failed")
        let ok = loadedAfter <= loadedBefore + 2
        print("\(ok ? "PASS" : "FAIL")  threads are released after use")
        return ok
    }
}
