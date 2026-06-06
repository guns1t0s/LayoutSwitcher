import XCTest
@testable import SwitcherCore

/// Regression gate for the #1 acceptance criterion (§9): zero corruption of
/// already-correct text. Uses the real bundled dictionaries.
final class DetectionCorpusTests: XCTestCase {

    private let engine = DetectionEngine(dictionaries: .loadBundled())

    // Correctly-typed words that MUST be left untouched.
    private let correctRU = ["привет", "текст", "спасибо", "вопрос", "ответ",
                             "система", "проект", "релиз", "сервер", "договор",
                             "помощь", "пример", "сообщение"]
    private let correctEN = ["hello", "world", "trust", "fetch", "build", "test",
                             "server", "project", "release", "commit", "merge",
                             "report", "api", "switcher"]

    func testZeroFalsePositivesOnCorrectText() {
        var corrupted: [String] = []
        for w in correctRU + correctEN where engine.evaluate(w).shouldConvert {
            corrupted.append(w)
        }
        XCTAssertEqual(corrupted, [], "false conversions of correct words: \(corrupted)")
    }

    func testWrongLayoutWordsAreFixed() {
        // Type a Russian word on the EN layout → must convert back to it.
        for w in correctRU {
            let typed = KeyMap.convert(w, to: .en)
            let d = engine.evaluate(typed)
            XCTAssertTrue(d.shouldConvert, "did not fix '\(w)' typed as '\(typed)'")
            XCTAssertEqual(d.converted, w)
        }
    }

    func testWrongLayoutEnglishIsFixed() {
        for w in ["trust", "fetch", "server", "report"] {
            let typed = KeyMap.convert(w, to: .ru)        // typed on RU layout
            let d = engine.evaluate(typed)
            XCTAssertTrue(d.shouldConvert, "did not fix '\(w)' typed as '\(typed)'")
            XCTAssertEqual(d.converted, w)
        }
    }

    // Case is preserved across the corpus.
    func testCasePreservedAcrossCorpus() {
        for w in ["привет", "текст", "спасибо"] {
            let typed = KeyMap.convert(w.capitalized, to: .en)
            XCTAssertEqual(engine.evaluate(typed).converted, w.capitalized)
        }
    }
}
