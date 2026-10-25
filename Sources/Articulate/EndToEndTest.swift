import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio

/// Drives the real app against TextEdit with synthetic key presses and recorded speech
/// standing in for the microphone (`open Articulate.app --args --e2e <audio-dir> <report>`).
@MainActor
enum EndToEndTest {
    private static var lines: [String] = []
    private static var failures = 0

    private static func log(_ text: String) {
        lines.append(text)
        NSLog("Articulate E2E: \(text)")
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        log("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private static func skip(_ name: String, _ why: String) {
        log("SKIP  \(name) — \(why)")
    }

    // MARK: - Synthetic input

    private static let triggerFlags: UInt64 = 0x100 | CGEventFlags.maskCommand.rawValue | 0x10

    private static func flagsEvent(_ keyCode: CGKeyCode, _ flags: UInt64) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        e.type = .flagsChanged
        e.flags = CGEventFlags(rawValue: flags)
        e.post(tap: .cghidEventTap)
    }

    private static func key(_ keyCode: CGKeyCode, flags: UInt64 = 0x100) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = CGEventFlags(rawValue: flags)
            e.post(tap: .cghidEventTap)
        }
    }

    private static func triggerDown() { flagsEvent(54, triggerFlags) }
    private static func triggerUp() { flagsEvent(54, 0x100) }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func tapTrigger() async {
        triggerDown()
        await sleep(0.08)
        triggerUp()
    }

    @discardableResult
    private static func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await sleep(0.1)
        }
        return condition()
    }

    private static func duration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 3 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - TextEdit

    private static var textEditPID: pid_t = 0

    private static func textArea() -> AXUIElement? {
        let app = AXUIElementCreateApplication(textEditPID)
        return ScreenContextReader.attribute(app, kAXFocusedUIElementAttribute)
    }

    private static func text() -> String {
        textArea().flatMap { ScreenContextReader.value(of: $0) } ?? ""
    }

    private static func setText(_ value: String, selectAll: Bool = false) {
        guard let area = textArea() else { return }
        AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, value as CFString)
        var range = CFRange(location: selectAll ? 0 : value.utf16.count, length: selectAll ? value.utf16.count : 0)
        if let axRange = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, axRange)
        }
    }

    private static func focusTextEdit() async {
        NSRunningApplication(processIdentifier: textEditPID)?.activate()
        await waitUntil(3) { NSWorkspace.shared.frontmostApplication?.processIdentifier == textEditPID }
        await sleep(0.3)
    }

    private static func openTextEdit(_ dir: URL) async -> Bool {
        let doc = dir.appendingPathComponent("articulate-e2e-\(Int(Date().timeIntervalSince1970)).txt")
        FileManager.default.createFile(atPath: doc.path, contents: Data())
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard let app = try? await NSWorkspace.shared.open([doc], withApplicationAt: appURL, configuration: config) else { return false }
        textEditPID = app.processIdentifier
        return await waitUntil(8) { textArea() != nil }
    }

    // MARK: - Dictation helpers

    private static func holdToDictate(_ app: AppDelegate, _ audio: URL) async {
        app.controller.simulatedAudio = audio
        triggerDown()
        await sleep(duration(audio) + 0.5)
        triggerUp()
        await waitUntil(150) { app.controller.state == .idle }
        await sleep(1.0)
    }

    private static func outputMuted() -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var mute = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &mute) else { return nil }
        var value: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &mute, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }

    // MARK: - Run

    static func run(app: AppDelegate, audioDir: URL, report: URL) async {
        let historyBefore = Set(HistoryStore.shared.entries.map(\.id))
        let dictionaryBefore = DictionaryStore.shared.words
        let pasteboardBefore = TextInserter.snapshot(NSPasteboard.general)
        let targetsBefore = Prefs.translationTargets
        let wordsBefore = StatsStore.shared.totalWords
        let statsBefore = StatsStore.shared.days
        func audio(_ name: String) -> URL { audioDir.appendingPathComponent(name) }
        let engine = AIEngine.current()

        log("Articulate end-to-end test — \(Date())")
        log("AI engine: \(engine?.name ?? "none")")

        check("輔助使用權限", AXIsProcessTrusted())
        check("全域熱鍵監聽 (CGEventTap)", app.hotkeys.isRunning)
        guard AXIsProcessTrusted(), app.hotkeys.isRunning else { return finish(report) }
        check("麥克風清單", !Microphones.inputDevices().isEmpty, Microphones.inputDevices().map(\.name).joined(separator: ", "))
        check("互動音效存在", NSSound(named: "Tink") != nil && NSSound(named: "Pop") != nil)

        guard await openTextEdit(audioDir) else {
            check("開啟 TextEdit", false)
            return finish(report)
        }
        await focusTextEdit()

        // 1. Screen context
        setText("前文測試：")
        await sleep(0.3)
        let ctx = ScreenContextReader.capture()
        check("讀取畫面上下文", ctx.focusIsEditable == true && (ctx.textBefore ?? "").hasSuffix("前文測試：") && ctx.bundleID == "com.apple.TextEdit",
              "app=\(ctx.appName ?? "-") editable=\(String(describing: ctx.focusIsEditable)) before=\(ctx.textBefore ?? "-") title=\(ctx.windowTitle ?? "-")")

        // 2. Hold to dictate (+ dictionary hint, mute, history, stats)
        DictionaryStore.shared.add("報價單", source: .manual)
        setText("")
        let mutedBefore = outputMuted()
        app.controller.simulatedAudio = audio("dictate.wav")
        triggerDown()
        await sleep(1.0)
        let mutedDuring = outputMuted()
        check("按住說話：開始錄音", app.controller.state == .recording)
        await sleep(duration(audio("dictate.wav")) - 0.5)
        triggerUp()
        await waitUntil(150) { app.controller.state == .idle }
        await sleep(1.0)
        let dictated = text()
        check("按住說話：放開後輸入文字", dictated.contains("報價單"), "「\(dictated)」")
        if mutedBefore == false {
            check("錄音時靜音其他聲音，結束後恢復", mutedDuring == true && outputMuted() == false, "during=\(String(describing: mutedDuring)) after=\(String(describing: outputMuted()))")
        } else {
            skip("錄音時靜音", "輸出裝置不支援靜音或原本就是靜音")
        }
        let first = HistoryStore.shared.entries.first
        check("歷史紀錄：模式／狀態／錄音檔", first?.effectiveMode == .dictation && first?.effectiveStatus == .completed
              && first?.audioURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        check("統計：口述字數增加", StatsStore.shared.totalWords > wordsBefore)
        if engine != nil {
            check("AI 潤稿：刪贅字、套用改口", !dictated.contains("那個") && !dictated.contains("三點") && (dictated.contains("四點") || dictated.contains("4")), "原始：「\(first?.raw ?? "")」")
            // 3. Undo AI edits
            if let raw = first?.raw, raw != dictated {
                app.controller.toggleAIEdits()
                await sleep(1.5)
                let reverted = text()
                check("撤銷 AI 修改", reverted.contains(raw.prefix(6)) && HistoryStore.shared.entries.first?.revertedAI == true, "「\(reverted)」")
                app.controller.toggleAIEdits()
                await sleep(1.5)
                let restored = text()
                check("恢復 AI 修改", restored.contains(dictated.prefix(6)) && !restored.contains(raw.prefix(6))
                      && HistoryStore.shared.entries.first?.revertedAI == false, "「\(restored)」")
            }
        } else {
            skip("AI 潤稿 / 撤銷", "沒有 AI 引擎")
        }

        // 4. Tap to start, tap again to finish (Typeless style)
        setText("")
        app.controller.simulatedAudio = audio("dictate2.wav")
        await tapTrigger()
        await sleep(1.0)
        check("按一下右⌘：開始錄音（免持）", app.controller.state == .recording && app.controller.bar.model.handsFree)
        await sleep(duration(audio("dictate2.wav")))
        check("放開後持續錄音", app.controller.state == .recording)
        await tapTrigger()
        await waitUntil(150) { app.controller.state == .idle }
        await sleep(1.5)
        check("再按一下：結束並自動貼上", text().contains("公園"), "「\(text())」")

        // 6. Keyboard shortcut with the trigger cancels
        setText("")
        app.controller.simulatedAudio = audio("dictate2.wav")
        triggerDown()
        await sleep(0.6)
        key(8, flags: triggerFlags) // ⌘C
        await sleep(0.3)
        let cancelledByShortcut = app.controller.state == .idle
        triggerUp()
        await sleep(0.8)
        check("按住時按其他鍵（⌘C）視為快捷鍵並取消", cancelledByShortcut && text().isEmpty)

        // 7. Esc cancels; the recording can be restored from history
        setText("")
        app.controller.simulatedAudio = audio("dictate2.wav")
        triggerDown()
        await sleep(2.5)
        key(53, flags: triggerFlags) // Esc
        await sleep(0.3)
        let escCancelled = app.controller.state == .idle
        triggerUp()
        await sleep(1.0)
        let cancelledEntry = HistoryStore.shared.entries.first
        check("Esc 取消錄音", escCancelled && text().isEmpty)
        check("取消的錄音保留在歷史紀錄", cancelledEntry?.effectiveStatus == .cancelled && cancelledEntry?.audioURL != nil)
        if let id = cancelledEntry?.id {
            let restored = await app.controller.retry(id)
            check("從歷史紀錄恢復已取消的錄音", restored?.contains("天氣") == true, "「\(restored ?? "nil")」")
        }

        // 8. Paste last result
        await focusTextEdit()
        setText("")
        key(TextInserter.pasteKeyCode, flags: 0x100 | CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue)
        await sleep(1.0)
        let lastText = HistoryStore.shared.lastCompleted?.finalText ?? "?"
        check("⌃⌘V 貼上上一次的結果", text() == lastText, "「\(text())」 vs 「\(lastText)」")

        // 9. Whispering (quiet input is boosted)
        setText("")
        await holdToDictate(app, audio("quiet.wav"))
        check("低語：音量很小也能辨識", text().contains("公園"), "「\(text())」")

        // 10. Learning from the user's edits
        setText("")
        await holdToDictate(app, audio("learn.wav"))
        let inserted = text()
        // Whatever the recognizer heard as the name after 「寄給」, the user "corrects" it by hand.
        let heardName = inserted.range(of: #"寄給\s*[^，,。\s]+"#, options: .regularExpression)
            .map { inserted[$0].replacingOccurrences(of: "寄給", with: "").trimmingCharacters(in: .whitespaces) }
        if let heardName, !heardName.isEmpty {
            setText(inserted.replacingOccurrences(of: heardName, with: "Alex Chen"))
            app.controller.learner.checkPending()
            let learned = await waitUntil(120) { DictionaryStore.shared.terms.contains { $0.contains("Alex Chen") } }
            check("從修改自動學習新單字加入字典", learned && HistoryStore.shared.entries.first?.editedText != nil,
                  "auto words: \(DictionaryStore.shared.words.filter { $0.source == .auto }.map(\.term))")
        } else {
            check("從修改自動學習（前置：辨識出收件人名字）", false, "「\(inserted)」")
        }

        if engine != nil {
            // 11. Ask Anything: rewrite the selection
            setText("我今天很忙，沒空去開會，明天再說。", selectAll: true)
            await sleep(0.3)
            app.controller.simulatedAudio = audio("ask_translate.wav")
            triggerDown()
            await sleep(0.3)
            key(49, flags: triggerFlags) // Space
            await sleep(0.2)
            triggerUp()
            check("右⌘＋空白鍵：進入隨便問", app.controller.bar.model.mode == .ask)
            await sleep(duration(audio("ask_translate.wav")))
            await tapTrigger()
            await waitUntil(180) { app.controller.state == .idle }
            await sleep(1.5)
            let rewritten = text()
            check("隨便問：改寫選取的文字（翻成英文）", !rewritten.isEmpty && !containsCJK(rewritten), "「\(rewritten)」")

            // 12. Ask Anything: answer a question
            setText("")
            app.controller.simulatedAudio = audio("ask_question.wav")
            triggerDown()
            await sleep(0.3)
            key(49, flags: triggerFlags)
            await sleep(0.2)
            triggerUp()
            await sleep(duration(audio("ask_question.wav")))
            await tapTrigger()
            await waitUntil(180) { app.controller.state == .idle }
            await sleep(1.0)
            let answer = app.controller.answerCard.model.answer
            check("隨便問：回答問題", (app.controller.answerCard.isVisible && answer.contains("玉山")) || text().contains("玉山"),
                  "card=\(app.controller.answerCard.isVisible) 「\(answer.prefix(80))」 text=「\(text())」")
            app.controller.answerCard.hide()

            // 13. Translation mode
            await focusTextEdit()
            setText("")
            Prefs.translationTargets = ["en-US", "ja-JP"]
            app.controller.simulatedAudio = audio("translate.wav")
            triggerDown()
            await sleep(0.3)
            flagsEvent(60, triggerFlags | CGEventFlags.maskShift.rawValue | 0x04) // right Shift down
            await sleep(0.1)
            flagsEvent(60, triggerFlags) // right Shift up
            await sleep(0.1)
            triggerUp()
            check("右⌘＋右 Shift：進入翻譯模式", app.controller.bar.model.mode == .translation && app.controller.bar.model.translationTarget == "en-US")
            await sleep(duration(audio("translate.wav")))
            await tapTrigger()
            await waitUntil(180) { app.controller.state == .idle }
            await sleep(1.5)
            let translated = text()
            check("翻譯模式：輸入英文譯文", !translated.isEmpty && !containsCJK(translated) && translated.contains("9"), "「\(translated)」")

            // 14. Cycling the translation target
            app.controller.simulatedAudio = audio("dictate2.wav")
            triggerDown()
            await sleep(0.3)
            flagsEvent(60, triggerFlags | CGEventFlags.maskShift.rawValue | 0x04)
            await sleep(0.1)
            flagsEvent(60, triggerFlags)
            await sleep(0.1)
            triggerUp()
            await sleep(0.2)
            flagsEvent(60, 0x100 | CGEventFlags.maskShift.rawValue | 0x04)
            await sleep(0.1)
            flagsEvent(60, 0x100)
            await sleep(0.3)
            check("翻譯中再按右 Shift 切換目標語言", app.controller.bar.model.translationTarget == "ja-JP")
            key(53)
            await sleep(1.0)
            Prefs.translationTargets = targetsBefore
        } else {
            skip("隨便問 / 翻譯", "沒有 AI 引擎")
        }

        // 15. Nowhere to type: offer copying instead
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            finder.activate()
            await waitUntil(3) { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" }
            await sleep(0.5)
            let finderContext = ScreenContextReader.capture()
            if finderContext.focusIsEditable == false {
                await holdToDictate(app, audio("dictate2.wav"))
                let offered = app.controller.bar.model.phase == .copyable
                app.controller.copyLast()
                let copied = NSPasteboard.general.string(forType: .string) ?? ""
                check("沒有輸入框時改為「複製最後的轉錄」", offered && copied.contains("公園"), "phase=\(app.controller.bar.model.phase) copied=「\(copied)」")
            } else {
                skip("沒有輸入框時改為複製", "Finder 焦點元素可編輯或無法判斷（\(String(describing: finderContext.focusIsEditable))）")
            }
        }

        // Clean up: remove test data so the user's history, dictionary and clipboard are untouched.
        for word in DictionaryStore.shared.words where !dictionaryBefore.contains(word) {
            DictionaryStore.shared.delete([word.id])
        }
        let testEntries = Set(HistoryStore.shared.entries.map(\.id)).subtracting(historyBefore)
        HistoryStore.shared.delete(testEntries)
        StatsStore.shared.replace(statsBefore)
        TextInserter.restore(pasteboardBefore, to: NSPasteboard.general)
        app.controller.simulatedAudio = nil
        log("Cleaned up \(testEntries.count) test history entries")
        finish(report)
    }

    private static func finish(_ report: URL) {
        log(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
