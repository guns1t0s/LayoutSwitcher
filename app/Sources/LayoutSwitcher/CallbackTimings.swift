import Foundation

/// Where the time of a keyboard callback goes. A slow callback holds the whole
/// system's typing, and one number ("slowest key callback") cannot say why: the
/// ring below keeps the last slow ones with their stages. In memory only, and with
/// no typed text (SEC-2): a path, numbers and an app id.
final class CallbackTimings {

    struct Slow {
        let at: Date
        let path: String
        let totalMs: Double
        let stages: [String: Double]
        let app: String

        /// Time in no stage at all: what the measured stages cannot explain. The
        /// speller runs inside other stages, so it is not added on top of them.
        var restMs: Double { max(0, totalMs - stages.filter { $0.key != "spell" }.values.reduce(0, +)) }
    }

    static let slowThresholdMs = 50.0
    private static let ringSize = 20

    /// letter | boundary | early | comma6 | flags | mouse | later (a rewrite from outside the callback).
    var path = "letter"
    private var stages: [String: Double] = [:]
    private var startedAt: UInt64 = 0

    private(set) var ring: [Slow] = []
    private(set) var slowestMs = 0.0
    private(set) var slowCount = 0
    private(set) var slowByPath: [String: Int] = [:]
    private(set) var slowestStages: [String: Double] = [:]
    /// How long events waited for the callback: a long wait with a short callback
    /// means the main thread was busy with something else.
    private(set) var maxQueueDelayMs = 0.0
    private(set) var lateEvents = 0
    /// Mid-word checks refused because the speller was not warm.
    var spellerMisses = 0
    /// Boundaries left alone because the focused field had not been read yet.
    var fieldPendingSkips = 0

    func begin(path: String) {
        self.path = path
        stages.removeAll(keepingCapacity: true)
        startedAt = DispatchTime.now().uptimeNanoseconds
    }

    func measure<T>(_ stage: String, _ body: () -> T) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            stages[stage, default: 0] += ms
            if ms > slowestStages[stage, default: 0] { slowestStages[stage] = ms }
        }
        return body()
    }

    func end(app: @autoclosure () -> String) {
        let totalMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        if totalMs > slowestMs { slowestMs = totalMs }
        guard totalMs > Self.slowThresholdMs else { return }
        slowCount += 1
        slowByPath[path, default: 0] += 1
        ring.insert(Slow(at: Date(), path: path, totalMs: totalMs, stages: stages, app: app()), at: 0)
        if ring.count > Self.ringSize { ring.removeLast() }
    }

    /// `timestamp` as an event carries it. Its unit depends on the hardware, so the
    /// reading that makes sense is taken: ticks or nanoseconds of the same clock.
    func noteQueueDelay(eventTimestamp timestamp: UInt64) {
        guard timestamp > 0 else { return }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(mach_absolute_time()) - Double(timestamp)
        let viaTicks = ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
        let viaNanos = (Double(DispatchTime.now().uptimeNanoseconds) - Double(timestamp)) / 1_000_000
        let sensible = [viaTicks, viaNanos].filter { $0 >= 0 && $0 < 60_000 }.min()
        guard let ms = sensible else { return }
        if ms > maxQueueDelayMs { maxQueueDelayMs = ms }
        if ms > Self.slowThresholdMs { lateEvents += 1 }
    }
}
