import XCTest
@testable import SwitcherCore

/// ALL-CAPS acronyms typed in the RU layout (history 21-27.09: СУЩ→CEO ×2,
/// ЕШУ→TIE ×2, ЛШЕ→KIT, РКВ→HRD, ЫЫЩ→SSO... all fixed by hand, all "tooShort").
final class AcronymTests: XCTestCase {
    private let e = DetectionEngine(dictionaries: .loadBundled())

    func testCapsAcronymsConvert() {
        let cases = ["СУЩ": "CEO", "ЕШУ": "TIE", "ЛШЕ": "KIT", "РКВ": "HRD",
                     "ЫЫЩ": "SSO", "ФАЛ": "AFK", "ГЫЕ": "UST", "ЫЗИ": "SPB"]
        for (cyr, lat) in cases {
            let d = e.evaluate(cyr, typedLayout: .ru)
            XCTAssertTrue(d.shouldConvert, "\(cyr) should become \(lat) [\(d.reason)]")
            XCTAssertEqual(d.converted, lat)
        }
        XCTAssertEqual(e.evaluate("СУЩ,").converted, "CEO,")          // outer punct kept
    }

    // The user's own Russian abbreviations (left as typed in the history) and the
    // glossary ones must never be touched — the whole point of the caps-only rule.
    func testRussianAbbreviationsUntouched() {
        for ru in ["УК", "БА", "ИБ", "ИИ", "СТГ", "КТ", "МРТ", "ИТ", "ВТБ", "БД", "ЦФА",
                   "ЦБ", "ПИФ", "НДФЛ", "ВАИ", "ОФР", "НКЦ", "СПБ", "РФ"] {
            let d = e.evaluate(ru, typedLayout: .ru)
            XCTAssertFalse(d.shouldConvert, "\(ru) must stay Russian, got \(d.converted) [\(d.reason)]")
        }
    }

    // Caps only: the lowercase twin of "tie" is "ешу", one keystroke from "еду" —
    // a typo of real Russian must never flip to English.
    func testLowercaseTwinsNotConvertedByAcronymRule() {
        XCTAssertNotEqual(e.evaluate("ешу").reason, .acronym)
        XCTAssertNotEqual(e.evaluate("Ешу").reason, .acronym)          // not all caps
    }

    // Invariant on the shipped lists: no English acronym may have a cyrillic twin
    // that is a Russian abbreviation the user types. Guards future list edits.
    func testAcronymListsAreDisjointThroughTheKeyboard() {
        let d = Dictionaries.loadBundled()
        XCTAssertFalse(d.acronymsEN.isEmpty)
        for a in d.acronymsEN {
            let twin = KeyMap.convert(a, to: .ru)
            XCTAssertFalse(d.acronymsRU.contains(twin), "\(a) collides with Russian \(twin)")
        }
    }

    // Short English words added to the general dictionary (gated: twin not a
    // Russian word, not one typo away from a short Russian word).
    func testShortEnglishWordsFromHistory() {
        XCTAssertEqual(e.evaluate("цуи").converted, "web")
        XCTAssertEqual(e.evaluate("лше").converted, "kit")
    }
}

/// The user's habitual ⇧4-for-ж slip (history: nfr$t, yf$bvf, ye$ty, ну;но ×2).
final class ZhSlipTests: XCTestCase {
    private let e = DetectionEngine(dictionaries: .loadBundled())

    func testSlipRepairedOnBothLayouts() {
        XCTAssertEqual(e.evaluate("nfr$t").converted, "также")      // EN layout: $ for ж
        XCTAssertEqual(e.evaluate("ye$yj").converted, "нужно")
        XCTAssertEqual(e.evaluate("ну;но").converted, "нужно")      // RU layout: ; for ж
        XCTAssertEqual(e.evaluate("ну;но").reason, .slipRepaired)
        XCTAssertEqual(e.evaluate("nfr$t,").converted, "также,")    // outer punct kept
    }

