import AppKit
import CoreGraphics
import SwitcherCore

/// The policy layer (decomposition module 6). Wires keystrokes → buffer →
/// DetectionEngine → LayoutController, and owns shadow-mode, the correction
/// loop, undo, hold-to-suppress and layout memory. Runs entirely on main.
final class ActionCoordinator: InputCaptureDelegate {

    let store: Store
    let engine: DetectionEngine
    private let layout: LayoutController
    private let context: ContextProvider
    private let buffer = KeystrokeBuffer()
    /// Opt-in persistent history of switching actions (FR: analyse false triggers).
    let eventLog: EventLog

    /// Recent applied/would-be conversions for the review panel (FR-21). Ring.
    private(set) var shadowLog: [ShadowEntry] = []
    private var shadowCounter = 0
    private let shadowCap = 50

    private struct LastWord { let text: String; let boundary: Character? }
    private struct LastConversion { let original: String; let converted: String; let boundary: Character?; let layoutBefore: Layout }
    private var lastCompleted: LastWord?
    /// Recent AUTO conversions as they now read on screen. A manual fix of exactly
    /// that text shortly after — by ⇧⇧ on the last word, on a selection or at the
    /// caret — is the user reverting us: the false-positive signal the history
    /// must count (logged as "undo"). The ⇧⇧-on-last-word case alone missed the
    /// "ФТ" → "AN" revert, which was done on a selection.
    private struct RecentAuto {
        let converted: String; let original: String; let layoutBefore: Layout; let at: TimeInterval
        var prefix = false     // early conversion: the word grew after it, match by prefix
    }
    private var recentAutos: [RecentAuto] = []
    /// The latin prefix an early (mid-word) conversion produced for the word in
    /// progress; nil when the current word was not early-converted.
    private var earlyWord: String?
    /// Set when a mention ("@login") was produced from a quote typed on the RU
    /// layout: once the login is finished, go back to that layout. In the history
    /// the text after a mention was Russian every time it was visible, and each
    /// time it cost an extra conversion of the first Russian word typed on EN.
    private var mentionReturn: Layout?
    /// The text of the last RU→EN conversion until the next word is decided —
    /// logged as "after-en" with that word's decision. The log skips correct
    /// words, so whether the user goes back to Russian after an English insert
    /// (and the layout should follow) was invisible in 63 of 92 cases.
    private var afterForeign: String?
    private var lastConversion: LastConversion?
    private var lastContextLayout: Layout?

    private var suppressActive = false
    private var fullscreenActive = false
    // Two invalidation epochs with DIFFERENT policies (intentionally separate):
    //  • keystrokeEpoch — bumped on EVERY keyDown. A snippet/autofix replacement
    //    aborts if the user typed anything after it (its expansion is fixed, not
    //    layout-derived, so it can't absorb extra characters).
    //  • disruptionEpoch — bumped only on DISRUPTIVE events (backspace, nav,
    //    click, another boundary). An auto-conversion absorbs plain typing that
    //    followed it (same wrong layout) but aborts on disruption.
    private var keystrokeEpoch = 0

    // Diagnostics (in-memory only; shown on demand in the Diagnostics panel).
    private(set) var boundariesSeen = 0
    private(set) var conversionsApplied = 0
    private(set) var lastReason = "—"
    /// Last N boundary decisions incl. noops/guard-skips — pinpoints WHY a word
    /// wasn't converted. Ephemeral ring, never persisted.
    private(set) var recentDecisions: [String] = []
    /// REL-9 in-session metrics: how often each outcome fired (reason → count).
    private(set) var reasonCounts: [String: Int] = [:]
    var isSuppressing: Bool { suppressActive }
    var isFullscreen: Bool { fullscreenActive }

    /// Record one boundary outcome: tally the reason and append to the ring.
    private func note(_ word: String, _ reason: String, converted: String? = nil) {
        if let pending = afterForeign, !word.lowercased().hasPrefix(pending.lowercased()) {
            afterForeign = nil
            log("after-en", original: word, reason: "\(reason)/tis:\(layout.currentLayout()?.short ?? "?")")
        }
        reasonCounts[reason, default: 0] += 1
        let entry = converted.map { "\(word) → \($0) [\(reason)]" } ?? "\(word) [\(reason)]"
        recentDecisions.insert(entry, at: 0)
        if recentDecisions.count > 12 { recentDecisions.removeLast() }
    }

    /// Called after any state change so the menu bar / overlay can refresh.
    var onChange: (() -> Void)?
    /// Called when a real layout switch was applied — drives toast/flash (FR-2/E5.5).
    /// Second arg is the converted word (nil for selection/line), for the undo toast.
    var onConversionApplied: ((Layout, String?) -> Void)?
    /// Called when a word was learned into the dictionary (3× manual fix).
    var onWordLearned: ((String) -> Void)?

    init(store: Store, dictionaries: Dictionaries, layout: LayoutController,
         context: ContextProvider, eventLog: EventLog) {
        self.store = store
        self.layout = layout
        self.context = context
        self.eventLog = eventLog
        self.engine = DetectionEngine(dictionaries: dictionaries)
        syncFromStore()
    }

    // MARK: - layout switch / keystroke alignment

