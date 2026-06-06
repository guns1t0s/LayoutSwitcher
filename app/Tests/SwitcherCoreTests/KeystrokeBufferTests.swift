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

    func testPunctuationIsBoundary() {
        let b = KeystrokeBuffer()
        for c in "hello" { _ = b.input(c) }
        let step = b.input(".")
        XCTAssertEqual(step.completedWord, "hello")
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
