import XCTest
@testable import SwitcherCore

/// Mid-word conversion of English words typed on the RU layout (history
/// 08-17.10: 95 of 120 manual fixes were ⇧⇧ pressed mid-word).
final class EarlyConversionTests: XCTestCase {
    private func engine() -> DetectionEngine {
        let e = DetectionEngine(dictionaries: .loadBundled())
        e.whitelistLatin = ["owa", "niko", "jit"]
        return e
    }
    private func firstFire(_ e: DetectionEngine, _ word: String) -> (Int, String)? {
        for n in 1...word.count {
            if let d = e.evaluatePrefix(String(word.prefix(n))) { return (n, d.converted) }
        }
        return nil
    }

    func testEnglishWordsCaughtAfterThreeLetters() {
        let e = engine()
        for (typed, expect) in ["срф": "cha", "пкф": "gra", "вщс": "doc", "здф": "pla",
                                "щцф": "owa", "швь": "idm", "АФЙ": "FAQ", "ГФЕ": "UAT"] {
            XCTAssertEqual(e.evaluatePrefix(typed)?.converted, expect, typed)
        }
    }

    // A mention typed on the RU layout: the leading Shift+2 is converted with it.
    func testMentionPrefix() {
        XCTAssertEqual(engine().evaluatePrefix("\"тшл")?.converted, "@nik")
    }

    // The three Russian words the history would have broken without the n-gram
    // gap (typo "еше", "сутево", "Рунет"): their letters start no known Russian
    // word, their twins start English ones — and still nothing fires.
    func testRussianWordsWithUnknownPrefixesStayRussian() {
        let e = engine()
        for w in ["еше", "сутево", "Рунет"] {
            XCTAssertNil(firstFire(e, w).map { "\(w) fired at \($0.0): \($0.1)" } ?? nil)
        }
    }

    private func firstFireEN(_ e: DetectionEngine, _ word: String, context: Layout? = nil) -> (Int, String)? {
        for n in 1...word.count {
            if let d = e.evaluatePrefixEN(String(word.prefix(n)), context: context) { return (n, d.converted) }
        }
        return nil
    }

    // Russian typed on the EN layout, fixed by hand after a few letters.
    func testRussianOnTheEnglishLayout() {
        let e = engine()
        XCTAssertEqual(e.evaluatePrefixEN("Xth", context: nil)?.converted, "Чер")
        XCTAssertEqual(e.evaluatePrefixEN("Dkf", context: .ru)?.converted, "Вла")
        XCTAssertEqual(e.evaluatePrefixEN("ghbd", context: nil)?.converted, "прив")
        XCTAssertEqual(e.evaluatePrefixEN("ghbd", context: nil)?.reason, .early)
    }

    func testEnglishStaysEnglish() {
        let e = engine()
        for w in ["hello", "world", "server", "release", "the", "pdf", "api", "jit", "owa"] {
            XCTAssertNil(firstFireEN(e, w), w)
        }
    }

    // Abbreviations and identifiers: three lowercase letters, caps, camelCase, digits.
    func testShapesThatAreNotWords() {
        let e = engine()
        XCTAssertNil(e.evaluatePrefixEN("ghb", context: nil), "three lowercase letters look like an abbreviation")
        XCTAssertNil(e.evaluatePrefixEN("GHB", context: nil))
        XCTAssertNil(e.evaluatePrefixEN("gHbd", context: nil))
        XCTAssertNil(e.evaluatePrefixEN("ghb1", context: nil))
        XCTAssertNil(e.evaluatePrefixEN("ghb_", context: nil))
    }

    func testEnglishContextHoldsTheRuleBack() {
        let e = engine()
        XCTAssertNil(e.evaluatePrefixEN("ghbd", context: .en))
        XCTAssertNotNil(e.evaluatePrefixEN("ghbd", context: .ru))
    }

    func testRevertsAndTheSpellerHoldTheRuleBack() {
        let e = engine()
        e.learnedReverts = ["ghbdtn"]
        XCTAssertNil(e.evaluatePrefixEN("ghbd", context: nil))
        e.learnedReverts = ["привет"]
        XCTAssertNil(e.evaluatePrefixEN("ghbd", context: nil))
        e.learnedReverts = []
        e.enPrefixOracle = { $0 == "ghbd" }
        XCTAssertNil(e.evaluatePrefixEN("ghbd", context: nil))
    }

    // Ordinary Russian never fires: every prefix of a dictionary word is known.
    func testDictionaryWordsNeverFire() {
        let e = engine()
        for w in ["привет", "сегодня", "встреча", "раскладка", "проверь", "логирование",
                  "срочно", "швейцария", "здание", "сфера"] {
            XCTAssertNil(firstFire(e, w), w)
        }
    }

    // A Russian word missing from the bundled lists ("пшеница") is caught by the
    // prefix oracle (the system spell checker in the app) — without it, "пше"
    // would become "git".
    func testPrefixOracleBlocksRussianOutsideTheDictionary() {
        let e = engine()
        XCTAssertEqual(e.evaluatePrefix("пше")?.converted, "git", "precondition: dictionary alone is not enough")
        e.ruPrefixOracle = { ["пше", "пшен", "пшени"].contains($0) }
        XCTAssertNil(e.evaluatePrefix("пше"))
        XCTAssertNotNil(e.evaluatePrefix("срф"), "letters with no Russian continuation still convert")
    }

    // Protected Russian abbreviations and words the user reverted block early.
    func testProtectedAndRevertedBlock() {
        let e = engine()
        XCTAssertNil(e.evaluatePrefix("ЦФА"))
        XCTAssertNotNil(e.evaluatePrefix("срф"))
        e.learnedReverts = ["срфкф"]
        XCTAssertNil(e.evaluatePrefix("срф"), "a reverted word blocks its prefixes")
    }

    // Not for letters that land on punctuation, digits or mixed script — except
    // the two deliberate cases: the bracket pair "хъ" and a code that EXACTLY
    // spells a curated term (both tested in CodesAndBracketsTests).
    func testOnlyPureCyrillicLetters() {
        let e = engine()
        XCTAssertNil(e.evaluatePrefix("хх"))       // [[ twin, not the bracket pair
        XCTAssertNil(e.evaluatePrefix("бюж"))      // , . ; twins
        XCTAssertNil(e.evaluatePrefix("ы9"))       // digit code, not curated
        XCTAssertNil(e.evaluatePrefix("ыsх"))      // mixed script
    }
}

/// Codes with a digit typed on the RU layout ("Й4" → Q4, "ы3" → s3).
final class DigitAcronymTests: XCTestCase {
    func testDigitCodesConvertWhenCurated() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        XCTAssertEqual(e.evaluate("Й4").converted, "Q4")
        XCTAssertEqual(e.evaluate("ы3").converted, "s3")
        XCTAssertEqual(e.evaluate("ЙЩ").converted, "QO")
        XCTAssertFalse(e.evaluate("Т0").shouldConvert)       // T0 settlement, not in the list
        XCTAssertFalse(e.evaluate("п2").shouldConvert)
    }
}
