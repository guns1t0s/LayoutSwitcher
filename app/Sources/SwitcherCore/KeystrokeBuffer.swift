import Foundation

/// Accumulates the word currently being typed. Holds the *minimum* needed to
/// analyse the active word and is wiped the instant a boundary/navigation/focus
/// event arrives (SEC-2: no persistent capture of typed text).
public final class KeystrokeBuffer {

    public private(set) var word: String = ""

    /// Result of feeding one keystroke.
    public struct Step {
        /// The completed word emitted at a boundary (without the boundary char),
        /// or nil if no word just finished.
        public let completedWord: String?
        /// The boundary character that closed the word (space/newline/punct), or nil.
        public let boundary: Character?
    }

    public init() {}

    /// Symbols that attach to a word rather than ending it: @mentions, #hashtags,
    /// snake_case, and their RU-layout twins (Shift+2 → ", Shift+3 → №). Keeping
    /// them in the token lets conversion flip "фтшлщтщкщм → @anikonorov" whole.
    private static let wordSymbols: Set<Character> = ["@", "#", "_", "\"", "№"]

    /// Punctuation that is actually a Russian LETTER on the same physical key
    /// (б→"," ж→";" х→"[" ъ→"]" э→"'" ё→"`" ю→"."). When a Russian word is typed
    /// in the wrong (EN) layout these appear mid-word; treating them as
    /// boundaries fragmented the word ("обратно"→"j,hfnyj" split at the comma)
    /// so it never converted. Keep them inside the token instead. Leading/trailing
    /// ones are preserved unconverted by the DetectionEngine (real punctuation).
    private static let softPunct: Set<Character> = [",", ".", ";", "'", "[", "]", "`"]

    /// Characters that end a word.
    private func isBoundary(_ c: Character) -> Bool {
        if KeystrokeBuffer.wordSymbols.contains(c) { return false }
        if KeystrokeBuffer.softPunct.contains(c) { return false }
        return c == " " || c == "\n" || c == "\t" || c == "\r"
            || c.isPunctuation || c.isSymbol
    }

    /// Feed one printable character. Returns the completed word if this char
    /// closed one. The boundary char itself is not added to the buffer.
    public func input(_ c: Character) -> Step {
        if isBoundary(c) {
            let done = word.isEmpty ? nil : word
            word = ""
            return Step(completedWord: done, boundary: c)
        }
        word.append(c)
        return Step(completedWord: nil, boundary: nil)
    }

    /// Backspace: drop the last char of the in-progress word. (If the buffer is
    /// already empty we cannot know what was deleted — caller should treat that
    /// as a reset, since the edit reached into committed text.)
    @discardableResult
    public func backspace() -> Bool {
        if word.isEmpty { return false }
        word.removeLast()
        return true
    }

    /// Navigation / click / focus change / any non-typing edit: drop state.
    public func reset() { word = "" }

    /// Replace the in-progress word (used when a late conversion also rewrote
    /// the first characters of the next word on screen).
    public func replaceWord(_ s: String) { word = s }

    public var isEmpty: Bool { word.isEmpty }
}
