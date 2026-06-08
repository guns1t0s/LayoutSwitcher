import XCTest
@testable import SwitcherCore

final class KeystrokeBufferTests: XCTestCase {

    func testAccumulatesWordUntilBoundary() {
        let b = KeystrokeBuffer()
        for c in "ghbdtn" { _ = b.input(c) }
        XCTAssertEqual(b.word, "ghbdtn")
        let step = b.input(" ")
        XCTAssertEqual(step.completedWord, "ghbdtn")
        XCTAssertEqual(step.boundary, " ")
        XCTAssertTrue(b.isEmpty)
    }

    func testHardPunctuationIsBoundary() {
        let b = KeystrokeBuffer()
        for c in "hello" { _ = b.input(c) }
        let step = b.input("!")          // "!" is a hard boundary
        XCTAssertEqual(step.completedWord, "hello")
    }

    func testLetterMappingPunctStaysInWord() {
        // "," ";" etc. are RU letters on the EN layout — must NOT split the word,
        // so "обратно" typed as "j,hfnyj" stays one token.
        let b = KeystrokeBuffer()
        var completed: [String] = []
        for c in "j,hfnyj" { if let w = b.input(c).completedWord { completed.append(w) } }
        XCTAssertEqual(completed, [])
        XCTAssertEqual(b.word, "j,hfnyj")
    }

    func testBackspaceShortensWord() {
        let b = KeystrokeBuffer()
        for c in "tesp" { _ = b.input(c) }
        XCTAssertTrue(b.backspace())
        XCTAssertEqual(b.word, "tes")
    }

    func testBackspaceOnEmptyReturnsFalse() {
        let b = KeystrokeBuffer()
        XCTAssertFalse(b.backspace())
    }

    func testResetClearsBuffer() {
        let b = KeystrokeBuffer()
        for c in "abc" { _ = b.input(c) }
        b.reset()
        XCTAssertTrue(b.isEmpty)
    }
}
