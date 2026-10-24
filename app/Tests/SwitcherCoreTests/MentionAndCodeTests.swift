import XCTest
import AppKit
@testable import SwitcherCore

/// History 15-24.10: 46 manual "\"" → "@" fixes (43 in Mattermost) and "\"ыв" →
/// "@sd", "\"лф" → "@ka"... A quote is swapped for "@" only once the letters
/// after it cannot start a Russian word.
final class MentionTests: XCTestCase {
    private let e = DetectionEngine(dictionaries: .loadBundled())

    func testMentionsFromHistory() {
        for (typed, expect) in ["\"ы": "@s", "\"ь": "@m", "\"тш": "@ni", "\"дф": "@la",
                                "\"лф": "@ka", "\"зщ": "@po", "\"фк": "@ar"] {
            let d = e.evaluateMention(typed)
            XCTAssertEqual(d?.converted, expect, typed)
            XCTAssertEqual(d?.reason, .mention, typed)
        }
    }

    // A quotation starts a Russian word: no prefix of a quoted dictionary word may
    // turn the quote into "@". Swept over the whole bundled Russian list.
    func testQuotedRussianWordsNeverBecomeMentions() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ru_words", withExtension: "txt"))
        let words = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        var fired: [String] = []
        for w in words where !w.isEmpty {
            for n in 1...min(w.count, 6) {
                let p = "\"" + String(w.prefix(n))
                if e.evaluateMention(p) != nil { fired.append(p); break }
            }
        }
        XCTAssertEqual(fired, [], "quoted Russian words turned into mentions")
    }

    // The quotes the user actually typed in Mattermost, with the system Russian
    // spell checker as the prefix oracle — exactly as the app is wired.
    func testRealQuotesStayQuotesWithSystemSpeller() throws {
        let sp = NSSpellChecker.shared
        try XCTSkipUnless(sp.availableLanguages.contains("ru"), "no Russian spell checker on this host")
        let e = DetectionEngine(dictionaries: .loadBundled())
        e.ruPrefixOracle = { p in
            !(sp.completions(forPartialWordRange: NSRange(location: 0, length: (p as NSString).length),
                             in: p, language: "ru", inSpellDocumentWithTag: 0) ?? []).isEmpty
        }
        for q in ["\"готовить", "\"гасятся", "\"нишагуназад", "\"Привет", "\"ГОСТ", "\"игра"] {
            for n in 2...q.count { XCTAssertNil(e.evaluateMention(String(q.prefix(n))), String(q.prefix(n))) }
        }
        XCTAssertEqual(e.evaluateMention("\"тш")?.converted, "@ni")
    }

    // Only the first three lowercase letters: names, abbreviations and typos live
    // later or in caps ("Акимов", "НРД", "прсото").
    func testWindowIsThreeLowercaseLetters() {
        XCTAssertNil(e.evaluateMention("\"ТШ"))
        XCTAssertNil(e.evaluateMention("\"Тш"))
        XCTAssertNil(e.evaluateMention("\"тшлщ"), "4th letter is outside the window")
    }

    func testMentionNeedsLoginShapedTwin() {
        XCTAssertNil(e.evaluateMention("\""))
        XCTAssertNil(e.evaluateMention("\"б"))        // б → "," : not a login
        XCTAssertNil(e.evaluateMention("\"ыю"))       // ю → "."
        XCTAssertNil(e.evaluateMention("тш"))         // no quote, not a mention
    }

    func testRevertedMentionPrefixBlocks() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        XCTAssertNotNil(e.evaluateMention("\"тш"))
        e.learnedReverts = ["тшлщ"]
        XCTAssertNil(e.evaluateMention("\"тш"))
    }

    func testOracleBlocksAmbiguousPrefixes() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        e.ruPrefixOracle = { $0 == "тш" }
        XCTAssertNil(e.evaluateMention("\"тш"))
        XCTAssertNotNil(e.evaluateMention("\"ь"), "one-letter ы/ь rule does not depend on the oracle")
    }
}

final class CodesAndBracketsTests: XCTestCase {
    private let e = DetectionEngine(dictionaries: .loadBundled())

    func testExactCuratedCodesConvertMidWord() {
        XCTAssertEqual(e.evaluatePrefix("Й4")?.converted, "Q4")
        XCTAssertEqual(e.evaluatePrefix("ы3")?.converted, "s3")
        XCTAssertEqual(e.evaluatePrefix("Ь3")?.converted, "M3")
        for keep in ["Т0", "п2", "1С", "Й", "й44"] { XCTAssertNil(e.evaluatePrefix(keep), keep) }
    }

    func testBracketPair() {
        XCTAssertEqual(e.evaluatePrefix("хъ")?.converted, "[]")
        XCTAssertEqual(e.evaluatePrefix("хъ")?.reason, .brackets)
        XCTAssertEqual(e.evaluatePrefix("ХЪ")?.converted, "{}")
        XCTAssertNil(e.evaluatePrefix("Хъ"))
    }

    // Russian abbreviation typed in caps on the EN layout inside Russian text.
    func testReverseAcronymNeedsRussianContext() {
        XCTAssertEqual(e.evaluate("ER", typedLayout: .en, context: .ru).converted, "УК")
        XCTAssertEqual(e.evaluate("LRG", typedLayout: .en, context: .ru).converted, "ДКП")
        XCTAssertFalse(e.evaluate("ER", typedLayout: .en, context: nil).shouldConvert)
        XCTAssertFalse(e.evaluate("ER", typedLayout: .en, context: .en).shouldConvert)
        XCTAssertFalse(e.evaluate("HR", typedLayout: .en, context: .ru).shouldConvert, "HR is English")
        XCTAssertFalse(e.evaluate("Er", typedLayout: .en, context: .ru).shouldConvert, "caps only")
    }
}
