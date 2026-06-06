import Foundation
import Carbon
import CoreGraphics
import SwitcherCore

/// Reads/sets the system keyboard layout (TIS) and executes text replacement.
/// Replacement strategy is synthetic Backspace + Unicode insert — works in
/// every app including Electron/terminals where AXValue writes fail (S0.2).
/// Every posted event is tagged `K.syntheticTag` so our own tap skips it.
final class LayoutController {

    private let src = CGEventSource(stateID: .privateState)
    private var sourceCache: [Layout: TISInputSource] = [:]

    // MARK: - read current layout

    func currentLayout() -> Layout? {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        let langs = languages(of: cur)
        if langs.contains(where: { $0.hasPrefix("ru") }) { return .ru }
        if langs.contains(where: { $0.hasPrefix("en") }) { return .en }
        return nil
    }

    // MARK: - switch layout (FR-13 manual, proactive set FR-6)

    @discardableResult
    func select(_ layout: Layout) -> Bool {
        if let cached = sourceCache[layout] {
            return TISSelectInputSource(cached) == noErr
        }
        guard let src = inputSource(for: layout) else { return false }
        sourceCache[layout] = src
        return TISSelectInputSource(src) == noErr
    }

    func toggle() {
        guard let cur = currentLayout() else { return }
        select(cur.other)
    }

    // MARK: - text replacement

    /// Replace the last `deleteCount` characters before the caret with `text`.
    ///
    /// Synthetic Backspace + Unicode insert only. The AX "select range then
    /// overwrite" path was removed: on partial failure it left a live selection,
    /// and the backspace fallback then deleted the selection PLUS `deleteCount`
    /// more chars — eating the previous word. Synthetic is the universal,
    /// non-corrupting path the design (S0.2) picked as primary.
    func replace(deleteCount: Int, with text: String) {
        guard deleteCount >= 0 else { return }
        for _ in 0..<deleteCount { postKey(virtualKey: 51) }   // 51 = Delete/Backspace
        if !text.isEmpty { insert(text) }
    }

    func insert(_ text: String) {
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
        var utf16 = Array(text.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.setIntegerValueField(.eventSourceUserData, value: K.syntheticTag)
        up.setIntegerValueField(.eventSourceUserData, value: K.syntheticTag)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private func postKey(virtualKey: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false) else { return }
        down.setIntegerValueField(.eventSourceUserData, value: K.syntheticTag)
        up.setIntegerValueField(.eventSourceUserData, value: K.syntheticTag)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    // MARK: - TIS helpers

    private func languages(of source: TISInputSource) -> [String] {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return []
        }
        let arr = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue()
        return (arr as? [String]) ?? []
    }

    private func isSelectable(_ source: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable) else {
            return false
        }
        return Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue() == kCFBooleanTrue
    }

    private func inputSource(for layout: Layout) -> TISInputSource? {
        let want = (layout == .ru) ? "ru" : "en"
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any] as CFDictionary
        guard let listPtr = TISCreateInputSourceList(filter, false)?.takeRetainedValue(),
              let list = listPtr as? [TISInputSource] else { return nil }
        // Prefer an ASCII-capable / selectable source for the language.
        return list.first { src in
            isSelectable(src) && languages(of: src).contains { $0.hasPrefix(want) }
        }
    }
}
