import XCTest
@testable import SwitcherCore

final class KeyMapTests: XCTestCase {

    func testEnToRuWords() {
        XCTAssertEqual(KeyMap.convert("ghbdtn", to: .ru), "привет")
        XCTAssertEqual(KeyMap.convert("ntrcn", to: .ru), "текст")
    }

    func testRuToEnWords() {
        XCTAssertEqual(KeyMap.convert("екгые", to: .en), "trust")
        XCTAssertEqual(KeyMap.convert("ыцшесрук", to: .en), "switcher")
    }

    func testRoundTripPreservesEverything() {
        // Every latin char round-trips through RU and back unchanged.
        let s = "the quick brown fox jumps; api2 build-test."
        let ru = KeyMap.convert(s, to: .ru)
        let back = KeyMap.convert(ru, to: .en)
        XCTAssertEqual(back, s)
    }

    func testCasePreserved() {
        XCTAssertEqual(KeyMap.convert("Ghbdtn", to: .ru), "Привет")
        XCTAssertEqual(KeyMap.convert("GHBDTN", to: .ru), "ПРИВЕТ")
    }

    func testDigitsAndSpacePassThrough() {
        XCTAssertEqual(KeyMap.convert("abc 123", to: .ru), "фис 123")
    }

    func testSpecialSymbols() {
        // @ mention typed on RU layout ("=Shift+2) round-trips to @.
        XCTAssertEqual(KeyMap.convert("@anikonorov", to: .ru), "\"фтшлщтщкщм")
        XCTAssertEqual(KeyMap.convert("\"фтшлщтщкщм", to: .en), "@anikonorov")
        // Shifted number-row symbols that differ between layouts.
        XCTAssertEqual(KeyMap.convert("@#$^&", to: .ru), "\"№;:?")
        XCTAssertEqual(KeyMap.convert("\"№;:?", to: .en), "@#$^&")
        // Identical ones pass through.
        XCTAssertEqual(KeyMap.convert("!%*()", to: .ru), "!%*()")
    }

    func testDominantLayout() {
        XCTAssertEqual("привет".dominantLayout, .ru)
        XCTAssertEqual("hello".dominantLayout, .en)
        XCTAssertNil("123".dominantLayout)
        XCTAssertEqual("api2".dominantLayout, .en)
    }
}
