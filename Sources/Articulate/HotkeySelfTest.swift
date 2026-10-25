import CoreGraphics
import Foundation

/// Scripted key sequences checked against HotkeyLogic (`Articulate --selftest-hotkeys`).
enum HotkeySelfTest {
    private struct Step {
        var event: KeyEvent
        var expect: [HotkeyAction]
        var swallow = false
    }

    private static let cmd = CGEventFlags.maskCommand.rawValue
    private static let ctrl = CGEventFlags.maskControl.rawValue
    private static let shift = CGEventFlags.maskShift.rawValue
    private static let base: UInt64 = 0x100 // NX_NONCOALSESCEDMASK, present on real events

    private static func flags(_ trigger: TriggerKey, down: Bool, extra: UInt64 = 0) -> UInt64 {
        base | extra | (down ? trigger.classMask | trigger.pressedMask : 0)
    }

    private static func trig(_ trigger: TriggerKey = .rightCommand, down: Bool, at t: TimeInterval, extra: UInt64 = 0) -> KeyEvent {
        KeyEvent(kind: .flagsChanged, keyCode: trigger.keyCode, flags: flags(trigger, down: down, extra: extra), time: t)
    }

    private static func key(_ kind: KeyEvent.Kind, _ code: Int64, flags: UInt64 = base, at t: TimeInterval) -> KeyEvent {
        KeyEvent(kind: kind, keyCode: code, flags: flags, time: t)
    }

    private static func rightShift(down: Bool, held: Bool, at t: TimeInterval) -> KeyEvent {
        let f = base | (held ? flags(.rightCommand, down: true) : 0) | (down ? shift | HotkeyLogic.rightShiftMask : 0)
        return KeyEvent(kind: .flagsChanged, keyCode: HotkeyLogic.rightShiftKey, flags: f, time: t)
    }

