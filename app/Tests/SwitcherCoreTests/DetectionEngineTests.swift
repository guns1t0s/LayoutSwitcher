import XCTest
@testable import SwitcherCore

final class DetectionEngineTests: XCTestCase {

    private func engine(ru: [String], en: [String],
                        config: DetectionEngine.Config = .init()) -> DetectionEngine {
        DetectionEngine(dictionaries: .from(ruWords: ru, enWords: en), config: config)
    }

    // Headline: wrong-layout word gets fixed (uses the real bundled lists).
    func testConvertsWrongLayoutRussianWord() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        let d = e.evaluate("ghbdtn")
        XCTAssertTrue(d.shouldConvert)
        XCTAssertEqual(d.to, .ru)
        XCTAssertEqual(d.converted, "привет")
        XCTAssertEqual(d.reason, .altIsWord)
    }

    // #1 acceptance criterion: never corrupt already-correct text.
    func testLeavesValidEnglishWordAlone() {
        let e = engine(ru: ["привет"], en: ["trust", "fetch"])
        XCTAssertFalse(e.evaluate("trust").shouldConvert)
        XCTAssertFalse(e.evaluate("fetch").shouldConvert)
        XCTAssertEqual(e.evaluate("trust").reason, .typedIsValidWord)
    }

    // Valid in BOTH layouts → leave it (when-in-doubt-do-nothing).
    func testAmbiguousLeftUntouchedByDefault() {
        let e = engine(ru: ["мама"], en: ["vfvf"])     // "vfvf" -> "мама"
        let d = e.evaluate("vfvf")
        XCTAssertFalse(d.shouldConvert)
        XCTAssertEqual(d.reason, .ambiguousBothValid)
    }

    func testExceptionsAreNeverConverted() {
        let e = engine(ru: ["привет"], en: [])
        e.exceptions = ["ghbdtn", "привет"]
        XCTAssertFalse(e.evaluate("ghbdtn").shouldConvert)
        XCTAssertEqual(e.evaluate("ghbdtn").reason, .excepted)
    }

    func testLearnedRevertStopsConversion() {
        let e = engine(ru: ["привет"], en: [])
        e.learnedReverts = ["привет"]
        XCTAssertFalse(e.evaluate("ghbdtn").shouldConvert)
    }

    func testWhitelistForcesLatinFromCyrillic() {
        let e = engine(ru: [], en: [])
        e.whitelistLatin = ["api"]
        let d = e.evaluate("фзш")                       // "фзш" -> "api"
        XCTAssertTrue(d.shouldConvert)
        XCTAssertEqual(d.to, .en)
        XCTAssertEqual(d.converted, "api")
        XCTAssertEqual(d.reason, .whitelistedLatin)
    }

    func testCaseShapePreserved() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        XCTAssertEqual(e.evaluate("Ghbdtn").converted, "Привет")
        XCTAssertEqual(e.evaluate("GHBDTN").converted, "ПРИВЕТ")
    }

    func testShortGarbageIsNoop() {
        let e = engine(ru: [], en: [])
        let d = e.evaluate("qw")                        // 2 letters, no dict hit
        XCTAssertFalse(d.shouldConvert)
        XCTAssertEqual(d.reason, .tooShort)
    }

    func testNoLettersIsNoop() {
        let e = engine(ru: [], en: [])
        XCTAssertFalse(e.evaluate("123").shouldConvert)
    }

    func testLearnedWordTreatedAsDictionary() {
        let e = engine(ru: [], en: [])
        XCTAssertFalse(e.evaluate("dhjlt").shouldConvert)   // unknown → leave it
        e.learnedWords = ["вроде"]                          // learned from manual fixes
        let d = e.evaluate("dhjlt")
        XCTAssertTrue(d.shouldConvert)
        XCTAssertEqual(d.converted, "вроде")
        XCTAssertEqual(d.reason, .altIsWord)
    }

    // Russian word typed on EN layout whose letters include punctuation-keys
    // ("б"→",") must convert WHOLE, not fragment.
    func testFragmentedRussianWordConvertsWhole() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        let d = e.evaluate("j,hfnyj")          // обратно (comma = б)
        XCTAssertTrue(d.shouldConvert)
        XCTAssertEqual(d.converted, "обратно")
    }

    // A real trailing period stays a period (not converted to the letter "ю").
    func testTrailingPunctuationPreserved() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        let d = e.evaluate("ghbdtn.")
        XCTAssertTrue(d.shouldConvert)
        XCTAssertEqual(d.converted, "привет.")
    }
}
