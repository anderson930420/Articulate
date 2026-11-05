import Foundation

/// Selects on the first token, then cancels the other turn through its ordinary interrupt path.
final class FirstTokenRace: @unchecked Sendable {
    private let lock = NSLock()
    private var winner: Int?
    private var tasks: [Int: Task<String, Error>] = [:]
    private var cancelled = false

    private func choose(_ copy: Int) {
        let loser: Task<String, Error>? = lock.withLock {
            guard !cancelled, winner == nil else { return nil }
            winner = copy
            return tasks[1 - copy]
        }
        loser?.cancel()
    }

    private func attach(_ task: Task<String, Error>, copy: Int) {
        let stop = lock.withLock {
            tasks[copy] = task
            return cancelled || (winner != nil && winner != copy)
        }
        if stop { task.cancel() }
    }

    private func cancel() {
        let pending = lock.withLock { cancelled = true; return Array(tasks.values) }
        pending.forEach { $0.cancel() }
    }

    func run(turn: @escaping @Sendable (Int, @escaping @Sendable () -> Void) async throws -> String) async throws -> (text: String, by: String) {
        defer { lock.withLock { tasks.removeAll() } }
        return try await withTaskCancellationHandler {
            let (events, continuation) = AsyncStream<(Int, Result<String, Error>)>.makeStream()
            for copy in 0..<2 {
                let task = Task<String, Error> {
                    do {
                        try Task.checkCancellation()
                        let text = try await turn(copy, { self.choose(copy) })
                        // Some transports complete without sending a delta.
                        self.choose(copy)
                        continuation.yield((copy, .success(text)))
                        return text
                    } catch {
                        continuation.yield((copy, .failure(error)))
                        throw error
                    }
                }
                attach(task, copy: copy)
            }
            defer { continuation.finish(); cancel() }
            var lastError: Error = AIError.emptyResult
            var completed = 0
            for await (copy, result) in events {
                completed += 1
                let selected = lock.withLock { winner }
                if selected == copy {
                    return (try result.get(), copy == 0 ? "first" : "twin")
                }
                if case .failure(let error) = result { lastError = error }
                if completed == 2 { throw lastError }
            }
            throw CancellationError()
        } onCancel: { self.cancel() }
    }
}
