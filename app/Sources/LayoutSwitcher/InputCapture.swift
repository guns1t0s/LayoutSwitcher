import AppKit
import CoreGraphics

protocol InputCaptureDelegate: AnyObject {
    /// Return `true` to CONSUME the event (the delegate converted a word at this
    /// boundary and re-inserted the boundary char itself — a synchronous,
    /// race-free replacement). `false` passes the keystroke through unchanged.
    func inputDidKeyDown(keycode: Int64, chars: String, flags: CGEventFlags) -> Bool
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

    /// Health of the capture, surfaced to the UI (REL-7, scenario 10.6).
    enum Health: Equatable { case active, disabled, noPermission, noTap }
    /// Notified ONLY when health changes.
    var onHealthChange: ((Health) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: DispatchSourceTimer?
    private let healthQueue = DispatchQueue(label: "com.oateplov.layoutswitcher.health")
    private var lastHealth: Health?

    /// Diagnostics: is the tap currently enabled, and how many key events seen.
    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    private(set) var eventsSeen = 0
    private(set) var tapRearms = 0          // times re-enabled
    private(set) var tapRecreations = 0     // times fully rebuilt (dead port)

    // double-shift gesture state
    private var prevFlags = CGEventFlags()
    private var lastShiftPress: TimeInterval = 0
    private var otherKeySinceShift = false

    /// Create the tap if permissions allow. Idempotent. Starts the watchdog.
    @discardableResult
    func start() -> Bool {
        if tap == nil { _ = createTap() }
        startWatchdog()
        return isActive
    }

    private func createTap() -> Bool {
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: InputCapture.callback, userInfo: refcon
        ) else {
            return false   // no Input Monitoring / Accessibility permission yet
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func teardownTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        runLoopSource = nil
        tap = nil
    }

    /// Dead port (revoked + regranted, or killed under load): rebuild from scratch.
    private func recreateTap() {
        teardownTap()
        tapRecreations += 1
        _ = createTap()
    }

    func stop() {
        healthTimer?.cancel(); healthTimer = nil
        teardownTap()
    }

    /// Triggered by sleep/wake too — force an immediate health check.
    func rearmIfNeeded() { healthQueue.async { [weak self] in self?.healthCheck() } }

    // MARK: - self-healing watchdog (REL-1/REL-7)

    private func startWatchdog() {
        guard healthTimer == nil else { return }
        // DispatchSourceTimer (not a runloop Timer) so it keeps firing during
        // tracking loops/modals; generous interval + leeway respects NFR-6.
        let t = DispatchSource.makeTimerSource(queue: healthQueue)
        t.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(2))
        t.setEventHandler { [weak self] in self?.healthCheck() }
        healthTimer = t
        t.resume()
    }

    /// Runs on the health queue; all tap mutation hops to main (the runloop owner).
    private func healthCheck() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A keyboard tap needs BOTH Accessibility and Input Monitoring; either
            // can be revoked at runtime, leaving the app silently deaf (REL-7/10.6).
            guard Permissions.isAccessibilityTrusted, Permissions.isInputMonitoringGranted else {
                self.teardownTap()
                self.setHealth(.noPermission)
                return
            }
            guard let tap = self.tap else {
                // Permissions returned after a revocation → rebuild.
                self.setHealth(self.createTap() ? .active : .noTap)
                return
            }
            if CGEvent.tapIsEnabled(tap: tap) {
                self.setHealth(.active)
            } else {
                CGEvent.tapEnable(tap: tap, enable: true)
                self.tapRearms += 1
                if CGEvent.tapIsEnabled(tap: tap) {
                    self.setHealth(.active)
                } else {
                    self.recreateTap()                       // re-enable failed → dead port
                    self.setHealth(self.isActive ? .active : .noTap)
                }
            }
        }
    }

    private func setHealth(_ h: Health) {
        guard h != lastHealth else { return }
        lastHealth = h
        onHealthChange?(h)
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
            // The delegate may convert the just-finished word SYNCHRONOUSLY and
            // swallow this boundary keystroke (re-inserting it itself) — that
            // eliminates the async race where a fast next keystroke cancelled a
            // pending conversion in a busy app. Drop the event when it says so.
            if me.delegate?.inputDidKeyDown(keycode: keycode, chars: chars, flags: event.flags) == true {
                return nil
            }

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
