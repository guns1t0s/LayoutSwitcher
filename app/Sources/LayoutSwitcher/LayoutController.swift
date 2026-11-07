import Foundation
import AppKit
import Carbon
import CoreGraphics
import SwitcherCore

/// Reads/sets the system keyboard layout (TIS) and executes text replacement.
/// Replacement strategy is synthetic Backspace + Unicode insert — works in
/// every app including Electron/terminals where AXValue writes fail (S0.2).
/// Every posted event is tagged `K.syntheticTag` so our own tap skips it.
class LayoutController {

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

    /// REL-4: an input METHOD (CJK/Vietnamese/etc.) is active rather than a plain
    /// keyboard layout. During IME composition the raw keys are not real text —
    /// we must stand down (this switcher only handles RU/EN plain layouts).
    func isInputMethodActive() -> Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceType) else {
            return false
        }
        let type = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        return type != (kTISTypeKeyboardLayout as String)   // plain layout = safe
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
        down.flags = []; up.flags = []          // never inherit a held modifier
        down.setIntegerValueField(.eventSourceUserData, value: K.syntheticTag)
        up.setIntegerValueField(.eventSourceUserData, value: K.syntheticTag)
        send(down)
        send(up)
    }

    // MARK: - when a rewrite runs

    /// Run a rewrite where its events go in ahead of every key not seen yet: in the tap
    /// callback, this one when we are in it, else the next (`InputCapture.later`). With
    /// no callback to come, right away: then no key waits at the tap either.
    func inCallback(_ body: @escaping () -> Void) {
        if InputCapture.proxy != nil || !InputCapture.later(body) { body() }
    }

    /// Run a rewrite once the event of this callback has gone on to the app, ahead of the
    /// next one. A snippet needs its boundary key in the field first.
    func afterThisEvent(_ body: @escaping () -> Void) {
        if !InputCapture.later(body) { DispatchQueue.main.async(execute: body) }
    }

    /// Into the event stream. Posted the ordinary way, an event comes back through
    /// our own tap and queues behind every key already waiting there. A rewrite counts
    /// its Backspaces for the screen as it is now, so landing behind the next letters
    /// it deleted those instead: with two keys waiting "ghbdtn" came out as "gрприв".
    /// From inside the callback an event goes in at the tap, ahead of all of them, and
    /// every rewrite runs there (`inCallback`). The ordinary way is left for a run with
    /// no tap, where nothing waits.
    private func send(_ event: CGEvent) {
        if let proxy = InputCapture.proxy {
            event.flags.insert(Self.posted)
            event.tapPostEvent(proxy)
        } else {
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// The flag CGEventPost puts on every event it posts (bit 29, not in the headers;
    /// SLEventPost sets it on this Mac, SLEventTapPostEvent does not). Without it the
    /// window server takes our event for the key itself, and an insertion made on key 0
    /// while the A key is still held can come out as that key's autorepeat, which apps
    /// throw away. With it the events go out flagged exactly as they did before.
    private static let posted = CGEventFlags(rawValue: 0x2000_0000)

    private func postKey(virtualKey: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false) else { return }
        // Explicit flags so a physically-held ⇧ (from the double-⇧ gesture) is
        // NOT applied to our Backspaces — that left the first letter unconverted.
        down.flags = flags; up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: K.syntheticTag)
        up.setIntegerValueField(.eventSourceUserData, value: K.syntheticTag)
        send(down)
        send(up)
    }

    /// Replace the CURRENTLY SELECTED text with `text` synthetically: one
    /// Backspace deletes the whole active selection, then insert the new text.
    /// Works where AX selection writes silently no-op (Electron/Chromium) and
    /// never touches the clipboard. Caller must have confirmed a live selection.
    func replaceSelection(with text: String) {
        postKey(virtualKey: 51, flags: [])      // Backspace → clears the selection
        if !text.isEmpty { insert(text) }
    }

    // MARK: - the real keyboard layouts

    /// Every key of the main block as this Mac's own EN and RU layouts render it,
    /// bare and with ⇧ (`KeyMap.install`). Empty when either layout is missing or
    /// has no key table: the tables of KeyMap stay then.
    func physicalKeys() -> [SwitcherCore.KeyMap.Key] {
        guard let en = keyTable(for: .en), let ru = keyTable(for: .ru) else { return [] }
        let notText: Set<Int> = [10, 36, 48, 49]     // § (ISO), Return, Tab, Space
        var keys = [SwitcherCore.KeyMap.Key]()
        for code in 0...50 where !notText.contains(code) {
            guard let e = glyph(en, code, shift: false), let eS = glyph(en, code, shift: true),
                  let r = glyph(ru, code, shift: false), let rS = glyph(ru, code, shift: true) else { continue }
            keys.append(.init(code: code, en: e, enShift: eS, ru: r, ruShift: rS))
        }
        return keys
    }

    private func keyTable(for layout: Layout) -> CFData? {
        guard let source = inputSource(for: layout),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
    }

    private func glyph(_ table: CFData, _ code: Int, shift: Bool) -> Character? {
        guard let bytes = CFDataGetBytePtr(table) else { return nil }
        let keyboard = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(keyboard, UInt16(code), UInt16(kUCKeyActionDown),
                                    shift ? UInt32(shiftKey >> 8) : 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        guard status == noErr, length == 1, chars[0] >= 0x20, chars[0] != 0x7F else { return nil }
        return String(utf16CodeUnits: chars, count: 1).first
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
        // Prefer an ASCII-capable / selectable source for the language: a real
        // keyboard layout over an input method or dictation source of that language.
        let candidates = list.filter { src in
            isSelectable(src) && languages(of: src).contains { $0.hasPrefix(want) }
        }
        return candidates.first { TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) != nil }
            ?? candidates.first
    }
}
