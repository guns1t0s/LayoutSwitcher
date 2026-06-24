import AppKit
import Carbon
import ApplicationServices

/// Knows *where* the user is typing: frontmost app, whether the field is
/// secure/password, and a coarse field role for proactive layout (FR-5).
/// Backs the password-field stand-down (SEC-4, REL-6) and layout memory (FR-4).
final class ContextProvider {

    /// Role guess for the focused field, used to bias layout to latin.
    enum FieldRole { case secure, urlOrEmail, search, generic, unknown }

    var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// REL-6: secure detection. The AX secure-field subrole is the precise,
    /// per-field signal. `IsSecureEventInputEnabled()` is a *global* flag that
    /// other apps (terminals, password managers) routinely leave on, so it is
    /// only honored when we genuinely cannot read the focused field — otherwise
    /// it would suppress conversion everywhere.
    var isSecureInput: Bool {
        let role = focusedRole()
        if role == .secure { return true }
        if role == .unknown { return IsSecureEventInputEnabled() }
        return false
    }

    /// Cheap AX read of the system-wide focused element. Returns `.unknown`
    /// (fail-open) on any error — never blocks the input path.
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
    func hasEditableTextFocus() -> Bool {
        switch focusedRole() {
        case .generic, .search, .urlOrEmail: return true
        case .secure, .unknown: return false
        }
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
        switch focusedRole() {
        case .secure: return "secure"
        case .urlOrEmail: return "url"
        case .search: return "search"
        case .generic: return "text"
        case .unknown: return ""
        }
    }
}