    /// The layout we last selected ourselves, and when. See `aligned(_:)`.
    private var pendingLayout: Layout?
    private var pendingLayoutAt: TimeInterval = 0

    /// Select a layout AND remember it, so the next keystrokes can be interpreted
    /// the way the receiving app will interpret them (see `aligned(_:)`).
    private func switchLayout(_ l: Layout) {
        layout.select(l)
        pendingLayout = l
        pendingLayoutAt = ProcessInfo.processInfo.systemUptime
    }

    /// Re-interpret a keystroke's characters in the layout that is ACTUALLY active.
    ///
    /// `keyboardGetUnicodeString` resolves a key with the layout attached to the
    /// event, which can disagree with the layout the receiving app renders with —
    /// measured in the wild for seconds at a time after a switch. The screen then
    /// shows "abkmnh" while our buffer holds "фильтр", so the engine sees
    /// perfectly correct Russian and leaves it alone: conversion looks dead after
    /// every switch, which is exactly the reported symptom.
    ///
    /// The system's current input source is what the app renders with, and it
    /// reads back immediately in-process (verified), so anchor on it and re-map
    /// the characters by physical-key equivalence. A disagreement can only mean
    /// stale event characters — when they already agree this is a no-op, and if
    /// the layout is unreadable (a third layout, an IME) nothing is touched.
    private func aligned(_ chars: String) -> String {
        guard let script = chars.dominantLayout else { return chars }   // digits/punct
        if let now = layout.currentLayout() {
            return script == now ? chars : KeyMap.convert(chars, to: now)
        }
        // TIS unreadable: fall back to the layout we ourselves selected last.
        if let want = pendingLayout,
           ProcessInfo.processInfo.systemUptime - pendingLayoutAt < K.layoutSkewWindow {
            return script == want ? chars : KeyMap.convert(chars, to: want)
        }
        return chars
    }

