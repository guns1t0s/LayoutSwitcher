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
        XCTAssertEqual(KeyMap.convert("@user", to: .ru), "\"гыук")
        XCTAssertEqual(KeyMap.convert("\"гыук", to: .en), "@user")
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

/// The macOS "Russian" layout, as `LayoutController.physicalKeys()` reads it, on
/// the keys where it differs from Russian – PC, plus the keys the tests touch.
private let macRussianKeys: [KeyMap.Key] = [
    .init(code: 50, en: "`", enShift: "~", ru: "]", ruShift: "["),
    .init(code: 42, en: "\\", enShift: "|", ru: "ё", ruShift: "Ё"),
    .init(code: 44, en: "/", enShift: "?", ru: "/", ruShift: "?"),
    .init(code: 19, en: "2", enShift: "@", ru: "2", ruShift: "\""),
    .init(code: 20, en: "3", enShift: "#", ru: "3", ruShift: "№"),
    .init(code: 21, en: "4", enShift: "$", ru: "4", ruShift: "%"),
    .init(code: 23, en: "5", enShift: "%", ru: "5", ruShift: ":"),
    .init(code: 22, en: "6", enShift: "^", ru: "6", ruShift: ","),
    .init(code: 26, en: "7", enShift: "&", ru: "7", ruShift: "."),
    .init(code: 28, en: "8", enShift: "*", ru: "8", ruShift: ";"),
    .init(code: 33, en: "[", enShift: "{", ru: "х", ruShift: "Х"),
    .init(code: 30, en: "]", enShift: "}", ru: "ъ", ruShift: "Ъ"),
    .init(code: 41, en: ";", enShift: ":", ru: "ж", ruShift: "Ж"),
    .init(code: 39, en: "'", enShift: "\"", ru: "э", ruShift: "Э"),
    .init(code: 43, en: ",", enShift: "<", ru: "б", ruShift: "Б"),
    .init(code: 47, en: ".", enShift: ">", ru: "ю", ruShift: "Ю"),
    .init(code: 0, en: "a", enShift: "A", ru: "ф", ruShift: "Ф"),
]

final class RealLayoutTests: XCTestCase {
    override func setUp() { KeyMap.install(macRussianKeys) }
    override func tearDown() { KeyMap.resetToStandard() }

    // The key left of 1 gives "]" and "[" on this layout: a code fence typed there
    // comes out "]]]", and ⇧⇧ has to give it back.
    func testKeyLeftOfOneConvertsPhysically() {
        XCTAssertEqual(KeyMap.convert("]]]", to: .en), "```")
        XCTAssertEqual(KeyMap.convert("[", to: .en), "~")
        XCTAssertEqual(KeyMap.convert("]", to: .ru), "ъ", "the EN key of the same glyph is another key")
    }

    func testLettersOutsideThePCPlacement() {
        XCTAssertEqual(KeyMap.convert("ё", to: .en), "\\")
        XCTAssertEqual(KeyMap.convert("\\", to: .ru), "ё")
        XCTAssertEqual(KeyMap.convert("/", to: .ru), "/")
    }

    // Typed on the Russian layout, these were meant as punctuation.
    func testSentencePunctuationSurvivesTheWayToEnglish() {
        XCTAssertEqual(KeyMap.convert("КЫ Й:", to: .en).suffix(1), ":")
        for c in [",", ".", ":", ";", "?", "%"] { XCTAssertEqual(KeyMap.convert(c, to: .en), c) }
    }

    // ...while on the EN layout the same number row is a Russian mark typed wrong.
    func testNumberRowFromEnglishFollowsTheKey() {
        XCTAssertEqual(KeyMap.convert("^", to: .ru), ",")
        XCTAssertEqual(KeyMap.convert("&", to: .ru), ".")
        XCTAssertEqual(KeyMap.convert("%", to: .ru), ":")
    }

