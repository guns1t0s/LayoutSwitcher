import AppKit
import CoreGraphics
import SwitcherCore

/// Typing scenarios for the part of the app no unit test reaches: the coordinator,
/// with its buffer, word state and layout switches. What is judged is what ends up
/// on screen and which layout is active. They run two ways.
///
/// Simulated, anywhere, with no permissions and nothing on screen. The real
/// coordinator and engine and the real keyboard tables, with a model of a text field
/// in place of an app. It runs in build_app.sh, and it can do what real keys cannot,
/// such as a keyboard event that carries the previous layout:
///
///     LayoutSwitcher --simulate
///
/// Live: the real event tap and a real text view, driven by real key events the app
/// posts to itself, on a throwaway data directory. It needs the running instance
/// stopped, an unlocked screen, and `open`: a process started from a shell has that
/// shell's permissions, not the ones granted to the app. If the window loses the
/// front the run aborts, so that keys never reach another app, and while it runs
/// the checked coordinator acts on nothing but this window. A failed scenario comes
/// with what the tap saw, key by key.
///
///     open dist/LayoutSwitcher.app --args --livecheck /path/to/report.txt
///     open dist/LayoutSwitcher.app      # a moment later: brings its window to the front
enum LiveCheck {

    static let reportPath: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--livecheck"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// `--only <part of a name>` and `--repeat <rounds>`, for a race that shows up once
    /// in a while; `--trace` keeps the trace of the scenarios that pass too.
    static let only: String? = value(after: "--only")
    static let traceAll = CommandLine.arguments.contains("--trace")
    static let rounds: Int = value(after: "--repeat").map { Int($0) ?? 0 } ?? 1

    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Everything a run learns stays out of the user's lexicons and history.
    static let dataDirectory: URL? = reportPath == nil ? nil : throwawayDirectory()

    private static func throwawayDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("layoutswitcher-check-\(getpid())")
    }

    /// What the tap delivered during the run. The tap holds its delegate weakly.
    private static var tapTrace: TapTrace?
    private static var termination: DispatchSourceSignal?

    /// The snippet the scenarios type, in the throwaway store of a run.
    fileprivate static let snippet = (key: "brb", text: "be right back")

    /// Start the live run in the app that was just composed.
    static func start(coordinator: ActionCoordinator, layout: LayoutController, input: InputCapture) {
        let trace = TapTrace(next: coordinator, layout: layout)
        tapTrace = trace
        input.delegate = trace
        coordinator.store.updateData { $0.snippets[snippet.key] = snippet.text }
        let driver = RealKeyboard(coordinator: coordinator, layout: layout, trace: trace)
        driver.show()
        // Stopped from outside (a timeout): no Shift left down, the layout and pointer back.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler {
            driver.stop("stopped from outside (SIGTERM)")
            driver.liftShift()
            DispatchQueue.main.async {
                driver.restore()
                if let dir = dataDirectory { try? FileManager.default.removeItem(at: dir) }
                exit(2)
            }
        }
        term.resume()
        termination = term
        DispatchQueue.global().async {
            let lines = driver.waitForTheFront()
                ? CheckRunner(driver: driver, coordinator: coordinator, live: true).run().lines
                : ["ABORT: \(driver.stopReason)", "0 passed, 1 failed"]
            DispatchQueue.main.async {
                driver.restore()
                try? (lines.joined(separator: "\n") + "\n")
                    .write(toFile: reportPath ?? "", atomically: true, encoding: .utf8)
                if let dir = dataDirectory { try? FileManager.default.removeItem(at: dir) }
                NSApp.terminate(nil)
            }
        }
    }

    /// The scenarios against the model of a text field; the exit code is the verdict.
    static func simulate() -> Never {
        let dir = throwawayDirectory()
        let layout = SimulatedLayout()
        let keys = layout.physicalKeys()
        guard !keys.isEmpty else {
            print("simulation skipped: this Mac has no RU and EN layouts to read")
            exit(0)
        }
        KeyMap.install(keys)
        let store = Store(directory: dir)
        store.seedMentionApps([SimulatedContext.chat: 12])
        store.updateData { $0.snippets[snippet.key] = snippet.text }
        let context = SimulatedContext()
        let coordinator = ActionCoordinator(store: store, dictionaries: Dictionaries.loadForApp(directory: dir),
                                            layout: layout, context: context, eventLog: EventLog(directory: dir))
        coordinator.engine.warmUp()
        let speller = SpellerGate()
        speller.attach(to: coordinator.engine, timings: coordinator.timings) { true }
        coordinator.onWordStart = { speller.wakeUp() }
        context.onFocusRead = { coordinator.handleFocusRead() }
        let driver = SimulatedField(coordinator: coordinator, layout: layout, context: context, keys: keys)
        DispatchQueue.global().async {
            let result = CheckRunner(driver: driver, coordinator: coordinator, live: false).run()
            try? FileManager.default.removeItem(at: dir)
            result.lines.filter { !$0.hasPrefix("ok") }.forEach { print($0) }
            exit(result.failed == 0 ? 0 : 1)
        }
        dispatchMain()
    }
}

