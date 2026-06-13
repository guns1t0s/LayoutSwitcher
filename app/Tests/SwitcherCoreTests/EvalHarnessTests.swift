import XCTest
@testable import SwitcherCore

/// Turns the "≤0.5% false positives, misses tolerable" acceptance bar into a
/// measured, gated invariant (REL-9). Runs a labeled corpus through the real
/// bundled dictionaries: FALSE POSITIVES (corrupting correct text) must be ZERO;
/// the miss rate is measured and reported, with a loose ceiling.
final class EvalHarnessTests: XCTestCase {

    // Correct text — converting ANY of these is a false positive (forbidden).
    private let correctRU = ["привет", "спасибо", "вопрос", "ответ", "система", "проект",
                             "сервер", "договор", "пример", "сообщение", "неделя", "сегодня",
                             "компания", "решение", "задача", "обновление", "пользователь",
                             "встреча", "документ", "результат"]
    private let correctEN = ["hello", "world", "build", "test", "server", "project", "release",
                             "commit", "report", "client", "update", "message", "review",
                             "status", "budget", "deploy", "docker", "github", "branch", "merge"]
    // Latin terms inside a Russian sentence (context = RU) — must stay latin (FR-19).
    private let termsInRu = ["backlog", "api", "sprint", "commit", "deploy", "github", "merge"]

    // Wrong-layout text — these SHOULD convert (a miss is tolerable but measured).
    private let ruIntended = ["привет", "спасибо", "вопрос", "система", "проект", "сервер",
                              "решение", "задача", "сегодня", "компания", "обновление", "встреча"]
    private let enIntended = ["hello", "world", "build", "server", "report", "client",
                              "update", "review", "status", "deploy"]

    private func engine(_ cfg: DetectionEngine.Config = .init()) -> DetectionEngine {
        DetectionEngine(dictionaries: .loadBundled(), config: cfg)
    }

    /// (falsePositives, mustNotTotal, misses, shouldTotal)
    private func measure(_ e: DetectionEngine) -> (fp: Int, mustNot: Int, miss: Int, should: Int) {
        var fp = 0
        for w in correctRU where e.evaluate(w).shouldConvert { fp += 1 }
        for w in correctEN where e.evaluate(w).shouldConvert { fp += 1 }
        for w in termsInRu where e.evaluate(w, context: .ru).shouldConvert { fp += 1 }
        let mustNot = correctRU.count + correctEN.count + termsInRu.count

        var miss = 0
        for w in ruIntended {
            let d = e.evaluate(KeyMap.convert(w, to: .en))
            if !d.shouldConvert || d.converted != w { miss += 1 }
        }
        for w in enIntended {
            let d = e.evaluate(KeyMap.convert(w, to: .ru))
            if !d.shouldConvert || d.converted != w { miss += 1 }
        }
        let should = ruIntended.count + enIntended.count
        return (fp, mustNot, miss, should)
    }

    func testZeroFalsePositivesOnLabeledCorpus() {
        let r = measure(engine())
        XCTAssertEqual(r.fp, 0, "false conversions of correct text — the one thing forbidden")
        let missPct = Double(r.miss) / Double(r.should) * 100
        print(String(format: "[eval] FP %d/%d, misses %d/%d (%.1f%%) at default params",
                     r.fp, r.mustNot, r.miss, r.should, missPct))
        // Misses tolerable, but a regression that silently stops converting common
        // wrong-layout words should fail.
        XCTAssertLessThanOrEqual(missPct, 20.0, "too many missed conversions")
    }

    /// Informational sweep — prints the FP/miss tradeoff across thresholds so the
    /// magic numbers (threshold / minMargin) can be tuned on real data.
    func testParameterSweepReport() {
        for th in [0.65, 0.75, 0.85, 0.95] {
            let r = measure(engine(.init(threshold: th)))
            print(String(format: "[sweep] threshold=%.2f → FP=%d miss=%d/%d", th, r.fp, r.miss, r.should))
            XCTAssertEqual(r.fp, 0, "FP must stay zero even at threshold \(th)")
        }
    }
}
