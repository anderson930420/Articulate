import AppKit

/// Coordinates one session: record → transcribe → (polish | translate | ask) → deliver.
@MainActor
final class DictationController {
    enum State: Equatable {
        case idle, recording, processing
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?

    let bar = FloatingBar()
    let answerCard = AnswerCard()
    let learner = EditLearner()
    /// End-to-end tests play this file instead of using the microphone.
    var simulatedAudio: URL?

    private let muter = BackgroundAudioMuter()
    private var transcriber: LiveTranscriber?
    /// Polishes long dictations while the user is still speaking.
    private var speculative: SpeculativePolisher?
    /// TEA-ASR's transcript of the same recording ("Apple＋TEA 融合"); the AI compares both.
    private var companion: CompanionRecognizer?
    private var processingTask: Task<Void, Never>?
    private var session = Session()
    private var recentCancels: [Date] = []
    private(set) var lastDelivery: Delivery?

    struct Session {
        var id = UUID()
        var startedAt = Date()
        var mode: DictationMode = .dictation
        var translationIndex = 0
        var screen: ScreenContext?
        var audioFile: String?
    }

    struct Delivery {
        var entryID: UUID
        var raw: String
        /// What is in the document now: the AI version, or `raw` after switching back.
        var text: String
        var inserted: Bool
        /// The AI version, for switching back and forth.
        var polished: String?
    }

    /// Switching versions posts ⌘Z and ⌘V; a second switch before they land would scramble the text.
    private var switchingUntil = Date.distantPast

    var phase: SessionPhase {
        switch state {
        case .idle: .idle
        case .recording: .recording
        case .processing: .processing
        }
    }

    init() {
        bar.model.onStart = { [weak self] in self?.start(handsFree: true) }
        bar.model.onCancel = { [weak self] in self?.cancel() }
        bar.model.onFinish = { [weak self] in self?.finish() }
        bar.model.onToggleAIEdits = { [weak self] in self?.toggleAIEdits() }
        bar.model.onCopy = { [weak self] in self?.copyLast() }
        learner.onLearned = { [weak self] terms in
            guard let self, self.state == .idle else { return }
            self.bar.model.onRemoveLearned = { [weak self] in
                DictionaryStore.shared.remove(terms)
                self?.bar.flash(.message("已從字典移除"), seconds: 1.5)
            }
            self.bar.flash(.learned(terms), seconds: 5, untilOutsideInput: true)
        }
    }

    func handle(_ action: HotkeyAction) {
        switch action {
        case .start: start()
        case .finish: finish()
        case .cancel: cancel()
        case .handsFree: bar.model.handsFree = true
        case .setMode(let mode): setMode(mode)
        case .cycleTranslationTarget: cycleTranslationTarget()
        case .pasteLast: pasteLast()
        }
    }

    // MARK: - Recording

