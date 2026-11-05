import Foundation

/// Plain-text log in ~/Library/Logs/Articulate/articulate.log for diagnosing "nothing was typed" reports.
/// Records events and decisions only (lengths, app names, permission state), never the dictated text.
enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "local.articulate.log")
    static let url: URL = {
        // Benchmarks set ARTICULATE_LOG_FILE so they don't mix their lines into the app's log.
        if let path = ProcessInfo.processInfo.environment["ARTICULATE_LOG_FILE"] { return URL(fileURLWithPath: path) }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Articulate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("articulate.log")
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
                try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("old.log"))
                try? FileManager.default.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("old.log"))
            }
            if let handle = FileHandle(forWritingAtPath: url.path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
