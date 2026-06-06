import XCTest
@testable import SwitcherCore

final class LanguageModelTests: XCTestCase {

    func testContainsIsCaseInsensitive() {
        let m = LanguageModel(layout: .en, words: ["Hello", "world"])
        XCTAssertTrue(m.contains("hello"))
        XCTAssertTrue(m.contains("HELLO"))
        XCTAssertFalse(m.contains("nope"))
        XCTAssertEqual(m.wordCount, 2)
    }

    func testEmptyModelIsSafe() {
        let m = LanguageModel(layout: .ru, words: [])
        XCTAssertEqual(m.wordCount, 0)
        XCTAssertFalse(m.contains("x"))
        XCTAssertTrue(m.score("привет").isFinite)   // floor, never NaN/inf
    }

    func testNativeStringScoresHigherUnderItsOwnModel() {
        let ru = LanguageModel(layout: .ru, words: ["привет", "проверка", "программа", "пример"])
        let en = LanguageModel(layout: .en, words: ["hello", "world", "program", "sample"])
        // A cyrillic word is far more probable under the RU model than the EN one.
        XCTAssertGreaterThan(ru.score("привет"), en.score("привет"))
        // A latin word is more probable under the EN model.
        XCTAssertGreaterThan(en.score("hello"), ru.score("hello"))
    }

    func testInVocabularyScoresAboveRandom() {
        let en = LanguageModel(layout: .en, words: ["hello", "world", "release", "report", "server"])
        XCTAssertGreaterThan(en.score("report"), en.score("xqzwk"))
    }
}
