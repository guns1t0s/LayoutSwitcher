import XCTest
@testable import SwitcherCore

final class DetectionPolicyTests: XCTestCase {

    private func engine(ru: [String], en: [String],
                        _ cfg: DetectionEngine.Config = .init()) -> DetectionEngine {
        DetectionEngine(dictionaries: .from(ruWords: ru, enWords: en), config: cfg)
    }

    // A dictionary hit converts regardless of the (n-gram) threshold...
    func testDictionaryConversionIgnoresThreshold() {
        let e = engine(ru: ["привет"], en: [], .init(threshold: 0.999))
        XCTAssertTrue(e.evaluate("ghbdtn").shouldConvert)
        XCTAssertEqual(e.evaluate("ghbdtn").reason, .altIsWord)
    }

    // ...but the n-gram path is monotone in the threshold: anything that converts
    // via n-grams at a low threshold must NOT convert at a near-1.0 threshold.
    func testNgramPathRespectsThreshold() {
        let low = DetectionEngine(dictionaries: .loadBundled(), config: .init(threshold: 0.5))
        let high = DetectionEngine(dictionaries: .loadBundled(), config: .init(threshold: 0.999))
        for tok in ["rjirf", "ltdrf", " rjnbr"] {     // OOV cyrillic typed in EN
            let l = low.evaluate(tok)
            if l.shouldConvert && l.reason == .ngramMargin {
                XCTAssertFalse(high.evaluate(tok).shouldConvert, "\(tok) should drop at high threshold")
            }
        }
    }

    func testContextCanTipAmbiguousWhenEnabled() {
        let cfg = DetectionEngine.Config(convertAmbiguous: true)
        let e = engine(ru: ["мама"], en: ["vfvf"], cfg)        // "vfvf" <-> "мама"
        // No context → still left alone.
        XCTAssertFalse(e.evaluate("vfvf").shouldConvert)
        // Context says the surrounding text is Russian → convert toward RU.
        let d = e.evaluate("vfvf", context: .ru)
        XCTAssertTrue(d.shouldConvert)
        XCTAssertEqual(d.to, .ru)
    }

    func testMinWordLengthGatesNgram() {
        // 3-letter OOV converts by n-gram with default min=3; with min=5 it's too short.
        let permissive = DetectionEngine(dictionaries: .loadBundled(), config: .init(threshold: 0.5, minWordLength: 3))
        let strict = DetectionEngine(dictionaries: .loadBundled(), config: .init(threshold: 0.5, minWordLength: 5))
        let tok = "ghb"   // -> "при"
        if permissive.evaluate(tok).reason == .ngramMargin {
            XCTAssertEqual(strict.evaluate(tok).reason, .tooShort)
        }
    }

    func testCaseShapePreservedAllCapsAndTitle() {
        let e = DetectionEngine(dictionaries: .loadBundled())
        XCTAssertEqual(e.evaluate("GHBDTN").converted, "ПРИВЕТ")
        XCTAssertEqual(e.evaluate("Ghbdtn").converted, "Привет")
        XCTAssertEqual(e.evaluate("ghbdtn").converted, "привет")
    }

    func testLearnedRevertBlocksEvenStrongCandidate() {
        let e = engine(ru: ["привет"], en: [])
        XCTAssertTrue(e.evaluate("ghbdtn").shouldConvert)
        e.learnedReverts = ["привет"]
        XCTAssertFalse(e.evaluate("ghbdtn").shouldConvert)
        XCTAssertEqual(e.evaluate("ghbdtn").reason, .excepted)
    }

    func testWhitelistedLatinTypedCorrectlyStays() {
        let e = engine(ru: [], en: [])
        e.whitelistLatin = ["api"]
        let d = e.evaluate("api")                  // already latin
        XCTAssertFalse(d.shouldConvert)
    }
}
