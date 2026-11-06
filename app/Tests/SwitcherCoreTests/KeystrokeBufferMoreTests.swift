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

    func testMentionSymbolsStayInWord() {
        // @ # _ and RU twins (" №) attach to the word, so a mention is one token.
        let b = KeystrokeBuffer()
        let done = feed(b, "@user")
        XCTAssertEqual(done, [])            // no boundary emitted
        XCTAssertEqual(b.word, "@user")
        let b2 = KeystrokeBuffer()
        _ = feed(b2, "\"гыук")        // @user typed on RU
        XCTAssertEqual(b2.word, "\"гыук")
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

    // A capital Ж/Б/Ю/Х typed on the EN layout opens the word; mid-word the same
    // characters are punctuation, as they look.
    func testShiftedLetterKeyOpensAWord() {
        let b = KeystrokeBuffer()
        _ = feed(b, ":tyobyf")
        XCTAssertEqual(b.word, ":tyobyf")
        XCTAssertEqual(b.input(" ").completedWord, ":tyobyf")
        _ = feed(b, "12")
        XCTAssertEqual(b.input(":").completedWord, "12", "time and ratios still split")
    }

    // ё sits on the backslash key of the macOS Russian layout.
    func testBackslashStaysInTheWord() {
        let b = KeystrokeBuffer()
        _ = feed(b, "x\\hn")
        XCTAssertEqual(b.word, "x\\hn")
    }
}
