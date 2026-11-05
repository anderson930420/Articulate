import CoreGraphics
import Foundation

struct KeyEvent {
    enum Kind { case flagsChanged, keyDown, keyUp }

    var kind: Kind
    var keyCode: Int64
    var flags: UInt64
    var time: TimeInterval
    var isRepeat = false
}

enum HotkeyAction: Equatable {
    case start
    case finish
    case cancel
    /// Recording continues after the trigger is released; the next trigger press finishes it.
    case handsFree
    case setMode(DictationMode)
    case cycleTranslationTarget
    case pasteLast
}

enum SessionPhase {
    case idle, recording, processing
}

/// Pure state machine for the shortcuts, kept free of CGEvent so it can be self-tested.
/// Layout follows Typeless (trigger = right ⌘ by default):
///
/// - Tap trigger → start dictating; tap again → insert (Typeless's default).
/// - Or hold trigger while speaking; release → insert.
/// - `pressMode` can limit this to holding only or tapping only.
/// - Trigger + Space → Ask Anything (press trigger again to finish).
/// - Trigger + right Shift → translation (press trigger again to finish); right Shift cycles the target.
/// - Any other key while holding the trigger means a keyboard shortcut, so recording is cancelled.
/// - Esc cancels recording or processing. ⌃⌘V pastes the last result.
struct HotkeyLogic {
    /// Presses shorter than this are taps (toggle); longer ones are push-to-talk. Unhurried taps measured up to
    /// about 0.4 s, and nobody says anything in under half a second.
    static let minHold: TimeInterval = 0.5
    static let spaceKey: Int64 = 49
    static let escapeKey: Int64 = 53
    static let rightShiftKey: Int64 = 60
    static let rightShiftMask: UInt64 = 0x04 // NX_DEVICERSHIFTKEYMASK

    var trigger: TriggerKey
    var pasteKeyCode: Int64 = 9
    var pressMode: PressMode = .both

    private(set) var triggerDown = false
    /// The current recording continues after the trigger is released.
    private(set) var toggleSession = false
    private(set) var mode: DictationMode = .dictation
    private var downAt: TimeInterval = 0
    private var otherKeyDuringHold = false
    private var ignorePress = false
    private var stopPress = false
    private var rightShiftDown = false
    private var swallowedKeyUps = Set<Int64>()

    init(trigger: TriggerKey) {
        self.trigger = trigger
    }

    private func hasOtherModifiers(_ flags: UInt64) -> Bool {
        let generic = CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
        return flags & generic & ~trigger.classMask != 0 || flags & trigger.otherSideMask != 0
    }

    private var holdActive: Bool { triggerDown && !ignorePress && !stopPress }

    /// Returns the actions to perform and whether the event should be swallowed.
    mutating func handle(_ e: KeyEvent, phase: SessionPhase) -> (actions: [HotkeyAction], swallow: Bool) {
        let isRecording = phase == .recording
        if !isRecording {
            toggleSession = false
            mode = .dictation
        }

        switch e.kind {
        case .flagsChanged:
            if e.keyCode == Self.rightShiftKey {
                let pressed = e.flags & Self.rightShiftMask != 0
                defer { rightShiftDown = pressed }
                guard pressed, !rightShiftDown, isRecording else { return ([], false) }
                if holdActive && mode != .translation && !otherKeyDuringHold {
                    mode = .translation
                    toggleSession = true
                    return ([.setMode(.translation)], false)
                }
                if mode == .translation && !triggerDown {
                    return ([.cycleTranslationTarget], false)
                }
                return ([], false)
            }

            guard e.keyCode == trigger.keyCode else {
                // Another modifier joined the trigger: this is a keyboard shortcut, not dictation.
                if holdActive && !toggleSession && !otherKeyDuringHold {
                    otherKeyDuringHold = true
                    return (isRecording ? [.cancel] : [], false)
                }
                return ([], false)
            }

            let pressed = e.flags & trigger.pressedMask != 0
            if pressed && !triggerDown {
                triggerDown = true
                downAt = e.time
                otherKeyDuringHold = false
                ignorePress = false
                stopPress = false
                if isRecording && toggleSession {
                    stopPress = true
                    toggleSession = false
                    return ([.finish], false)
                }
                if hasOtherModifiers(e.flags) {
                    ignorePress = true
                    return ([], false)
                }
                // While processing, .start lets the controller say it is still busy.
                return ([.start], false)
            }
            if !pressed && triggerDown {
                triggerDown = false
                if stopPress || ignorePress {
                    stopPress = false
                    ignorePress = false
                    return ([], false)
                }
                if !isRecording || toggleSession { return ([], false) }
                if otherKeyDuringHold { return ([.cancel], false) }
                let held = e.time - downAt >= Self.minHold
                switch pressMode {
                case .hold:
                    // Push-to-talk only: a quick tap is not a dictation, so it is dropped without a word.
                    return (held ? [.finish] : [.cancel], false)
                case .both where held:
                    return ([.finish], false)
                case .both, .toggle:
                    // A tap (or, tapping only, any press) starts hands-free dictation: tap again to finish.
                    toggleSession = true
                    return ([.handsFree], false)
                }
            }
            return ([], false)

        case .keyDown:
            let ctrlCmd = CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue
            if e.keyCode == pasteKeyCode && e.flags & ctrlCmd == ctrlCmd {
                swallowedKeyUps.insert(e.keyCode)
                if e.isRepeat { return ([], true) }
                switch phase {
                case .idle: return ([.pasteLast], true)
                case .recording: return (toggleSession ? [] : [.cancel, .pasteLast], true)
                case .processing: return ([], true)
                }
            }
            if holdActive {
                if e.keyCode == Self.spaceKey && isRecording && !otherKeyDuringHold {
                    swallowedKeyUps.insert(e.keyCode)
                    if mode != .ask && !e.isRepeat {
                        mode = .ask
                        toggleSession = true
                        return ([.setMode(.ask)], true)
                    }
                    return ([], true)
                }
                if !toggleSession {
                    otherKeyDuringHold = true
                    return (isRecording ? [.cancel] : [], false)
                }
            }
            if e.keyCode == Self.escapeKey && phase != .idle {
                toggleSession = false
                swallowedKeyUps.insert(e.keyCode)
                return ([.cancel], true)
            }
            return ([], false)

        case .keyUp:
            if swallowedKeyUps.remove(e.keyCode) != nil { return ([], true) }
            return ([], false)
        }
    }
}
