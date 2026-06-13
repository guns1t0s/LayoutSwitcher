import Foundation

/// Loads the bundled RU/EN word lists into two `LanguageModel`s, plus optional
/// frequency-ranked lists used to break ties between two valid readings.
/// Read-only at runtime; lists ship in the app bundle (NFR-5).
public final class Dictionaries: @unchecked Sendable {
    public let ru: LanguageModel
    public let en: LanguageModel
    /// word → 1-based frequency rank (lower = more common). Empty if no list.
    private let ruFreq: [String: Int]
    private let enFreq: [String: Int]

    public init(ru: LanguageModel, en: LanguageModel,
                ruFreq: [String: Int] = [:], enFreq: [String: Int] = [:]) {
        self.ru = ru
        self.en = en
        self.ruFreq = ruFreq
        self.enFreq = enFreq
    }

    public func model(for layout: Layout) -> LanguageModel { layout == .ru ? ru : en }

    /// Frequency rank of `word` in `layout` (1 = most common), or nil if absent.
    public func freqRank(_ word: String, _ layout: Layout) -> Int? {
        (layout == .ru ? ruFreq : enFreq)[word.lowercased()]
    }

    /// Load from the SwitcherCore resource bundle. Falls back to empty models
    /// (fail-open: detection simply becomes conservative) if a list is missing.
    public static func loadBundled() -> Dictionaries {
        Dictionaries(
            ru: LanguageModel(layout: .ru, words: readList("ru_words")),
            en: LanguageModel(layout: .en, words: readList("en_words")),
            ruFreq: rankMap(readList("ru_freq")),
            enFreq: rankMap(readList("en_freq"))
        )
    }

    /// For tests / corpus import.
    public static func from(ruWords: [String], enWords: [String],
                            ruFreq: [String] = [], enFreq: [String] = []) -> Dictionaries {
        Dictionaries(
            ru: LanguageModel(layout: .ru, words: ruWords),
            en: LanguageModel(layout: .en, words: enWords),
            ruFreq: rankMap(ruFreq), enFreq: rankMap(enFreq)
        )
    }

    /// Ordered list → word:rank map (first occurrence wins, preserving order).
    private static func rankMap(_ ordered: [String]) -> [String: Int] {
        var m = [String: Int]()
        for (i, w) in ordered.enumerated() {
            let k = w.lowercased()
            if m[k] == nil { m[k] = i + 1 }
        }
        return m
    }

    private static func readList(_ name: String) -> [String] {
        // Try the SwiftPM resource bundle (dev / tests) then the host app's
        // Resources (packaged .app copies the raw .txt there). Fail-open: empty.
        let candidates = [
            Bundle.module.url(forResource: name, withExtension: "txt"),
            Bundle.main.url(forResource: name, withExtension: "txt"),
        ]
        guard let url = candidates.compactMap({ $0 }).first,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" })
            .map(String.init)
    }
}