/// One way of typing into something and seeing the result. The methods hop to the
/// main thread themselves: the runner lives on another one and waits between keys.
private protocol CheckDriver: AnyObject {
    var isReady: Bool { get }
    /// Why `isReady` went false.
    var stopReason: String { get }
    var text: String { get }
    var activeLayout: Layout? { get }
    /// What happened during the current scenario, step by step, for a failure.
    func takeTrace() -> [String]
    func begin(in layout: Layout)
    func press(_ stroke: Stroke, staleEvent: Bool)
    /// Strokes that arrive while the main thread is busy and pile up at the tap. `then`
    /// runs on the main thread before it lets them in, the way a hotkey or a timer would.
    func burst(_ strokes: [Stroke], then action: (() -> Void)?)
    func doubleShift()
    func click()
    func perform(_ step: CheckStep) -> Bool
}

private func onMain<T>(_ body: () -> T) -> T { DispatchQueue.main.sync(execute: body) }

private func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\n", with: "\\n") + "\"" }

/// What a hand does, one key at a time.
private enum Stroke {
    case key(CGKeyCode, shift: Bool)
    case command(CGKeyCode)         // ⌘ with a key: a shortcut
    case shiftTap                  // "⇧" in a scenario: Shift alone, down and up
    case shiftDown, shiftUp         // "⇑" and "⇓": a Shift held across what comes between
}

private enum CheckStep {
    case keys(String)               // physical keys, named by the US layout; ⇧ ⇑ ⇓ for Shift
    /// The same, behind a main thread that is taking its time; `then` acts on the
    /// coordinator before the keys come in, the way a hotkey or the menu does.
    case burst(String, then: ((ActionCoordinator) -> Void)? = nil)
    case selectAll                  // ⌘A
    case doubleShift
    case wait(Int)                  // ms
    case press(CGKeyCode, shift: Bool)
    case click
    case passwordFieldByTab         // live: login field, keys, Tab into a password field
    case fieldIsProtected(Bool)     // simulated: a password field no flag gives away
    case otherApp                   // simulated: the front app changes with no key or click
    case fieldReadEmpty             // simulated: the read of the field found it empty
    case layoutIs(Layout)           // a checkpoint: later typing could hide a wrong layout
}

private struct CheckScenario {
    let name: String
    let start: Layout
    let steps: [CheckStep]
    let text: String
    let layout: Layout
    var staleEvents = false
    var liveOnly = false
    var simulatedOnly = false
    var extra: ((ActionCoordinator) -> String?)?
}

private let returnKey: CGKeyCode = 36, tabKey: CGKeyCode = 48, backspaceKey: CGKeyCode = 51, downKey: CGKeyCode = 125
private let shiftKey: CGKeyCode = 56, commandKey: CGKeyCode = 55

/// The reverts the store had when the current scenario began: rounds of --repeat
/// share one store, and some scenarios learn a revert on purpose. The same for the
/// count of each decision.
private var revertsAtStart = Set<String>()
private var reasonsAtStart = [String: Int]()

private func noReverts(_ c: ActionCoordinator) -> String? {
    let left = c.store.revertedWords().subtracting(revertsAtStart)
    return left.isEmpty ? nil : "learned reverts left: \(left.sorted())"
}

private func decided(_ reason: String) -> (ActionCoordinator) -> String? {
    { c in c.reasonCounts[reason, default: 0] > reasonsAtStart[reason, default: 0] ? nil : "no [\(reason)] decision" }
}

/// An undo learns its word, which is how it is seen to have run; the lesson goes again
/// at once, for the scenarios and the rounds after this one.
private func learnedRevert(_ word: String) -> (ActionCoordinator) -> String? {
    { c in
        let learned = c.store.revertedWords().subtracting(revertsAtStart).contains(word)
        if c.store.forgiveReverts(of: word) { c.syncFromStore() }
        return learned ? nil : "no revert of \(word) learned"
    }
}

