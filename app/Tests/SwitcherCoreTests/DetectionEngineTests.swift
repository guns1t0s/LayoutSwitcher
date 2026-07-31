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

    // Regression: the system keyboard layout can lag / be flipped out from under
    // us, so it must NOT override the actual script of the text. Correct Russian
    // (cyrillic) typed while the system layout reads EN must be left alone — not
    // "converted" to itself and flipped, which oscillated the layout every word
    // ("мигание"). The wrong-layout latin word converts regardless of a stale RU
    // system layout.
    func testStaleSystemLayoutDoesNotOscillate() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        // Cyrillic word, system layout desynced to EN → leave it, no flip.
        let correct = e.evaluate("нужно", typedLayout: .en)
        XCTAssertFalse(correct.shouldConvert, "correct Russian must not convert on a lagging system layout")
        // Latin wrong-layout word, system layout desynced to RU → still converts.
        let wrong = e.evaluate("gjyznm", typedLayout: .ru)   // = понять
        XCTAssertTrue(wrong.shouldConvert)
        XCTAssertEqual(wrong.converted, "понять")
        XCTAssertEqual(wrong.to, .ru)
    }

    // Learning guard: ⇧⇧-cycling must not teach wrong-layout garbage. "xnj,s" is
    // the EN-layout image of "чтобы" → NOT learnable; "чтобы" itself is already a
    // dictionary word → not learnable either; a genuinely new token (a name) is.
    func testIsLearnableRejectsWrongLayoutImagesAndKnownWords() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        XCTAssertFalse(e.isLearnable("xnj,s"), "wrong-layout image of чтобы must not be learned")
        XCTAssertFalse(e.isLearnable("чтобы"), "dictionary word needs no learning")
        XCTAssertTrue(e.isLearnable("никоноров"), "new proper name is learnable")
    }

    // Whitelisted acronyms typed in the RU layout convert immediately (ЫЗМ→SPV),
    // including 2-3 letter ones the OOV length gate would normally skip.
    func testWhitelistedAcronymConvertsFromCyrillic() {
        let e = engine(ru: ["привет"], en: [])
        e.whitelistLatin = ["spv", "qa", "rfi"]
        XCTAssertEqual(e.evaluate("ЫЗМ").converted, "SPV")
        XCTAssertTrue(e.evaluate("ЫЗМ").shouldConvert)
        XCTAssertEqual(e.evaluate("ЙФ").converted, "QA")
    }

    // FP guard on the whitelist path: if the cyrillic reading is itself a valid
    // Russian word, lowercase must be left alone (zero-corruption) — but the
    // ALL-CAPS acronym form still converts (КАШ→RFI wanted even though "каш" is
    // a real word form).
    func testWhitelistGuardProtectsRealRussianWords() {
        let e = engine(ru: ["каш"], en: [])
        e.whitelistLatin = ["rfi"]
        XCTAssertFalse(e.evaluate("каш").shouldConvert, "valid RU word must not convert")
        XCTAssertTrue(e.evaluate("КАШ").shouldConvert, "ALL-CAPS acronym form must convert")
        XCTAssertEqual(e.evaluate("КАШ").converted, "RFI")
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

    // Mixed RU+EN token (mid-word layout switch) must never be touched.
    func testMixedScriptLeftAlone() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        let d = e.evaluate("abвгд")
        XCTAssertFalse(d.shouldConvert)
        XCTAssertEqual(d.reason, .mixedScript)
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

    // Trailing "[" is the letter х when the dictionary says so: "vbhjds[" → "мировых".
    func testTrailingSoftPunctAsLetterViaDictionary() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        let d = e.evaluate("vbhjds[")
        XCTAssertTrue(d.shouldConvert)
        XCTAssertEqual(d.converted, "мировых")
        XCTAssertEqual(d.reason, .altIsWord)
    }

    // Trailing "." resolves to ю when that makes a dictionary word: "ltkf." → "делаю".
    func testTrailingPeriodAsYuViaDictionary() {
        let e = DetectionEngine(dictionaries: .from(ruWords: ["делаю"], enWords: []))
        let d = e.evaluate("ltkf.")
        XCTAssertTrue(d.shouldConvert)
        XCTAssertEqual(d.converted, "делаю")
    }
}
