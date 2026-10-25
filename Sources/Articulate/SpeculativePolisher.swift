import Foundation

/// Something that polishes a dictation while it is still being spoken.
@MainActor
protocol SpeculativePolishing: AnyObject {
    func update(finalized: String)
    /// `second`: the other recognizer's whole transcript (fusion), when there is one.
    func finish(transcript: String, alternatives: [(chosen: String, others: [String])], second: String?) async throws -> String
    func cancel()
    /// How the last `finish` produced its result, for diagnostics.
    var lastPath: String { get }
    var speculativeRequests: Int { get }
}

/// Polishes a dictation piece by piece while the user is still talking. Each new stretch of finalized
/// text is polished as a continuation of what is already done, so every request stays small and the
/// polisher keeps up however long the dictation runs; after release only the last few words remain.
/// Finalized recognizer text is stable, so polished pieces stay valid.
///
/// With fusion, a second recognizer (TEA) transcribes the same audio piece by piece. Each piece of Apple's text
/// then goes out together with TEA's text for the same stretch (found by aligning the two), so fusion keeps its
/// accuracy and still polishes while the user talks; a piece waits until TEA has heard that far.
@MainActor
final class SpeculativePolisher: SpeculativePolishing {
    /// Polish a new piece once this many finalized characters are waiting.
    static let minGrowth = 40
    /// Start only once the dictation is this long: shorter ones are polished whole after release, which keeps
    /// their quality (no seams) at the same speed. In paired real-time runs, pieces only paid off from ~200
    /// characters (400+: 2.5 s instead of 4.4 s), and the whole-text pass made slightly fewer content errors.
    static let firstPiece = 150
    /// Without any sentence-ending punctuation, cut anyway after this many characters.
    static let maxUnpunctuated = 200

    /// A request that, when done, holds the polished text for the finalized prefix `covers`
    /// (and, with fusion, the second transcript up to `secondCovers`).
    private struct Job {
        let covers: String
        var secondCovers = 0
        let task: Task<String, Error>
    }

    private let engine: LanguageModel
    private let ctx: PromptContext
    /// Finalized text polished so far, and its polished form.
    private var covered = ""
    private var polished = ""
    private var latest = ""
    private var inFlight: Job?
    /// A piece asked to change earlier text: the next request polishes everything so far at once.
    private var needsRebase = false
    private var finished = false
    private(set) var speculativeRequests = 0
    private(set) var lastPath = ""
    /// No piece is being polished (benchmarks wait for this between sentences).
    var isIdle: Bool { inFlight == nil }
    /// Fusion: the second recognizer's text so far, and how much of it the polished pieces cover.
    private let usesSecond: Bool
    private var second: [Character] = []
    private var secondCovered = 0

    init(engine: LanguageModel, ctx: PromptContext, usesSecond: Bool = false) {
        self.engine = engine
        self.ctx = ctx
        self.usesSecond = usesSecond
    }

    /// Fusion: called whenever the second recognizer has finished another piece.
    func update(second text: String) {
        second = Array(text)
        launchIfReady()
    }

    /// Called whenever more of the recording becomes final.
    func update(finalized: String) {
        latest = finalized.trimmingCharacters(in: .whitespacesAndNewlines)
        launchIfReady()
    }

    private func launchIfReady() {
        let rebase = needsRebase
        guard !finished, inFlight == nil, latest.hasPrefix(covered) else { return }
        // Pieces end at a sentence end, so the AI never has to close a half sentence (and add a stray 。).
        let pending = latest.dropFirst(covered.count)
        let end = pending.lastIndex(where: { "。？！?!".contains($0) }).map { pending.index(after: $0) }
            ?? (pending.count >= Self.maxUnpunctuated ? pending.endIndex : nil)
        guard let end else { return }
        let text = covered + pending[..<end]
        guard rebase || text.count - covered.count >= (covered.isEmpty ? Self.firstPiece : Self.minGrowth) else { return }
        // Fusion: the matching stretch of the second transcript; wait while that recognizer is behind.
        var secondPiece: (from: Int, to: Int)?
        if usesSecond {
            let from = rebase ? 0 : secondCovered
            guard let to = TranscriptAlignment.map(Array(latest), from: rebase ? 0 : covered.count, cut: text.count,
                                                   onto: second, from: from) else { return }
            secondPiece = (from, to)
        }
        needsRebase = false
        speculativeRequests += 1
        var job = start(text, after: rebase ? nil : (covered, polished),
                        second: secondPiece.map { String(second[$0.from..<$0.to]) })
        job.secondCovers = secondPiece?.to ?? 0
        inFlight = job
        Task {
            let result = await job.task.result
            guard !finished else { return }
            inFlight = nil
            switch result {
            case .success(let text):
                covered = job.covers
                secondCovered = job.secondCovers
                polished = text
            case .failure(AIError.needsRevision):
                needsRebase = true
            case .failure:
                break  // Tried again, with more text, on the next update.
            }
            launchIfReady()
        }
    }

