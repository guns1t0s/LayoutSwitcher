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
    /// English acronyms (lowercase) that may be converted from an ALL-CAPS
    /// cyrillic token (СУЩ → CEO). Pre-gated at build time: each one's cyrillic
    /// twin contains a letter no Russian word starts with, or was observed as a
    /// real manual fix — so it cannot be a Russian abbreviation.
    public let acronymsEN: Set<String>
    /// Russian abbreviations the user types in caps (УК, БА, ИБ, ЦФА...). Never
    /// converted by the acronym rule — a runtime backstop to the build-time gate.
    public let acronymsRU: Set<String>

    public init(ru: LanguageModel, en: LanguageModel,
                ruFreq: [String: Int] = [:], enFreq: [String: Int] = [:],
                acronymsEN: Set<String> = [], acronymsRU: Set<String> = []) {
        self.ru = ru
        self.en = en
        self.ruFreq = ruFreq
        self.enFreq = enFreq
        self.acronymsEN = acronymsEN
        self.acronymsRU = acronymsRU
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
            enFreq: rankMap(readList("en_freq")),
            acronymsEN: Set(readList("en_acronyms").map { $0.lowercased() }),
            acronymsRU: Set(readList("ru_acronyms").map { $0.lowercased() })
        )
    }

    /// For tests / corpus import.
    public static func from(ruWords: [String], enWords: [String],
                            ruFreq: [String] = [], enFreq: [String] = [],
                            acronymsEN: [String] = [], acronymsRU: [String] = []) -> Dictionaries {
        Dictionaries(
            ru: LanguageModel(layout: .ru, words: ruWords),
            en: LanguageModel(layout: .en, words: enWords),
            ruFreq: rankMap(ruFreq), enFreq: rankMap(enFreq),
            acronymsEN: Set(acronymsEN), acronymsRU: Set(acronymsRU)
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
        // Bundle.main FIRST, and Bundle.module only lazily (the `??` autoclosure):
        // in the packaged .app there is no SwiftPM resource bundle, and merely
        // touching `Bundle.module` there is a fatalError. The old eager array did
        // touch it — it only survived because the accessor fell back to a path
        // baked in at compile time, i.e. the app was silently reading its
        // dictionaries from the BUILD directory. A toolchain update moved that
        // directory and the app crashed at launch.
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt")
                ?? Bundle.module.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" })
            .map(String.init)
    }
}
