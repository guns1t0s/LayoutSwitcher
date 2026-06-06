import Foundation

/// EPIC 7 text utilities — pure, deterministic, testable. Operate on a selected
/// string; the app layer reads/writes the selection via Accessibility.

// MARK: - Transliteration (FR-23)

public enum Transliterator {
    // Cyrillic → Latin (practical/GOST-ish scheme).
    private static let ruToLat: [(String, String)] = [
        ("щ", "shch"), ("ш", "sh"), ("ч", "ch"), ("ж", "zh"), ("х", "kh"),
        ("ц", "ts"), ("ё", "yo"), ("ю", "yu"), ("я", "ya"), ("й", "y"),
        ("а","a"),("б","b"),("в","v"),("г","g"),("д","d"),("е","e"),("з","z"),
        ("и","i"),("к","k"),("л","l"),("м","m"),("н","n"),("о","o"),("п","p"),
        ("р","r"),("с","s"),("т","t"),("у","u"),("ф","f"),("ы","y"),("э","e"),
        ("ъ",""),("ь",""),
    ]

    public static func toLatin(_ text: String) -> String {
        transform(text) { ch in
            let lower = String(ch).lowercased()
            guard let pair = ruToLat.first(where: { $0.0 == lower }) else { return nil }
            return matchCase(of: ch, to: pair.1)
        }
    }

    public static func toCyrillic(_ text: String) -> String {
        // Longest-match latin → cyrillic (best effort; ambiguous by nature).
        let pairs = ruToLat.filter { !$0.1.isEmpty }.sorted { $0.1.count > $1.1.count }
        var result = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            var matched = false
            for (cyr, lat) in pairs {
                let n = lat.count
                guard i + n <= chars.count else { continue }
                let slice = String(chars[i..<(i + n)])
                if slice.lowercased() == lat {
                    result += matchCase(of: chars[i], to: cyr)
                    i += n; matched = true; break
                }
            }
            if !matched { result.append(chars[i]); i += 1 }
        }
        return result
    }

    /// Detect dominant script and flip to the other (FR-23 toggle).
    public static func transliterate(_ text: String) -> String {
        let cyr = text.reduce(0) { $0 + ($1.isCyrillic ? 1 : 0) }
        let lat = text.reduce(0) { $0 + ($1.isLatinLetter ? 1 : 0) }
        return cyr >= lat ? toLatin(text) : toCyrillic(text)
    }

    private static func transform(_ text: String, _ map: (Character) -> String?) -> String {
        var out = ""
        for ch in text { out += map(ch) ?? String(ch) }
        return out
    }

    private static func matchCase(of source: Character, to target: String) -> String {
        source.isUppercase ? target.prefix(1).uppercased() + target.dropFirst() : target
    }
}

// MARK: - Case change (FR-24)

public enum CaseConverter {
    public enum Mode { case lower, upper, title }

    public static func apply(_ mode: Mode, to text: String) -> String {
        switch mode {
        case .lower: return text.lowercased()
        case .upper: return text.uppercased()
        case .title: return titleCase(text)
        }
    }

    /// Cycle lower → UPPER → Title → lower (FR-24 one-key cycling).
    public static func cycle(_ text: String) -> String {
        if text == text.lowercased() { return text.uppercased() }
        if text == text.uppercased() { return titleCase(text) }
        return text.lowercased()
    }

    private static func titleCase(_ text: String) -> String {
        var out = ""
        var atWordStart = true
        for ch in text {
            if ch.isLetter {
                out += atWordStart ? String(ch).uppercased() : String(ch).lowercased()
                atWordStart = false
            } else {
                out.append(ch)
                atWordStart = true
            }
        }
        return out
    }
}

// MARK: - Typo fixes (FR-25)

public enum TextFixes {
    /// "HEllo" → "Hello": two leading capitals followed by lowercase.
    public static func fixDoubleCapital(_ word: String) -> String {
        let c = Array(word)
        guard c.count >= 3, c[0].isUppercase, c[1].isUppercase, c[2].isLowercase,
              c[0].isLetter, c[1].isLetter else { return word }
        return String(c[0]) + String(c[1]).lowercased() + String(c[2...])
    }

    /// Accidental Caps Lock: "tHE qUICK" → "The Quick". Inverts case when the
    /// word looks case-inverted (first letter lower, the rest mostly upper).
    public static func fixCapsLock(_ word: String) -> String {
        let letters = word.filter { $0.isLetter }
        guard letters.count >= 2, let first = letters.first, first.isLowercase else { return word }
        let rest = letters.dropFirst()
        let upper = rest.filter { $0.isUppercase }.count
        guard Double(upper) / Double(rest.count) >= 0.6 else { return word }
        return String(word.map { c in
            c.isUppercase ? Character(c.lowercased()) :
            (c.isLowercase ? Character(c.uppercased()) : c)
        })
    }
}

// MARK: - Snippets / autoreplace (FR-26)

public enum Snippets {
    /// Expand a finished word if it matches a snippet key (case-insensitive).
    public static func expand(_ word: String, using map: [String: String]) -> String? {
        if let v = map[word] { return v }
        return map[word.lowercased()]
    }
}
