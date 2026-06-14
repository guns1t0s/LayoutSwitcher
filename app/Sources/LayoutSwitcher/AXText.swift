import AppKit
import ApplicationServices

/// Thin Accessibility helpers: read/replace the selection (REL-5), find the
/// caret rectangle (caret overlay), and detect fullscreen (FR-31). Every call
/// is best-effort and returns nil/false on failure — never blocks the input path.
enum AXText {

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused else { return nil }
        return (el as! AXUIElement)
    }

    static func selectedText(_ el: AXUIElement? = nil) -> String? {
        guard let el = el ?? focusedElement() else { return nil }
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &v) == .success else { return nil }
        let s = v as? String
        return (s?.isEmpty == false) ? s : nil
    }

    /// Replace the current selection with `text` (FR-23/24/25 selection tools).
    @discardableResult
    static func replaceSelection(with text: String, in el: AXUIElement? = nil) -> Bool {
        guard let el = el ?? focusedElement() else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Full text of the focused field + caret offset (UTF-16). For line ops.
    static func focusedValueAndCaret() -> (String, Int)? {
        guard let el = focusedElement() else { return nil }
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success,
              let text = v as? String else { return nil }
        var rv: AnyObject?
        var caret = (text as NSString).length
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rv) == .success,
           let r = rv, CFGetTypeID(r) == AXValueGetTypeID() {
            var range = CFRange()
            AXValueGetValue((r as! AXValue), .cfRange, &range)
            caret = range.location
        }
        return (text, caret)
    }

    /// Select an explicit range in the focused field (for line/range replace).
    @discardableResult
    static func setSelectedRange(location: Int, length: Int) -> Bool {
        guard let el = focusedElement() else { return false }
        var r = CFRange(location: location, length: length)
        guard let val = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, val) == .success
    }

    /// Caret rectangle in Cocoa (bottom-left origin) screen coordinates.
    static func caretRect() -> CGRect? {
        guard let el = focusedElement() else { return nil }
        var rv: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rv) == .success,
              let axRange = rv, CFGetTypeID(axRange) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        AXValueGetValue((axRange as! AXValue), .cfRange, &range)
        // Bounds for a 1-char range at (or just before) the caret.
        let loc = max(0, range.location - (range.location > 0 ? 1 : 0))
        var probe = CFRange(location: loc, length: 1)
        guard let probeVal = AXValueCreate(.cfRange, &probe) else { return nil }
        var boundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
                el, kAXBoundsForRangeParameterizedAttribute as CFString, probeVal, &boundsRef) == .success,
              let bounds = boundsRef, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        AXValueGetValue((bounds as! AXValue), .cgRect, &rect)
        if rect.isEmpty { return nil }
        return flipToCocoa(rect)
    }

    /// FR-31: is the frontmost app in *native* fullscreen? Only the AX
    /// fullscreen flag is used — a window merely sized to the screen (maximized)
    /// must NOT count, or conversion would be suppressed for normal full-window work.
    static func isFrontmostFullscreen() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(pid)
        var win: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let win else { return false }
        var fs: AnyObject?
        if AXUIElementCopyAttributeValue((win as! AXUIElement), "AXFullScreen" as CFString, &fs) == .success,
           let flag = fs as? Bool, flag { return true }
        return false
    }

    /// Best-effort URL of the frontmost browser tab (via the AXURL attribute that
    /// Safari/Chrome/etc. expose on the web area/window). nil for non-browsers or
    /// when unreadable → caller fails open. Used for web-password domain stand-down.
    static func frontmostURL() -> URL? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var win: AnyObject?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
           let w = win, let u = url(from: w as! AXUIElement) { return u }
        if let el = focusedElement(), let u = url(from: el) { return u }
        return nil
    }

    private static func url(from el: AXUIElement) -> URL? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, "AXURL" as CFString, &v) == .success, let v else { return nil }
        if let u = v as? URL { return u }
        if let u = v as? NSURL { return u as URL }
        if let s = v as? String { return URL(string: s) }
        return nil
    }

    // AX rects use top-left origin; Cocoa windows use bottom-left.
    private static func flipToCocoa(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let totalHeight = primary.frame.maxY
        return CGRect(x: rect.origin.x, y: totalHeight - rect.origin.y - rect.height,
                      width: rect.width, height: rect.height)
    }
}
