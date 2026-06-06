import XCTest
@testable import SwitcherCore

final class SettingsCodableTests: XCTestCase {

    func testSettingsRoundTrip() throws {
        var s = Settings()
        s.threshold = 0.83
        s.appBlacklist = ["com.apple.Terminal", "com.googlecode.iterm2"]
        s.holdToSuppressModifier = 8388608
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(s, back)
    }

    func testUserDataRoundTrip() throws {
        var d = UserData()
        d.exceptions = ["fetch", "ssh"]
        d.whitelistLatin = ["api", "pr"]
        d.learnedReverts = ["привет": 3]
        d.layoutMemory = ["com.apple.Safari|url": .en, "com.apple.Notes|text": .ru]
        d.snippets = ["брб": "буду рядом быстро"]
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(UserData.self, from: data)
        XCTAssertEqual(d, back)
    }

    func testLayoutCodable() throws {
        let data = try JSONEncoder().encode([Layout.ru, .en])
        XCTAssertEqual(try JSONDecoder().decode([Layout].self, from: data), [.ru, .en])
    }
}
