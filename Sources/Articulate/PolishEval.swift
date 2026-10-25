import Foundation

/// How far the polish step drifts (`Articulate --polish-eval <cases.json> <runs> <report.json>`).
/// Each case is polished several times; every output is checked mechanically (list or not, item count,
/// spoken ordinals left in, words that must stay or go, characters kept or added) and by a larger model
/// (readable? content changed? topic first?). Reports latency, how often the result is right, how wrong it
/// gets, and run-to-run spread.
///
/// cases.json: [{"id": "...", "group": "...", "raw": "...", "kind": "list" | "plain" | "either", "items": 3,
///               "include": [["8", "八"]], "exclude": [["7", "七"]]}]
/// `include`: each entry needs one of its spellings in the output; `exclude`: none of an entry's spellings may remain.
enum PolishEval {
    struct Case {
        let id: String
        let group: String
        let raw: String
        /// "list": should become a numbered list of `items`; "plain": must not; "either": both acceptable.
        let kind: String
        let items: Int
        let include: [[String]]
        let exclude: [[String]]
        var hasWordChecks: Bool { !include.isEmpty || !exclude.isEmpty }
    }

    struct Output {
        let caseIndex: Int
        let text: String
        let seconds: Double
        var listItems = 0
        var ordinalsLeft = false
        /// Share of the spoken content characters still present / share of output characters that were spoken.
        var kept = 0.0
        var added = 0.0
        var readable = 0
        var contentErrors = 0
        var topicFirst: Bool?
        var worst = ""
        /// Word checks that failed, e.g. "缺「8」" or "留著「7」".
        var failedChecks: [String] = []
    }

    static func run(cases url: URL, runs: Int, report: URL) async {
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("cannot read \(url.path)")
            return
        }
        let cases = rows.map {
            Case(id: $0["id"] as? String ?? "", group: $0["group"] as? String ?? "", raw: $0["raw"] as? String ?? "",
                 kind: $0["kind"] as? String ?? "either", items: $0["items"] as? Int ?? 0,
                 include: $0["include"] as? [[String]] ?? [], exclude: $0["exclude"] as? [[String]] ?? [])
        }
        guard let engine = AIEngine.current() else {
            print("no AI engine")
            return
        }
        AIEngine.prewarm()
        try? await Task.sleep(for: .seconds(3))

