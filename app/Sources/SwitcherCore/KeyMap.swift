import Foundation

/// Bidirectional character mapping between the EN (QWERTY) and RU (ЙЦУКЕН)
/// keyboard layouts, keyed by the *physical* key. Used to reinterpret a word
/// that was typed in the wrong layout.
///
/// The four reference strings below are aligned character-by-character: index
/// `i` of `enLower` sits on the same physical key as index `i` of `ruLower`.
public enum KeyMap {

    // Physical-key aligned. EN char  <->  RU char on the same key.
    //                        `1234567890-=  ...letters...
    static let enLower = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./"
    static let ruLower = "ёйцукенгшщзхъфывапролджэячсмитьбю."
    static let enUpper = "~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?"
    static let ruUpper = "ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,"

    private static let enToRu: [Character: Character] = buildMap(from: enLower + enUpper,
                                                                 to: ruLower + ruUpper)
    private static let ruToEn: [Character: Character] = buildMap(from: ruLower + ruUpper,
                                                                 to: enLower + enUpper)

    private static func buildMap(from: String, to: String) -> [Character: Character] {
        var m = [Character: Character]()
        for (a, b) in zip(from, to) { m[a] = b }
        // Digits and space are identical on both layouts — pass them through so
        // mixed tokens ("api2") round-trip cleanly.
        for c in "0123456789 " { m[c] = c }
        return m
    }

    /// Reinterpret `text` as if the *other* layout had been active.
    /// Characters with no mapping (already cross-layout, e.g. emoji) pass through.
    public static func convert(_ text: String, to target: Layout) -> String {
        let table = (target == .ru) ? enToRu : ruToEn
        return String(text.map { table[$0] ?? $0 })
    }

    /// Convert from an explicitly known source layout to the other one.
    public static func swap(_ text: String, from source: Layout) -> String {
        convert(text, to: source == .ru ? .en : .ru)
    }
}

public enum Layout: String, Codable, Sendable, CaseIterable {
    case ru
    case en

    public var other: Layout { self == .ru ? .en : .ru }
    public var short: String { self == .ru ? "RU" : "EN" }
}

public extension Character {
    /// Cyrillic letter (incl. ё/Ё).
    var isCyrillic: Bool {
        guard let s = unicodeScalars.first else { return false }
        return (s.value >= 0x0410 && s.value <= 0x044F) || s == "ё" || s == "Ё"
    }
    /// Basic Latin letter.
    var isLatinLetter: Bool {
        ("a"..."z").contains(self) || ("A"..."Z").contains(self)
    }
}

public extension String {
    /// Dominant script of the token, ignoring digits/punctuation.
    var dominantLayout: Layout? {
        var ru = 0, en = 0
        for c in self {
            if c.isCyrillic { ru += 1 }
            else if c.isLatinLetter { en += 1 }
        }
        if ru == 0 && en == 0 { return nil }
        return ru >= en ? .ru : .en
    }

    var letterCount: Int { reduce(0) { $0 + ($1.isCyrillic || $1.isLatinLetter ? 1 : 0) } }
}