    func start(handsFree: Bool = false) {
        DiagnosticLog.write("start requested (state=\(state), handsFree=\(handsFree))")
        if state == .processing {
            bar.flash("Articulate 仍在處理上次的轉錄，按 Esc 可以取消", seconds: 3)
            return
        }
        guard state == .idle else { return }
        answerCard.hide()
        learner.checkPending()

        var session = Session()
        if Prefs.historyRetention != .never {
            session.audioFile = "\(session.id.uuidString).caf"
        }
        let transcriber = LiveTranscriber(
            locale: Locale(identifier: Prefs.language.rawValue),
            contextualStrings: DictionaryStore.shared.terms,
            recordingURL: session.audioFile.map { AppPaths.recordings.appendingPathComponent($0) }
        )
        transcriber.onLevel = { [weak self] level in self?.bar.model.push(level: level) }
        transcriber.onPartial = { [weak self] text in
            guard let self, self.state == .recording else { return }
            self.bar.model.preview = text
        }
        do {
            if let simulatedAudio {
                try transcriber.startSimulatedMicrophone(file: simulatedAudio)
            } else {
                try transcriber.startMicrophone(deviceUID: Prefs.microphoneUID)
            }
        } catch {
            Sounds.error()
            bar.flash("無法開始錄音：\(error.localizedDescription)", seconds: 4)
            return
        }
        // Fusion: a second recognizer hears the same audio and transcribes it piece by piece while the user talks.
        var companion: CompanionRecognizer?
        if Prefs.recognizer == .fusion, CompanionServer.isInstalled {
            let second = CompanionRecognizer()
            second.setContext(terms: DictionaryStore.shared.terms)
            transcriber.audioSink = { second.append($0) }
            companion = second
            Task { _ = await CompanionServer.shared.ensureRunning() }
        }
        self.companion = companion
        self.transcriber = transcriber
        state = .recording
        bar.model.resetRecording()
        bar.model.handsFree = handsFree
        bar.show(.listening)
        Sounds.start()
        AIEngine.prewarm()

        // Read the screen after the microphone is already running, so no speech is lost.
        session.screen = ScreenContextReader.capture()
        self.session = session
        // Words visible on screen (earlier messages, the document being edited) steer recognition, as in Typeless.
        let screenTerms = ScreenVocabulary.terms(from: session.screen?.visibleText ?? "", limit: 120)
        transcriber.updateContext(terms: screenTerms)
        companion?.setContext(terms: Array(DictionaryStore.shared.terms.prefix(30)) + screenTerms.prefix(30))
        // Polish while the user talks. With fusion each piece waits for TEA's version of it, so both transcripts
        // still reach the AI; after release only the last stretch is left.
        let polisher = AIEngine.current().map { SpeculativePolisher(engine: $0, ctx: promptContext(for: session), usesSecond: companion != nil) }
        speculative = polisher
        companion?.onProgress { [weak polisher] text in polisher?.update(second: text) }
        transcriber.onFinalized = { [weak self] finalized in
            guard let self, self.state == .recording, self.session.mode == .dictation else { return }
            self.speculative?.update(finalized: finalized)
        }
        if Prefs.muteBackgroundAudio {
            // Let the start sound play before muting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                if self?.state == .recording { self?.muter.begin() }
            }
        }
    }

    private func setMode(_ mode: DictationMode) {
        guard state == .recording else { return }
        session.mode = mode
        bar.model.mode = mode
        if mode == .translation {
            session.translationIndex = 0
            bar.model.translationTarget = Prefs.translationTargets.first ?? "en-US"
        }
    }

    private func cycleTranslationTarget() {
        guard state == .recording, session.mode == .translation else { return }
        let targets = Prefs.translationTargets
        session.translationIndex = (session.translationIndex + 1) % max(targets.count, 1)
        bar.model.translationTarget = targets[session.translationIndex]
    }

    func cancel() {
        DiagnosticLog.write("cancel (state=\(state))")
        if state == .processing {
            processingTask?.cancel()
            processingTask = nil
            state = .idle
            bar.flash("已取消")
            return
        }
        guard state == .recording, let transcriber else { return }
        self.transcriber = nil
        companion = nil
        speculative?.cancel()
        speculative = nil
        muter.end()
        state = .idle
        bar.hide()
        let session = session
        let duration = Date().timeIntervalSince(session.startedAt)
        Task {
            await transcriber.cancel()
            // Accidental taps aren't worth keeping; real recordings can be restored from history.
            guard duration >= 1.0, let audio = session.audioFile else {
                if let audio = session.audioFile { try? FileManager.default.removeItem(at: AppPaths.recordings.appendingPathComponent(audio)) }
                return
            }
            HistoryStore.shared.add(HistoryEntry(
                id: session.id, date: session.startedAt, raw: "", text: "", appName: session.screen?.appName,
                duration: duration, engine: nil, mode: session.mode, status: .cancelled,
                bundleID: session.screen?.bundleID, audioFile: audio
            ))
            recentCancels = recentCancels.filter { Date().timeIntervalSince($0) < 120 } + [Date()]
            if recentCancels.count >= 2 {
                recentCancels.removeAll()
                bar.flash(.message("取消的錄音可以在「歷史紀錄」裡恢復"), seconds: 4)
            }
        }
    }

