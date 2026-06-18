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

    /// Recent applied/would-be conversions for the review panel (FR-21). Ring.
    private(set) var shadowLog: [ShadowEntry] = []
    private var shadowCounter = 0
    private let shadowCap = 50

    private struct LastWord { let text: String; let boundary: Character? }
    private struct LastConversion { let original: String; let converted: String; let boundary: Character?; let layoutBefore: Layout }
    private var lastCompleted: LastWord?
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

    init(store: Store, dictionaries: Dictionaries, layout: LayoutController, context: ContextProvider) {
        self.store = store
        self.layout = layout
        self.context = context
        self.engine = DetectionEngine(dictionaries: dictionaries)
        syncFromStore()
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
    }

    // MARK: - InputCaptureDelegate

    /// Bumped by anything that invalidates a scheduled text replacement
    /// (backspace, navigation, click, another boundary). Plain typed characters
    /// do NOT bump it — a late replacement can absorb them (see onBoundary).
    private var disruptionEpoch = 0

    func inputDidKeyDown(keycode: Int64, chars: String, flags: CGEventFlags) {
        keystrokeEpoch &+= 1
        switch keycode {
        case 51:                                   // Backspace
            disruptionEpoch &+= 1
            if !buffer.backspace() { resetWordState() }
            return
        case 117, 53, 71, 115, 116, 119, 121, 123, 124, 125, 126:  // fwd-del/esc/clear/nav
            resetWordState(); return
        case 36, 76:                               // Return / Enter
            commitBoundary("\n"); return
        case 48:                                   // Tab
            commitBoundary("\t"); return
        default:
            break
        }
        for c in chars {
            let step = buffer.input(c)
            if let word = step.completedWord { onBoundary(word, step.boundary) }
        }
    }

    func inputDidChangeFlags(_ flags: CGEventFlags) {
        let mask = store.settings.holdToSuppressModifier
        suppressActive = mask != 0 && (flags.rawValue & UInt64(mask)) == UInt64(mask)
    }

    func inputDidDoubleShift() {
        if store.settings.doubleShiftConvertWord { fix() }   // convert last word + switch layout
    }

    func inputDidClick() { resetWordState() }

    // MARK: - boundary pipeline (auto-convert)

    private func commitBoundary(_ b: Character) {
        let step = buffer.input(b)
        if let word = step.completedWord { onBoundary(word, step.boundary) }
    }

    private func onBoundary(_ word: String, _ boundary: Character?) {
        boundariesSeen += 1
        lastCompleted = LastWord(text: word, boundary: boundary)

        // FR-26: snippet/autoreplace expansion takes priority over conversion.
        if store.settings.expandSnippets,
           let expansion = Snippets.expand(word, using: store.data.snippets) {
            applyReplacement(word, with: expansion, boundary: boundary, layoutAfter: nil)
            return
        }
        // FR-25: fix accidental Caps Lock ("пРИВЕТ"→"Привет") and two leading
        // capitals on the fly (opt-in). Caps-lock pattern is a strong signature
        // (first letter lower, rest upper) → low false-positive.
        if store.settings.autoFixCapitals {
            let fixed = TextFixes.fixCapsLock(TextFixes.fixDoubleCapital(word))
            if fixed != word {
                applyReplacement(word, with: fixed, boundary: boundary, layoutAfter: nil)
                return
            }
        }

        guard store.settings.autoConvertEnabled else {
            note(word, "off"); updateContext(with: word); return
        }
        guard !suppressActive else {
            note(word, "fn-suppress"); updateContext(with: word); return
        }
        guard !fullscreenActive else {
            note(word, "fullscreen"); updateContext(with: word); return
        }
        if layout.isInputMethodActive() {                                         // REL-4
            note(word, "ime"); return       // composing via an IME — not real RU/EN text
        }
        if context.isSecureInput {                                                // SEC-4
            note(word, "secure"); updateContext(with: word); return
        }
        if domainBlocked() {                                                       // REL-6
            note(word, "domain"); updateContext(with: word); return
        }
        let rule = effectiveRule(for: context.frontmostBundleID)                   // FR-32 / per-app
        if rule.mode == .off {
            note(word, "app-off"); updateContext(with: word); return
        }

        let typed = layout.currentLayout()
        let decision = engine.evaluate(word, typedLayout: typed, context: lastContextLayout)
        lastReason = decision.reason.rawValue
        guard decision.shouldConvert else {
            note(word, decision.reason.rawValue)
            updateContext(with: word); return
        }

        if store.settings.shadowMode || rule.mode == .shadow {                    // FR-20 / per-app
            note(word, "shadow", converted: decision.converted)
            record(decision, applied: false)
            updateContext(with: word)
            return
        }

        // Boundary interrupts an earlier pending replacement of the previous word.
        disruptionEpoch &+= 1
        let snapshot = disruptionEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A backspace/click/another boundary arrived first → applying the
            // stale replacement would corrupt; skip (fail-open).
            guard self.disruptionEpoch == snapshot else {
                self.note(word, "raced"); return
            }
            // Absorb plain characters of the next word typed in the same wrong
            // layout (delete + re-insert converted). Pure math lives in the planner.
            let plan = CorrectionPlanner.autoConvert(
                original: word, converted: decision.converted, boundary: boundary,
                extras: self.buffer.word, extrasTo: decision.to)
            self.layout.replace(deleteCount: plan.deleteCount, with: plan.insertText)
            self.layout.select(decision.to)
            if !plan.convertedExtras.isEmpty { self.buffer.replaceWord(plan.convertedExtras) }
            self.feedback()
            self.onConversionApplied?(decision.to, decision.converted)
        }
        conversionsApplied += 1
        note(word, decision.reason.rawValue, converted: decision.converted)
        lastConversion = LastConversion(original: word, converted: decision.converted,
                                        boundary: boundary, layoutBefore: decision.from)
        lastContextLayout = decision.to
        record(decision, applied: true)
    }

    /// Shared replace used by snippets / autofix (no layout switch).
    private func applyReplacement(_ original: String, with text: String,
                                  boundary: Character?, layoutAfter: Layout?) {
        let plan = CorrectionPlanner.replace(original: original, with: text, boundary: boundary)
        let snapshot = keystrokeEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.keystrokeEpoch == snapshot else { return }
            self.layout.replace(deleteCount: plan.deleteCount, with: plan.insertText)
            if let l = layoutAfter { self.layout.select(l) }
        }
        lastCompleted = LastWord(text: text, boundary: boundary)
        lastConversion = LastConversion(original: original, converted: text,
                                        boundary: boundary, layoutBefore: layout.currentLayout() ?? .en)
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

    func fix() {
        guard !mutationBlocked() else { note("⌃⌥Z", "blocked"); return }
        // 1) Actively typing → convert the in-progress word (synthetic, reliable).
        if !buffer.isEmpty {
            note(buffer.word, "fix-buffer")
            fixWord(buffer.word, boundary: nil, inProgress: true); return
        }
        // 2) A real selection (read via AX) → convert it synthetically.
        if let sel = AXText.selectedText(), sel.contains(where: { $0.isLetter }) {
            note(sel.prefix(16).description, "fix-selection")
            convertSelection(sel); return
        }
        // 3) Last finished word (e.g. "пшерги " + double-⇧ → "github ").
        if let last = lastCompleted {
            note(last.text, "fix-last")
            fixWord(last.text, boundary: last.boundary, inProgress: false); return
        }
        // Nothing to fix. We deliberately do NOT probe the clipboard: a Cmd+C/Cmd+V
        // round-trip in Electron/chat apps grabbed and pasted the user's REAL
        // clipboard (a URL → an auto-link) — corruption far worse than a miss.
        note("⌃⌥Z", "nothing-to-fix")
    }

    /// Convert an AX-read selection by replacing it SYNTHETICALLY (Backspace +
    /// insert) — works in Electron where AX writes no-op; never the clipboard.
    private func convertSelection(_ sel: String) {
        let from = sel.dominantLayout ?? layout.currentLayout() ?? .en
        let to = from.other
        let converted = KeyMap.convert(sel, to: to)
        let epoch = keystrokeEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in   // let ⌃⌥/⇧ release
            guard let self, self.keystrokeEpoch == epoch else { return }
            self.layout.replaceSelection(with: converted)
            self.layout.select(to)
            self.onConversionApplied?(to, nil)
            self.onChange?()
        }
    }

    /// Convert a single word in place via synthetic Backspace + insert.
    private func fixWord(_ text: String, boundary: Character?, inProgress: Bool) {
        let from = text.dominantLayout ?? layout.currentLayout() ?? .en
        let to = from.other
        let converted = KeyMap.convert(text, to: to)
        let plan = CorrectionPlanner.replace(original: text, with: converted, boundary: boundary)
        // Snapshot BEFORE the async hop. If the user types between the double-⇧
        // gesture and this running, the on-screen word grew but deleteCount is
        // stale → deleting too few left a leading character ("gпривет"). Any new
        // keystroke bumps keystrokeEpoch → abort cleanly (no state mutated). All
        // state changes live inside the guard so an abort leaves nothing half-done.
        let epoch = keystrokeEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.keystrokeEpoch == epoch else { return }
            self.layout.replace(deleteCount: plan.deleteCount, with: plan.insertText)
            self.layout.select(to)
            self.feedback()
            self.onConversionApplied?(to, converted)
            if inProgress { self.buffer.reset() }
            // Enable the cycle: a second double-⇧ swaps the converted form back.
            self.lastCompleted = LastWord(text: converted, boundary: boundary)
            self.lastConversion = LastConversion(original: text, converted: converted,
                                                 boundary: boundary, layoutBefore: from)
            // Learn from repeated manual fixes: after N, the word joins the dictionary.
            if !converted.contains(" "), self.store.recordManualFix(converted) {
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
        layout.select(to)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in   // let ⌃⌥ release
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
        fullscreenActive = store.settings.disableInFullscreen && AXText.isFrontmostFullscreen()

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