private let scenarios: [CheckScenario] = [
    // The regression that came back three times in August.
    CheckScenario(name: "russian words after an English one", start: .ru,
                  steps: [.keys("ghbdtn vbh github ghbdtn vbh lheu ")],
                  text: "привет мир github привет мир друг ", layout: .ru),
    CheckScenario(name: "english caught mid-word", start: .ru,
                  steps: [.keys("chat ")], text: "chat ", layout: .en),
    CheckScenario(name: "russian caught mid-word", start: .en,
                  steps: [.keys("Xthtp ")], text: "Через ", layout: .ru),
    CheckScenario(name: "mention from a quote at a line start, arrows and Return", start: .ru,
                  steps: [.keys("vbh"), .press(returnKey, shift: false), .keys("@ni"), .layoutIs(.en),
                          .press(downKey, shift: false), .press(returnKey, shift: false), .layoutIs(.ru),
                          .keys("ghbdtn ")],
                  text: "мир\n@ni\nпривет ", layout: .ru),
    CheckScenario(name: "mention in an empty field on arrival", start: .ru, steps: [.fieldReadEmpty, .keys("@")],
                  text: "@", layout: .en, simulatedOnly: true),
    CheckScenario(name: "quote in a sentence stays until its letters decide", start: .ru,
                  steps: [.keys("cnfnec @ss ghbdtn ")], text: "статус @ss привет ", layout: .ru),
    CheckScenario(name: "quote stays a quote before a Russian word", start: .ru,
                  steps: [.keys("cnfnec @ghbdtn ")], text: "статус \"привет ", layout: .ru),
    CheckScenario(name: "mention ended by a click", start: .ru,
                  steps: [.keys("vbh"), .press(returnKey, shift: false), .keys("@ni"), .click, .wait(150),
                          .layoutIs(.ru), .keys("ghbdtn ")],
                  text: "мир\n@niпривет ", layout: .ru),
    CheckScenario(name: "double shift right after a conversion is ignored", start: .en,
                  steps: [.keys("ghbdtn "), .doubleShift], text: "привет ", layout: .ru, extra: noReverts),
    CheckScenario(name: "double shift back and forth leaves no revert", start: .en,
                  steps: [.keys("ghbdtn "), .wait(1200), .doubleShift, .wait(500), .doubleShift],
                  text: "привет ", layout: .ru, extra: noReverts),
    // Three lowercase letters: the mid-word rule leaves them to the boundary.
    CheckScenario(name: "a word before Return is left alone", start: .en,
                  steps: [.keys("vbh"), .press(returnKey, shift: false)], text: "vbh\n", layout: .en),
    CheckScenario(name: "double shift after Return types nothing", start: .en,
                  steps: [.keys("vbh"), .press(returnKey, shift: false), .wait(100), .doubleShift, .wait(150)],
                  text: "vbh\n", layout: .ru),
    CheckScenario(name: "a word before shift-Return is left alone", start: .en,
                  steps: [.keys("vbh"), .press(returnKey, shift: true)], text: "vbh\n", layout: .en),
    CheckScenario(name: "double shift in an empty field switches the layout", start: .ru,
                  steps: [.doubleShift, .wait(150)], text: "", layout: .en),
    CheckScenario(name: "brackets come back with double shift", start: .ru,
                  steps: [.keys("[]"), .wait(1200), .doubleShift, .wait(150)], text: "хъ", layout: .ru),
    CheckScenario(name: "code fence on the Russian layout", start: .ru,
                  steps: [.keys("``` ")], text: "``` ", layout: .ru),
    CheckScenario(name: "comma key after a word", start: .ru,
                  steps: [.keys("gjlujnjdm, ")], text: "подготовь, ", layout: .ru),
    CheckScenario(name: "the comma repair goes back and forth on the same layout", start: .ru,
                  steps: [.keys("gjlujnjdm, "), .wait(1200), .doubleShift, .wait(500), .doubleShift],
                  text: "подготовь, ", layout: .ru),
    CheckScenario(name: "real comma on the Russian layout", start: .ru,
                  steps: [.keys("ghbdtn^ vbh ")], text: "привет, мир ", layout: .ru),
    CheckScenario(name: "acronym, then nothing to fix after two boundaries", start: .ru,
                  steps: [.keys("CPU! "), .wait(1200), .doubleShift, .wait(150)], text: "CPU! ", layout: .ru),
    CheckScenario(name: "backspace resumes the word for a fix", start: .ru,
                  steps: [.keys("rjuf "), .press(backspaceKey, shift: false), .wait(100), .doubleShift],
                  text: "rjuf", layout: .en),
    CheckScenario(name: "a word set by hand mid-word is not flipped back", start: .ru,
                  steps: [.keys("ob"), .doubleShift, .keys(" ")], text: "ob ", layout: .en),
    CheckScenario(name: "a finished word set by hand stays set", start: .ru,
                  steps: [.keys("ob "), .doubleShift, .wait(100), .keys("ob ")], text: "ob ob ", layout: .en),
    CheckScenario(name: "a stale event does not change what the word is", start: .ru,
                  steps: [.keys("nj;t ")], text: "тоже ", layout: .ru, staleEvents: true, simulatedOnly: true,
                  extra: { $0.lastReason == "typedIsValidWord" ? nil : "decided \($0.lastReason)" }),
    CheckScenario(name: "stale punctuation stays a letter in a fix", start: .ru,
                  steps: [.keys("j,hfotybt "), .wait(1200), .doubleShift], text: "j,hfotybt ", layout: .en,
                  staleEvents: true, simulatedOnly: true),
    CheckScenario(name: "another app takes the word in progress away", start: .en,
                  steps: [.keys("gh"), .otherApp, .keys("btn ")], text: "ghbtn ", layout: .en, simulatedOnly: true),
    CheckScenario(name: "a protected field is left alone and leaves no trace", start: .en,
                  steps: [.fieldIsProtected(true), .keys("ghbdtn "), .fieldIsProtected(false)],
                  text: "ghbdtn ", layout: .en, simulatedOnly: true,
                  extra: { $0.recentDecisions.contains { $0.contains("gh") } ? "the word reached the decisions" : nil }),
    CheckScenario(name: "a snippet expands at its boundary", start: .en,
                  steps: [.keys("brb x")], text: "be right back x", layout: .en),
    CheckScenario(name: "password field is left alone", start: .en,
                  steps: [.passwordFieldByTab, .keys("ghbdtn ")], text: "ghbdtn ", layout: .en, liveOnly: true),
    // A rewrite made in the callback must land ahead of the keys already waiting behind
    // it. Queued after them it deleted the wrong letters: "gрприв" for "привет".
    CheckScenario(name: "keys waiting behind a mid-word conversion", start: .en,
                  steps: [.keys("gh"), .burst("bdtn ")], text: "привет ", layout: .ru, liveOnly: true,
                  extra: decided("early")),
    CheckScenario(name: "keys waiting behind a boundary conversion", start: .en,
                  steps: [.keys("vbh"), .burst(" lheu ")], text: "мир друг ", layout: .ru, liveOnly: true),
    // The space comes on its own: the window draws keys after our callbacks, and the
    // layout goes back on the space, which would redraw the login itself.
    CheckScenario(name: "keys waiting behind a mention", start: .ru,
                  steps: [.keys("vbh"), .press(returnKey, shift: false), .burst("@ni"), .keys(" ")],
                  text: "мир\n@ni ", layout: .ru, liveOnly: true),
    // Three letters: no mid-word rule takes them, only the fix can give "при".
    CheckScenario(name: "keys waiting behind a double shift", start: .en,
                  steps: [.keys("gh"), .burst("⇧⇧b")], text: "при", layout: .ru, liveOnly: true),
    // The rewrites made later than the key that asks for them go in at the next callback,
    // ahead of its event. A double shift with the second Shift still down waits for it to
    // come up: the fix lands right behind the release, ahead of the key typed after it.
    CheckScenario(name: "keys waiting behind a double shift held down", start: .en,
                  steps: [.keys("gh⇧⇑"), .burst("⇓b")], text: "при", layout: .ru, liveOnly: true,
                  extra: decided("fix-buffer")),
    CheckScenario(name: "keys waiting behind a double shift on a selection", start: .ru,
                  steps: [.keys("ghbdtn"), .selectAll, .wait(200), .keys("⇧⇑"), .burst("⇓xy")],
                  text: "ghbdtnxy", layout: .en, liveOnly: true, extra: decided("fix-selection")),
    // A hotkey or the menu acts while keys wait at the tap.
    CheckScenario(name: "keys waiting behind an undo", start: .en,
                  steps: [.keys("ljv "), .burst("vb", then: { $0.undo() })],
                  text: "ljv vb", layout: .en, liveOnly: true, extra: learnedRevert("ljv")),
    CheckScenario(name: "keys waiting behind a text tool", start: .en,
                  steps: [.keys("abc"), .selectAll, .wait(200), .burst("xy", then: { $0.cycleCaseSelection() })],
                  text: "ABCxy", layout: .en, liveOnly: true),
    // The expansion lets its boundary key reach the field first, then goes in ahead of
    // the keys behind that.
    CheckScenario(name: "keys waiting behind a snippet", start: .en,
                  steps: [.keys("brb"), .burst(" the ")], text: "be right back the ", layout: .en,
                  liveOnly: true),
]