    func finish() {
        guard state == .recording, let transcriber else { return }
        DiagnosticLog.write("finish (mode=\(session.mode.rawValue), \(String(format: "%.1f", Date().timeIntervalSince(session.startedAt)))s)")
        self.transcriber = nil
        muter.end()
        state = .processing
        bar.show(.thinking)
        Sounds.stop()
        let session = session
        let duration = Date().timeIntervalSince(session.startedAt)
        let speculative = session.mode == .dictation ? self.speculative : nil
        self.speculative = nil
        let companion = session.mode == .dictation ? self.companion : nil
        self.companion = nil

        processingTask = Task {
            await process(transcriber, session: session, duration: duration, speculative: speculative, companion: companion)
            if !Task.isCancelled { state = .idle }
        }
    }

    // MARK: - Processing

    private func process(_ transcriber: LiveTranscriber, session: Session, duration: TimeInterval, speculative: SpeculativePolisher?,
                         companion: CompanionRecognizer?) async {
        var entry = HistoryEntry(
            id: session.id, date: session.startedAt, raw: "", text: "", appName: session.screen?.appName,
            duration: duration, engine: nil, mode: session.mode, status: .completed,
            bundleID: session.screen?.bundleID, audioFile: session.audioFile
        )
        // TEA finishes its last piece while Apple finalizes; it never holds the result up for more than 3 s.
        // Still loading (the first dictation after it sat idle): wait at most 0.5 s, then go on with Apple's text,
        // instead of making a short dictation wait ~1.5 s for the model to load.
        async let secondTranscript = companion?.finish(timeout: CompanionServer.shared.isReady ? 3 : 0.5)
        var second: String?
        do {
            entry.raw = try await transcriber.finish()
            second = await secondTranscript
            if companion != nil { DiagnosticLog.write("companion: \(second.map { "\($0.count) chars" } ?? "unavailable, Apple only")") }
            // Apple heard nothing but TEA did (e.g. a very quiet start): use TEA's text.
            if entry.raw.isEmpty, let second, !second.isEmpty { entry.raw = second }
        } catch {
            entry.status = .error
            entry.errorMessage = error.localizedDescription
            HistoryStore.shared.add(entry)
            DiagnosticLog.write("recognition failed: \(error.localizedDescription)")
            Sounds.error()
            bar.flash("辨識失敗：\(error.localizedDescription)", seconds: 4)
            return
        }
        guard !Task.isCancelled else { return }
        DiagnosticLog.write("recognized \(entry.raw.count) chars")
        guard !entry.raw.isEmpty else {
            entry.status = .empty
            HistoryStore.shared.add(entry)
            bar.flash("沒有聽到內容")
            return
        }

        do {
            let result = try await run(mode: session.mode, raw: entry.raw, session: session, speculative: speculative,
                                       alternatives: transcriber.alternatives, secondTranscript: second)
            guard !Task.isCancelled else { return }
            entry.text = result.text
            entry.engine = result.engine
            entry.targetLanguage = result.target
            entry.askAction = result.askAction
            // Paste first: saving history and stats (and redrawing an open history page) must not delay the text.
            deliver(result, entry: entry, session: session)
            HistoryStore.shared.add(entry)
            StatsStore.shared.record(text: result.text, seconds: duration)
        } catch {
            guard !Task.isCancelled else { return }
            entry.status = .error
            entry.errorMessage = error.localizedDescription
            HistoryStore.shared.add(entry)
            Sounds.error()
            bar.flash("\(session.mode.label)失敗：\(error.localizedDescription)", seconds: 5)
        }
    }

    struct Result {
        enum Output { case insert, answer, openURL(URL) }
        var text: String
        var output: Output = .insert
        var engine: String?
        var target: String?
        var askAction: String?
        var polished = false
    }