    /// Run `body` once the gesture modifiers (⇧/⌃/⌥/⌘) have PHYSICALLY released,
    /// polling the live hardware flag state. Synthetic Backspaces posted while a
    /// modifier is still down are seen as e.g. Shift+Backspace by apps that read
    /// the global modifier state (Spotlight) and get dropped — leaving a stray
    /// leading letter ("кфн" + ⇧⇧ → "кray"). Fires anyway after a bounded wait so
    /// a stuck modifier can't hang the correction.
    private func afterModifiersRelease(attempt: Int = 0, _ body: @escaping () -> Void) {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        if !held.isEmpty && attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.afterModifiersRelease(attempt: attempt + 1, body)
            }
        } else {
            body()
        }
    }

    /// Append one switching action to the opt-in history (no-op when disabled).
    private func log(_ kind: String, branch: String = "", original: String = "",
                     converted: String = "", from: Layout? = nil, to: Layout? = nil,
                     reason: String = "", confidence: Double = 0, interval: TimeInterval = -1) {
        eventLog.record(LoggedEvent(
            t: Date().timeIntervalSince1970, kind: kind, branch: branch,
            original: original, converted: converted,
            from: from?.short.lowercased() ?? "", to: to?.short.lowercased() ?? "",
            reason: reason, confidence: confidence,
            app: context.frontmostBundleID ?? "", interval: interval))
    }

    /// Pull tunables + lexicons out of the Store into the engine (call on change).
    func syncFromStore() {
        let s = store.settings
        engine.config = .init(threshold: s.threshold,
                              minWordLength: s.minWordLength,
                              convertAmbiguous: s.convertAmbiguous)
        engine.exceptions = store.data.exceptions
        engine.whitelistLatin = store.data.whitelistLatin
        engine.learnedReverts = store.revertedWords()
        engine.learnedWords = store.data.learnedWords
        eventLog.enabled = s.logHistory
    }

    // MARK: - InputCaptureDelegate

    /// Bumped by anything that invalidates a scheduled text replacement
    /// (backspace, navigation, click, another boundary). Plain typed characters
    /// do NOT bump it — a late replacement can absorb them (see onBoundary).
    private var disruptionEpoch = 0

    @discardableResult
    func inputDidKeyDown(keycode: Int64, chars: String, flags: CGEventFlags) -> Bool {
        keystrokeEpoch &+= 1
        // A ⌘/⌃ chord is a shortcut, not text — its letter must never enter the
        // word buffer. It did: ⌘C fed "c", and at the next boundary "c" → "с"
        // (a real dictionary word) CONVERTED, posting a Backspace that ate a real
        // on-screen character and inserting a stray "с" (after ⌘C + Enter in a
        // chat, that is a phantom message). ⌘V pastes, ⌘Z undoes, ⌘A selects —
        // the text under the caret may have changed, so also drop word state and
        // any pending replacement, exactly like a navigation key.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            resetWordState()
            return false
        }
        // ⌥⌫ / ⌘⌫ delete a whole word or line, not one character — the buffer
        // cannot mirror that, so treat them as a disruption too.
        if keycode == 51, flags.contains(.maskAlternate) {
            resetWordState()
            return false
        }
        // RU layout: remap ⇧+6 (keycode 22) to a comma — the user's muscle memory
        // puts the comma there. SHIFT only (never hijack ⌘/⌃/⌥+6 shortcuts), and
        // stand down in secure/blacklisted fields like every other intervention.
        let onlyShift = flags.contains(.maskShift)
            && !flags.contains(.maskCommand) && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
        if store.settings.ruShift6Comma, keycode == 22, onlyShift,
           layout.currentLayout() == .ru, !mutationBlocked() {
            layout.insert(",")
            _ = buffer.input(",")   // keep the word buffer in sync (soft-punct)
            return true             // swallow the layout's own ⇧+6 glyph
        }
        switch keycode {
        case 51:                                   // Backspace
            disruptionEpoch &+= 1
            if buffer.backspace() { return false }
            // The buffer was empty, so this Backspace reached committed text. When it
            // deletes the boundary right after the last finished word, the caret is
            // back at that word's end: resume it as the word in progress. Forgetting
            // it (the old behaviour) turned the common "word, space, oops, ⌫, ⇧⇧" into
            // a phantom gesture — and in Electron apps, where the caret is not
            // readable over AX, the user had to select the word with the mouse.
            if let last = lastCompleted, last.boundary != nil, !last.text.isEmpty {
                buffer.replaceWord(last.text)
                lastCompleted = nil
                lastConversion = nil       // its boundary is gone — undo would misfire
                return false
            }
            resetWordState()
            return false
        case 117, 53, 71, 115, 116, 119, 121, 123, 124, 125, 126:  // fwd-del/esc/clear/nav
            resetWordState(); return false
        case 36, 76:                               // Return / Enter
            commitBoundary("\n"); return false     // async path (Enter has side effects)
        case 48:                                   // Tab
            commitBoundary("\t"); return false
        default:
            break
        }
        // Space / punctuation boundaries take the SYNCHRONOUS swallow path: if the
        // finished word converts, we drop this boundary keystroke and re-insert it
        // ourselves, so no async gap exists for the next keystroke to race.
        let typed = aligned(chars)
        for c in typed {
            let step = buffer.input(c)
            if let word = step.completedWord, onBoundary(word, step.boundary, canSwallow: true) {
                return true
            }
            // Mid-word: an English word typed on the RU layout is caught as soon as
            // its letters cannot start a Russian word (see evaluatePrefix). Single-
            // character keystrokes only, once per word; the engine check is cheap
            // and returns nil for ordinary Russian typing, so the guards below — a
            // few of which touch AX — run only on the rare candidate.
            if step.completedWord == nil, step.boundary == nil, typed.count == 1, earlyWord == nil {
                let w = buffer.word
                let d = w.first == "\"" ? (engine.evaluateMention(w) ?? engine.evaluatePrefix(w))
                                       : engine.evaluatePrefix(w)
                if let d, earlyAllowed() {
                    applyEarly(d)
                    return true
                }
            }
        }
        return false
    }

    /// Guards for a mid-word conversion: the same stand-downs as the boundary
    /// path (off / shadow / Fn / fullscreen / IME / secure / domain / per-app),
    /// plus the earlyConvert setting and the RU layout actually being active.
    private func earlyAllowed() -> Bool {
        let s = store.settings
        guard s.autoConvertEnabled, s.earlyConvert, !s.shadowMode,
              !suppressActive, !fullscreenActive else { return false }
        guard layout.currentLayout() == .ru, !layout.isInputMethodActive() else { return false }
        guard !context.isSecureInput, !domainBlocked() else { return false }
        return effectiveRule(for: context.frontmostBundleID).mode == .auto
    }

    /// Replace the word in progress with its latin form and switch to EN. Runs in
    /// the tap callback for the keystroke that completed the prefix: that letter
    /// is not on screen yet (we swallow it), so the screen holds one fewer.
    private func applyEarly(_ d: Decision) {
        let onScreen = max(0, buffer.word.count - 1)
        // Brackets are layout-neutral and Russian text follows them: keep RU.
        let keepLayout = d.reason == .brackets
        if !keepLayout { switchLayout(.en) }
        layout.replace(deleteCount: onScreen, with: d.converted)
        buffer.replaceWord(d.converted)
        earlyWord = d.converted
        if !keepLayout { lastContextLayout = .en }
        if d.reason == .mention { mentionReturn = .ru }
        conversionsApplied += 1
        note(d.original, d.reason.rawValue, converted: d.converted)
        if !keepLayout { afterForeign = d.converted }
        log("auto", original: d.original, converted: d.converted, from: .ru, to: .en,
            reason: d.reason.rawValue, confidence: d.confidence)
        recentAutos.append(RecentAuto(converted: d.converted, original: d.original, layoutBefore: .ru,
                                      at: ProcessInfo.processInfo.systemUptime, prefix: true))
        if recentAutos.count > 5 { recentAutos.removeFirst() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.feedback()
            self.onConversionApplied?(.en, d.converted)
            self.record(d, applied: true)
        }
    }

    func inputDidChangeFlags(_ flags: CGEventFlags) {
        let mask = store.settings.holdToSuppressModifier
        suppressActive = mask != 0 && (flags.rawValue & UInt64(mask)) == UInt64(mask)
    }

    func inputDidDoubleShift(interval: TimeInterval) {
        if store.settings.doubleShiftConvertWord { fix(interval: interval) }  // convert last word + switch
    }

    func inputDidClick() { resetWordState() }

    // MARK: - boundary pipeline (auto-convert)

    private func commitBoundary(_ b: Character) {
        let step = buffer.input(b)
        if let word = step.completedWord { _ = onBoundary(word, step.boundary, canSwallow: false) }
    }

    /// Decide and (maybe) apply an auto-conversion at a word boundary.
    /// Returns `true` IFF it applied a synchronous swallowing conversion — the
    /// caller must then consume the boundary keystroke (the boundary char is
    /// re-inserted inside the replacement). `canSwallow` is false for Enter/Tab,
    /// which keep the legacy async path because the raw keystroke has side
    /// effects (submit / focus move) we must let through, not re-synthesize.
    @discardableResult
    private func onBoundary(_ word: String, _ boundary: Character?, canSwallow: Bool) -> Bool {
        boundariesSeen += 1
        lastCompleted = LastWord(text: word, boundary: boundary)
        let early = earlyWord
        earlyWord = nil
        if let back = mentionReturn {
            mentionReturn = nil
            if word.hasPrefix("@") && layout.currentLayout() != back {
                switchLayout(back)
                lastContextLayout = back
                log("mention-return", original: word, to: back, reason: "login finished")
            }
        }

        // FR-26: snippet/autoreplace expansion takes priority over conversion.
        if store.settings.expandSnippets,
           let expansion = Snippets.expand(word, using: store.data.snippets) {
            applyReplacement(word, with: expansion, boundary: boundary, layoutAfter: nil)
            return false
        }
        // FR-25: fix accidental Caps Lock ("пRИВЕТ"→"Привет") and two leading
        // capitals on the fly (opt-in). Caps-lock pattern is a strong signature
        // (first letter lower, rest upper) → low false-positive.
        if store.settings.autoFixCapitals {
            let fixed = TextFixes.fixCapsLock(TextFixes.fixDoubleCapital(word))
            if fixed != word {
                applyReplacement(word, with: fixed, boundary: boundary, layoutAfter: nil)
                return false
            }
        }

        // A guard that silently stands down is indistinguishable from a bug from
        // the outside ("it just stopped converting"), so record which one fired.
        func blocked(_ reason: String, keepContext: Bool = true) -> Bool {
            note(word, reason)
            log("blocked", original: word, reason: reason)
            if keepContext { updateContext(with: word) }
            return false
        }
        guard store.settings.autoConvertEnabled else { return blocked("off") }
        guard !suppressActive else { return blocked("fn-suppress") }
        guard !fullscreenActive else { return blocked("fullscreen") }
        if layout.isInputMethodActive() {                                         // REL-4
            return blocked("ime", keepContext: false)   // IME composition isn't real RU/EN text
        }
        if context.isSecureInput { return blocked("secure") }                     // SEC-4
        if domainBlocked() { return blocked("domain") }                           // REL-6
        let rule = effectiveRule(for: context.frontmostBundleID)                   // FR-32 / per-app
        if rule.mode == .off { return blocked("app-off") }

        let typed = layout.currentLayout()
        let decision = engine.evaluate(word, typedLayout: typed, context: lastContextLayout)
        lastReason = decision.reason.rawValue
        guard decision.shouldConvert else {
            note(word, decision.reason.rawValue)
            // Log the skips that could plausibly have been conversions, with the
            // alt reading and the deciding reason. `typedIsValidWord` is ~70% of
            // all boundaries (correct text, working as intended) and would drown
            // the log, so it is excluded; everything else is a candidate miss and
            // is what makes "why didn't it convert" answerable from data.
            if decision.reason != .typedIsValidWord, let from = word.dominantLayout {
                log("skip", original: word,
                    converted: KeyMap.convert(word, to: from.other),
                    from: from, to: from.other,
                    reason: "\(decision.reason.rawValue)/tis:\(layout.currentLayout()?.short ?? "?")",
                    confidence: decision.confidence)
            }
            updateContext(with: word); return false
        }

        if store.settings.shadowMode || rule.mode == .shadow {                    // FR-20 / per-app
            note(word, "shadow", converted: decision.converted)
            record(decision, applied: false)
            updateContext(with: word)
            return false
        }

        if let early, word.hasPrefix(early), decision.to == .ru {
            // The word we converted mid-word turned out Russian once complete, and
            // the ordinary rules are converting it back: an early false positive
            // that healed itself. Count it, so the early rule can be judged on data.
            log("early-healed", original: word, converted: decision.converted, from: .en, to: .ru,
                reason: decision.reason.rawValue)
            recentAutos.removeAll { $0.prefix && word.hasPrefix($0.converted) }
        }
        conversionsApplied += 1
        note(word, decision.reason.rawValue, converted: decision.converted)
        log("auto", original: word, converted: decision.converted,
            from: decision.from, to: decision.to,
            reason: decision.reason.rawValue, confidence: decision.confidence)
        // Carry layout-dependent boundary intent into the target layout
        // ("привет^" typed on EN with the RU-⇧6-comma preference → "привет,").
        let boundary = CorrectionPlanner.mapBoundary(
            boundary, to: decision.to, ruShift6Comma: store.settings.ruShift6Comma)
        lastContextLayout = decision.to
        // What the screen holds once the replacement lands. lastCompleted and
        // lastConversion must describe THAT: they used to keep the typed original,
        // so a ⇧⇧ right after a wrong auto-conversion re-converted the original into
        // the very same text — a silent no-op instead of a revert.
        let applied = { [weak self] in
            guard let self else { return }
            self.lastCompleted = LastWord(text: decision.converted, boundary: boundary)
            self.recentAutos.append(RecentAuto(converted: decision.converted, original: word,
                                               layoutBefore: decision.from,
                                               at: ProcessInfo.processInfo.systemUptime))
            if self.recentAutos.count > 5 { self.recentAutos.removeFirst() }
            self.lastConversion = LastConversion(original: word, converted: decision.converted,
                                                 boundary: boundary, layoutBefore: decision.from)
        }

        if decision.to == .en { afterForeign = decision.converted }

        if canSwallow {
            // SYNCHRONOUS path: the boundary keystroke is about to be swallowed,
            // so on screen the word sits WITHOUT its boundary char. Delete the
            // word, insert converted + boundary. No async, no epoch — nothing can
            // race it out. UI side effects are deferred so the tap callback stays
            // fast (REL-2).
            let plan = CorrectionPlanner.autoConvertSwallow(
                original: word, converted: decision.converted, boundary: boundary)
            // Switch the layout FIRST: the replacement inserts a Unicode string, so
            // it is layout-independent, while every event we post before the switch
            // widens the window in which the user's next keystroke still lands in
            // the old layout — that is what leaves half a word in each script.
            switchLayout(decision.to)
            layout.replace(deleteCount: plan.deleteCount, with: plan.insertText)
            applied()
            let d = decision
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.feedback()
                self.onConversionApplied?(d.to, d.converted)
                self.record(d, applied: true)
            }
            return true
        }

        // ASYNC path (Enter/Tab): let the raw boundary keystroke through and apply
        // the replacement on the next runloop turn, aborting if a disruptive event
        // intervenes. Absorbs next-word characters typed during the gap.
        disruptionEpoch &+= 1
        let snapshot = disruptionEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.disruptionEpoch == snapshot else {
                self.note(word, "raced"); return
            }
            let plan = CorrectionPlanner.autoConvert(
                original: word, converted: decision.converted, boundary: boundary,
                extras: self.buffer.word, extrasTo: decision.to)
            self.switchLayout(decision.to)       // first — see the swallow path
            self.layout.replace(deleteCount: plan.deleteCount, with: plan.insertText)
            if !plan.convertedExtras.isEmpty { self.buffer.replaceWord(plan.convertedExtras) }
            applied()                            // only once it really landed (may have raced)
            self.feedback()
            self.onConversionApplied?(decision.to, decision.converted)
            self.record(decision, applied: true)
        }
        return false
    }

    /// Shared replace used by snippets / autofix (no layout switch).
    private func applyReplacement(_ original: String, with text: String,
                                  boundary: Character?, layoutAfter: Layout?) {
        let plan = CorrectionPlanner.replace(original: original, with: text, boundary: boundary)
        let snapshot = keystrokeEpoch
        let before = layout.currentLayout() ?? .en
        DispatchQueue.main.async { [weak self] in
            guard let self, self.keystrokeEpoch == snapshot else { return }
            self.layout.replace(deleteCount: plan.deleteCount, with: plan.insertText)
            if let l = layoutAfter { self.layout.select(l) }
            // Only now is the expansion on screen; if the user typed first the
            // replacement aborted and the screen still holds the original word.
            self.lastCompleted = LastWord(text: text, boundary: boundary)
            self.lastConversion = LastConversion(original: original, converted: text,
                                                 boundary: boundary, layoutBefore: before)
        }
    }

    // MARK: - manual correction loop (FR-11/FR-12/FR-13)

    /// Convert the in-progress or last-finished word to the other layout, and
    /// switch the system layout. Idempotent-cycling: a second call swaps back.
    /// SEC-4 / FR-32: never read or rewrite text in a secure field or a
    /// blacklisted app — including manual (hotkey) paths, not just auto-convert.
    /// Per-app behaviour, falling back to the legacy blacklist then global default.
    private func effectiveRule(for bundleID: String?) -> AppRule {
        guard let bid = bundleID else { return AppRule() }
        if let r = store.data.appRules[bid] { return r }
        if store.settings.appBlacklist.contains(bid) { return AppRule(mode: .off) }
        return AppRule()
    }

    /// REL-6: stand down on a user-listed browser domain (web password/login pages
    /// that don't expose a secure-text role). Fail-open if the URL is unreadable.
    private func domainBlocked() -> Bool {
        guard !store.data.domainBlacklist.isEmpty,
              let host = AXText.frontmostURL()?.host?.lowercased() else { return false }
        return store.data.domainBlacklist.contains { !$0.isEmpty && host.contains($0) }
    }

    private func mutationBlocked() -> Bool {
        if effectiveRule(for: context.frontmostBundleID).mode == .off { return true }
        if layout.isInputMethodActive() { return true }                  // REL-4
        if context.isSecureInput { return true }
        if domainBlocked() { return true }                               // REL-6
        if let bid = context.frontmostBundleID, store.settings.appBlacklist.contains(bid) { return true }
        return false
    }

    func fix(interval: TimeInterval = -1) {
        guard !mutationBlocked() else {
            note("⌃⌥Z", "blocked")
            log("blocked", reason: "mutation-blocked", interval: interval); return
        }
        // 1) Actively typing → convert the in-progress word (synthetic, reliable).
        if !buffer.isEmpty {
            note(buffer.word, "fix-buffer")
            logFix(branch: "fix-buffer", text: buffer.word, interval: interval)
            fixWord(buffer.word, boundary: nil, inProgress: true); return
        }
        // 2) A real selection (read via AX) → convert it synthetically.
        if let sel = AXText.selectedText(), sel.contains(where: { $0.isLetter }) {
            note(sel.prefix(16).description, "fix-selection")
            logFix(branch: "fix-selection", text: sel, interval: interval)
            convertSelection(sel); return
        }
        // 3) Last finished word (e.g. "пшерги " + double-⇧ → "github ").
        if let last = lastCompleted {
            note(last.text, "fix-last")
                logFix(branch: "fix-last", text: last.text, interval: interval)
            fixWord(last.text, boundary: last.boundary, inProgress: false); return
        }
        // 4) Nothing typed and nothing selected — but the caret may still sit right
        // after a word the user means (they clicked into existing text, which wipes
        // the typing buffer). Read that word via AX and convert it. This used to be
        // a dead end ("phantom" gestures in the history).
        if let w = AXText.wordBeforeCaret() {
            note(w, "fix-caret")
            logFix(branch: "fix-caret", text: w, interval: interval)
            fixWord(w, boundary: nil, inProgress: false); return
        }
        // Nothing to fix. We deliberately do NOT probe the clipboard: a Cmd+C/Cmd+V
        // round-trip in Electron/chat apps grabbed and pasted the user's REAL
        // clipboard (a URL → an auto-link) — corruption far worse than a miss.
        note("⌃⌥Z", "nothing-to-fix")
        // A phantom ⇧⇧ with nothing to convert is a prime accidental-gesture signal.
        log("phantom", reason: "nothing-to-fix", interval: interval)
    }

    /// Log a double-⇧ fix, computing the converted form the same way fixWord does.
    private func logFix(branch: String, text: String, interval: TimeInterval) {
        // Reverting a recent auto-conversion by hand is a false positive, whatever
        // gesture did it. Log it like undo() so the history stays honest.
        let now = ProcessInfo.processInfo.systemUptime
        let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = recentAutos.lastIndex(where: { a in
            now - a.at < 120 && (a.converted == shown || (a.prefix && shown.hasPrefix(a.converted)))
        }) {
            let a = recentAutos.remove(at: i)
            // For an early conversion the word grew after it: the original is the
            // whole word as the RU layout would have typed it.
            let original = a.prefix ? KeyMap.convert(shown, to: a.layoutBefore) : a.original
            log("undo", original: shown, converted: original,
                from: a.layoutBefore.other, to: a.layoutBefore, reason: "manual-revert/\(branch)")
            // Learn it, like the undo hotkey does (FR-18): a word the user reverted
            // by hand is never auto-converted again — whole word or, for early
            // conversion, any prefix of it. Before, a reverted word ("сфтп" →
            // "cang") would have been converted again the next time.
            // Stored without a leading quote: the rules compare letters only, so a
            // reverted mention ("тшл" from "\"тшл") must block by its letters.
            store.recordRevert(original.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            engine.learnedReverts = store.revertedWords()
        }
        let from = text.dominantLayout ?? layout.currentLayout() ?? .en
        let converted = KeyMap.convert(text, to: from.other)
        log("doubleShift", branch: branch, original: text,
            converted: from.other == .ru ? DetectionEngine.repairInnerZh(converted) : converted,
            from: from, to: from.other, interval: interval)
    }

    /// Convert an AX-read selection by replacing it SYNTHETICALLY (Backspace +
    /// insert) — works in Electron where AX writes no-op; never the clipboard.
    private func convertSelection(_ sel: String) {
        let from = sel.dominantLayout ?? layout.currentLayout() ?? .en
        let to = from.other
        var converted = KeyMap.convert(sel, to: to)
        if to == .ru { converted = DetectionEngine.repairInnerZh(converted) }   // "ye$ty" → "нужен"
        let epoch = keystrokeEpoch
        afterModifiersRelease { [weak self] in
            guard let self, self.keystrokeEpoch == epoch else { return }
            self.layout.replaceSelection(with: converted)
            self.switchLayout(to)
            self.lastContextLayout = to
            self.onConversionApplied?(to, nil)
            self.onChange?()
        }
    }

    /// Convert a single word in place via synthetic Backspace + insert.
    private func fixWord(_ text: String, boundary: Character?, inProgress: Bool) {
        let from = text.dominantLayout ?? layout.currentLayout() ?? .en
        let to = from.other
        var converted = KeyMap.convert(text, to: to)
        if to == .ru { converted = DetectionEngine.repairInnerZh(converted) }   // "$" slip → ж
        // The trailing boundary is re-typed by the replacement, so carry its
        // layout intent too ("^" from EN ⇧6 → "," under the RU-comma preference).
        let boundary = CorrectionPlanner.mapBoundary(
            boundary, to: to, ruShift6Comma: store.settings.ruShift6Comma)
        let plan = CorrectionPlanner.replace(original: text, with: converted, boundary: boundary)
        // Snapshot BEFORE the async hop. If the user types between the double-⇧
        // gesture and this running, the on-screen word grew but deleteCount is
        // stale → deleting too few left a leading character ("gпривет"). Any new
        // keystroke bumps keystrokeEpoch → abort cleanly (no state mutated). All
        // state changes live inside the guard so an abort leaves nothing half-done.
        let epoch = keystrokeEpoch
        // Wait for the gesture's Shift to physically release before deleting —
        // otherwise the first synthetic Backspace lands as Shift+Backspace in apps
        // that read global modifier state (Spotlight) and is dropped, leaving a
        // stray leading letter ("кфн" + ⇧⇧ → "кray" instead of "ray").
        afterModifiersRelease { [weak self] in
            guard let self, self.keystrokeEpoch == epoch else { return }
            self.layout.replace(deleteCount: plan.deleteCount, with: plan.insertText)
            self.switchLayout(to)
            self.lastContextLayout = to   // keep engine context aligned with the new layout
            if inProgress, text.hasPrefix("\""), to == .en { self.mentionReturn = from }   // "\"" + ⇧⇧ = "@"
            if to == .en { self.afterForeign = converted }
            self.feedback()
            self.onConversionApplied?(to, converted)
            if inProgress {
                // The word is still being typed: keep the CONVERTED prefix in the
                // buffer, so the letters that follow extend it ("приве"+"т") and the
                // boundary judges the whole word. Resetting it left the buffer holding
                // only the tail, and a second ⇧⇧ converted that tail alone.
                self.buffer.replaceWord(converted)
                self.lastCompleted = nil
            } else {
                // Enable the cycle: a second double-⇧ swaps the converted form back.
                self.lastCompleted = LastWord(text: converted, boundary: boundary)
            }
            self.lastConversion = LastConversion(original: text, converted: converted,
                                                 boundary: boundary, layoutBefore: from)
            // Learn from repeated manual fixes: after N, the word joins the
            // dictionary — but only genuinely NEW vocabulary. Cycling a word back
            // and forth with ⇧⇧ must not teach its wrong-layout image as a "word"
            // (that poisoned the lexicon and blocked real conversions). A fix of a
            // word still being typed is a FRAGMENT by definition ("тер", "изнес",
            // "алер" all got learned that way) — never learn from those either.
            if !inProgress, !converted.contains(" "), self.engine.isLearnable(converted),
               self.store.recordManualFix(converted) {
                self.engine.learnedWords = self.store.data.learnedWords
                self.onWordLearned?(converted)
            }
            self.onChange?()
        }
    }

    /// Manual layout switch (FR-13 / scenario 4.5 — double ⇧). Does NOT convert
    /// any text; single ⇧ for capitals is untouched (handled in InputCapture).
    func toggleLayout() {
        buffer.reset()
        guard let cur = layout.currentLayout() else { layout.toggle(); onChange?(); return }
        let to = cur.other
        switchLayout(to)
        onConversionApplied?(to, nil)
        onChange?()
    }

    /// FR-12 line granularity / scenario 4.4: convert the whole line at the caret.
    func convertCurrentLine() {
        guard !mutationBlocked() else { return }
        guard let (text, caret) = AXText.focusedValueAndCaret() else { return }
        let ns = text as NSString
        let loc = max(0, min(caret, ns.length))
        var range = ns.lineRange(for: NSRange(location: loc, length: 0))
        // Drop a trailing newline so we convert text only.
        if range.length > 0, ns.character(at: range.location + range.length - 1) == 10 {
            range.length -= 1
        }
        guard range.length > 0 else { return }
        let line = ns.substring(with: range)
        guard line.contains(where: { $0.isLetter }) else { return }
        let from = line.dominantLayout ?? layout.currentLayout() ?? .en
        let to = from.other
        let converted = KeyMap.convert(line, to: to)
        if AXText.setSelectedRange(location: range.location, length: range.length),
           AXText.replaceSelection(with: converted) {
            layout.select(to)
            onConversionApplied?(to, nil)
            onChange?()
        }
    }

    func toggleAuto() {
        store.updateSettings { $0.autoConvertEnabled.toggle() }
        onChange?()
    }

    func setShadowMode(_ on: Bool) {
        store.updateSettings { $0.shadowMode = on }
        onChange?()
    }

    /// Reverse the last conversion and learn from it (FR-15 + FR-18).
    func undo() {
        guard let lc = lastConversion else { return }
        // An undo retroactively flags the prior conversion as a false positive —
        // the single most valuable signal for tuning the engine.
        log("undo", original: lc.converted, converted: lc.original,
            from: lc.layoutBefore.other, to: lc.layoutBefore, reason: "user-revert")
        let plan = CorrectionPlanner.replace(original: lc.converted, with: lc.original, boundary: lc.boundary)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layout.replace(deleteCount: plan.deleteCount, with: plan.insertText)
            self.layout.select(lc.layoutBefore)
        }
        store.recordRevert(lc.original)            // stop auto-converting this word
        engine.learnedReverts = store.revertedWords()
        lastCompleted = LastWord(text: lc.original, boundary: lc.boundary)
        lastConversion = nil
        onChange?()
    }

    // MARK: - shadow review actions (FR-21)

    func addToExceptions(_ word: String) {
        store.updateData { $0.exceptions.insert(word.lowercased()) }
        engine.exceptions = store.data.exceptions
        onChange?()
    }
    func addToWhitelist(_ word: String) {
        store.updateData { $0.whitelistLatin.insert(word.lowercased()) }
        engine.whitelistLatin = store.data.whitelistLatin
        onChange?()
    }

    func currentLayout() -> Layout? { layout.currentLayout() }

    // MARK: - text tools on selection (FR-23/24/25)

    func transliterateSelection() { convertSelectionTool { Transliterator.transliterate($0) } }
    func cycleCaseSelection() { convertSelectionTool { CaseConverter.cycle($0) } }
    func fixCapsSelection() { convertSelectionTool { TextFixes.fixCapsLock(TextFixes.fixDoubleCapital($0)) } }

    /// Apply a transform to the current selection via a direct Accessibility
    /// write — never the clipboard (that pasted the user's real clipboard in
    /// Electron). If AX can't read the selection, no-op (a miss, not corruption).
    private func convertSelectionTool(_ transform: @escaping (String) -> String) {
        guard !mutationBlocked() else { return }
        guard let sel = AXText.selectedText(), !sel.isEmpty else { return }
        let result = transform(sel)
        afterModifiersRelease { [weak self] in
            self?.layout.replaceSelection(with: result)
        }
    }

    // MARK: - focus changes (FR-4/5/6, FR-31)

    private var lastBundleID: String?

    /// Caret/field/app changed: refresh fullscreen state and, only on a real app
    /// switch, proactively set the layout.
    func handleFocusChange() {
        // 1) Mid-word: ignore. Electron/chat apps spam focused-element-changed
        //    while typing; acting on it would corrupt the word in progress.
        guard buffer.isEmpty else { return }
        // Suppress in fullscreen ONLY when there is no editable text focus — a
        // fullscreen game/video should stand down, but a fullscreen editor or
        // chat (common for Electron apps) is exactly where the user types and
        // needs conversion. Without this, every word in a fullscreen Claude /
        // Obsidian window was silently dropped ("fullscreen" guard).
        fullscreenActive = store.settings.disableInFullscreen
            && AXText.isFrontmostFullscreen()
            && !context.hasEditableTextFocus()

        // 2) Only switch layout when the FRONTMOST APP actually changed. A letter
        //    typed in the wrong layout can emit punctuation (e.g. "б"→","), which
        //    momentarily empties the buffer; a within-app focus event must NOT
        //    flip the layout then, or the rest of the word lands in the other
        //    layout ("Реб"+"енок" → "Ht,"+"енок").
        let bid = context.frontmostBundleID
        guard bid != lastBundleID else { return }
        lastBundleID = bid
        resetWordState()
        proactiveLayout()
        onChange?()
    }

    private func proactiveLayout() {
        // Per-app forced layout wins (e.g. always EN in the terminal).
        if let bid = context.frontmostBundleID, let force = store.data.appRules[bid]?.forceLayout {
            layout.select(force); return
        }
        let role = context.focusedRole()
        if store.settings.latinForUrlEmailSearch,
           role == .secure || role == .search || role == .urlOrEmail {
            layout.select(.en); return                                            // FR-5
        }
        guard store.settings.rememberLayoutPerApp, let bid = context.frontmostBundleID,
              let remembered = store.recalledLayout(bundleID: bid, role: context.roleKey()) else { return }
        layout.select(remembered)                                                 // FR-4
    }

    // MARK: - helpers

    private func updateContext(with word: String) {
        guard let l = word.dominantLayout else { return }
        lastContextLayout = l
        // FR-4: remember the settled layout per app+field (write only on change).
        if store.settings.rememberLayoutPerApp, let bid = context.frontmostBundleID {
            let rk = context.roleKey()
            if store.recalledLayout(bundleID: bid, role: rk) != l {
                store.rememberLayout(l, bundleID: bid, role: rk)
            }
        }
    }

    private func resetWordState() {
        disruptionEpoch &+= 1       // invalidate any scheduled replacement
        buffer.reset()
        lastCompleted = nil
        lastConversion = nil
        earlyWord = nil
        mentionReturn = nil
        afterForeign = nil
        lastContextLayout = nil   // drop stale surrounding-language context (cut random n-gram bias)
    }

    private func record(_ d: Decision, applied: Bool) {
        shadowCounter += 1
        let entry = ShadowEntry(id: shadowCounter, original: d.original, converted: d.converted,
                                from: d.from, to: d.to, confidence: d.confidence,
                                reason: d.reason, applied: applied)
        shadowLog.insert(entry, at: 0)
        if shadowLog.count > shadowCap { shadowLog.removeLast() }
        onChange?()
    }

    private func feedback() {
        if store.settings.soundOnConvert { NSSound.beep() }
        // flashOnConvert: visual flash overlay — TODO (E5.5); off by default.
    }
}
