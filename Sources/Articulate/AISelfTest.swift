import Foundation

/// Checks each AI task against the configured engine (`Articulate --ai-test`).
enum AISelfTest {
    static func run() async -> Bool {
        guard let engine = AIEngine.current() else {
            print("SKIP  沒有可用的 AI 引擎：\(AIEngine.statusDescription)")
            return false
        }
        print("engine: \(engine.name)")
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
        }
        func timed<T>(_ body: () async throws -> T) async -> (T?, String, Double) {
            let start = Date()
            do { return (try await body(), "", Date().timeIntervalSince(start)) } catch {
                return (nil, error.localizedDescription, Date().timeIntervalSince(start))
            }
        }

        var ctx = PromptContext(language: .zhTW)
        ctx.dictionary = ["Articulate", "報價單"]

        // Filler words + change of mind
        let (p1, e1, t1) = await timed { try await AITasks.polish("嗯那個我明天下午三點不對四點要跟客戶開會然後請幫我準備一下報價單", ctx: ctx, with: engine) }
        check("潤稿：刪贅字、聽懂改口", p1.map { !$0.contains("那個") && !$0.contains("三點") && $0.contains("報價單") } ?? false, "\(String(format: "%.1fs", t1)) 「\(p1 ?? e1)」")

        // Spoken list → numbered list
        let (p2, e2, t2) = await timed { try await AITasks.polish("這次出差要帶的東西有三個第一個是筆電第二個是充電器第三個是護照", ctx: ctx, with: engine) }
        check("潤稿：口述清單變條列", p2.map { $0.contains("\n") && $0.contains("護照") } ?? false, "\(String(format: "%.1fs", t2)) 「\(p2 ?? e2)」")

        // Points whose topic comes last in speech are reordered topic-first, Typeless style
        let (pl, el, tl) = await timed { try await AITasks.polish("我現在有 3 點。第一個點是，我想要讓分析的時候，我們可以看得到彼此之間的差距，就是不同部門。然後第二個是，我希望同一個部門可以跟同一個月份的自己比。第三個是，我想要知道上述這兩個東西，分成成本跟效率，要怎麼樣做到？", ctx: ctx, with: engine) }
        check("潤稿：分點排版、主題放前面", pl.map { text in
            let lines = text.components(separatedBy: "\n")
            return lines.contains { $0.hasPrefix("1. 不同部門") } && lines.contains { $0.hasPrefix("3. ") } && !text.contains("第一個點")
        } ?? false, "\(String(format: "%.1fs", tl)) 「\(pl ?? el)」")

        // Email formatting from context
        var mail = ctx
        mail.screen = ScreenContext(appName: "Mail", bundleID: "com.apple.mail", windowTitle: "新郵件")
        let (p3, e3, t3) = await timed { try await AITasks.polish("嗨王經理我想跟你確認一下下週二的會議時間是不是下午兩點如果可以的話請回覆我謝謝小明", ctx: mail, with: engine) }
        check("潤稿：依情境整理成 email 格式", p3.map { $0.components(separatedBy: "\n").filter { !$0.isEmpty }.count >= 3 } ?? false, "\(String(format: "%.1fs", t3)) 「\(p3 ?? e3)」")

        // Phone number formatting
        let (p4, e4, t4) = await timed { try await AITasks.polish("我的電話是零九一二三四五六七八", ctx: ctx, with: engine) }
        check("潤稿：電話號碼格式", p4.map { $0.contains("0912") } ?? false, "\(String(format: "%.1fs", t4)) 「\(p4 ?? e4)」")

        // Dictionary spelling
        let (p5, e5, t5) = await timed { try await AITasks.polish("我現在用 murmer 這個 app 打字", ctx: ctx, with: engine) }
        check("潤稿：依字典修正拼字", p5.map { $0.contains("Articulate") } ?? false, "\(String(format: "%.1fs", t5)) 「\(p5 ?? e5)」")

