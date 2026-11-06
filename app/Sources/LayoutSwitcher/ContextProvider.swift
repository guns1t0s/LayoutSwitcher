import AppKit
import Carbon
import ApplicationServices
import SwitcherCore

/// Knows *where* the user is typing: frontmost app, whether the field is
/// secure/password, and a coarse field role for proactive layout (FR-5).
/// Backs the password-field stand-down (SEC-4, REL-6) and layout memory (FR-4).
class ContextProvider {

    /// Role guess for the focused field, used to bias layout to latin.
    enum FieldRole { case secure, urlOrEmail, search, generic, unknown }

    var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: - what the keystroke path may ask

    /// The event tap runs on the main thread, and an Accessibility call blocks until
    /// the other app answers: up to 0.3 s each while an Electron renderer is busy,
    /// three of them per word, and keystrokes queue behind it. So the tap path reads
    /// the last known answer, and the reads run here. Main-thread state only.
    private let axQueue = DispatchQueue(label: "com.oateplov.layoutswitcher.ax", qos: .userInteractive)
    private var cachedRole: FieldRole = .unknown
    private(set) var isFrontmostFullscreen = false
    private(set) var hasEditableFocus = false
    private var reading = false
    private var readAgain = false
    private var lastReadAt: TimeInterval = 0
    private var focusEpoch = 0

    /// The focus may have moved and no read has finished since. Not "unreadable":
    /// that is an answer (unknown role, the old fail-open). Until the answer is in,
    /// automatic rewriting stands aside, which costs a miss, not a password.
    private(set) var isFieldPending = false

    /// Something happened that can move the focus (a focus event, a click, Tab, a
    /// shortcut). Must come first on those paths, before any guard. A keystroke or a
    /// click is still held by the tap at this point: a read started now would see the
    /// old field and declare it current, so that read waits for the app to get it.
    func focusMayHaveMoved(afterHeldEvent: Bool = false) {
        focusEpoch &+= 1
        isFieldPending = true
        guard afterHeldEvent else { refreshFocus(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.refreshFocus() }
    }

    /// Does the app want to know what precedes the caret? Asked before each read.
    var wantsCaretContext: (() -> Bool)?
    /// The current keystroke number: an answer is good only until the next key.
    var currentKeystroke: (() -> Int)?
    private var caretReadEpoch = -1
    private var quoteFitsCaret = false
    private var caretKeystroke = -1

    /// Would a quote at the caret be a mention, as of the read made at `keystroke`?
    func quoteFitsCaret(atKeystroke keystroke: Int) -> Bool {
        quoteFitsCaret && caretKeystroke == keystroke
    }

    /// Called on the main thread after each read of the focused field.
    var onFocusRead: (() -> Void)?

    /// Re-read the focused field off the main thread. Coalesced, so a stalled app
    /// costs one pending read however often this is called. Reads that were asked
    /// for during a read cannot trust its result, so one more follows.
    func refreshFocus() {
        guard !reading else { readAgain = true; return }
        reading = true
        let epoch = focusEpoch
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Only what is derived from the text is kept, never the text itself.
        let wantsCaret = epoch != caretReadEpoch && wantsCaretContext?() == true
        let keystroke = currentKeystroke?() ?? 0
        axQueue.async { [weak self] in
            guard let self else { return }
            let role = self.focusedRole()
            var quoteFits = false
            if wantsCaret, role != .secure, let (text, caret) = AXText.focusedValueAndCaret() {
                let ns = text as NSString
                quoteFits = DetectionEngine.quoteStartsMention(
                    before: ns.substring(to: max(0, min(caret, ns.length))))
            }
            let fullscreen = pid.map { AXText.isFullscreen(pid: $0) } ?? false
            let editable = fullscreen && self.isEditable(role)
            DispatchQueue.main.async {
                self.cachedRole = role
                self.isFrontmostFullscreen = fullscreen
                self.hasEditableFocus = editable
                self.reading = false
                self.lastReadAt = ProcessInfo.processInfo.systemUptime
                if wantsCaret {
                    self.caretReadEpoch = epoch
                    self.quoteFitsCaret = quoteFits
                    self.caretKeystroke = keystroke
                }
                if epoch == self.focusEpoch { self.isFieldPending = false }
                if self.readAgain {
                    self.readAgain = false
                    self.refreshFocus()         // this answer may predate the change
                } else {
                    self.onFocusRead?()
                }
            }
        }
    }

    /// While typing goes on in one field, once a second is plenty. Focus changes
    /// call `refreshFocus` directly.
    func refreshFocusIfStale() {
        if ProcessInfo.processInfo.systemUptime - lastReadAt >= 1 { refreshFocus() }
    }

    /// For the check on every letter: never waits, and leans to the safe side.
    var mayBeSecure: Bool { isFieldPending || cachedRole == .secure || IsSecureEventInputEnabled() }

    /// The field role as of the last read: for the proactive layout, right after one.
    var lastKnownRole: FieldRole { cachedRole }

    /// REL-6: secure detection. The AX secure-field subrole is the precise,
    /// per-field signal. `IsSecureEventInputEnabled()` is a *global* flag that
    /// other apps (terminals, password managers) routinely leave on, so it is
    /// only honored when we genuinely cannot read the focused field — otherwise
    /// it would suppress conversion everywhere. The flag itself is cheap, and with
    /// it down the last read will do. Automatic paths stop at `isFieldPending` before
    /// they get here; for a manual gesture, and with the flag up, this is the one
    /// case worth waiting for the answer.
    var isSecureInput: Bool {
        let flag = IsSecureEventInputEnabled()
        guard flag || isFieldPending else { return cachedRole == .secure }
        let role = focusedRole()
        return role == .secure || (role == .unknown && flag)
    }

    /// AX read of the system-wide focused element, up to three messages to the other
    /// app. Returns `.unknown` (fail-open) on any error. Off the main thread normally.
    func focusedRole() -> FieldRole {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return .unknown }
        let el = element as! AXUIElement

        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        var subroleRef: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleRef)
        let role = (roleRef as? String) ?? ""
        let subrole = (subroleRef as? String) ?? ""

