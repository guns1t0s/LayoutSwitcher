import XCTest
@testable import SwitcherCore

final class DictionariesTests: XCTestCase {

    /// Guards against shipping a corrupt/empty word list (which would silently
    /// disable detection). CI fails if the bundled dictionaries don't load.
    func testBundledDictionariesAreLoaded() {
        let d = Dictionaries.loadBundled()
        XCTAssertGreaterThan(d.ru.wordCount, 5000, "RU dictionary failed to load")
        XCTAssertGreaterThan(d.en.wordCount, 2000, "EN dictionary failed to load")
        // Frequency lists present and ranked.
        XCTAssertNotNil(d.freqRank("не", .ru), "RU frequency list missing")
        XCTAssertNotNil(d.freqRank("the", .en), "EN frequency list missing")
    }

    func testMorphologyRecognizesKnownStemInflections() {
        let ru = Dictionaries.loadBundled().ru
        XCTAssertTrue(ru.looksLikeInflection("вопросами"))   // stem "вопрос" is known
        XCTAssertTrue(ru.looksLikeInflection("системами"))
        XCTAssertFalse(ru.looksLikeInflection("qwerty"))
        XCTAssertFalse(ru.looksLikeInflection("zzzzzz"))
    }

    func testHeadlineConversionsFromBundled() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        XCTAssertEqual(e.evaluate("ghbdtn").converted, "привет")
        XCTAssertFalse(e.evaluate("trust").shouldConvert)
    }
}
