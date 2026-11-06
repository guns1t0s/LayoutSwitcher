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

    // Shifted number-row symbols that DIFFER between layouts (same physical key),
    // as on Russian – PC; `install` overrides them with the real layouts:
    //   Shift+2 @↔"   Shift+3 #↔№   Shift+4 $↔;   Shift+6 ^↔:   Shift+7 &↔?
    // The matching ones (! % * ( )) are identical → they pass through unchanged.
    static let enSym = "@#$^&"
    static let ruSym = "\"№;:?"

    private static let standardEnToRu: [Character: Character] = buildMap(from: enLower + enUpper + enSym,
                                                                         to: ruLower + ruUpper + ruSym)
    private static let standardRuToEn: [Character: Character] = buildMap(from: ruLower + ruUpper + ruSym,
                                                                         to: enLower + enUpper + enSym)

    private static func buildMap(from: String, to: String) -> [Character: Character] {
        var m = [Character: Character]()
        for (a, b) in zip(from, to) { m[a] = b }
        // Digits and space are identical on both layouts — pass them through so
        // mixed tokens ("api2") round-trip cleanly.
        for c in "0123456789 " { m[c] = c }
        return m
    }

    /// One physical key as the two layouts render it, bare and with ⇧.
    public struct Key: Equatable, Sendable {
        public let code: Int
        public let en: Character, enShift: Character
        public let ru: Character, ruShift: Character
        public init(code: Int, en: Character, enShift: Character, ru: Character, ruShift: Character) {
            self.code = code
            self.en = en; self.enShift = enShift
            self.ru = ru; self.ruShift = ruShift
        }
    }

    /// Keys outside the letter block of Russian – PC, the layout the reference
    /// strings describe. `install` replaces this with what the Mac really has.
    private static let standardSymbolKeys: [Int: Key] = {
        let rows: [(Int, Character, Character, Character, Character)] = [
            (50, "`", "~", "ё", "Ё"), (19, "2", "@", "2", "\""), (20, "3", "#", "3", "№"),
            (21, "4", "$", "4", ";"), (22, "6", "^", "6", ":"), (26, "7", "&", "7", "?"),
            (33, "[", "{", "х", "Х"), (30, "]", "}", "ъ", "Ъ"), (41, ";", ":", "ж", "Ж"),
            (39, "'", "\"", "э", "Э"), (43, ",", "<", "б", "Б"), (47, ".", ">", "ю", "Ю"),
            (44, "/", "?", ".", ","),
        ]
        var m = [Int: Key]()
        for r in rows { m[r.0] = Key(code: r.0, en: r.1, enShift: r.2, ru: r.3, ruShift: r.4) }
        return m
    }()

    private static var enToRu = standardEnToRu
    private static var ruToEn = standardRuToEn
    private static var symbolKeys = standardSymbolKeys

    /// Punctuation a Russian layout gives on its own keys. Typed on that layout it
    /// was meant as punctuation: on the way to English it stays, it does not turn
    /// into whatever the same key gives there ("Й:" is "Q:", not "Q^").
    private static let sentencePunctuation: Set<Character> = [",", ".", ":", ";", "?", "!", "%"]

    /// Use the layouts this Mac really has. macOS' own "Russian" differs from
    /// Russian – PC outside the letters: ё sits on the "\\" key, the key left of 1
    /// gives "]" and "[", the number row gives % : , . ; on ⇧4…⇧8 and "/" stays "/".
    /// With the PC tables "```" typed on the RU layout ("]]]") could not be fixed
    /// by hand at all. Call once at launch, on the main thread.
    public static func install(_ keys: [Key]) {
        var e2r = standardEnToRu, r2e = standardRuToEn
        var symbols = [Int: Key]()
        for k in keys {
            for (en, ru) in [(k.en, k.ru), (k.enShift, k.ruShift)] {
                e2r[en] = ru
                r2e[ru] = sentencePunctuation.contains(ru) ? ru : en
            }
            if !k.en.isLetter { symbols[k.code] = k }
        }
        enToRu = e2r; ruToEn = r2e; symbolKeys = symbols
    }

    /// Back to the tables of the reference strings.
    public static func resetToStandard() {
        enToRu = standardEnToRu; ruToEn = standardRuToEn; symbolKeys = standardSymbolKeys
    }

    /// Reinterpret `text` as if the *other* layout had been active.
    /// Characters with no mapping (already cross-layout, e.g. emoji) pass through.
    public static func convert(_ text: String, to target: Layout) -> String {
        let table = (target == .ru) ? enToRu : ruToEn
        return String(text.map { table[$0] ?? $0 })
    }

    /// Read a non-letter keystroke in the layout that is really active. A keyboard
    /// event can carry the text of the previous layout for a minute after a switch.
    /// Letters give themselves away by script; "," does not, yet on the RU layout
    /// that key is the letter б. Only the glyph this very key has in the other
    /// layout is replaced, so synthetic events and foreign layouts pass unchanged.
    public static func realignSymbol(_ chars: String, keycode: Int, shift: Bool,
                                     capsLock: Bool = false, to layout: Layout) -> String {
        guard chars.count == 1, let c = chars.first, let k = symbolKeys[keycode] else { return chars }
        let here = layout == .ru ? (shift ? k.ruShift : k.ru) : (shift ? k.enShift : k.en)
        let there = layout == .ru ? (shift ? k.enShift : k.en) : (shift ? k.ruShift : k.ru)
        guard c == there, here != there else { return chars }
        return capsLock ? String(here).uppercased() : String(here)
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
