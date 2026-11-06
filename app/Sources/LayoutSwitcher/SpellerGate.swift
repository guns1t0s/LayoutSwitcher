import AppKit
import SwitcherCore

/// The system spell checker, for code that runs while the keyboard waits.
///
/// NSSpellChecker answers from another process, AppleSpell, which macOS stops when
/// it idles (27 times in five days here), and there is no timeout on the call. Warm
/// it takes 2-3 ms; cold it held every keystroke of the system for up to 360 ms,
/// almost certainly the 451 ms "slowest key callback". So a synchronous question is
/// only asked right after an answer came, and the first letter of a word wakes the
/// process up in the background with a fixed text, never with what the user typed.
final class SpellerGate {

    private let speller = NSSpellChecker.shared
    private var lastAnswer = -TimeInterval.infinity
    private var pingedAt = -TimeInterval.infinity

    private static let freshFor: TimeInterval = 60
    private static let pingAfter: TimeInterval = 30
    private static let pingTimeout: TimeInterval = 5

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var isReady: Bool { now - lastAnswer <= Self.freshFor }

    /// Cheap, for the first letter of a word.
    func wakeUp() {
        guard now - lastAnswer > Self.pingAfter, now - pingedAt > Self.pingTimeout else { return }
        pingedAt = now
        let text = "привет hello"
        speller.requestChecking(of: text, range: NSRange(location: 0, length: (text as NSString).length),
                                types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                                options: nil, inSpellDocumentWithTag: 0) { [weak self] _, _, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastAnswer = self.now
            }
        }
    }

    /// Does any word of `language` start with `prefix`?
    func knowsPrefix(_ prefix: String, language: String) -> Bool {
        let n = (prefix as NSString).length
        let found = speller.completions(forPartialWordRange: NSRange(location: 0, length: n), in: prefix,
                                        language: language, inSpellDocumentWithTag: 0) ?? []
        lastAnswer = now
        return !found.isEmpty
    }

    func knowsWord(_ word: String, language: String) -> Bool {
        let wrong = speller.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
        lastAnswer = now
        return wrong.location == NSNotFound
    }

    /// Give the engine the dictionaries of the system, far larger than ours, for the
    /// rare words about to be rewritten. These first lookups also warm the process,
    /// before the keyboard depends on it.
    func attach(to engine: DetectionEngine, timings: CallbackTimings, mayAsk: @escaping () -> Bool) {
        if speller.availableLanguages.contains("ru") {
            _ = knowsPrefix("при", language: "ru")
            _ = knowsWord("привет", language: "ru")
            engine.ruPrefixOracle = { [self] p in timings.measure("spell") { knowsPrefix(p, language: "ru") } }
            engine.ruWordOracle = { [self] w in timings.measure("spell") { knowsWord(w, language: "ru") } }
        }
        if speller.availableLanguages.contains("en") {
            _ = knowsPrefix("the", language: "en")
            _ = knowsWord("hello", language: "en")
            engine.enPrefixOracle = { [self] p in timings.measure("spell") { knowsPrefix(p, language: "en") } }
            engine.enWordOracle = { [self] w in timings.measure("spell") { knowsWord(w, language: "en") } }
        }
        engine.spellerReady = { [self] in
            if !isReady { timings.spellerMisses += 1 }
            return isReady && mayAsk()
        }
    }
}
