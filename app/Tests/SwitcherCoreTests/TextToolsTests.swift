import XCTest
@testable import SwitcherCore

final class TextToolsTests: XCTestCase {

    // FR-23
    func testToLatin() {
        XCTAssertEqual(Transliterator.toLatin("привет"), "privet")
        XCTAssertEqual(Transliterator.toLatin("щука"), "shchuka")
        XCTAssertEqual(Transliterator.toLatin("хорошо"), "khorosho")
        XCTAssertEqual(Transliterator.toLatin("Москва"), "Moskva")
    }

    func testToCyrillicRoundTripCore() {
        // Unambiguous subset round-trips.
        XCTAssertEqual(Transliterator.toCyrillic("privet"), "привет")
        XCTAssertEqual(Transliterator.toCyrillic("shchuka"), "щука")
    }

    func testTransliterateAutoDirection() {
        XCTAssertEqual(Transliterator.transliterate("привет"), "privet")
        XCTAssertEqual(Transliterator.transliterate("privet"), "привет")
    }

    // FR-24
    func testCaseCycle() {
        XCTAssertEqual(CaseConverter.cycle("hello world"), "HELLO WORLD")
        XCTAssertEqual(CaseConverter.cycle("HELLO WORLD"), "Hello World")
        XCTAssertEqual(CaseConverter.cycle("Hello World"), "hello world")
    }

    func testCaseApply() {
        XCTAssertEqual(CaseConverter.apply(.title, to: "the quick fox"), "The Quick Fox")
        XCTAssertEqual(CaseConverter.apply(.upper, to: "abc"), "ABC")
    }

    // FR-25
    func testFixDoubleCapital() {
        XCTAssertEqual(TextFixes.fixDoubleCapital("HEllo"), "Hello")
        XCTAssertEqual(TextFixes.fixDoubleCapital("Hello"), "Hello")     // unchanged
        XCTAssertEqual(TextFixes.fixDoubleCapital("API"), "API")         // all-caps unchanged
    }

    func testFixCapsLock() {
        XCTAssertEqual(TextFixes.fixCapsLock("tHE"), "The")
        XCTAssertEqual(TextFixes.fixCapsLock("pRIVET"), "Privet")
        XCTAssertEqual(TextFixes.fixCapsLock("Hello"), "Hello")          // normal unchanged
    }

    // FR-26
    func testSnippetExpand() {
        let map = ["api": "Application Programming Interface", "брб": "буду рядом быстро"]
        XCTAssertEqual(Snippets.expand("api", using: map), "Application Programming Interface")
        XCTAssertEqual(Snippets.expand("API", using: map), "Application Programming Interface")
        XCTAssertNil(Snippets.expand("xyz", using: map))
    }
}
