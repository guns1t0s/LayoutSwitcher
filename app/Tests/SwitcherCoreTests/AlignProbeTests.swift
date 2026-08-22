import XCTest
@testable import SwitcherCore

/// The alignment rule itself is one KeyMap call; verify the physical-key
/// equivalence it relies on, in both directions and on a no-op.
final class AlignProbeTests: XCTestCase {
    func testPhysicalKeyAlignment() {
        XCTAssertEqual(KeyMap.convert("фильтр", to: .en), "abkmnh")
        XCTAssertEqual(KeyMap.convert("abkmnh", to: .ru), "фильтр")
        XCTAssertEqual(KeyMap.convert("abkmnh", to: .en), "abkmnh")   // already aligned
        XCTAssertEqual(KeyMap.convert("123 ", to: .ru), "123 ")       // untouched
    }
}
