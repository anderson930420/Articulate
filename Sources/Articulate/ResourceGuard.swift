import Darwin
import Foundation

/// Hard memory limits for the helper processes Articulate starts (the Codex app-server and the companion speech model).
/// Only Articulate's own process tree is ever looked at or touched: the search starts at Articulate's pid and follows
/// parent → child links, so processes of other apps and agents are never in scope.
enum ResourceGuard {
    /// Threads are released after each request and unloaded after a few seconds, so the Codex app-server stays
    /// around 85 MB with both models warm (80 requests in a row: 63 → 82 MB; it used to keep about 2.3 MB per
    /// request). Past the soft limit it is restarted while Articulate is idle (and warmed up again at once); past the
    /// hard limit, always. Normal use should never reach either.
    static let codexSoftLimit: UInt64 = 200 << 20
    static let codexLimit: UInt64 = 512 << 20
    /// The speech model is about 2.5 GB including its weights on the GPU.
    static let speechModelLimit: UInt64 = 4_608 << 20
    static let checkInterval: TimeInterval = 30
    /// Codex briefly runs the user's login shell to read its environment (under a second). Tool servers stay up,
    /// so only processes that have been running at least this long count as leftovers.
    static let lingerAge: TimeInterval = 20

    struct Helper {
        let pid: pid_t
        let name: String
        /// What Activity Monitor shows as Memory: resident plus compressed plus GPU memory.
        let footprint: UInt64
        /// Processes the helper started itself (e.g. tool servers), at any depth.
        let descendants: [pid_t]
        /// Those of them that have been running for at least `lingerAge`.
        var lingering: [pid_t] { descendants.filter { age(of: $0) >= lingerAge } }
    }

    /// Articulate's direct child processes with their memory and their own descendants.
    static func helpers(of root: pid_t = getpid()) -> [Helper] {
        children(of: root).map { pid in
            Helper(pid: pid, name: name(of: pid), footprint: footprint(of: pid), descendants: descendants(of: pid))
        }
    }

    /// Memory of a process and everything below it.
    static func treeFootprint(of root: pid_t = getpid()) -> UInt64 {
        ([root] + descendants(of: root)).reduce(0) { $0 + footprint(of: $1) }
    }

    static func descendants(of pid: pid_t) -> [pid_t] {
        children(of: pid).flatMap { [$0] + descendants(of: $0) }
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        return count > 0 ? Array(buffer.prefix(Int(count))).filter { $0 > 0 } : []
    }

    static func age(of pid: pid_t) -> TimeInterval {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return 0 }
        return Date().timeIntervalSince1970 - TimeInterval(info.pbi_start_tvsec)
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        return String(cString: buffer)
    }

    private static func footprint(of pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : 0
    }

    static func megabytes(_ bytes: UInt64) -> String { "\(bytes >> 20) MB" }

    // MARK: In the app

    @MainActor private static var timer: Timer?
    @MainActor private static var isIdle: () -> Bool = { true }

    /// `isIdle`: no dictation is being recorded or processed, so a helper can be restarted without interrupting.
    @MainActor static func start(isIdle: @escaping () -> Bool) {
        self.isIdle = isIdle
        DiagnosticLog.write("resource guard: Codex ≤ \(megabytes(codexSoftLimit)) when idle and ≤ \(megabytes(codexLimit)) always, "
            + "speech model ≤ \(megabytes(speechModelLimit)), checked every \(Int(checkInterval)) s")
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { _ in
            MainActor.assumeIsolated { check() }
        }
    }

    /// Stops a helper that went over its limit (it starts again when next needed) and ends any process the
    /// Codex app-server left running: polishing needs no tools, so those can only be leftovers.
    @MainActor static func check() {
        for helper in helpers() {
            if helper.name == "codex" {
                let leftovers = helper.lingering
                if !leftovers.isEmpty {
                    DiagnosticLog.write("resource guard: Codex left \(leftovers.count) process(es) running; ending them")
                    for pid in leftovers { kill(pid, SIGTERM) }
                }
                if helper.footprint > codexLimit || (helper.footprint > codexSoftLimit && isIdle()) {
                    DiagnosticLog.write("resource guard: Codex uses \(megabytes(helper.footprint)); restarting it")
                    CodexAppServer.shared.stop()
                    Task {
                        await CodexThreadPool.shared.reset()
                        // Start the new one and prime its threads now, so the next dictation is not slower.
                        AIEngine.prewarm()
                    }
                }
            } else if helper.name.lowercased().hasPrefix("python"), helper.footprint > speechModelLimit {
                DiagnosticLog.write("resource guard: speech model uses \(megabytes(helper.footprint)); stopping it")
                CompanionServer.shared.stop()
            }
        }
    }
}
