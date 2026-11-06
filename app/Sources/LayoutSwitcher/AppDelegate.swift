import AppKit
import SwitcherCore

/// App composition root + lifecycle/supervision (decomposition module 10).
/// Single-instance, permission onboarding, tap supervision across sleep/wake.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = Store(directory: LiveCheck.dataDirectory)
    private let layout = LayoutController()
    private let context = ContextProvider()
    private let input = InputCapture()
    private let eventLog = EventLog(directory: LiveCheck.dataDirectory)
    private let hotkeys = HotkeyManager()
    private let focus = FocusObserver()
    private let overlay = OverlayController()
    private let speller = SpellerGate()

    private var coordinator: ActionCoordinator!
    private var menuBar: MenuBarController!
    private var settingsWC: SettingsWindowController!
    private var permissionRetry: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ensureSingleInstance() else { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)   // menu-bar only (also LSUIElement in Info.plist)
        // Global cap on every Accessibility call (set on the system-wide element it
        // applies to all). The default is 6 s: one busy Electron renderer could
        // stall our main thread — the same run loop the event tap is serviced on —
        // long enough for macOS to disable the tap (the "rearms" in diagnostics).
        // AX readers here all fail open, so a slow app just reads as "unknown".
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)

        // The layouts this Mac really has, not the ones the static tables assume.
        let keys = layout.physicalKeys()
        if !keys.isEmpty { KeyMap.install(keys) }

        let dicts = Dictionaries.loadForApp()   // bundled + local personal lexicon
        coordinator = ActionCoordinator(store: store, dictionaries: dicts,
                                        layout: layout, context: context, eventLog: eventLog)
        coordinator.engine.warmUp()   // prefix sets now, not inside the first key callback
        let timings = coordinator.timings
        speller.attach(to: coordinator.engine, timings: timings) { [weak coordinator] in
            coordinator?.mayAskSpeller() == true
        }
        coordinator.onWordStart = { [speller] in speller.wakeUp() }
        input.timings = timings
        input.frontmostApp = { [context] in context.frontmostBundleID ?? "" }
        input.delegate = coordinator

        // Restarts used to reset word-learning progress (the manual-fix tally is
        // memory-only per SEC-2). When the user has the event history enabled,
        // rebuild the tally from it so repeated ⇧⇧ fixes keep counting toward
        // learnAfterManualFixes across restarts.
        if store.settings.logHistory {
            var counts: [String: Int] = [:]
            var mentionApps: [String: Int] = [:]
            for e in eventLog.all() where e.kind == "doubleShift" && !e.converted.isEmpty {
                counts[e.converted.lowercased(), default: 0] += 1
                if e.original.hasPrefix("\""), e.converted.hasPrefix("@") { mentionApps[e.app, default: 0] += 1 }
            }
            store.seedManualFixTally(counts)
            store.seedMentionApps(mentionApps)
        }

        let model = SettingsModel(store: store, coordinator: coordinator)
        settingsWC = SettingsWindowController(model: model)
        menuBar = MenuBarController(coordinator: coordinator, settingsWC: settingsWC)

        // State changes refresh both the menu-bar indicator and the caret badge.
        coordinator.onChange = { [weak self] in
            guard let self else { return }
            self.menuBar.refreshTitle()
            self.overlay.refresh(layout: self.coordinator.currentLayout(), settings: self.store.settings)
        }
        coordinator.onConversionApplied = { [weak self] layout, converted in
            guard let self else { return }
            let undoKey = HotkeyManager.describe(.undoConversion, custom: self.store.settings.hotkeys)
            self.overlay.notifySwitch(to: layout, converted: converted, undoKey: undoKey,
                                      settings: self.store.settings)
        }
        coordinator.onWordLearned = { [weak self] word in
            self?.overlay.notifyLearned(word)
        }

        hotkeys.register(.init(
            toggle: { [weak self] in self?.coordinator.toggleAuto() },
            fix: { [weak self] in self?.coordinator.fix() },
            undo: { [weak self] in self?.coordinator.undo() },
            transliterate: { [weak self] in self?.coordinator.transliterateSelection() },
            caseCycle: { [weak self] in self?.coordinator.cycleCaseSelection() },
            fixCaps: { [weak self] in self?.coordinator.fixCapsSelection() },
            convertLine: { [weak self] in self?.coordinator.convertCurrentLine() }
        ), custom: store.settings.hotkeys)

        // Scenario 9.3: re-bind live when the user changes a hotkey in Settings.
        model.onHotkeysChanged = { [weak self] in
            guard let self else { return }
            self.hotkeys.reload(custom: self.store.settings.hotkeys)
        }

        menuBar.diagnostics = { [weak self] in self?.diagnosticsReport() ?? "" }

        context.onFocusRead = { [weak self] in self?.coordinator.handleFocusRead() }
        focus.onFocusChange = { [weak self] in self?.coordinator.handleFocusChange() }
        focus.start()
        context.refreshFocus()

        // Health drives the menu-bar state; the watchdog re-acquires the tap on
        // its own when permissions return, so no separate retry timer is needed.
        input.onHealthChange = { [weak self] health in self?.handleHealth(health) }

        Permissions.requestAccessibility()
        Permissions.requestInputMonitoring()   // prompt + register in the IM list
        input.start()
        observeSystemEvents()
        if LiveCheck.reportPath != nil {
            // The app itself is the "chat" of the run, one that earned the quote rule.
            store.seedMentionApps([Bundle.main.bundleIdentifier ?? "": 12])
            LiveCheck.start(coordinator: coordinator, layout: layout)
        } else {
            LoginItem.set(enabled: store.settings.startAtLogin)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
        eventLog.flushNow()
        input.stop()
        focus.stop()
        hotkeys.unregister()
        overlay.hide()
    }

    // MARK: - capture health → UI (REL-7 / scenario 10.6)

    private var permissionAlertShown = false

    private func handleHealth(_ health: InputCapture.Health) {
        menuBar?.setHealth(health)
        switch health {
        case .active:
            NSLog("[LayoutSwitcher] capture active")
            permissionAlertShown = false        // re-arm the alert for a future revocation
        case .noPermission, .noTap:
            NSLog("[LayoutSwitcher] capture inactive: \(health)")
            if !permissionAlertShown {          // once per transition, not every tick
                permissionAlertShown = true
                Permissions.requestInputMonitoring()
                Permissions.showInputMonitoringAlert()
            }
        case .disabled:
            break
        }
    }

    private func diagnosticsReport() -> String {
        let s = store.settings
        let t = coordinator.timings
        func ms(_ v: Double) -> String { String(format: "%.0f", v) }
        func pairs(_ d: [String: Double], _ format: String) -> String {
            d.sorted { $0.value > $1.value }.map { "\($0.key) \(String(format: format, $0.value))" }
                .joined(separator: ", ")
        }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        return """
        Accessibility trusted: \(Permissions.isAccessibilityTrusted)
        Input Monitoring granted: \(Permissions.isInputMonitoringGranted)
        Event tap active: \(input.isActive)  (rearms: \(input.tapRearms), recreations: \(input.tapRecreations))
        Tap disabled by macOS: timeout \(input.disabledByTimeout), user input \(input.disabledByUserInput)
        Slowest key callback: \(ms(t.slowestMs)) ms (\(t.slowCount) over 50 ms: \(pairs(t.slowByPath.mapValues(Double.init), "%.0f")))
        Slowest stages, ms: \(pairs(t.slowestStages, "%.1f"))
        Queue delay: max \(ms(t.maxQueueDelayMs)) ms, \(t.lateEvents) over 50 ms
        Speller misses: \(t.spellerMisses), field-pending skips: \(t.fieldPendingSkips)
        Key events seen: \(input.eventsSeen)
        Word boundaries seen: \(coordinator.boundariesSeen)
        Conversions applied: \(coordinator.conversionsApplied)
        Last decision: \(coordinator.lastReason)
        Current layout: \(coordinator.currentLayout()?.short ?? "—")
        Auto-convert: \(s.autoConvertEnabled)  Shadow: \(s.shadowMode)
        Suppressing(Fn): \(coordinator.isSuppressing)  Fullscreen-off: \(coordinator.isFullscreen)
        Frontmost fullscreen: \(AXText.isFrontmostFullscreen())  Editable focus: \(context.hasEditableTextFocus())
        Front app: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
        Secure input now: \(context.isSecureInput)
        Blacklisted apps: \(s.appBlacklist.count)
        Dict: ru \(coordinator.engine.learnedWords.count) learned, reverts \(coordinator.engine.learnedReverts.count), mention apps \(store.data.mentionApps.filter { $0.value >= Store.mentionAppThreshold }.count)
        Outcomes: \(coordinator.reasonCounts.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        Recent decisions (new→old):
        \(coordinator.recentDecisions.isEmpty ? "  —" : coordinator.recentDecisions.map { "  " + $0 }.joined(separator: "\n"))
        Slow callbacks (new→old):
        \(t.ring.isEmpty ? "  —" : t.ring.map { "  \(clock.string(from: $0.at)) \($0.path) \(ms($0.totalMs)) ms \(pairs($0.stages, "%.0f")), rest \(ms($0.restMs)) \($0.app)" }.joined(separator: "\n"))
        """
    }

    // MARK: - supervision (REL-7)

    private func observeSystemEvents() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.input.rearmIfNeeded()
                self?.menuBar?.refreshTitle()
            }
        }
        // Monitor attach/detach + resolution change (REL-7 / scenario 10.4).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.input.rearmIfNeeded() }
    }

    // MARK: - single instance (REL-8)

    private func ensureSingleInstance() -> Bool {
        guard let bid = Bundle.main.bundleIdentifier else { return true }   // dev binary: skip
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0 != NSRunningApplication.current }
        return others.isEmpty
    }
}
