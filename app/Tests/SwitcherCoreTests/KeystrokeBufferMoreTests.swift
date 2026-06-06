import XCTest
@testable import SwitcherCore

final class KeystrokeBufferMoreTests: XCTestCase {

    private func feed(_ b: KeystrokeBuffer, _ s: String) -> [String] {
        var completed: [String] = []
        for c in s { if let w = b.input(c).completedWord { completed.append(w) } }
        return completed
    }

    func testMultipleWords() {
        let b = KeystrokeBuffer()
        let done = feed(b, "ghbdtn world ")
        XCTAssertEqual(done, ["ghbdtn", "world"])
        XCTAssertTrue(b.isEmpty)
    }

    func testWordContinuesAfterBoundary() {
        let b = KeystrokeBuffer()
        _ = feed(b, "hello ")
        _ = feed(b, "wor")
        XCTAssertEqual(b.word, "wor")
    }

    func testNewlineIsBoundary() {
        let b = KeystrokeBuffer()
        _ = b.input("a"); _ = b.input("b")
        XCTAssertEqual(b.input("\n").completedWord, "ab")
    }

    func testTabIsBoundary() {
        let b = KeystrokeBuffer()
        _ = b.input("x")
        XCTAssertEqual(b.input("\t").completedWord, "x")
    }

    func testHyphenSplitsWord() {
        let b = KeystrokeBuffer()
        let done = feed(b, "co-op")
        XCTAssertEqual(done, ["co"])     // '-' is a boundary
        XCTAssertEqual(b.word, "op")
    }

    func testBoundaryWithEmptyBufferEmitsNothingButReportsBoundary() {
        let b = KeystrokeBuffer()
        let step = b.input(" ")
        XCTAssertNil(step.completedWord)
        XCTAssertEqual(step.boundary, " ")
    }
}
