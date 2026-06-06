import Foundation

/// Loads the bundled RU/EN frequency word lists into two `LanguageModel`s.
/// Read-only at runtime; lists ship in the app bundle (NFR-5).
public final class Dictionaries: @unchecked Sendable {
    public let ru: LanguageModel
    public let en: LanguageModel

    public init(ru: LanguageModel, en: LanguageModel) {
        self.ru = ru
        self.en = en
    }

    public func model(for layout: Layout) -> LanguageModel { layout == .ru ? ru : en }

    /// Load from the SwitcherCore resource bundle. Falls back to empty models
    /// (fail-open: detection simply becomes conservative) if a list is missing.
    public static func loadBundled() -> Dictionaries {
        let ruWords = readList("ru_words")
        let enWords = readList("en_words")
        return Dictionaries(
            ru: LanguageModel(layout: .ru, words: ruWords),
            en: LanguageModel(layout: .en, words: enWords)
        )
    }

    /// For tests / corpus import.
    public static func from(ruWords: [String], enWords: [String]) -> Dictionaries {
        Dictionaries(
            ru: LanguageModel(layout: .ru, words: ruWords),
            en: LanguageModel(layout: .en, words: enWords)
        )
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