    // The regression the replay caught: "ну;но" was being flipped to "ye$yj".
    // A symbol between letters must never come out of a conversion.
    func testNoConversionEmitsSymbolBetweenLetters() {
        for t in ["ну;но", "ab$cd", "ghb$dtn"] {
            let d = e.evaluate(t)
            if d.shouldConvert {
                XCTAssertFalse(DetectionEngine.hasInnerSymbol(d.converted), "\(t) -> \(d.converted)")
            }
        }
    }

    // Real punctuation stays punctuation: a trailing ";" is not a ж slip.
    func testTrailingSemicolonIsNotASlip() {
        XCTAssertNotEqual(e.evaluate("нужно;").reason, .slipRepaired)
        XCTAssertFalse(e.evaluate("нужно;").shouldConvert)
    }
}

final class ManualZhRepairTests: XCTestCase {
    func testManualConversionRepairsInnerSemicolon() {
        XCTAssertEqual(DetectionEngine.repairInnerZh(KeyMap.convert("ye$ty ljg", to: .ru)), "нужен доп")
        XCTAssertEqual(DetectionEngine.repairInnerZh("нужно; да"), "нужно; да")     // real punctuation kept
    }
}

/// History 28.09-08.10: the two false positives (HRBP → РКИЗ, ФТ → AN), NIE codes,
/// the trailing-bracket х, and the local personal lexicon.
final class HistoryRound3Tests: XCTestCase {
    private let e = DetectionEngine(dictionaries: .loadBundled())

    func testEnglishAcronymTypedInCapsStays() {
        let d = e.evaluate("HRBP", typedLayout: .en)
        XCTAssertFalse(d.shouldConvert, "HRBP must stay, got \(d.converted) [\(d.reason)]")
        XCTAssertEqual(e.evaluate("РКИЗ").converted, "HRBP")       // and the RU-layout typo converts
    }

    func testShortCapsCyrillicNotTurnedIntoEnglishWord() {
        let d = e.evaluate("ФТ")
        XCTAssertFalse(d.shouldConvert, "ФТ must stay, got \(d.converted) [\(d.reason)]")
        XCTAssertEqual(e.evaluate("GJ").converted, "ПО")           // caps RU word typed on EN still converts
    }

    func testIDCodesTypedInRussianLayout() {
        XCTAssertEqual(e.evaluate("Я1185954Ч").converted, "Z1185954X")
        XCTAssertEqual(e.evaluate("Я2208055Я").converted, "Z2208055Z")
        XCTAssertEqual(e.evaluate("Я1185954,").converted, "Z1185954,")
        for keep in ["А123ВС77", "1С", "Т0", "3д", "М2М", "Б1234567"] {      // plates, 1С, T0, Б→","
            XCTAssertNotEqual(e.evaluate(keep).reason, .idCode, "\(keep) is not an ID code")
        }
    }

    func testTrailingBracketIsKhaWhenConvertingToRussian() {
        XCTAssertEqual(DetectionEngine.convertPreservingOuterPunct("lt;ehys[", to: .ru), "дежурных")
        XCTAssertEqual(DetectionEngine.convertPreservingOuterPunct("lt;ehys[.", to: .ru), "дежурных.")
        XCTAssertEqual(DetectionEngine.convertPreservingOuterPunct("[ghbdtn]", to: .ru), "[привет]")
        let d = e.evaluate("lt;ehys[")
        if d.shouldConvert { XCTAssertFalse(d.converted.contains("["), d.converted) }
    }

    func testPersonalLexiconIsLocalOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lswt-lex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "квазислово\n".write(to: dir.appendingPathComponent(Dictionaries.userLexiconFile),
                                 atomically: true, encoding: .utf8)
        let typo = KeyMap.convert("квазислово", to: .en)
        let app = DetectionEngine(dictionaries: .loadForApp(directory: dir)).evaluate(typo)
        XCTAssertEqual(app.converted, "квазислово")
        XCTAssertEqual(app.reason, .altIsWord)
        XCTAssertNotEqual(e.evaluate(typo).reason, .altIsWord)     // bundled lists know nothing of it
    }
}
