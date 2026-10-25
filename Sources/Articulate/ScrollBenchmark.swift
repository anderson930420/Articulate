import AppKit
import SwiftUI

/// Measures how long the main thread takes per scroll step in each Hub page (`Articulate --bench-scroll`).
/// The window sits off screen, so nothing appears and the mouse is never touched.
@MainActor
enum ScrollBenchmark {
    static func run() {
        let variants: [(String, NSHostingSizingOptions)] = [("default sizing", [.minSize, .intrinsicContentSize, .maxSize]), ("min size only", [.minSize])]
        for section in [HubSection.home, .history, .dictionary, .settings] {
            for (name, sizing) in variants {
                let line = String(format: "%-10@ %-15@ %@\n", section.rawValue as NSString, name as NSString, measure(section, sizing: sizing))
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }

    private static func measure(_ section: HubSection, sizing: NSHostingSizingOptions) -> String {
        let state = HubState()
        state.section = section
        let window = NSWindow(contentRect: NSRect(x: -12000, y: 0, width: 1200, height: 840), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: HubView(state: state))
        host.sizingOptions = sizing
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        settle(0.5)

        guard let scrollView = largestScrollView(in: host), let document = scrollView.documentView else { return "no scroll view" }
        let clip = scrollView.contentView
        let range = max(0, document.frame.height - clip.bounds.height)
        guard range > 100 else { return String(format: "nothing to scroll (content %.0f pt)", document.frame.height) }

        var times: [Double] = []
        var y: CGFloat = 0
        var direction: CGFloat = 1
        for _ in 0..<60 {
            y += 30 * direction
            if y >= range || y <= 0 { direction = -direction; y = min(max(y, 0), range) }
            let start = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
            RunLoop.main.run(mode: .default, before: Date())
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        let sorted = times.sorted()
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        let over8 = times.filter { $0 > 8.3 }.count
        let over16 = times.filter { $0 > 16.7 }.count
        return String(format: "avg %.2f ms  p95 %.2f ms  max %.1f ms  >8.3ms: %d  >16.7ms: %d  (content %.0f pt)",
                      times.reduce(0, +) / Double(times.count), p95, sorted.last ?? 0, over8, over16, document.frame.height)
    }

    private static func settle(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The page's main scroll view: the one with the most content.
    private static func largestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ v: NSView) {
            if let s = v as? NSScrollView, (s.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = s }
            v.subviews.forEach(visit)
        }
        visit(view)
        return best
    }
}
