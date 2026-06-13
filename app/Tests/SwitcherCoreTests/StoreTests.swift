import XCTest
@testable import SwitcherCore

final class StoreTests: XCTestCase {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lswt-test-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    func testPersistsAndReloadsSettings() {
        let dir = tempDir()
        let s1 = Store(directory: dir)
        s1.updateSettings { $0.threshold = 0.9; $0.autoConvertEnabled = false }
        // Fresh instance reads from disk.
        let s2 = Store(directory: dir)
        XCTAssertEqual(s2.settings.threshold, 0.9)
        XCTAssertFalse(s2.settings.autoConvertEnabled)
    }

    func testPersistsUserData() {
        let dir = tempDir()
        let s1 = Store(directory: dir)
        s1.updateData { $0.exceptions.insert("fetch"); $0.snippets["брб"] = "буду рядом быстро" }
        let s2 = Store(directory: dir)
        XCTAssertTrue(s2.data.exceptions.contains("fetch"))
        XCTAssertEqual(s2.data.snippets["брб"], "буду рядом быстро")
    }

    func testLayoutMemoryRoundTrip() {
        let s = Store(directory: tempDir())
        s.rememberLayout(.en, bundleID: "com.apple.Safari", role: "url")
        XCTAssertEqual(s.recalledLayout(bundleID: "com.apple.Safari", role: "url"), .en)
        XCTAssertNil(s.recalledLayout(bundleID: "com.apple.Safari", role: "text"))
    }

    func testLearnedReverts() {
        let s = Store(directory: tempDir())
        s.recordRevert("привет")
        s.recordRevert("привет")
        s.recordRevert("текст")
        XCTAssertEqual(s.revertedWords(min: 2), ["привет"])
        XCTAssertEqual(s.revertedWords(min: 1), ["привет", "текст"])
    }

    func testLearnWordAfterRepeatedManualFixes() {
        let s = Store(directory: tempDir())          // default threshold = 3
        XCTAssertFalse(s.recordManualFix("вроде"))    // 1
        XCTAssertFalse(s.recordManualFix("вроде"))    // 2
        XCTAssertTrue(s.recordManualFix("вроде"))     // 3 → learned
        XCTAssertTrue(s.data.learnedWords.contains("вроде"))
        XCTAssertFalse(s.recordManualFix("вроде"))    // already learned, no re-trigger
    }

    func testManualFixTallyNotPersisted() {
        let dir = tempDir()
        let s = Store(directory: dir)            // threshold 3
        _ = s.recordManualFix("секрет")           // 1 — in memory only
        _ = s.recordManualFix("секрет")           // 2
        XCTAssertTrue(s.data.learnedWords.isEmpty)
        let url = dir.appendingPathComponent("userdata.json")
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            XCTAssertFalse(raw.contains("секрет"), "raw typed word leaked to disk (SEC-2)")
            XCTAssertFalse(raw.contains("learnedWordCounts"))
        }
        XCTAssertTrue(s.recordManualFix("секрет")) // 3 → promote
        XCTAssertTrue(Store(directory: dir).data.learnedWords.contains("секрет"))
    }

    func testLearnDisabledWhenThresholdZero() {
        let s = Store(directory: tempDir())
        s.updateSettings { $0.learnAfterManualFixes = 0 }
        XCTAssertFalse(s.recordManualFix("слово"))
        XCTAssertTrue(s.data.learnedWords.isEmpty)
    }

    func testImportWordsIntoWhitelist() {
        let s = Store(directory: tempDir())
        s.importWords(["API", " Sprint ", ""], into: \.whitelistLatin)
        XCTAssertTrue(s.data.whitelistLatin.contains("api"))
        XCTAssertTrue(s.data.whitelistLatin.contains("sprint"))
        XCTAssertFalse(s.data.whitelistLatin.contains(""))
    }

    func testExportDecodesBack() throws {
        let s = Store(directory: tempDir())
        s.updateData { $0.exceptions = ["a", "b"] }
        let data = try XCTUnwrap(s.exportData())
        let decoded = try JSONDecoder().decode(UserData.self, from: data)
        XCTAssertEqual(decoded.exceptions, ["a", "b"])
    }

    func testResetRestoresDefaults() {
        let dir = tempDir()
        let s = Store(directory: dir)
        s.updateSettings { $0.threshold = 0.5; $0.shadowMode = true }
        s.resetSettings()
        XCTAssertEqual(s.settings, Settings())
        // and the reset persisted
        XCTAssertEqual(Store(directory: dir).settings, Settings())
    }
}
