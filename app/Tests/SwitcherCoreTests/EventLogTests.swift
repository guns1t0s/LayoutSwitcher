import XCTest
@testable import SwitcherCore

final class EventLogTests: XCTestCase {

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("lswt-eventlog-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func ev(_ kind: String, _ original: String = "x") -> LoggedEvent {
        LoggedEvent(t: 1, kind: kind, original: original, converted: "y")
    }

    func testDisabledRecordsNothing() {
        let log = EventLog(directory: tempDir(), enabled: false)
        log.record(ev("auto"))
        // record() hops to a private queue; all()/count() are synchronous barriers.
        XCTAssertEqual(log.count(), 0)
    }

    func testEnabledRecordsAndPersists() {
        let dir = tempDir()
        let log = EventLog(directory: dir, enabled: true)
        log.record(ev("auto", "ghbdtn"))
        log.record(ev("undo", "привет"))
        XCTAssertEqual(log.count(), 2)
        // A fresh instance over the same dir reloads from disk.
        let reopened = EventLog(directory: dir, enabled: true)
        XCTAssertEqual(reopened.count(), 2)
        XCTAssertEqual(reopened.all().first?.original, "ghbdtn")
    }

    func testRingCap() {
        let log = EventLog(directory: tempDir(), cap: 10, enabled: true)
        for i in 0..<25 { log.record(ev("auto", "w\(i)")) }
        XCTAssertEqual(log.count(), 10)
        // Oldest dropped, newest kept.
        XCTAssertEqual(log.all().last?.original, "w24")
        XCTAssertEqual(log.all().first?.original, "w15")
    }

    func testClear() {
        let log = EventLog(directory: tempDir(), enabled: true)
        log.record(ev("auto"))
        log.clear()
        XCTAssertEqual(log.count(), 0)
    }

    func testReportSummarizesSignals() {
        let log = EventLog(directory: tempDir(), enabled: true)
        log.record(ev("auto"))
        log.record(ev("undo"))
        log.record(ev("phantom"))
        let r = log.report()
        XCTAssertTrue(r.contains("откатов(=ложные)=1"))
        XCTAssertTrue(r.contains("фантомных ⇧⇧=1"))
    }
}