    /// Polishes `text`, continuing from `base` when given, otherwise from scratch. `second` is the other
    /// recognizer's version of the part being polished (fusion).
    private func start(_ text: String, after base: (covered: String, polished: String)?, second: String? = nil) -> Job {
        let engine = engine
        let ctx = ctx
        let task = Task<String, Error> {
            guard let base, !base.covered.isEmpty else {
                return try await AITasks.polish(text, ctx: Self.context(ctx, text, second), with: engine)
            }
            let piece = String(text.dropFirst(base.covered.count))
            let output = try await AITasks.polishContinuation(piece, previous: base.polished, ctx: Self.context(ctx, piece, second), with: engine)
            return Self.join(base.polished, output)
        }
        return Job(covers: text, task: task)
    }

    /// `ctx` with both recognizers' versions of `text` when they differ.
    private static func context(_ ctx: PromptContext, _ text: String, _ second: String?) -> PromptContext {
        var ctx = ctx
        if let second, !second.isEmpty, second != text { ctx.hypotheses = [text, second] }
        return ctx
    }

    /// The final text for `transcript`, reusing every piece that was polished while the user talked.
    func finish(transcript: String, alternatives: [(chosen: String, others: [String])] = [], second final: String? = nil) async throws -> String {
        finished = true
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fusion: TEA's final transcript extends what it reported while the user talked (earlier pieces stay as they were).
        let secondText = usesSecond ? final.map(Array.init) : nil
        var fullContext = Self.context(ctx, transcript, secondText.map { String($0) })
        fullContext.alternatives = alternatives
        func polishWhole(_ reason: String) async throws -> String {
            lastPath = "whole (\(reason))"
            return try await AITasks.polish(transcript, ctx: fullContext, with: engine)
        }

        // A piece still being polished is kept if the final transcript still starts with it.
        var pending = inFlight
        if let job = pending, !transcript.hasPrefix(job.covers) {
            job.task.cancel()
            pending = nil
        }
        if needsRebase { pending?.task.cancel(); return try await polishWhole("revision") }
        guard transcript.hasPrefix(covered) else { return try await polishWhole("recognizer revised text") }
        guard !covered.isEmpty || pending != nil else { return try await polishWhole("short") }

        let head = pending?.covers ?? covered
        let rest = String(transcript.dropFirst(head.count))
        if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let pending else { lastPath = "speculated"; return polished }
            do {
                let text = try await pending.task.value
                lastPath = "speculated (waited for last piece)"
                return text
            } catch {
                return try await polishWhole("error")
            }
        }

        // The rest starts now, alongside the piece still in flight; for context it sees that piece unpolished.
        let secondRest = secondText.map { chars in String(chars[min(pending?.secondCovers ?? secondCovered, chars.count)...]) }
        var restContext = Self.context(ctx, rest, secondRest)
        restContext.alternatives = alternatives.filter { rest.contains($0.chosen) }
        let previous = polished + String(head.dropFirst(covered.count))
        let model = engine
        let restTask = Task<String, Error> {
            try await AITasks.polishContinuation(rest, previous: previous, ctx: restContext, with: model)
        }
        do {
            let polishedHead = try await pending?.task.value ?? polished
            let polishedRest = try await restTask.value
            lastPath = "continued \(rest.count) chars" + (pending == nil ? "" : " + last piece")
            return Self.join(polishedHead, polishedRest)
        } catch AIError.needsRevision {
            restTask.cancel()
            return try await polishWhole("revision")
        } catch {
            restTask.cancel()
            return try await polishWhole("error")
        }
    }

    func cancel() {
        finished = true
        inFlight?.task.cancel()
    }

    /// Appends a polished continuation, keeping a space between words of space-separated languages.
    static func join(_ head: String, _ tail: String) -> String {
        guard let last = head.last, let first = tail.first, !last.isWhitespace, last.isASCII,
              first.isASCII, first.isLetter || first.isNumber else { return head + tail }
        return head + " " + tail
    }
}