        if subrole == (kAXSecureTextFieldSubrole as String) { return .secure }
        if subrole == "AXSearchField" { return .search }
        if role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) {
            return .generic
        }
        return .unknown
    }

    /// Is the user focused on an EDITABLE text field right now? Used to keep
    /// converting in a fullscreen window when it is actually a text editor / chat
    /// (the "disable in fullscreen" guard is meant for games & video players that
    /// have no text focus, not for someone typing in a fullscreen Electron app).
    ///
    /// Role alone is unreliable: web/Electron contenteditable areas often report a
    /// role we don't classify (.unknown), which wrongly suppressed conversion in a
    /// fullscreen browser/editor. So if the role check is inconclusive, fall back
    /// to whether the focused element's VALUE is settable — true for any real text
    /// input (native or web), false for a game/video with no editable focus.
    func hasEditableTextFocus() -> Bool { isEditable(focusedRole()) }

    private func isEditable(_ role: FieldRole) -> Bool {
        switch role {
        case .generic, .search, .urlOrEmail: return true
        case .secure: return false
        case .unknown: return focusedValueIsSettable()
        }
    }

    /// AX: does the system-wide focused element expose a SETTABLE value? A text
    /// field / contenteditable does; a button, image, game surface or no-focus
    /// does not. Fail-closed (false) on any read error.
    private func focusedValueIsSettable() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return false }
        let el = element as! AXUIElement
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    /// FR-5: latin-by-default field?
    func prefersLatin() -> Bool {
        switch focusedRole() {
        case .urlOrEmail, .search, .secure: return true
        default: return false
        }
    }

    /// Stable key for layout memory by app + field role (FR-4).
    func roleKey() -> String {
        switch cachedRole {
        case .secure: return "secure"
        case .urlOrEmail: return "url"
        case .search: return "search"
        case .generic: return "text"
        case .unknown: return ""
        }
    }
}
