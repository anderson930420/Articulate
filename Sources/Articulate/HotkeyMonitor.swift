import AppKit
import CoreGraphics

/// Global keyboard listener built on a CGEventTap (needs Accessibility permission).
/// It is an active tap so Space/Esc/⌃⌘V can be swallowed while they act as dictation shortcuts.
final class HotkeyMonitor {
    var phase: () -> SessionPhase = { .idle }
    var onAction: (HotkeyAction) -> Void = { _ in }
    /// Return or Enter is about to reach the app (often sending a message); called before it does.
    var onReturnKey: () -> Void = {}

    private var logic = HotkeyLogic(trigger: Prefs.triggerKey)
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?

    var isRunning: Bool { tap != nil }

    /// Starts the tap, retrying every two seconds until Accessibility permission is granted.
    func start() {
        guard tap == nil else { return }
        if installTap() { return }
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if self.installTap() { timer.invalidate() }
        }
    }

    private func installTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("Articulate: keyboard monitor started")
        DiagnosticLog.write("keyboard monitor started (trigger=\(Prefs.triggerKey.rawValue))")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .flagsChanged, .keyDown, .keyUp:
            break
        default:
            return Unmanaged.passUnretained(event)
        }
        // Ignore the ⌘V we post ourselves when inserting text.
        if event.getIntegerValueField(.eventSourceUserData) == TextInserter.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown, [36, 76].contains(event.getIntegerValueField(.keyboardEventKeycode)) { onReturnKey() }

        let trigger = Prefs.triggerKey
        if logic.trigger != trigger {
            logic = HotkeyLogic(trigger: trigger)
        }
        logic.pasteKeyCode = Int64(TextInserter.pasteKeyCode)
        logic.pressMode = Prefs.pressMode

        let kind: KeyEvent.Kind = switch type {
        case .flagsChanged: .flagsChanged
        case .keyDown: .keyDown
        default: .keyUp
        }
        // When the key actually went down or up, not when this callback got to run: starting the microphone can
        // hold up the main thread for a moment (most after a long idle), and a quick tap whose release was handled
        // late used to be measured as a hold, so recording stopped right away with nothing heard.
        let now = ProcessInfo.processInfo.systemUptime
        let stamped = NSEvent(cgEvent: event)?.timestamp ?? 0
        let time = stamped > 0 && stamped <= now && now - stamped < 5 ? stamped : now
        let keyEvent = KeyEvent(
            kind: kind,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags.rawValue,
            time: time,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
        let (actions, swallow) = logic.handle(keyEvent, phase: phase())
        if !actions.isEmpty { DiagnosticLog.write("hotkey \(actions) (handled \(String(format: "%.2f", now - time))s after the key)") }
        for action in actions { onAction(action) }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
