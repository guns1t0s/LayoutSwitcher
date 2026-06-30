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

    /// Regression: a settings.json written by an OLDER build is missing every
    /// field added since. Decoding must keep the saved values and default only
    /// the absent ones — NOT throw and wipe the whole configuration.
    func testTolerantDecodeOfOlderJSONKeepsSavedValues() throws {
        // Only a few keys present (as an old build would have left them), and a
        // non-default value for one of them.
        let legacy = #"{"threshold":0.66,"shadowMode":true,"appBlacklist":["com.apple.Terminal"]}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertEqual(s.threshold, 0.66)               // saved value preserved
        XCTAssertTrue(s.shadowMode)                      // saved value preserved
        XCTAssertEqual(s.appBlacklist, ["com.apple.Terminal"])
        XCTAssertTrue(s.ruShift6Comma)                   // newest field → its default
        XCTAssertTrue(s.autoConvertEnabled)              // absent → default true
        XCTAssertEqual(s.minWordLength, 4)               // absent → default
    }

    func testEmptyObjectDecodesToAllDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(s, Settings())
    }

    func testUserDataRoundTrip() throws {
        var d = UserData()
        d.exceptions = ["fetch", "ssh"]
        d.whitelistLatin = ["api", "pr"]
        d.learnedReverts = ["привет": 3]
        d.layoutMemory = ["com.apple.Safari|url": .en, "com.apple.Notes|text": .ru]
        d.snippets = ["брб": "буду рядом быстро"]
        d.appRules = ["com.apple.Terminal": AppRule(mode: .off),
                      "com.apple.dt.Xcode": AppRule(mode: .auto, forceLayout: .en),
                      "com.tinyspeck.slackmacgap": AppRule(mode: .shadow)]
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(UserData.self, from: data)
        XCTAssertEqual(d, back)
    }

    func testLayoutCodable() throws {
        let data = try JSONEncoder().encode([Layout.ru, .en])
        XCTAssertEqual(try JSONDecoder().decode([Layout].self, from: data), [.ru, .en])
    }
}
