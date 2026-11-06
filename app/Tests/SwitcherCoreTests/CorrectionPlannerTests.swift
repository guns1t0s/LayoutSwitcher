import XCTest
@testable import SwitcherCore

final class CorrectionPlannerTests: XCTestCase {

    // Swallow path: boundary not yet on screen → delete word only, boundary goes
    // into the inserted text (synchronous, race-free).
    func testAutoConvertSwallowKeepsBoundaryInInsert() {
        let p = CorrectionPlanner.autoConvertSwallow(original: "rjulf", converted: "когда",
                                                     boundary: " ")
        XCTAssertEqual(p.deleteCount, 5)            // word only, NOT the space
        XCTAssertEqual(p.insertText, "когда ")
    }

    func testAutoConvertSwallowPunctBoundary() {
        let p = CorrectionPlanner.autoConvertSwallow(original: "ghbdtn", converted: "привет",
                                                     boundary: "!")
        XCTAssertEqual(p.deleteCount, 6)
        XCTAssertEqual(p.insertText, "привет!")
    }

    // "^" only appears from ⇧6 on the EN layout; converting to RU under the
    // ru-⇧6-comma preference must carry the comma intent. Everything else —
    // real punctuation, spaces, EN-target conversions, preference off — verbatim.
    func testMapBoundaryCaretToCommaOnlyForRuWithPreference() {
        XCTAssertEqual(CorrectionPlanner.mapBoundary("^", to: .ru, ruShift6Comma: true), ",")
        XCTAssertEqual(CorrectionPlanner.mapBoundary("^", to: .ru, ruShift6Comma: false), "^")
        XCTAssertEqual(CorrectionPlanner.mapBoundary("^", to: .en, ruShift6Comma: true), "^")
        XCTAssertEqual(CorrectionPlanner.mapBoundary(".", to: .ru, ruShift6Comma: true), ".")
        XCTAssertEqual(CorrectionPlanner.mapBoundary(" ", to: .ru, ruShift6Comma: true), " ")
        XCTAssertNil(CorrectionPlanner.mapBoundary(nil, to: .ru, ruShift6Comma: true))
    }

    func testReplaceWithBoundary() {
        let p = CorrectionPlanner.replace(original: "omw", with: "on my way", boundary: " ")
        XCTAssertEqual(p.deleteCount, 4)            // 3 + space
        XCTAssertEqual(p.insertText, "on my way ")
    }

    func testReplaceNoBoundary() {
        let p = CorrectionPlanner.replace(original: "привет", with: "ghbdtn", boundary: nil)
        XCTAssertEqual(p.deleteCount, 6)
        XCTAssertEqual(p.insertText, "ghbdtn")
    }
}