private final class CheckRunner {
    private let driver: CheckDriver
    private let coordinator: ActionCoordinator
    private let live: Bool

    init(driver: CheckDriver, coordinator: ActionCoordinator, live: Bool) {
        self.driver = driver
        self.coordinator = coordinator
        self.live = live
    }

    func run() -> (lines: [String], failed: Int) {
        var lines = [String](), failed = 0, passed = 0
        let chosen = scenarios.filter { s in
            (live ? !s.simulatedOnly : !s.liveOnly)
                && (LiveCheck.only.map { s.name.localizedCaseInsensitiveContains($0) } ?? true)
        }
        guard !chosen.isEmpty, LiveCheck.rounds > 0 else {
            return (["ABORT: nothing to run (--only \(LiveCheck.only ?? "-"), --repeat \(LiveCheck.rounds))",
                     "0 passed, 1 failed"], 1)
        }
        for s in (0..<LiveCheck.rounds).flatMap({ _ in chosen }) {
            guard driver.isReady else {
                lines.append("ABORT before \"\(s.name)\": \(driver.stopReason)")
                failed += 1
                break
            }
            driver.begin(in: s.start)
            onMain {
                coordinator.forgetTyping()
                revertsAtStart = coordinator.store.revertedWords()
                reasonsAtStart = coordinator.reasonCounts
            }
            usleep(300_000)
            _ = driver.takeTrace()
            var problems = [String]()
            for step in s.steps { perform(step, in: s, into: &lines, problems: &problems) }
            usleep(live ? 400_000 : 150_000)
            if !driver.isReady { problems.append("the front was lost: \(driver.stopReason)") }
            let (text, now, extra) = onMain { (driver.text, driver.activeLayout, s.extra?(coordinator)) }
            if text != s.text { problems.append("text \(quoted(text)), expected \(quoted(s.text))") }
            if now != s.layout { problems.append("layout \(now?.short ?? "?"), expected \(s.layout.short)") }
            if let extra { problems.append(extra) }
            if problems.isEmpty {
                passed += 1
                lines.append("ok    \(s.name)")
                if LiveCheck.traceAll { lines += driver.takeTrace().map { "      " + $0 } }
            } else {
                failed += 1
                lines.append("FAIL  \(s.name): \(problems.joined(separator: "; "))")
                lines += driver.takeTrace().map { "      " + $0 }
                lines += onMain { coordinator.recentDecisions.prefix(4).map { "      decided: " + $0 } }
            }
        }
        lines.append("\(passed) passed, \(failed) failed")
        return (lines, failed)
    }

