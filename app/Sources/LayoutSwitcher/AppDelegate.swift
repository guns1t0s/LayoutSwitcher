import AppKit
import SwitcherCore

/// App composition root + lifecycle/supervision (decomposition module 10).
/// Single-instance, permission onboarding, tap supervision across sleep/wake.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = Store()
    private let layout = LayoutController()
    private let context = ContextProvider()
    private let input = InputCapture()
    private let hotkeys = HotkeyManager()
    private let focus = FocusObserver()
    private let overlay = OverlayController()

    private var coordinator: ActionCoordinator!
    private var menuBar: MenuBarController!
    private var settingsWC: SettingsWindowController!
    private var permissionRetry: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ensureSingleInstance() else { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)   // menu-bar only (also LSUIElement in Info.plist)

        let dicts = Dictionaries.loadBundled()
        coordinator = ActionCoordinator(store: store, dictionaries: dicts,
                                        layout: layout, context: context)
        input.delegate = coordinator

        let model = SettingsModel(store: store, coordinator: coordinator)
        settingsWC = SettingsWindowController(model: model)
        menuBar = MenuBarController(coordinator: coordinator, settingsWC: settingsWC)

        // State changes refresh both the menu-bar indicator and the caret badge.
        coordinator.onChange = { [weak self] in
            guard let self else { return }
            self.menuBar.refreshTitle()
            self.overlay.refresh(layout: self.coordinator.currentLayout(), settings: self.store.settings)
        }
        coordinator.onConversionApplied = { [weak self] layout in
            guard let self else { return }
            self.overlay.notifySwitch(to: layout, settings: self.store.settings)
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

        focus.onFocusChange = { [weak self] in self?.coordinator.handleFocusChange() }
        focus.start()

        Permissions.requestAccessibility()
        Permissions.requestInputMonitoring()   // prompt + register in the IM list
        startInputCapture()
        observeSystemEvents()
        LoginItem.set(enabled: store.settings.startAtLogin)
    }

    func applicationWillTerminate(_ notification: Notification) {
        input.stop()
        focus.stop()
        hotkeys.unregister()
        overlay.hide()
        permissionRetry?.invalidate()
    }

    // MARK: - input capture w/ permission retry

    private func diagnosticsReport() -> String {
        let s = store.settings
        return """
        Accessibility trusted: \(Permissions.isAccessibilityTrusted)
        Input Monitoring granted: \(Permissions.isInputMonitoringGranted)
        Event tap active: \(input.isActive)
        Key events seen: \(input.eventsSeen)
        Word boundaries seen: \(coordinator.boundariesSeen)
        Conversions applied: \(coordinator.conversionsApplied)
        Last decision: \(coordinator.lastReason)
        Current layout: \(coordinator.currentLayout()?.short ?? "—")
        Auto-convert: \(s.autoConvertEnabled)  Shadow: \(s.shadowMode)
        Suppressing(Fn): \(coordinator.isSuppressing)  Fullscreen-off: \(coordinator.isFullscreen)
        Front app: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
        Secure input now: \(context.isSecureInput)
        Blacklisted apps: \(s.appBlacklist.count)
        """
    }

    private func startInputCapture() {
        // A keyboard tap created with Accessibility alone is "active" but
        // receives NO events — Input Monitoring is the gate. Require both.
        let ready = input.start() && Permissions.isInputMonitoringGranted
        if ready {
            NSLog("[LayoutSwitcher] event tap active + Input Monitoring granted")
            permissionRetry?.invalidate(); permissionRetry = nil
            menuBar?.refreshTitle()
            return
        }
        NSLog("[LayoutSwitcher] not ready — IM granted: \(Permissions.isInputMonitoringGranted), AX: \(Permissions.isAccessibilityTrusted)")
        Permissions.requestInputMonitoring()
        Permissions.showInputMonitoringAlert()
        if permissionRetry == nil {
            permissionRetry = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.input.start() && Permissions.isInputMonitoringGranted {
                    self.permissionRetry?.invalidate(); self.permissionRetry = nil
                    self.menuBar?.refreshTitle()
                    NSLog("[LayoutSwitcher] Input Monitoring now granted — tap live")
                }
            }
        }
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
