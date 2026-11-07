import AppKit
import Carbon
import CoreGraphics

protocol InputCaptureDelegate: AnyObject {
    /// Return `true` to CONSUME the event (the delegate converted a word at this
    /// boundary and re-inserted the boundary char itself — a synchronous,
    /// race-free replacement). `false` passes the keystroke through unchanged.
    func inputDidKeyDown(keycode: Int64, chars: String, flags: CGEventFlags) -> Bool
    func inputDidChangeFlags(_ flags: CGEventFlags)
    /// `interval` = seconds between the two ⇧ taps (for spotting accidental gestures).
    func inputDidDoubleShift(interval: TimeInterval)
    func inputDidClick()
}

/// CGEventTap front-end (NFR-1 event-driven, REL-1/REL-2/REL-3).
///
/// The callback runs on the main thread and holds every keystroke of the system
/// while it does, so it works from memory: no Accessibility calls, no file writes.
/// It can swallow a keystroke when a word is converted right there; anything else
/// goes through untouched (fail-open). Word handling is not under 1 ms, see
/// `CallbackTimings` for what it really takes.
/// A self-healing watchdog plus the tap-disabled events re-arm the tap if
/// macOS kills it under load (the classic "switcher silently stopped" bug).
final class InputCapture {

    weak var delegate: InputCaptureDelegate?

    /// While the callback runs: the tap's own place in the event stream, the only
    /// way to get ahead of the keys waiting behind this one (`LayoutController.send`).
    /// Main thread only, like the callback.
    private(set) static var proxy: CGEventTapProxy?

    /// Rewrites decided outside the callback, waiting for the next one (`later`), and
    /// how many of them ran there or were dropped. Main thread only.
    private static var pending: [(at: TimeInterval, body: () -> Void)] = []
    private(set) static var laterRun = 0
    private(set) static var laterDropped = 0
    private static let markerSource = CGEventSource(stateID: .privateState)
    /// The tap, for `later`: whether a callback is going to come at all.
    private static var activeTap: CFMachPort?

    /// ⇧⌃⌥⌘ as the apps have them, from the last modifier change the tap passed on: set
    /// before the callback reports it. A posted modifier (another tool's, a live check's)
    /// reaches the apps, but never the hardware state that `CGEventSource.flagsState` reads.
    private(set) static var modifiers = CGEventFlags()

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
    /// Why macOS turned the tap off, and how long our own key handling takes —
    /// the two things that explain a tap that keeps getting disabled.
    private(set) var disabledByTimeout = 0
    private(set) var disabledByUserInput = 0
    private(set) var tapRecreations = 0     // times fully rebuilt (dead port)
    /// Shared with the coordinator, whose stages it adds up per callback.
    var timings: CallbackTimings?
    var frontmostApp: () -> String = { "" }

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
        // Key-ups only for `later`: its marker is one, and a rewrite waiting for a
        // callback takes the first that comes.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
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
        InputCapture.activeTap = tap
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
        InputCapture.activeTap = nil
        InputCapture.dropLater()
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
                InputCapture.dropLater()            // keys went by the tap unseen
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

    private static let callback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<InputCapture>.fromOpaque(refcon).takeUnretainedValue()

        // macOS disabled the tap (timeout / heavy load) → turn it back on now.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if type == .tapDisabledByTimeout { me.disabledByTimeout += 1 } else { me.disabledByUserInput += 1 }
            InputCapture.dropLater()            // keys went by unseen: a waiting rewrite would miss them
            if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        let tag = event.getIntegerValueField(.eventSourceUserData)
        // Skip events we posted ourselves (would otherwise re-enter the pipeline).
        if tag == K.syntheticTag {
            return Unmanaged.passUnretained(event)
        }

        InputCapture.proxy = proxy
        defer { InputCapture.proxy = nil }