        // Round-robin over the cases, so a slow patch of the network spreads over all of them.
        var outputs: [Output] = []
        var peak: UInt64 = 0
        for round in 1...runs {
            for (i, c) in cases.enumerated() {
                let start = Date()
                let text = (try? await AITasks.polish(c.raw, ctx: PromptContext(language: Prefs.language), with: engine)) ?? c.raw
                outputs.append(measure(Output(caseIndex: i, text: text, seconds: Date().timeIntervalSince(start)), c))
                peak = max(peak, guardMemory())
            }
            print("round \(round)/\(runs) polished — memory of this test and its helpers: peak \(ResourceGuard.megabytes(peak))")
        }
        await judge(&outputs, cases: cases)
        summarize(outputs, cases: cases, runs: runs)
        save(outputs, cases: cases, to: report)
    }

    /// The test and the processes it started must stay small; it stops itself rather than pile anything up.
    static let memoryLimit: UInt64 = 2_048 << 20

    private static func guardMemory() -> UInt64 {
        let used = ResourceGuard.treeFootprint()
        let extra = ResourceGuard.helpers().flatMap(\.lingering)
        if used > memoryLimit || !extra.isEmpty {
            print("stopping: \(ResourceGuard.megabytes(used)) in use, \(extra.count) unexpected process(es) under the helpers")
            for pid in extra { kill(pid, SIGTERM) }
            CodexAppServer.shared.stop()
            exit(3)
        }
        return used
    }

    // MARK: Mechanical checks

    private static let ordinals = ["第一個是", "第一點是", "第一個點", "第二個是", "第二點是", "第三個是", "首先是", "再來是", "另一個是"]
    private static let fillers = ["嗯", "呃", "欸", "那個", "就是說", "然後"]

    private static func measure(_ output: Output, _ c: Case) -> Output {
        var o = output
        let lines = o.text.components(separatedBy: "\n")
        o.listItems = lines.filter { $0.range(of: #"^\s*\d+[.、．]\s*"#, options: .regularExpression) != nil }.count
        o.ordinalsLeft = c.kind != "plain" && ordinals.contains { o.text.contains($0) }
        var spoken = c.raw
        for word in fillers + ordinals { spoken = spoken.replacingOccurrences(of: word, with: "") }
        let said = counts(TypelessBenchmark.normalize(spoken)), wrote = counts(TypelessBenchmark.normalize(o.text))
        let common = said.reduce(0) { $0 + min($1.value, wrote[$1.key] ?? 0) }
        o.kept = Double(common) / Double(max(said.values.reduce(0, +), 1))
        o.added = 1 - Double(common) / Double(max(wrote.values.reduce(0, +), 1))
        for spellings in c.include where !spellings.contains(where: o.text.contains) {
            o.failedChecks.append("缺「\(spellings[0])」")
        }
        for spellings in c.exclude {
            if let left = spellings.first(where: o.text.contains) { o.failedChecks.append("留著「\(left)」") }
        }
        return o
    }

    private static func counts(_ characters: [Character]) -> [Character: Int] {
        characters.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func formatRight(_ o: Output, _ c: Case) -> Bool? {
        switch c.kind {
        case "list": o.listItems == c.items && !o.ordinalsLeft
        case "plain": o.listItems == 0
        default: nil
        }
    }

    // MARK: Judge

    private static func judge(_ outputs: inout [Output], cases: [Case]) async {
        let judge = CodexModel(model: ProcessInfo.processInfo.environment["ARTICULATE_JUDGE_MODEL"] ?? "gpt-6.1-sol")
        let system = """
            你在評估語音輸入法「潤稿＋排版」的結果。<spoken> 是使用者口述的語音辨識原文，<output> 是整理後要貼出去的文字。
            readable：一般讀者能不能一眼看懂、讀起來通順（5 完全沒問題，4 小瑕疵，3 看得懂但彆扭，2 要猜，1 看不懂）。
            content_errors：和口述相比，意思被改變、實質內容被漏掉或憑空加入的地方，每一處算一個。
            不算錯誤：刪掉贅字和口頭序數（第一個是⋯）、套用使用者的改口、修正聽錯的字、調整語序、標點、分段或條列格式、意思相同的措辭。
            topic_first：如果 output 是條列，每一點是否以該點的主題開頭（是填 true）；不是條列填 null。
            worst：最嚴重的一個問題，沒有就填空字串。
            """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "readable": ["type": "integer"], "content_errors": ["type": "integer"],
                "topic_first": ["type": ["boolean", "null"]], "worst": ["type": "string"],
            ],
            "required": ["readable", "content_errors", "topic_first", "worst"],
            "additionalProperties": false,
        ]
        // Identical outputs are judged once.
        var verdicts: [String: [String: Any]] = [:]
        var peak: UInt64 = 0
        let unique = Array(Set(outputs.map { "\($0.caseIndex)\u{1}\($0.text)" }))
        await withTaskGroup(of: (String, [String: Any]?).self) { group in
            var next = 0
            func enqueue() {
                guard next < unique.count else { return }
                let key = unique[next]
                next += 1
                let parts = key.split(separator: "\u{1}", maxSplits: 1).map(String.init)
                let user = "<spoken>\n\(cases[Int(parts[0])!].raw)\n</spoken>\n<output>\n\(parts.count > 1 ? parts[1] : "")\n</output>"
                group.addTask { (key, try? await judge.json(system: system, user: user, schema: schema)) }
            }
            for _ in 0..<6 { enqueue() }
            while let (key, verdict) = await group.next() {
                verdicts[key] = verdict
                peak = max(peak, guardMemory())
                enqueue()
            }
        }
        for i in outputs.indices {
            guard let v = verdicts["\(outputs[i].caseIndex)\u{1}\(outputs[i].text)"] else { continue }
            outputs[i].readable = v["readable"] as? Int ?? 0
            outputs[i].contentErrors = v["content_errors"] as? Int ?? 0
            outputs[i].topicFirst = v["topic_first"] as? Bool
            outputs[i].worst = v["worst"] as? String ?? ""
        }
        print("judged \(verdicts.count) distinct outputs — memory of this test and its helpers: peak \(ResourceGuard.megabytes(peak))")
    }

    // MARK: Report

    private static func summarize(_ outputs: [Output], cases: [Case], runs: Int) {
        func pct(_ part: Int, _ whole: Int) -> String { String(format: "%d/%d (%.0f%%)", part, whole, 100 * Double(part) / Double(max(whole, 1))) }
        let seconds = outputs.map(\.seconds).sorted()
        print(String(format: "\nLatency per polish: median %.2fs, p90 %.2fs, max %.2fs (%d calls)",
                     TypelessBenchmark.median(seconds), seconds[Int(Double(seconds.count) * 0.9)], seconds.last ?? 0, seconds.count))

        let graded = outputs.compactMap { o in formatRight(o, cases[o.caseIndex]).map { (o, $0) } }
        let lists = graded.filter { cases[$0.0.caseIndex].kind == "list" }
        let plains = graded.filter { cases[$0.0.caseIndex].kind == "plain" }
        if !graded.isEmpty {
            print("Format right: spoken lists \(pct(lists.filter(\.1).count, lists.count)), ordinary sentences left unlisted \(pct(plains.filter(\.1).count, plains.count))")
        }
        let checked = outputs.filter { cases[$0.caseIndex].hasWordChecks }
        if !checked.isEmpty {
            print("Word checks (what must stay / must go):")
            var groups: [String] = []
            for c in cases where c.hasWordChecks && !groups.contains(c.group) { groups.append(c.group) }
            for group in groups {
                let rows = checked.filter { cases[$0.caseIndex].group == group }
                print("  \(group): \(pct(rows.filter { $0.failedChecks.isEmpty }.count, rows.count)) right")
            }
            var seenFailures = Set<String>()
            for o in checked where !o.failedChecks.isEmpty && seenFailures.insert(o.text).inserted {
                print("  ✗ [\(cases[o.caseIndex].id)] \(o.failedChecks.joined(separator: "、"))：\(o.text.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
        let judged = outputs.filter { $0.readable > 0 }
        let readable = (1...5).reversed().map { score in "\(score): \(judged.filter { $0.readable == score }.count)" }
        print("Readable (judge, 5 best): \(readable.joined(separator: "  "))  → readable (≥3) \(pct(judged.filter { $0.readable >= 3 }.count, judged.count))")
        print("Content changed (judge): none \(pct(judged.filter { $0.contentErrors == 0 }.count, judged.count)), "
              + "one \(judged.filter { $0.contentErrors == 1 }.count), two or more \(judged.filter { $0.contentErrors >= 2 }.count)")
        let listed = judged.compactMap(\.topicFirst)
        print("Topic first in lists (judge): \(pct(listed.filter { $0 }.count, listed.count))")
        print(String(format: "Characters: kept %.0f%% of what was said (median), added %.0f%% new (median)",
                     100 * TypelessBenchmark.median(outputs.map(\.kept)), 100 * TypelessBenchmark.median(outputs.map(\.added))))

        // Spread between runs of the same case: mean pairwise character edit distance.
        var spread: [(Case, Double, Int)] = []
        for (i, c) in cases.enumerated() {
            let texts = outputs.filter { $0.caseIndex == i }.map(\.text)
            var distances: [Double] = []
            for a in texts.indices { for b in texts.indices where b > a { distances.append(TypelessBenchmark.cer(texts[a], reference: texts[b])) } }
            spread.append((c, distances.isEmpty ? 0 : distances.reduce(0, +) / Double(distances.count), Set(texts).count))
        }
        let identical = spread.filter { $0.2 == 1 }.count
        print(String(format: "Run-to-run spread: %d/%d cases gave the same text every run; mean difference between runs %.1f%% (median case %.1f%%)",
                     identical, cases.count, 100 * spread.map(\.1).reduce(0, +) / Double(cases.count), 100 * TypelessBenchmark.median(spread.map(\.1))))
        for (c, d, n) in spread.sorted(by: { $0.1 > $1.1 }).prefix(3) {
            print(String(format: "  most variable: %@ — %.1f%% apart, %d different versions in %d runs", c.id, 100 * d, n, runs))
        }

        print("\nWorst outputs:")
        let worst = judged.sorted { ($0.readable, -$0.contentErrors) < ($1.readable, -$1.contentErrors) }
        var seen = Set<String>()
        for o in worst where seen.insert(o.text).inserted && seen.count <= 6 {
            print("  [\(cases[o.caseIndex].id)] readable \(o.readable), content errors \(o.contentErrors) — \(o.worst)")
            print("    " + o.text.replacingOccurrences(of: "\n", with: "\n    "))
        }
    }

    private static func save(_ outputs: [Output], cases: [Case], to url: URL) {
        let rows: [[String: Any]] = outputs.map { o in
            ["case": cases[o.caseIndex].id, "group": cases[o.caseIndex].group, "kind": cases[o.caseIndex].kind,
             "raw": cases[o.caseIndex].raw, "text": o.text, "failed_checks": o.failedChecks,
             "seconds": o.seconds, "list_items": o.listItems, "ordinals_left": o.ordinalsLeft, "kept": o.kept, "added": o.added,
             "readable": o.readable, "content_errors": o.contentErrors, "topic_first": o.topicFirst.map { $0 as Any } ?? NSNull(),
             "worst": o.worst]
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) { try? data.write(to: url) }
    }
}
