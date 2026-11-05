import Foundation
import Testing
@testable import ArticulateCore

/// Tests that need this Mac's AI engine, the network, or the user's real data run only when asked for:
/// `ARTICULATE_LIVE_TESTS=1 swift test`. Each test prints what it checked.
let liveTests = ProcessInfo.processInfo.environment["ARTICULATE_LIVE_TESTS"] == "1"

@Suite(.serialized) struct SelfTests {
    @Test("快捷鍵狀態機") func hotkeys() {
        #expect(HotkeySelfTest.run())
    }

    @Test("從修改學字典（會暫時寫入真的字典）", .enabled(if: liveTests))
    @MainActor func learner() async {
        #expect(await LearnerSelfTest.run())
    }

    @Test("更新：找最新版、下載、驗證簽章、替換（要網路）", .enabled(if: liveTests))
    @MainActor func updater() async {
        #expect(await UpdaterSelfTest.run())
    }

    @Test("首次設定：Codex、uv、雜湊、下載（要網路）", .enabled(if: liveTests))
    @MainActor func setup() async {
        #expect(await SetupSelfTest.run())
    }

    @Test("潤稿、翻譯、隨便問、學單字（用目前的 AI 引擎）", .enabled(if: liveTests))
    func ai() async {
        #expect(await AISelfTest.run())
    }

    @Test("放棄等待的 Codex 請求會立刻結束（用 Codex）", .enabled(if: liveTests))
    func codexCancel() async {
        #expect(await CodexSelfTest.run())
    }

    @Test("Codex 用完會放掉對話（用 Codex）", .enabled(if: liveTests))
    func codexMemory() async {
        let requests = Int(ProcessInfo.processInfo.environment["ARTICULATE_MEMORY_REQUESTS"] ?? "") ?? 20
        #expect(await CodexSelfTest.memory(requests: requests))
    }
}
