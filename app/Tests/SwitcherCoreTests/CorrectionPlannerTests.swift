import XCTest
@testable import SwitcherCore

final class CorrectionPlannerTests: XCTestCase {

    // No trailing boundary, no extras: delete the word, insert converted.
    func testAutoConvertInProgressWord() {
        let p = CorrectionPlanner.autoConvert(original: "ghbdtn", converted: "привет",
                                              boundary: nil, extras: "", extrasTo: .ru)
        XCTAssertEqual(p.deleteCount, 6)
        XCTAssertEqual(p.insertText, "привет")
        XCTAssertEqual(p.convertedExtras, "")
    }

    // Trailing space is deleted and re-inserted (word + boundary).
    func testAutoConvertWithBoundary() {
        let p = CorrectionPlanner.autoConvert(original: "ghbdtn", converted: "привет",
                                              boundary: " ", extras: "", extrasTo: .ru)
        XCTAssertEqual(p.deleteCount, 7)            // 6 + space
        XCTAssertEqual(p.insertText, "привет ")
    }

    // Next-word characters typed in the same wrong layout are absorbed + converted.
    func testAutoConvertAbsorbsExtras() {
        // user typed "ghbdtn World" wanting "привет <ru>"; extras "ds" are wrong-layout
        let p = CorrectionPlanner.autoConvert(original: "ghbdtn", converted: "привет",
                                              boundary: " ", extras: "ds", extrasTo: .ru)
        XCTAssertEqual(p.convertedExtras, KeyMap.convert("ds", to: .ru))   // "вы"
        XCTAssertEqual(p.deleteCount, 6 + 1 + 2)
        XCTAssertEqual(p.insertText, "привет " + KeyMap.convert("ds", to: .ru))
    }

    // Swallow path: boundary not yet on screen → delete word only, boundary goes
    // into the inserted text (synchronous, race-free).
    func testAutoConvertSwallowKeepsBoundaryInInsert() {
        let p = CorrectionPlanner.autoConvertSwallow(original: "rjulf", converted: "когда",
                                                     boundary: " ")
        XCTAssertEqual(p.deleteCount, 5)            // word only, NOT the space
        XCTAssertEqual(p.insertText, "когда ")
        XCTAssertEqual(p.convertedExtras, "")
    }

    func testAutoConvertSwallowPunctBoundary() {
        let p = CorrectionPlanner.autoConvertSwallow(original: "ghbdtn", converted: "привет",
                                                     boundary: "!")
        XCTAssertEqual(p.deleteCount, 6)
        XCTAssertEqual(p.insertText, "привет!")
    }

    func testReplaceWithBoundary() {
        let p = CorrectionPlanner.replace(original: "omw", with: "on my way", boundary: " ")
        XCTAssertEqual(p.deleteCount, 4)            // 3 + space
        XCTAssertEqual(p.insertText, "on my way ")
        XCTAssertEqual(p.convertedExtras, "")
    }

    func testReplaceNoBoundary() {
        let p = CorrectionPlanner.replace(original: "привет", with: "ghbdtn", boundary: nil)
        XCTAssertEqual(p.deleteCount, 6)
        XCTAssertEqual(p.insertText, "ghbdtn")
    }
}