    /// Turns a transcript into the final output for a mode. Also used to retry saved recordings.
    private func promptContext(for session: Session) -> PromptContext {
        var ctx = PromptContext(screen: session.screen, dictionary: Array(DictionaryStore.shared.terms.prefix(150)), language: Prefs.language)
        if Prefs.personalization {
            ctx.styleExamples = HistoryStore.shared.styleExamples(bundleID: session.screen?.bundleID)
        }
        return ctx
    }

    func run(mode: DictationMode, raw: String, session: Session, speculative: SpeculativePolisher? = nil,
             alternatives: [(chosen: String, others: [String])] = [], secondTranscript: String? = nil) async throws -> Result {
        let engine = AIEngine.current()
        var ctx = promptContext(for: session)
        ctx.alternatives = alternatives
        if let secondTranscript, !secondTranscript.isEmpty, secondTranscript != raw {
            ctx.hypotheses = [raw, secondTranscript]
        }

        switch mode {
        case .dictation:
            // Very short utterances ("好", "OK") rarely need cleanup and shouldn't wait on a model.
            guard raw.count >= 4, let engine else { return Result(text: raw) }
            do {
                let text = if let speculative {
                    try await speculative.finish(transcript: raw, alternatives: alternatives, second: secondTranscript)
                } else {
                    try await AITasks.polish(raw, ctx: ctx, with: engine)
                }
                if let speculative {
                    DiagnosticLog.write("polish: \(speculative.lastPath), \(speculative.speculativeRequests) requests while speaking")
                }
                return Result(text: text, engine: engine.name, polished: text != raw)
            } catch {
                NSLog("Articulate: polishing with \(engine.name) failed: \(error.localizedDescription)")
                return Result(text: raw)
            }

        case .translation:
            guard let engine else { throw AIError.noEngine }
            let targets = Prefs.translationTargets
            let target = targets[min(session.translationIndex, targets.count - 1)]
            let text = try await AITasks.translate(raw, to: target, ctx: ctx, with: engine)
            return Result(text: text, engine: engine.name, target: target)

        case .ask:
            guard let engine else { throw AIError.noEngine }
            var selection = session.screen?.selectedText
            if selection == nil, session.screen?.focusedElement == nil {
                selection = await ScreenContextReader.selectedTextByCopying()
            }
            let answer = try await AITasks.ask(raw, selection: selection, ctx: ctx, with: engine)
            var result = Result(text: answer.text, engine: engine.name, askAction: answer.action.rawValue)
            switch answer.action {
            case .replaceSelection, .insert:
                result.output = session.screen?.focusIsEditable == false ? .answer : .insert
            case .openURL:
                result.output = answer.url.map { .openURL($0) } ?? .answer
            case .answer:
                result.output = .answer
            }
            return result
        }
    }