    // Keys that gave punctuation in the stale layout. The letters themselves are
    // covered by script; these are the ones script says nothing about.
    func testStaleEventsRealign() {
        XCTAssertEqual(KeyMap.realignSymbol(",", keycode: 43, shift: false, to: .ru), "б")
        XCTAssertEqual(KeyMap.realignSymbol(".", keycode: 47, shift: false, to: .ru), "ю")
        XCTAssertEqual(KeyMap.realignSymbol(";", keycode: 41, shift: false, to: .ru), "ж")
        XCTAssertEqual(KeyMap.realignSymbol("'", keycode: 39, shift: false, to: .ru), "э")
        XCTAssertEqual(KeyMap.realignSymbol("[", keycode: 33, shift: false, to: .ru), "х")
        XCTAssertEqual(KeyMap.realignSymbol("]", keycode: 30, shift: false, to: .ru), "ъ")
        XCTAssertEqual(KeyMap.realignSymbol("<", keycode: 43, shift: true, to: .ru), "Б")
        XCTAssertEqual(KeyMap.realignSymbol("@", keycode: 19, shift: true, to: .ru), "\"")
        XCTAssertEqual(KeyMap.realignSymbol("^", keycode: 22, shift: true, to: .ru), ",")
        XCTAssertEqual(KeyMap.realignSymbol("\"", keycode: 19, shift: true, to: .en), "@")
        XCTAssertEqual(KeyMap.realignSymbol(",", keycode: 43, shift: false, capsLock: true, to: .ru), "Б")
    }

    func testRealPunctuationStaysPut() {
        XCTAssertEqual(KeyMap.realignSymbol(",", keycode: 22, shift: true, to: .ru), ",", "⇧6 on RU is the real comma")
        XCTAssertEqual(KeyMap.realignSymbol(".", keycode: 26, shift: true, to: .ru), ".", "⇧7 on RU is the real period")
        XCTAssertEqual(KeyMap.realignSymbol(",", keycode: 43, shift: false, to: .en), ",")
        XCTAssertEqual(KeyMap.realignSymbol("-", keycode: 27, shift: false, to: .ru), "-")
        // A synthetic event from another app carries text on a keycode of its own.
        XCTAssertEqual(KeyMap.realignSymbol(",", keycode: 0, shift: false, to: .ru), ",")
        XCTAssertEqual(KeyMap.realignSymbol("hello", keycode: 43, shift: false, to: .ru), "hello")
    }

    // On the way to English the brackets of that key are not sentence punctuation.
    func testBracketsAtTheEdgeOfAWord() {
        let e = DetectionEngine(dictionaries: .from(ruWords: ["слово"], enWords: ["broker"]))
        XCTAssertEqual(e.evaluate("[икщлук").converted, "~broker")
    }

    func testPairedBracketsStayAPair() {
        let e = DetectionEngine(dictionaries: .from(ruWords: ["слово"], enWords: ["broker"]))
        XCTAssertEqual(e.evaluate("[икщлук]").converted, "[broker]")
    }

    // ⇧4 between Russian letters on the macOS layout, by hand: selection or caret.
    func testZhSlipOnTheRealTable() {
        XCTAssertEqual(DetectionEngine.repairInnerZh(KeyMap.convert("ye$ty", to: .ru)), "нужен")
        XCTAssertEqual(DetectionEngine.repairInnerZh("рост 50%"), "рост 50%")
    }

    func testCodeFenceOnTheRussianLayout() {
        let e = DetectionEngine(dictionaries: .from(ruWords: ["слово"], enWords: ["word"]))
        let d = e.evaluatePrefix("]]]")
        XCTAssertEqual(d?.converted, "```")
        XCTAssertEqual(d?.reason, .brackets, "no layout switch: Russian follows")
    }
}

final class StandardLayoutTests: XCTestCase {
    func testRevertedBracketsStay() {
        let e = DetectionEngine(dictionaries: .from(ruWords: ["слово"], enWords: ["word"]))
        XCTAssertEqual(e.evaluatePrefix("хъ")?.converted, "[]")
        e.learnedReverts = ["хъ"]
        XCTAssertNil(e.evaluatePrefix("хъ"))
    }

    func testStaleEventsOnThePCLayout() {
        XCTAssertEqual(KeyMap.realignSymbol(",", keycode: 43, shift: false, to: .ru), "б")
        XCTAssertEqual(KeyMap.realignSymbol("/", keycode: 44, shift: false, to: .ru), ".")
        XCTAssertEqual(KeyMap.realignSymbol("^", keycode: 22, shift: true, to: .ru), ":")
    }

    func testNoFenceWhereTheKeyDoesNotGiveIt() {
        let e = DetectionEngine(dictionaries: .from(ruWords: ["слово"], enWords: ["word"]))
        XCTAssertNil(e.evaluatePrefix("]]]"))
    }
}
