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

    // Not for letters that land on punctuation, digits or mixed script.
    func testOnlyPureCyrillicLetters() {
        let e = engine()
        XCTAssertNil(e.evaluatePrefix("хъ"))       // too short and [ ] twins
        XCTAssertNil(e.evaluatePrefix("бюж"))      // , . ; twins
        XCTAssertNil(e.evaluatePrefix("ы3"))
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
