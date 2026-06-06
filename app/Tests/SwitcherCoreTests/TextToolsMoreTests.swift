import XCTest
@testable import SwitcherCore

final class TextToolsMoreTests: XCTestCase {

    func testTranslitMultigraphs() {
        XCTAssertEqual(Transliterator.toLatin("ёж"), "yozh")
        XCTAssertEqual(Transliterator.toLatin("цирк"), "tsirk")
        XCTAssertEqual(Transliterator.toLatin("чай"), "chay")
        XCTAssertEqual(Transliterator.toCyrillic("yozh"), "ёж")
        XCTAssertEqual(Transliterator.toCyrillic("moskva"), "москва")
    }

    func testTranslitEmpty() {
        XCTAssertEqual(Transliterator.transliterate(""), "")
    }

    func testCaseApplyLower() {
        XCTAssertEqual(CaseConverter.apply(.lower, to: "HeLLo"), "hello")
    }

    func testCaseCycleMixedGoesLower() {
        XCTAssertEqual(CaseConverter.cycle("HeLLo"), "hello")
    }

    func testFixDoubleCapitalTooShortUnchanged() {
        XCTAssertEqual(TextFixes.fixDoubleCapital("HI"), "HI")
    }

    func testFixCapsLockSingleLetterUnchanged() {
        XCTAssertEqual(TextFixes.fixCapsLock("a"), "a")
    }

    func testSnippetCaseInsensitiveFallback() {
        let map = ["api": "Application Programming Interface"]
        XCTAssertEqual(Snippets.expand("Api", using: map), "Application Programming Interface")
    }
}