    private func perform(_ step: CheckStep, in s: CheckScenario, into lines: inout [String],
                         problems: inout [String]) {
        switch step {
        case .layoutIs(let expected):
            usleep(live ? 150_000 : 20_000)
            let now = onMain { driver.activeLayout }
            if now != expected { problems.append("layout \(now?.short ?? "?") midway, expected \(expected.short)") }
        case .keys(let text):
            for c in text {
                guard let stroke = Self.stroke(for: c) else { lines.append("no key for \(c)"); continue }
                driver.press(stroke, staleEvent: s.staleEvents)
            }
        case .burst(let text, let action):
            let coordinator = self.coordinator
            driver.burst(text.compactMap { Self.stroke(for: $0) }, then: action.map { act in { act(coordinator) } })
        case .selectAll:
            driver.press(.command(0), staleEvent: false)
        case .press(let code, let shift):
            driver.press(.key(code, shift: shift), staleEvent: s.staleEvents)
        case .doubleShift:
            driver.doubleShift()
        case .wait(let ms):
            usleep(UInt32(ms) * 1000)
        case .click:
            driver.click()
        case .passwordFieldByTab, .fieldIsProtected, .otherApp, .fieldReadEmpty:
            if !driver.perform(step) { lines.append("step not available in this run") }
        }
    }

    /// The key that gives `c` on the US layout: scenarios are written the way hands move.
    private static func stroke(for c: Character) -> Stroke? {
        let plain: [Character: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, " ": 49, "`": 50,
        ]
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "-", "+": "=", "{": "[", "}": "]", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "|": "\\",
            "~": "`",
        ]
        switch c {
        case "⇧": return .shiftTap
        case "⇑": return .shiftDown
        case "⇓": return .shiftUp
        default: break
        }
        if let code = plain[c] { return .key(code, shift: false) }
        if let base = shifted[c], let code = plain[base] { return .key(code, shift: true) }
        if c.isUppercase, let code = plain[Character(c.lowercased())] { return .key(code, shift: true) }
        return nil
    }
}

// MARK: - live

/// Sits between the tap and the coordinator and writes down what really arrived, so
/// that a failed live scenario can be read without another run. It also keeps the
/// checked coordinator to the window of the check: with another app in front a ⇧⇧ of
/// the run would fix the user's word there, and what the user types there is neither
/// acted on nor written down. Main thread only.
private final class TapTrace: InputCaptureDelegate {
    private let next: ActionCoordinator
    private let layout: LayoutController
    private var lines = [String]()
    private let started = ProcessInfo.processInfo.systemUptime

    init(next: ActionCoordinator, layout: LayoutController) {
        self.next = next
        self.layout = layout
    }

    func note(_ line: String) {
        lines.append(String(format: "%7.3f ", ProcessInfo.processInfo.systemUptime - started) + line)
    }

    func take() -> [String] {
        defer { lines = [] }
        return lines
    }

    func inputDidKeyDown(keycode: Int64, chars: String, flags: CGEventFlags) -> Bool {
        guard NSApp.isActive else {
            note("a key in another app, left alone")
            next.forgetTyping()         // and nothing scheduled for the check's window lands there
            return false
        }
        let before = layout.currentLayout()?.short ?? "?"
        let swallowed = next.inputDidKeyDown(keycode: keycode, chars: chars, flags: flags)
        note("key \(keycode) chars \(quoted(chars))\(flags.contains(.maskShift) ? " shift" : "") tis:\(before)"
             + (swallowed ? " swallowed" : ""))
        return swallowed
    }

