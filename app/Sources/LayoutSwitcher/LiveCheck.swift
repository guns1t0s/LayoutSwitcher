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
/// front the run aborts, so that keys never reach another app.
///
///     open dist/LayoutSwitcher.app --args --livecheck /path/to/report.txt
///     open dist/LayoutSwitcher.app      # a moment later: brings its window to the front
enum LiveCheck {

    static let reportPath: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--livecheck"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// Everything a run learns stays out of the user's lexicons and history.
    static let dataDirectory: URL? = reportPath == nil ? nil : throwawayDirectory()

    private static func throwawayDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("layoutswitcher-check-\(getpid())")
    }

    /// Start the live run in the app that was just composed.
    static func start(coordinator: ActionCoordinator, layout: LayoutController) {
        let driver = RealKeyboard(coordinator: coordinator, layout: layout)
        driver.show()
        DispatchQueue.global().async {
            driver.waitForTheFront()
            let lines = CheckRunner(driver: driver, coordinator: coordinator, live: true).run().lines
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
    var text: String { get }
    var activeLayout: Layout? { get }
    func begin(in layout: Layout)
    func press(_ code: CGKeyCode, shift: Bool, staleEvent: Bool)
    func doubleShift()
    func click()
    func perform(_ step: CheckStep) -> Bool
}

private func onMain<T>(_ body: () -> T) -> T { DispatchQueue.main.sync(execute: body) }

private enum CheckStep {
    case keys(String)               // physical keys, named by the US layout
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

private func noReverts(_ c: ActionCoordinator) -> String? {
    let left = c.store.revertedWords()
    return left.isEmpty ? nil : "learned reverts left: \(left.sorted())"
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
    CheckScenario(name: "password field is left alone", start: .en,
                  steps: [.passwordFieldByTab, .keys("ghbdtn ")], text: "ghbdtn ", layout: .en, liveOnly: true),
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
        for s in scenarios where live ? !s.simulatedOnly : !s.liveOnly {
            guard driver.isReady else {
                lines.append("ABORT: the window lost focus before \"\(s.name)\"")
                failed += 1
                break
            }
            onMain { coordinator.forgetTyping() }
            driver.begin(in: s.start)
            usleep(300_000)
            var problems = [String]()
            for step in s.steps { perform(step, in: s, into: &lines, problems: &problems) }
            usleep(live ? 400_000 : 150_000)
            let (text, now, extra) = onMain { (driver.text, driver.activeLayout, s.extra?(coordinator)) }
            if text != s.text { problems.append("text \(quoted(text)), expected \(quoted(s.text))") }
            if now != s.layout { problems.append("layout \(now?.short ?? "?"), expected \(s.layout.short)") }
            if let extra { problems.append(extra) }
            if problems.isEmpty {
                passed += 1
                lines.append("ok    \(s.name)")
            } else {
                failed += 1
                lines.append("FAIL  \(s.name): \(problems.joined(separator: "; "))")
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
                guard let (code, shift) = Self.key(for: c) else { lines.append("no key for \(c)"); continue }
                driver.press(code, shift: shift, staleEvent: s.staleEvents)
            }
        case .press(let code, let shift):
            driver.press(code, shift: shift, staleEvent: s.staleEvents)
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

    private func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\n", with: "\\n") + "\"" }

    /// The key that gives `c` on the US layout: scenarios are written the way hands move.
    private static func key(for c: Character) -> (CGKeyCode, shift: Bool)? {
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
        if let code = plain[c] { return (code, false) }
        if let base = shifted[c], let code = plain[base] { return (code, true) }
        if c.isUppercase, let code = plain[Character(c.lowercased())] { return (code, true) }
        return nil
    }
}

// MARK: - live

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

    init(coordinator: ActionCoordinator, layout: LayoutController) {
        self.coordinator = coordinator
        self.layout = layout
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        layoutBefore = layout.currentLayout()
        mouseBefore = CGEvent(source: nil)?.location
    }

    /// macOS may not let a background agent take the front on its own request.
    func waitForTheFront() {
        for _ in 0..<50 where !isReady {
            onMain {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                window.makeKeyAndOrderFront(nil)
            }
            usleep(200_000)
        }
        usleep(800_000)
    }

    func restore() {
        if let layoutBefore { layout.select(layoutBefore) }
        if let mouseBefore { CGWarpMouseCursorPosition(mouseBefore) }
    }

    var isReady: Bool { onMain { NSApp.isActive } }
    var text: String { inPasswordField ? secure.stringValue : textView.string }
    var activeLayout: Layout? { layout.currentLayout() }

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

    func press(_ code: CGKeyCode, shift: Bool, staleEvent: Bool) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        down.flags = shift ? .maskShift : []
        up.flags = down.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(45_000)
    }

    func doubleShift() {
        tapShift(); usleep(60_000); tapShift(); usleep(150_000)
    }

    private func tapShift() {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false) else { return }
        down.type = .flagsChanged
        down.flags = .maskShift
        up.type = .flagsChanged
        up.flags = []
        down.post(tap: .cghidEventTap)
        usleep(30_000)
        up.post(tap: .cghidEventTap)
    }

    func click() {
        let point: CGPoint = onMain {
            let frame = window.frame
            let top = NSScreen.screens.first?.frame.maxY ?? frame.maxY
            return CGPoint(x: frame.midX, y: top - frame.maxY + 60)
        }
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
        press(5, shift: false, staleEvent: false)
        press(4, shift: false, staleEvent: false)
        press(tabKey, shift: false, staleEvent: false)
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
    var activeLayout: Layout? { layout.active }

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

    func press(_ code: CGKeyCode, shift: Bool, staleEvent: Bool) {
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
