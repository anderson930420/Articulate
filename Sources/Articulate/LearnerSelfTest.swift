import ApplicationServices
import Foundation

/// `Articulate --selftest-learner`: replays what the user does to a field after Articulate inserts text (fix a word,
/// press Enter so the field empties) and checks what the edit learner picks up. No real field is touched;
/// a learned test term is taken out of the dictionary again.
@MainActor
enum LearnerSelfTest {
    static func run() async -> Bool {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
            if !ok { failures += 1 }
        }

        /// Feeds the field's successive contents to the learner, one per poll, and returns the version it kept.
        func replay(_ inserted: String, _ fieldStates: [String], offset: Int? = nil) async -> (edited: String?, learned: [String]) {
            let learner = EditLearner()
            var states = fieldStates[...]
            learner.readValue = { _ in states.popFirst() }
            var learned: [String] = []
            learner.onLearned = { learned = $0 }
            var screen = ScreenContext(focusIsEditable: true)
            screen.focusedElement = AXUIElementCreateSystemWide()
            screen.insertionOffset = offset
            learner.track(entryID: UUID(), inserted: inserted, screen: screen)
            for _ in fieldStates.indices { learner.poll() }
            learner.checkPending() // as when the next dictation starts
            let edited = learner.lastEdited
            // Term extraction runs in the background (AI when available).
            for _ in 0..<60 where edited != nil && learned.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
            }
            return (edited, learned)
        }

        let term = "Zentrova"
        let fixed = await replay("我們下週改用森卓瓦這套工具", ["我們下週改用森卓瓦這套工具", "我們下週改用 Zentrova 這套工具", ""])
        check("改完馬上送出：抓到送出前的版本", fixed.edited == "我們下週改用 Zentrova 這套工具", "「\(fixed.edited ?? "沒有")」")
        check("改完馬上送出：學到新詞", fixed.learned.contains(term), "\(fixed.learned)")
        // `learned` only lists terms that were new to the dictionary, so removing them undoes just this test.
        DictionaryStore.shared.remove(fixed.learned)

        let untouched = await replay("明天下午三點開會", ["明天下午三點開會", ""])
        check("沒改就送出：不學", untouched.edited == nil && untouched.learned.isEmpty, "edited=\(untouched.edited ?? "nil")")

        let before = String(repeating: "前面已經寫好的一大段其他內容，跟這次口述無關。", count: 6)
        let long = await replay("請 cloud 幫我整理這份報告", [before + "請 cloud 幫我整理這份報告", before + "請 Claude 幫我整理這份報告"],
                                offset: before.utf16.count)
        check("長文裡只改一個詞：對到正確段落", long.edited == "請 Claude 幫我整理這份報告", "「\(long.edited ?? "沒有")」")
        DictionaryStore.shared.remove(long.learned)

        // The user fixes a word and starts the next dictation before the next once-a-second look.
        do {
            let hadTerm = DictionaryStore.shared.contains("Claude")
            defer { if !hadTerm { DictionaryStore.shared.remove(["Claude"]) } }
            let learner = EditLearner()
            var field = "明天找 cloud 開會討論報告"
            learner.readValue = { _ in field }
            var screen = ScreenContext(focusIsEditable: true)
            screen.focusedElement = AXUIElementCreateSystemWide()
            learner.track(entryID: UUID(), inserted: field, screen: screen)
            learner.poll()
            field = "明天找 Claude 開會討論報告"
            learner.checkPending()
            check("改完馬上開始下一次口述：還是抓到修改", learner.lastEdited == field, "「\(learner.lastEdited ?? "沒有")」")
            for _ in 0..<60 where !DictionaryStore.shared.contains("Claude") { try? await Task.sleep(for: .milliseconds(500)) }
        }

        let terms = ["Claude", "ISO-9001", "量子運算", "營運長"], phrases = ["要畫幾種圖", "我覺得很好用", "這個月的報表"]
        check("只收專有名詞，不收句子", terms.allSatisfy(EditLearner.looksLikeTerm) && !phrases.contains(where: EditLearner.looksLikeTerm),
              "收：\(terms.filter(EditLearner.looksLikeTerm))，擋：\(phrases.filter { !EditLearner.looksLikeTerm($0) })")

        print(failures == 0 ? "all learner checks passed" : "\(failures) learner check(s) failed")
        return failures == 0
    }
}