    func inputDidChangeFlags(_ flags: CGEventFlags) { next.inputDidChangeFlags(flags) }

    func inputDidDoubleShift(interval: TimeInterval) {
        guard NSApp.isActive else { return note("a double shift in another app, left alone") }
        note(String(format: "double shift, interval %.3f", interval))
        next.inputDidDoubleShift(interval: interval)
    }

    func inputDidClick() {
        guard NSApp.isActive else {
            next.forgetTyping()
            return note("a click in another app, left alone")
        }
        note("click")
        next.inputDidClick()
    }
}

/// Written by the runner before it lets the main thread go, read there after.
private final class Gate { var open = true }

/// Real key events into a window of the app itself.
private final class RealKeyboard: CheckDriver {
    private let coordinator: ActionCoordinator
    private let layout: LayoutController
    private let window = NSWindow(contentRect: NSRect(x: 80, y: 300, width: 460, height: 260),
                                  styleMask: [.titled], backing: .buffered, defer: false)
    private let textView = NSTextView(frame: NSRect(x: 10, y: 60, width: 440, height: 190))
    private let login = NSTextField(frame: NSRect(x: 10, y: 32, width: 440, height: 22))
    private let secure = NSSecureTextField(frame: NSRect(x: 10, y: 6, width: 440, height: 22))
    private let source = CGEventSource(stateID: .hidSystemState)
    private var inPasswordField = false
    private var layoutBefore: Layout?
    private var mouseBefore: CGPoint?
    private let trace: TapTrace
    private var frontToken: NSObjectProtocol?
    /// Set once on losing the front: from then on nothing is posted.
    private var lostTo: String?
    private var clickedAt: CGPoint?
    /// Set from any thread when the run must end now (SIGTERM).
    private let stopLock = NSLock()
    private var stoppedBecause: String?

