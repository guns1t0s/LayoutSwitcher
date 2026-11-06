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
        XCTAssertTrue(e.isLearnable("пупкин"), "new proper name is learnable")
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

    // The layout can flip mid-word (right after an auto-conversion switched it),
    // leaving the start of the word in one script and the rest in the other.
    // Unifying the scripts restores the intended word; accepted only when exactly
    // one direction yields a real dictionary word.
    func testMixedScriptRepairedWhenOneDirectionIsAWord() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        let a = e.evaluate("пhbdtn")            // "п" (RU) + "hbdtn" (EN)
        XCTAssertTrue(a.shouldConvert)
        XCTAssertEqual(a.converted, "привет")
        XCTAssertEqual(a.reason, .mixedRepaired)
        XCTAssertEqual(a.to, .ru)

        let b = e.evaluate("Ht,енок")           // "Ht," (EN) + "енок" (RU)
        XCTAssertEqual(b.converted, "Ребенок")

        XCTAssertEqual(e.evaluate("пhbdtn.").converted, "привет.")   // outer punct kept
    }

    // Repair must not fire when it cannot be trusted: neither direction is a word,
    // or a letter of one script maps onto punctuation of the other (which trimming
    // would hide — "iPhoneХ" must never become "iPhone[").
    func testMixedScriptRepairRefusesUnsafeCases() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        for token in ["прhbdtn", "abвгд", "iPhoneХ", "ghbdtnю"] {
            let d = e.evaluate(token)
            XCTAssertFalse(d.shouldConvert, "\(token) must be left alone")
            XCTAssertEqual(d.reason, .mixedScript)
        }
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

    // The comma key on the RU layout gives б.
    func testCommaSlipAfterAKnownWord() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        XCTAssertEqual(e.evaluate("подготовьб").converted, "подготовь,")
        XCTAssertEqual(e.evaluate("подготовьб").reason, .slipRepaired)
        XCTAssertEqual(e.evaluate("Сообщениеб").converted, "Сообщение,")
        XCTAssertEqual(e.evaluate("подготовьб").to, .ru, "no layout switch")
    }

    func testCommaSlipLeavesRealWordsAlone() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        for w in ["столб", "зуб", "клуб", "гроб", "озноб"] {
            XCTAssertFalse(e.evaluate(w).shouldConvert, w)
        }
    }

    // Our lists are small; the system speller is asked before a conversion. It can
    // only stop one, and it stays out of the short words it mistakes for English.
    func testSpellerStopsAConversionOfARealWord() {
        let e = DetectionEngine(dictionaries: .from(ruWords: ["привет", "слово"], enWords: ["yard", "web"]))
        XCTAssertTrue(e.evaluate("нфкв").shouldConvert, "precondition: the twin of \"yard\" is no word here")
        e.ruWordOracle = { $0 == "нфкв" }
        XCTAssertFalse(e.evaluate("нфкв").shouldConvert)
    }

    func testSpellerStaysOutOfShortWords() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        e.enWordOracle = { _ in true }
        XCTAssertEqual(e.evaluate("z").converted, "я")
        XCTAssertEqual(e.evaluate("ye").converted, "ну")
        XCTAssertEqual(e.evaluate("tot").converted, "еще")
    }

    func testFourLettersOnENNeedARussianWord() {
        let e = DetectionEngine(dictionaries: .from(ruWords: ["слово"], enWords: ["web"]))
        e.ruWordOracle = { _ in false }
        XCTAssertFalse(e.evaluate("zlhj").shouldConvert)
        e.ruWordOracle = { $0 == "ядро" }
        XCTAssertTrue(e.evaluate("zlhj").shouldConvert)
    }

    func testDrawnOutInterjectionsStay() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        for w in ["аааа", "ааааа", "нууу", "Нууу", "ыыыы", "агааа"] {
            XCTAssertFalse(e.evaluate(w).shouldConvert, w)
        }
    }

    // A short caps token on the EN layout is an abbreviation, unless it spells a
    // Russian abbreviation.
    func testShortCapsStayOnEnglishLayout() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        for w in ["DS", "LF", "CTR", "EVT", "OB"] { XCTAssertFalse(e.evaluate(w).shouldConvert, w) }
        XCTAssertEqual(e.evaluate("GJ").converted, "ПО")
    }

    func testVsStaysInEnglishAndComesBackInRussian() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        XCTAssertFalse(e.evaluate("vs", typedLayout: .en, context: .en).shouldConvert)
        XCTAssertEqual(e.evaluate("vs", typedLayout: .en, context: .ru).converted, "мы")
    }

    func testCapitalOnAPunctuationKey() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        XCTAssertEqual(e.evaluate("<eltn").converted, "Будет")
        XCTAssertEqual(e.evaluate("{jhjij").converted, "Хорошо")
        for w in [":smile", "{name", "<div", "~home", "<the"] {
            XCTAssertFalse(e.evaluate(w).converted.contains(where: { $0.isCyrillic }), w)
        }
    }

    // What stays when the capital rule asks for a real word behind the key.
    func testMarkupOnPunctuationKeysStays() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        for w in ["<3", ":)", ":fire", "{}", "<br", "<SRE", "{V", ">U", ":LB"] {
            XCTAssertFalse(e.evaluate(w).converted.contains(where: { $0.isCyrillic }), w)
        }
    }

    // A cold speller must not be asked, and its silence must not convert anything.
    func testNotReadySpellerStandsAside() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        var asked = 0
        e.ruPrefixOracle = { _ in asked += 1; return false }
        e.enPrefixOracle = { _ in asked += 1; return false }
        e.ruWordOracle = { _ in asked += 1; return true }
        e.enWordOracle = { _ in asked += 1; return false }
        e.spellerReady = { false }
        XCTAssertNil(e.evaluatePrefix("срф"))
        XCTAssertNil(e.evaluatePrefixEN("Xth", context: nil))
        XCTAssertNil(e.evaluateMention("\"тш"))
        XCTAssertEqual(e.evaluate("ghbdtn").converted, "привет", "the dictionary path does not need it")
        XCTAssertFalse(e.evaluate("zlhj").shouldConvert, "four letters on EN need it")
        XCTAssertEqual(asked, 0)
        e.spellerReady = { true }
        XCTAssertNotNil(e.evaluatePrefix("срф"))
    }

    func testLoginBehindPunctuation() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        XCTAssertEqual(e.evaluate("@evs").reason, .login)
        XCTAssertEqual(e.evaluate(",@evs").reason, .login)
    }

    func testWordsTypedWithoutYo() {
        let e = DetectionEngine(dictionaries: .from(ruWords: ["отчётов", "слово"], enWords: ["web"]))
        XCTAssertEqual(e.evaluate("jnxtnjd").converted, "отчетов")
        XCTAssertEqual(e.evaluate("отчетов").reason, .typedIsValidWord)
    }

    // A refusal carries its score: a near miss can be told from a plain Russian word.
    func testRefusalKeepsItsScore() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        let d = e.evaluate("зараженное")
        XCTAssertEqual(d.reason, .belowThreshold)
        XCTAssertGreaterThan(d.confidence, 0)
    }

    func testShortCapsOnEnglishLayoutInEveryContext() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        XCTAssertFalse(e.evaluate("VS", typedLayout: .en, context: .ru).shouldConvert)
        XCTAssertFalse(e.evaluate("LF.", typedLayout: .en, context: .ru).shouldConvert)
        XCTAssertEqual(e.evaluate("GJ.", typedLayout: .en, context: .ru).converted, "ПО.")
    }

    // A Russian abbreviation among Russian words, an English one among English ones.
    func testAbbreviationFollowsTheContext() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        XCTAssertFalse(e.evaluate("WAF", typedLayout: .en, context: .en).shouldConvert)
        XCTAssertEqual(e.evaluate("WAF", typedLayout: .en, context: .ru).converted, "ЦФА")
        for w in ["CI", "CD", "PC", "DB"] {
            XCTAssertFalse(e.evaluate(w, typedLayout: .en, context: .ru).shouldConvert, w)
        }
    }

    func testOneLetterBesideMarkupStays() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        for w in [":D", "<b", "{c", "C#", "F#"] { XCTAssertFalse(e.evaluate(w).shouldConvert, w) }
        XCTAssertEqual(e.evaluate("f,").converted, "а,", "a Russian word before a comma still converts")
    }

    // A dot inside a latin token is a domain or a file name, not the letter ю.
    func testDomainsAndFilesStay() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        e.ruWordOracle = { _ in false }
        for w in ["vk.com", "next.js", "index.js", "data.csv"] { XCTAssertFalse(e.evaluate(w).shouldConvert, w) }
        XCTAssertEqual(e.evaluate("k.lb").converted, "люди", "a dictionary word with ю still converts")
    }

    // The speller splits "k.lb" and passes the pieces: that proves nothing.
    func testSpellerIsNotAskedAboutPunctuatedTokens() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        e.enWordOracle = { _ in true }
        XCTAssertEqual(e.evaluate("k.lb").converted, "люди")
    }

    // Nobody vouched for this cyrillic word: it stays.
    func testColdSpellerDoesNotLetACorrectWordGo() {
        let e = DetectionEngine(dictionaries: .from(ruWords: ["слово"], enWords: ["keys", "web"]))
        e.ruWordOracle = { _ in true }
        e.spellerReady = { false }
        XCTAssertFalse(e.evaluate("луны").shouldConvert)
    }

    func testAcronymStartDoesNotTakeARussianWord() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        e.ruPrefixOracle = { _ in false }
        XCTAssertNil(e.evaluatePrefix("куе"))
        XCTAssertNil(e.evaluatePrefix("УЕФ"))
        XCTAssertEqual(e.evaluatePrefix("КУЕ")?.converted, "RET")
    }
}
