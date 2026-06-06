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

    /// Characters that end a word.
    private func isBoundary(_ c: Character) -> Bool {
        c == " " || c == "\n" || c == "\t" || c == "\r"
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

    public var isEmpty: Bool { word.isEmpty }
}