    init(coordinator: ActionCoordinator, layout: LayoutController, trace: TapTrace) {
        self.coordinator = coordinator
        self.layout = layout
        self.trace = trace
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        for flag in [\NSTextView.isAutomaticQuoteSubstitutionEnabled, \.isAutomaticDashSubstitutionEnabled,
                     \.isAutomaticTextReplacementEnabled, \.isAutomaticSpellingCorrectionEnabled,
                     \.isContinuousSpellCheckingEnabled] {
            textView[keyPath: flag] = false
        }
        login.nextKeyView = secure
        window.title = "LayoutSwitcher live check"
        window.contentView?.addSubview(textView)
        window.contentView?.addSubview(login)
        window.contentView?.addSubview(secure)
        // ⌘A reaches the text view only through a menu item: the agent app has no menu.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let bar = NSMenu()
        for menu in [NSMenu(title: K.appName), edit] {
            let item = NSMenuItem()
            item.submenu = menu
            bar.addItem(item)
        }
        NSApp.mainMenu = bar
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        layoutBefore = layout.currentLayout()
        mouseBefore = CGEvent(source: nil)?.location
        frontToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.trace.note("front app: \(app?.bundleIdentifier ?? app?.localizedName ?? "?")")
        }
    }

    /// macOS may not let a background agent take the front on its own request.
    func waitForTheFront() -> Bool {
        for _ in 0..<50 where !onMain({ NSApp.isActive }) {
            onMain {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                window.makeKeyAndOrderFront(nil)
            }
            usleep(200_000)
        }
        usleep(800_000)
        guard isReady else {
            onMain { lostTo = "nobody: the window never got the front, \(lostTo ?? "?") kept it" }
            return false
        }
        return true
    }

    func stop(_ reason: String) {
        stopLock.lock(); defer { stopLock.unlock() }
        if stoppedBecause == nil { stoppedBecause = reason }
    }

    private var stopped: String? {
        stopLock.lock(); defer { stopLock.unlock() }
        return stoppedBecause
    }

    /// Main thread. The pointer goes back only if it is still where our click left it,
    /// the layout only if the user did not take over: then it is theirs.
    func restore() {
        liftShift()
        if lostTo == nil, let layoutBefore { layout.select(layoutBefore) }
        if let mouseBefore, let clickedAt, let now = CGEvent(source: nil)?.location,
           abs(now.x - clickedAt.x) < 2, abs(now.y - clickedAt.y) < 2 {
            CGWarpMouseCursorPosition(mouseBefore)
        }
    }

    /// Any thread.
    func liftShift() { postShift(down: false) }

    /// The frontmost ordinary window is ours, as the window server sees it: readable
    /// while the main thread is held, and wrong only about panels above the windows.
    private static func frontWindowOwner() -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let front = list.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
        return (front?[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) }
    }

    private static func frontWindowIsOurs() -> Bool { (frontWindowOwner() ?? getpid()) == getpid() }

    /// Who has the front: the owner of the front window when that is not us, else the
    /// active app.
    private static func frontName() -> String {
        if let pid = frontWindowOwner(), pid != getpid() {
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "process \(pid)"
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "another app"
    }

    var isReady: Bool {
        if let why = stopped { onMain { if lostTo == nil { lostTo = why } }; return false }
        return onMain {
            if lostTo == nil, !NSApp.isActive || !Self.frontWindowIsOurs() { lostTo = Self.frontName() }
            return lostTo == nil
        }
    }
    var stopReason: String { "the window lost the front to \(lostTo ?? "?")" }
    var text: String { inPasswordField ? secure.stringValue : textView.string }
    var activeLayout: Layout? { layout.currentLayout() }
    func takeTrace() -> [String] { onMain { trace.take() } }

    func begin(in start: Layout) {
        onMain {
            inPasswordField = false
            textView.string = ""
            login.stringValue = ""
            secure.stringValue = ""
            window.makeFirstResponder(textView)
            layout.select(start)
        }
    }

    func press(_ stroke: Stroke, staleEvent: Bool) {
        guard isReady else { return }
        post(stroke)
        onMain { trace.note("screen: \(quoted(text)) tis:\(layout.currentLayout()?.short ?? "?")") }
    }

    private func post(_ stroke: Stroke, gap: UInt32 = 45_000) {
        guard stopped == nil else { return }
        switch stroke {
        case .shiftTap: tapShift(hold: gap < 45_000 ? 10_000 : 30_000)
        case .shiftDown: postShift(down: true)
        case .shiftUp: postShift(down: false)
        case .key(let code, let shift): postKey(code, with: shift ? [shiftKey] : [])
        case .command(let code): postKey(code, with: [commandKey])
        }
        usleep(gap)
    }

    private static let flag: [CGKeyCode: CGEventFlags] = [
        shiftKey: .maskShift, commandKey: .maskCommand,
    ]

    /// Each modifier goes down as its own event, like a hand: a key event takes its
    /// character from the state of the keyboard when it is made, flags set on it
    /// afterwards change nothing there.
    private func postKey(_ code: CGKeyCode, with modifiers: [CGKeyCode]) {
        var flags = CGEventFlags()
        for m in modifiers {
            flags.insert(Self.flag[m] ?? [])
            postModifier(m, down: true, flags: flags)
            usleep(15_000)
        }
        if let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        for m in modifiers.reversed() {
            usleep(15_000)
            flags.remove(Self.flag[m] ?? [])
            postModifier(m, down: false, flags: flags)
        }
    }

    /// The main thread is held the way a slow callback holds it, while the keys go on.
    /// Nothing here may wait for it, so the front is asked of the window server, and the
    /// keys follow each other fast: while they wait at the tap, nothing can stop them.
    func burst(_ strokes: [Stroke], then action: (() -> Void)?) {
        guard isReady else { return }
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let act = Gate()
        DispatchQueue.main.async {
            held.signal()
            release.wait()
            // Still holding the main thread: the keys wait at the tap. Not with another app
            // in front, whose text a rewrite would change.
            if act.open { action?() }
        }
        held.wait()
        var lost: String?
        for stroke in strokes {
            guard stopped == nil, Self.frontWindowIsOurs() else {
                lost = stopped ?? "\(Self.frontName()), in the middle of a burst"
                break
            }
            post(stroke, gap: 3_000)
        }
        usleep(20_000)          // the last keys reach the tap too, before it runs again
        act.open = lost == nil && stopped == nil && Self.frontWindowIsOurs()
        release.signal()
        if let lost { onMain { if lostTo == nil { lostTo = lost } } }
        usleep(150_000)
        guard isReady else { return }
        onMain { trace.note("after the burst: \(quoted(text)) tis:\(layout.currentLayout()?.short ?? "?")") }
    }

    func doubleShift() {
        guard isReady else { return }
        tapShift(hold: 30_000)
        usleep(60_000)
        guard isReady else { return }
        tapShift(hold: 30_000)
        usleep(150_000)
        onMain { trace.note("after double shift: \(quoted(text)) tis:\(layout.currentLayout()?.short ?? "?")") }
    }

    private func tapShift(hold: UInt32) {
        postShift(down: true)
        usleep(hold)
        postShift(down: false)
    }

    private func postShift(down: Bool) { postModifier(shiftKey, down: down, flags: down ? .maskShift : []) }

    private func postModifier(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        if down, stopped != nil { return }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    func click() {
        guard isReady else { return }
        let point: CGPoint? = onMain {
            let frame = window.frame
            let top = NSScreen.screens.first?.frame.maxY ?? frame.maxY
            // The window under the point must be ours: a floating window of another app
            // (a call, a video) would take the click.
            let target = NSPoint(x: frame.midX, y: frame.maxY - 60)
            guard NSWindow.windowNumber(at: target, belowWindowWithWindowNumber: 0) == window.windowNumber else {
                lostTo = "a window of another app over the click point"
                return nil
            }
            return CGPoint(x: frame.midX, y: top - frame.maxY + 60)
        }
        guard let point else { return }
        onMain { clickedAt = point }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    func perform(_ step: CheckStep) -> Bool {
        guard case .passwordFieldByTab = step else { return false }
        onMain {
            inPasswordField = true
            window.makeFirstResponder(login)
        }
        usleep(200_000)
        press(.key(5, shift: false), staleEvent: false)
        press(.key(4, shift: false), staleEvent: false)
        press(.key(tabKey, shift: false), staleEvent: false)
        usleep(300_000)
        return true
    }
}

// MARK: - simulated

private final class SimulatedLayout: LayoutController {
    var active: Layout = .ru
    var onRewrite: ((Int, String) -> Void)?

    override func currentLayout() -> Layout? { active }
    @discardableResult override func select(_ layout: Layout) -> Bool { active = layout; return true }
    override func isInputMethodActive() -> Bool { false }
    override func replace(deleteCount: Int, with text: String) { onRewrite?(deleteCount, text) }
    override func insert(_ text: String) { onRewrite?(0, text) }
    override func replaceSelection(with text: String) {}
}

private final class SimulatedContext: ContextProvider {
    static let chat = "check.chat"
    var app: String? = SimulatedContext.chat
    var isProtected = false
    var fieldIsEmpty = false

    override var frontmostBundleID: String? { app }
    override var isSecureInput: Bool { isProtected }
    override var mayBeSecure: Bool { isProtected }
    override func refreshFocus() { onFocusRead?() }
    override func refreshFocusIfStale() {}
    override func focusMayHaveMoved(afterHeldEvent: Bool = false) { onFocusRead?() }
    override func roleKey() -> String { "text" }
    override func quoteFitsCaret(atKeystroke keystroke: Int) -> Bool { fieldIsEmpty }
}

/// A text field with the caret at its end, the way an app applies keys and our edits.
private final class SimulatedField: CheckDriver {
    private let coordinator: ActionCoordinator
    private let layout: SimulatedLayout
    private let context: SimulatedContext
    private let keys: [Int: SwitcherCore.KeyMap.Key]
    private(set) var text = ""

    init(coordinator: ActionCoordinator, layout: SimulatedLayout, context: SimulatedContext,
         keys: [SwitcherCore.KeyMap.Key]) {
        self.coordinator = coordinator
        self.layout = layout
        self.context = context
        self.keys = Dictionary(uniqueKeysWithValues: keys.map { ($0.code, $0) })
        layout.onRewrite = { [weak self] deleted, inserted in
            guard let self else { return }
            self.text = String(self.text.dropLast(deleted)) + inserted
        }
    }

    var isReady: Bool { true }
    var stopReason: String { "" }
    var activeLayout: Layout? { layout.active }
    func takeTrace() -> [String] { [] }

    func begin(in start: Layout) {
        onMain {
            text = ""
            layout.active = start
            context.app = SimulatedContext.chat
            context.fieldIsEmpty = false
            coordinator.handleFocusChange()
        }
    }

    private func glyph(_ code: CGKeyCode, shift: Bool, in layout: Layout) -> String {
        if code == 49 { return " " }
        guard let k = keys[Int(code)] else { return "" }
        return String(layout == .ru ? (shift ? k.ruShift : k.ru) : (shift ? k.enShift : k.en))
    }

    func press(_ stroke: Stroke, staleEvent: Bool) {
        guard case .key(let code, let shift) = stroke else { return }    // Shift alone, ⌘: live runs only
        onMain {
            let eventLayout = staleEvent ? layout.active.other : layout.active
            let swallowed = coordinator.inputDidKeyDown(keycode: Int64(code),
                                                        chars: glyph(code, shift: shift, in: eventLayout),
                                                        flags: shift ? .maskShift : [])
            guard !swallowed else { return }
            switch code {
            case returnKey: text += "\n"
            case tabKey: text += "\t"
            case backspaceKey: if !text.isEmpty { text.removeLast() }
            case downKey: break
            default: text += glyph(code, shift: shift, in: layout.active)
            }
        }
        usleep(1000)
    }

    func burst(_ strokes: [Stroke], then action: (() -> Void)?) {
        for stroke in strokes { press(stroke, staleEvent: false) }
        if let action { onMain(action) }
    }

    func doubleShift() {
        onMain { coordinator.inputDidDoubleShift(interval: 0.09) }
        usleep(100_000)
    }

    func click() {
        onMain { coordinator.inputDidClick() }
    }

    func perform(_ step: CheckStep) -> Bool {
        onMain {
            switch step {
            case .fieldIsProtected(let on):
                context.isProtected = on
            case .otherApp:
                context.app = "check.other"
                coordinator.handleFocusChange()
            case .fieldReadEmpty:
                context.fieldIsEmpty = true
            default:
                return false
            }
            return true
        }
    }
}