    private func deliver(_ result: Result, entry: HistoryEntry, session: Session) {
        switch result.output {
        case .answer:
            bar.hide()
            answerCard.show(question: entry.raw, answer: result.text)
            lastDelivery = Delivery(entryID: entry.id, raw: entry.raw, text: result.text, inserted: false)
        case .openURL(let url):
            NSWorkspace.shared.open(url)
            bar.flash(.message(result.text.isEmpty ? "已開啟 \(url.host() ?? "")" : result.text), seconds: 3)
            lastDelivery = Delivery(entryID: entry.id, raw: entry.raw, text: result.text, inserted: false)
        case .insert:
            // Like Typeless, the text goes wherever the cursor is now, even if the user switched apps while speaking.
            let readStart = Date()
            let screen = ScreenContextReader.capture(includeWindowText: false)
            DiagnosticLog.write("deliver \(result.text.count) chars → app=\(screen.appName ?? "?") role=\(screen.focusRole ?? "?") editable=\(screen.focusIsEditable.map(String.init) ?? "unknown") axTrusted=\(AXIsProcessTrusted()) (field read \(String(format: "%.2fs", Date().timeIntervalSince(readStart))))")
            guard AXIsProcessTrusted() else {
                // Without Accessibility permission macOS silently drops the ⌘V we post.
                TextInserter.copyToPasteboard(result.text)
                lastDelivery = Delivery(entryID: entry.id, raw: entry.raw, text: result.text, inserted: false)
                bar.flash("沒有「輔助使用」權限，無法自動貼上。已複製，按 ⌘V 貼上", seconds: 6)
                return
            }
            // Always paste: editability detection is unreliable in Electron apps and terminals.
            TextInserter.insert(result.text)
            lastDelivery = Delivery(entryID: entry.id, raw: entry.raw, text: result.text, inserted: true,
                                    polished: result.polished ? result.text : nil)
            if screen.focusIsEditable == false {
                // Probably nowhere to type: also offer copying.
                bar.flash(.copyable, seconds: 6)
                return
            }
            if session.mode == .dictation {
                learner.track(entryID: entry.id, inserted: result.text, screen: screen)
            }
            if result.polished {
                bar.flash(.inserted(original: false), seconds: Prefs.aiEditsBarSeconds, untilOutsideInput: true)
            } else {
                bar.hide()
            }
        }
    }

    // MARK: - After delivery

    /// Swaps the inserted text between the AI version and what was actually said. The bar stays up while
    /// the user compares, until the set time (設定 › AI) passes without a switch or they click or type somewhere else.
    func toggleAIEdits() {
        guard let last = lastDelivery, last.inserted, let polished = last.polished, polished != last.raw,
              Date() >= switchingUntil else { return }
        let original = last.text != last.raw
        let text = original ? last.raw : polished
        switchingUntil = Date().addingTimeInterval(0.4)
        TextInserter.replaceLastInsertion(with: text)
        HistoryStore.shared.update(last.entryID) { $0.revertedAI = original }
        lastDelivery?.text = text
        bar.flash(.inserted(original: original), seconds: Prefs.aiEditsBarSeconds, untilOutsideInput: true)
    }

    func copyLast() {
        guard let text = lastDelivery?.text ?? HistoryStore.shared.lastCompleted?.finalText else { return }
        TextInserter.copyToPasteboard(text)
        bar.flash(.copied, seconds: 1.5)
    }

    func pasteLast() {
        guard state == .idle else { return }
        guard let last = HistoryStore.shared.lastCompleted else {
            bar.flash("還沒有任何輸入紀錄")
            return
        }
        TextInserter.insert(last.finalText)
    }

    /// Re-transcribes a saved recording (cancelled, failed or completed) and copies the result.
    func retry(_ entryID: UUID) async -> String? {
        guard let entry = HistoryStore.shared.entries.first(where: { $0.id == entryID }), let audio = entry.audioURL,
              FileManager.default.fileExists(atPath: audio.path) else { return nil }
        let transcriber = LiveTranscriber(locale: Locale(identifier: Prefs.language.rawValue), contextualStrings: DictionaryStore.shared.terms)
        bar.show(.thinking)
        defer { bar.hide() }
        do {
            let raw = try await transcriber.transcribeFile(audio)
            guard !raw.isEmpty else {
                HistoryStore.shared.update(entryID) { $0.status = .empty }
                return nil
            }
            var session = Session()
            session.mode = entry.effectiveMode
            session.translationIndex = Prefs.translationTargets.firstIndex(of: entry.targetLanguage ?? "") ?? 0
            let result = try await run(mode: entry.effectiveMode, raw: raw, session: session)
            HistoryStore.shared.update(entryID) {
                $0.raw = raw
                $0.text = result.text
                $0.engine = result.engine
                $0.status = .completed
                $0.errorMessage = nil
            }
            TextInserter.copyToPasteboard(result.text)
            return result.text
        } catch {
            HistoryStore.shared.update(entryID) {
                $0.status = .error
                $0.errorMessage = error.localizedDescription
            }
            return nil
        }
    }
}