        let timings = me.timings
        // The marker of `later` and the key-ups are here for a rewrite that waits.
        if tag == K.markerTag || type == .keyUp {
            if !InputCapture.pending.isEmpty {
                timings?.begin(path: "later")
                InputCapture.runLater()
                timings?.end(app: me.frontmostApp())
            }
            return tag == K.markerTag ? nil : Unmanaged.passUnretained(event)
        }
        timings?.noteQueueDelay(eventTimestamp: event.timestamp)
        timings?.begin(path: type == .keyDown ? "letter" : type == .flagsChanged ? "flags" : "mouse")
        defer { timings?.end(app: me.frontmostApp()) }

        // A rewrite waiting for a callback goes in ahead of this event, and of the keys
        // behind it. Not ahead of a modifier coming up: the Shift of ⇧⇧ reaches the app
        // before the Backspaces do, and the marker or the next key is behind it.
        if !InputCapture.pending.isEmpty, type != .flagsChanged || !me.releasesModifier(event.flags) {
            if let timings { timings.measure("later") { InputCapture.runLater() } } else { InputCapture.runLater() }
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

    /// Does this change of the modifiers let one of ⇧⌃⌥⌘ go?
    private func releasesModifier(_ flags: CGEventFlags) -> Bool {
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        return !prevFlags.intersection(modifiers).subtracting(flags).isEmpty
    }

    // MARK: - rewrites from outside the callback

    /// Run `body` in the next callback, ahead of the event that brings it there: a key, a
    /// click, a modifier going down, or the marker posted here. An event posted outside the
    /// callback queues behind every key already waiting at the tap, and a rewrite counts its
    /// Backspaces for the screen as it is now: behind those keys it deleted them instead
    /// ("gпр" for "при"). Posted from the callback through the tap, it goes in ahead of
    /// them, and none of them has reached the app or the coordinator yet.
    /// False when no callback will come for it: no tap, or secure input keeps the keys
    /// away from it. No key waits at the tap then either, and the caller posts as before.
    static func later(_ body: @escaping () -> Void) -> Bool {
        // In a callback the tap is on; outside one, asking the window server is fine.
        if proxy == nil {
            guard let tap = activeTap, CGEvent.tapIsEnabled(tap: tap) else { return false }
        }
        guard !IsSecureEventInputEnabled() else { return false }
        pending.append((ProcessInfo.processInfo.systemUptime, body))
        // A key going up that no keyboard has. Posted the ordinary way it queues behind the
        // keys already waiting, and the callback drops it. The window server lets it reach
        // the tap: its check for key-ups of keys that are not down (SkyLight,
        // _CGXAdjustForRedundantState) runs after the session taps and passes posted events.
        // Past a tap that is off, an app gets the release of a key it never saw go down,
        // with the modifiers as they are, and ignores it.
        if let marker = CGEvent(keyboardEventSource: markerSource, virtualKey: K.markerKey, keyDown: false) {
            marker.flags = CGEventSource.flagsState(.combinedSessionState)
            marker.setIntegerValueField(.eventSourceUserData, value: K.markerTag)
            marker.post(tap: .cgSessionEventTap)
        }
        return true
    }

    /// In the callback. One that waited too long is dropped: the tap may have been off.
    private static func runLater() {
        let due = pending
        pending.removeAll()
        let now = ProcessInfo.processInfo.systemUptime
        for (at, body) in due {
            if now - at < K.laterDeadline { laterRun += 1; body() } else { laterDropped += 1 }
        }
    }

    /// Keys may have gone by the tap unseen: what a waiting rewrite would delete is unknown.
    private static func dropLater() {
        laterDropped += pending.count
        pending.removeAll()
    }

    private func handleFlags(_ flags: CGEventFlags) {
        Self.modifiers = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        let shiftNow = flags.contains(.maskShift)
        let shiftBefore = prevFlags.contains(.maskShift)
        if shiftNow && !shiftBefore {                 // Shift pressed down
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastShiftPress <= K.doubleShiftWindow && !otherKeySinceShift {
                delegate?.inputDidDoubleShift(interval: now - lastShiftPress)
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