    static func run() -> Bool {
        var failures = 0
        func scenario(_ name: String, trigger: TriggerKey = .rightCommand, pressMode: PressMode = .both, _ steps: [Step]) {
            var logic = HotkeyLogic(trigger: trigger)
            logic.pressMode = pressMode
            var phase = SessionPhase.idle
            for (i, step) in steps.enumerated() {
                let (actions, swallow) = logic.handle(step.event, phase: phase)
                for action in actions {
                    switch action {
                    case .start: if phase == .idle { phase = .recording }
                    case .finish, .cancel: phase = .idle
                    default: break
                    }
                }
                if actions != step.expect || swallow != step.swallow {
                    failures += 1
                    print("FAIL \(name) step \(i): got \(actions) swallow=\(swallow), expected \(step.expect) swallow=\(step.swallow)")
                    return
                }
            }
            print("ok   \(name)")
        }

        let held = flags(.rightCommand, down: true)
        scenario("hold only: release finishes", pressMode: .hold, [
            Step(event: trig(down: true, at: 0), expect: [.start]),
            Step(event: trig(down: false, at: 2), expect: [.finish]),
        ])
        scenario("hold only: a quick tap is dropped", pressMode: .hold, [
            Step(event: trig(down: true, at: 0), expect: [.start]),
            Step(event: trig(down: false, at: 0.2), expect: [.cancel]),
        ])
        scenario("tap only: a long press keeps recording until the next press", pressMode: .toggle, [
            Step(event: trig(down: true, at: 0), expect: [.start]),
            Step(event: trig(down: false, at: 2), expect: [.handsFree]),
            Step(event: trig(down: true, at: 5), expect: [.finish]),
            Step(event: trig(down: false, at: 5.1), expect: []),
        ])
        scenario("tap only: tap, tap", pressMode: .toggle, [
            Step(event: trig(down: true, at: 0), expect: [.start]),
            Step(event: trig(down: false, at: 0.15), expect: [.handsFree]),
            Step(event: trig(down: true, at: 4), expect: [.finish]),
        ])
        // Unhurried taps measured up to about 0.4 s; they must not end the recording they just started.
        scenario("slow tap still starts hands-free dictation", [
            Step(event: trig(down: true, at: 0), expect: [.start]),
            Step(event: trig(down: false, at: 0.42), expect: [.handsFree]),
            Step(event: trig(down: true, at: 3), expect: [.finish]),
            Step(event: trig(down: false, at: 3.1), expect: []),
        ])
        scenario("hold and release dictates", [
            Step(event: trig(down: true, at: 0), expect: [.start]),
            Step(event: trig(down: false, at: 1.2), expect: [.finish]),
        ])
        scenario("tap to start, tap again to finish (Typeless style)", [
            Step(event: trig(down: true, at: 0), expect: [.start]),
            Step(event: trig(down: false, at: 0.1), expect: [.handsFree]),
            Step(event: key(.keyDown, 0, at: 2), expect: []), // typing elsewhere doesn't stop it
            Step(event: trig(down: true, at: 6), expect: [.finish]),
            Step(event: trig(down: false, at: 6.1), expect: []),
            Step(event: key(.keyDown, 0, at: 7), expect: []),
        ])
        scenario("tap while still processing asks again (controller reports busy)", [
            Step(event: trig(down: true, at: 0), expect: [.start]),
            Step(event: trig(down: false, at: 0.1), expect: [.handsFree]),
            Step(event: trig(down: true, at: 3), expect: [.finish]),
            Step(event: trig(down: false, at: 3.1), expect: []),
            Step(event: trig(down: true, at: 4), expect: [.start]),
            Step(event: trig(down: false, at: 4.1), expect: [.handsFree]),
        ])
        scenario("right-cmd shortcut (⌘C) cancels and passes through", [
            Step(event: trig(down: true, at: 0), expect: [.start]),
            Step(event: key(.keyDown, 8, flags: held, at: 0.2), expect: [.cancel]),
            Step(event: key(.keyUp, 8, flags: held, at: 0.3), expect: []),
            Step(event: trig(down: false, at: 0.5), expect: []),
        ])
        scenario("trigger + Space is Ask Anything", [
            Step(event: trig(down: true, at: 0), expect: [.start]),
            Step(event: key(.keyDown, 49, flags: held, at: 0.2), expect: [.setMode(.ask)], swallow: true),
            Step(event: key(.keyUp, 49, flags: held, at: 0.3), expect: [], swallow: true),
            Step(event: trig(down: false, at: 0.4), expect: []),
            Step(event: trig(down: true, at: 4), expect: [.finish]),
            Step(event: trig(down: false, at: 4.1), expect: []),
        ])
        scenario("trigger + right Shift is translation; right Shift cycles target", [
            Step(event: trig(down: true, at: 0), expect: [.start]),
            Step(event: rightShift(down: true, held: true, at: 0.2), expect: [.setMode(.translation)]),
            Step(event: rightShift(down: false, held: true, at: 0.3), expect: []),
            Step(event: trig(down: false, at: 0.4), expect: []),
            Step(event: rightShift(down: true, held: false, at: 1), expect: [.cycleTranslationTarget]),
            Step(event: rightShift(down: false, held: false, at: 1.1), expect: []),
            Step(event: trig(down: true, at: 5), expect: [.finish]),
            Step(event: trig(down: false, at: 5.1), expect: []),
        ])
        scenario("esc cancels a hands-free session", [
            Step(event: trig(down: true, at: 0), expect: [.start]),
            Step(event: key(.keyDown, 49, flags: held, at: 0.2), expect: [.setMode(.ask)], swallow: true),
            Step(event: trig(down: false, at: 0.4), expect: []),
            Step(event: key(.keyDown, 53, at: 3), expect: [.cancel], swallow: true),
            Step(event: key(.keyUp, 53, at: 3.1), expect: [], swallow: true),
        ])
        scenario("left ⌘ already held: no dictation", [
            Step(event: trig(down: true, at: 0, extra: 0x08), expect: []),
            Step(event: trig(down: false, at: 1, extra: 0x08), expect: []),
        ])
        scenario("ctrl joining the hold cancels", [
            Step(event: trig(down: true, at: 0), expect: [.start]),
            Step(event: KeyEvent(kind: .flagsChanged, keyCode: 59, flags: held | ctrl, time: 0.2), expect: [.cancel]),
            Step(event: trig(down: false, at: 0.8, extra: ctrl), expect: []),
        ])
        scenario("⌃⌘V pastes the last result", [
            Step(event: key(.keyDown, 9, flags: base | ctrl | cmd | 0x08, at: 0), expect: [.pasteLast], swallow: true),
            Step(event: key(.keyUp, 9, flags: base | ctrl | cmd | 0x08, at: 0.1), expect: [], swallow: true),
        ])
        scenario("plain ⌘V is left alone", [
            Step(event: key(.keyDown, 9, flags: base | cmd | 0x08, at: 0), expect: []),
        ])
        scenario("fn trigger", trigger: .fn, [
            Step(event: trig(.fn, down: true, at: 0), expect: [.start]),
            Step(event: trig(.fn, down: false, at: 2), expect: [.finish]),
        ])
        scenario("right ⌥ trigger ignores left ⌥", trigger: .rightOption, [
            Step(event: trig(.rightOption, down: true, at: 0, extra: 0x20), expect: []),
            Step(event: trig(.rightOption, down: false, at: 1, extra: 0x20), expect: []),
            Step(event: trig(.rightOption, down: true, at: 2), expect: [.start]),
            Step(event: trig(.rightOption, down: false, at: 3), expect: [.finish]),
        ])

        print(failures == 0 ? "all hotkey scenarios passed" : "\(failures) scenario(s) failed")
        return failures == 0
    }
}
