import AppKit
import CoreGraphics

protocol InputCaptureDelegate: AnyObject {
    func inputDidKeyDown(keycode: Int64, chars: String, flags: CGEventFlags)
    func inputDidChangeFlags(_ flags: CGEventFlags)
    func inputDidDoubleShift()
    func inputDidClick()
}

/// CGEventTap front-end (NFR-1 event-driven, REL-1/REL-2/REL-3).
///
/// The C callback does the absolute minimum and ALWAYS returns the event
/// unmodified (fail-open: we never swallow real keystrokes). Corrections are
/// applied later by *posting* synthetic events, so the hot path stays <1ms.
/// A self-healing watchdog plus the tap-disabled events re-arm the tap if
/// macOS kills it under load (the classic "switcher silently stopped" bug).
final class InputCapture {

    weak var delegate: InputCaptureDelegate?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?

    /// Diagnostics: is the tap currently enabled, and how many key events seen.
    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    private(set) var eventsSeen = 0

    // double-shift gesture state
    private var prevFlags = CGEventFlags()
    private var lastShiftPress: TimeInterval = 0
    private var otherKeySinceShift = false

    func start() -> Bool {
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return true }   // idempotent
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: InputCapture.callback,
            userInfo: refcon
        ) else {
            return false   // no Input Monitoring / Accessibility permission yet
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startWatchdog()
        return true
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }

    /// REL-1: re-enable proactively in case a disabled event was missed.
    func rearmIfNeeded() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.rearmIfNeeded()
        }
    }

    // MARK: - C callback (hot path — keep tiny, never block)

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<InputCapture>.fromOpaque(refcon).takeUnretainedValue()

        // macOS disabled the tap (timeout / heavy load) → turn it back on now.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        // Skip events we posted ourselves (would otherwise re-enter the pipeline).
        if event.getIntegerValueField(.eventSourceUserData) == K.syntheticTag {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            me.eventsSeen += 1
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            var length = 0
            var buf = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buf)
            let chars = String(utf16CodeUnits: buf, count: length)
            me.otherKeySinceShift = true
            me.delegate?.inputDidKeyDown(keycode: keycode, chars: chars, flags: event.flags)

        case .flagsChanged:
            me.handleFlags(event.flags)

        case .leftMouseDown, .rightMouseDown:
            me.delegate?.inputDidClick()

        default:
            break
        }
        return Unmanaged.passUnretained(event)   // always pass through (fail-open)
    }

    private func handleFlags(_ flags: CGEventFlags) {
        let shiftNow = flags.contains(.maskShift)
        let shiftBefore = prevFlags.contains(.maskShift)
        if shiftNow && !shiftBefore {                 // Shift pressed down
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastShiftPress <= K.doubleShiftWindow && !otherKeySinceShift {
                delegate?.inputDidDoubleShift()
                lastShiftPress = 0
            } else {
                lastShiftPress = now
            }
            otherKeySinceShift = false
        }
        prevFlags = flags
        delegate?.inputDidChangeFlags(flags)
    }
}