        // Transcript that sounds like a request must not be answered
        let (p6, e6, t6) = await timed { try await AITasks.polish("幫我寫一首關於秋天的詩", ctx: ctx, with: engine) }
        check("潤稿：不會把口述內容當成指令執行", p6.map { $0.count < 30 && $0.contains("秋天") } ?? false, "\(String(format: "%.1fs", t6)) 「\(p6 ?? e6)」")

        // Translation
        let (tr, e7, t7) = await timed { try await AITasks.translate("嗯這個產品的價格是九美元我們提供免費退貨", to: "en-US", ctx: ctx, with: engine) }
        check("翻譯成英文", tr.map { $0.contains("9") && !$0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } } ?? false, "\(String(format: "%.1fs", t7)) 「\(tr ?? e7)」")
        let (tj, e8, t8) = await timed { try await AITasks.translate("謝謝你今天的幫忙", to: "ja-JP", ctx: ctx, with: engine) }
        check("翻譯成日文", tj.map { $0.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) } } ?? false, "\(String(format: "%.1fs", t8)) 「\(tj ?? e8)」")

        // Ask Anything
        var editable = ctx
        editable.screen = ScreenContext(appName: "TextEdit", bundleID: "com.apple.TextEdit", focusIsEditable: true)
        let (a1, e9, t9) = await timed { try await AITasks.ask("把它改得更有禮貌", selection: "明天的會議取消，不用來了。", ctx: editable, with: engine) }
        check("隨便問：改寫選取的文字", a1.map { $0.action == .replaceSelection && !$0.text.isEmpty } ?? false, "\(String(format: "%.1fs", t9)) \(a1.map { "\($0.action.rawValue) 「\($0.text)」" } ?? e9)")
        let (a2, e10, t10) = await timed { try await AITasks.ask("台灣最高的山是哪一座", selection: nil, ctx: editable, with: engine) }
        check("隨便問：回答問題", a2.map { $0.action == .answer && $0.text.contains("玉山") } ?? false, "\(String(format: "%.1fs", t10)) \(a2.map { "\($0.action.rawValue) 「\($0.text.prefix(60))」" } ?? e10)")
        var readOnly = ctx
        readOnly.screen = ScreenContext(appName: "Safari", bundleID: "com.apple.Safari", focusIsEditable: false)
        let (a3, e11, t11) = await timed { try await AITasks.ask("這段在講什麼", selection: "The mitochondria is the powerhouse of the cell.", ctx: readOnly, with: engine) }
        check("隨便問：解釋唯讀的選取文字", a3.map { $0.action == .answer && !$0.text.isEmpty } ?? false, "\(String(format: "%.1fs", t11)) \(a3.map { "\($0.action.rawValue) 「\($0.text.prefix(60))」" } ?? e11)")
        let (a4, e12, t12) = await timed { try await AITasks.ask("幫我上網搜尋台北明天的天氣", selection: nil, ctx: readOnly, with: engine) }
        check("隨便問：快速操作（開啟搜尋）", a4.map { $0.action == .openURL && $0.url != nil } ?? false, "\(String(format: "%.1fs", t12)) \(a4.map { "\($0.action.rawValue) \($0.url?.absoluteString ?? "")" } ?? e12)")
        let (a5, e13, t13) = await timed { try await AITasks.ask("幫我寫一句謝謝同事幫忙的訊息", selection: nil, ctx: editable, with: engine) }
        check("隨便問：撰寫並插入", a5.map { $0.action == .insert && !$0.text.isEmpty } ?? false, "\(String(format: "%.1fs", t13)) \(a5.map { "\($0.action.rawValue) 「\($0.text)」" } ?? e13)")

        // Learning corrected terms
        let (terms, e14, t14) = await timed { try await AITasks.learnedTerms(original: "請把報告寄給艾力克斯，副本給林小姐。", edited: "請把報告寄給 Alex Chen，副本給林小姐。", with: engine) }
        check("從修改中找出更正的專有名詞", terms.map { $0.contains { $0.contains("Alex") } } ?? false, "\(String(format: "%.1fs", t14)) \(terms.map { "\($0)" } ?? e14)")

        print(failures == 0 ? "all AI checks passed" : "\(failures) AI check(s) failed")
        return failures == 0
    }
}
