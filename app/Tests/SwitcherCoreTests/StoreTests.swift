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

    func testUserDataFromAnOlderBuildKeepsEverything() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = #"{"exceptions":["fetch"],"whitelistLatin":["zzz"],"learnedReverts":{"слово":1},"layoutMemory":{},"snippets":{},"appRules":{},"domainBlacklist":[],"learnedWords":["word"]}"#
        try old.write(to: dir.appendingPathComponent("userdata.json"), atomically: true, encoding: .utf8)
        let s = Store(directory: dir)
        XCTAssertEqual(s.data.whitelistLatin, ["zzz"])
        XCTAssertEqual(s.data.learnedWords, ["word"])
        XCTAssertEqual(s.data.learnedReverts["слово"], 1)
        XCTAssertTrue(s.data.mentionApps.isEmpty)
    }

    func testDeferredLayoutMemoryReachesTheDisk() {
        let dir = tempDir()
        let s = Store(directory: dir)
        s.rememberLayout(.en, bundleID: "com.apple.Safari", role: "url")
        s.flush()
        XCTAssertEqual(Store(directory: dir).recalledLayout(bundleID: "com.apple.Safari", role: "url"), .en)
    }

    // A deferred snapshot is older than a full save that follows it.
    func testDeferredSnapshotDoesNotOverwriteALaterSave() {
        let dir = tempDir()
        let s = Store(directory: dir)
        s.rememberLayout(.en, bundleID: "a", role: "")
        s.updateData { $0.exceptions.insert("fetch") }
        s.flush()
        let again = Store(directory: dir)
        XCTAssertTrue(again.data.exceptions.contains("fetch"))
        XCTAssertEqual(again.recalledLayout(bundleID: "a", role: ""), .en)
    }

    func testManualConversionForgivesARevert() {
        let s = Store(directory: tempDir())
        s.recordRevert("гыук")
        s.recordRevert("слово")
        XCTAssertFalse(s.forgiveReverts(of: "гы"), "a fragment forgives nothing unless asked to")
        XCTAssertTrue(s.forgiveReverts(of: "гы", prefix: true))
        XCTAssertEqual(s.revertedWords(), ["слово"])
        XCTAssertFalse(s.forgiveReverts(of: "с", prefix: true), "one letter is not evidence")
        XCTAssertTrue(s.forgiveReverts(of: "СЛОВО"))
        XCTAssertTrue(s.revertedWords().isEmpty)
        XCTAssertFalse(s.forgiveReverts(of: ""))
    }

    // Stored the way the engine compares: without what surrounds the word.
    func testRevertKeysMatchTheEngine() {
        let s = Store(directory: tempDir())
        s.recordRevert("ghbdtn,")
        XCTAssertEqual(s.revertedWords(), ["ghbdtn"])
        XCTAssertTrue(s.forgiveReverts(of: "ghbdtn."))
        s.recordRevert("]]]")
        XCTAssertEqual(s.revertedWords(), ["]]]"], "signs alone stay as they are")
    }

    func testMentionAppEarnsAndLosesTheRule() {
        let s = Store(directory: tempDir())
        XCTAssertFalse(s.isMentionApp("chat"))
        for _ in 0..<2 { s.recordMentionFix(bundleID: "chat") }
        XCTAssertFalse(s.isMentionApp("chat"))
        s.recordMentionFix(bundleID: "chat")
        XCTAssertTrue(s.isMentionApp("chat"))
        for _ in 0..<40 { s.recordMentionFix(bundleID: "chat") }
        for _ in 0..<3 { s.recordMentionRevert(bundleID: "chat") }
        XCTAssertFalse(s.isMentionApp("chat"), "three reverts outweigh any record")
        XCTAssertFalse(s.isMentionApp(nil))
    }

    func testMentionAppsSeedOnlyOnce() {
        let s = Store(directory: tempDir())
        s.seedMentionApps(["chat": 33, "": 5])
        XCTAssertTrue(s.isMentionApp("chat"))
        XCTAssertFalse(s.isMentionApp(""))
        s.recordMentionRevert(bundleID: "chat")
        s.seedMentionApps(["chat": 33, "other": 9])
        XCTAssertFalse(s.isMentionApp("other"), "counters that exist are left alone")
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
