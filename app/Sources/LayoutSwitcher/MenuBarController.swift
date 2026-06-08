import AppKit
import Carbon
import SwitcherCore

/// Menu-bar agent UI (FR-33, E5.1). Shows the live layout, quick toggles,
/// shadow-mode, a recent-conversions review submenu, settings and quit.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let coordinator: ActionCoordinator
    private let settingsWC: SettingsWindowController
    var diagnostics: (() -> String)?

    init(coordinator: ActionCoordinator, settingsWC: SettingsWindowController) {
        self.coordinator = coordinator
        self.settingsWC = settingsWC
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        loadMenuBarIcon()
        refreshTitle()
        observeLayoutChanges()
    }

    private var hasIcon = false

    /// Monochrome template glyph (system recolours it for light/dark menu bars).
    /// `NSImage(named:)` picks up the @2x variant; the "Template" name sets
    /// isTemplate automatically. Optional.
    private func loadMenuBarIcon() {
        let img = NSImage(named: NSImage.Name("MenuBarIconTemplate"))
            ?? Bundle.main.url(forResource: "MenuBarIconTemplate", withExtension: "png")
                .flatMap { NSImage(contentsOf: $0) }
        guard let icon = img else { return }
        icon.isTemplate = true
        icon.size = NSSize(width: 16, height: 16)
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageLeading
        hasIcon = true
    }

    // MARK: - title / indicator (FR-1/FR-2/FR-3)

    func refreshTitle() {
        // Icon-only menu bar — no layout/state text (keeps it uncluttered). The
        // current layout still shows in the dropdown header and the caret overlay.
        if hasIcon {
            statusItem.button?.title = ""
        } else {
            // No icon asset loaded → fall back to text so the item stays clickable.
            statusItem.button?.title = coordinator.currentLayout()?.short ?? "ЯА"
        }
    }

    private func observeLayoutChanges() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(layoutChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil)
    }
    @objc private func layoutChanged() {
        DispatchQueue.main.async { [weak self] in self?.refreshTitle() }
    }

    // MARK: - menu (rebuilt on open so checkmarks/recent stay fresh)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = coordinator.store.settings

        let layout = coordinator.currentLayout()?.short ?? "—"
        menu.addItem(withTitle: "Раскладка: \(layout)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        add(menu, "Автоконвертация", on: s.autoConvertEnabled,
            key: "a", #selector(toggleAuto))
        add(menu, "Shadow-mode (только лог)", on: s.shadowMode,
            key: "s", #selector(toggleShadow))
        menu.addItem(.separator())

        let recent = NSMenuItem(title: "Недавние конвертации", action: nil, keyEquivalent: "")
        recent.submenu = buildRecentMenu()
        menu.addItem(recent)

        let tools = NSMenuItem(title: "Текст (выделение)", action: nil, keyEquivalent: "")
        tools.submenu = buildToolsMenu()
        menu.addItem(tools)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Диагностика…", action: #selector(showDiagnostics), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Выход", action: #selector(quit), keyEquivalent: "q").target = self
    }

    private func add(_ menu: NSMenu, _ title: String, on: Bool, key: String, _ sel: Selector) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.control, .option]
        item.state = on ? .on : .off
        item.target = self
        menu.addItem(item)
    }

    private func buildRecentMenu() -> NSMenu {
        let sub = NSMenu()
        let log = coordinator.shadowLog
        if log.isEmpty {
            sub.addItem(withTitle: "(пусто)", action: nil, keyEquivalent: "")
            return sub
        }
        for entry in log.prefix(20) {
            let mark = entry.applied ? "✓" : "•"
            let title = "\(mark) \(entry.original) → \(entry.converted)  [\(entry.from.short)→\(entry.to.short)]"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let actions = NSMenu()
            actions.addItem(withTitle: "В исключения", action: #selector(addException(_:)), keyEquivalent: "")
                .representedObject = entry.original
            actions.addItem(withTitle: "В белый список", action: #selector(addWhitelist(_:)), keyEquivalent: "")
                .representedObject = entry.original
            for i in actions.items { i.target = self }
            item.submenu = actions
            sub.addItem(item)
        }
        return sub
    }

    private func buildToolsMenu() -> NSMenu {
        let sub = NSMenu()
        let items: [(String, Selector, HotkeyManager.Action)] = [
            ("Транслитерация", #selector(translit), .transliterate),
            ("Сменить регистр", #selector(caseCycle), .caseCycle),
            ("Исправить Caps/2 заглавные", #selector(fixCaps), .fixCaps),
            ("Конвертировать строку", #selector(convertLine), .convertLine),
        ]
        for (title, sel, action) in items {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.toolTip = HotkeyManager.describe(action)
            item.target = self
            sub.addItem(item)
        }
        return sub
    }

    // MARK: - actions

    @objc private func toggleAuto() { coordinator.toggleAuto() }
    @objc private func translit() { coordinator.transliterateSelection() }
    @objc private func caseCycle() { coordinator.cycleCaseSelection() }
    @objc private func fixCaps() { coordinator.fixCapsSelection() }
    @objc private func convertLine() { coordinator.convertCurrentLine() }
    @objc private func toggleShadow() { coordinator.setShadowMode(!coordinator.store.settings.shadowMode) }
    @objc private func openSettings() { settingsWC.show() }
    @objc private func showDiagnostics() {
        let a = NSAlert()
        a.messageText = "Диагностика"
        a.informativeText = diagnostics?() ?? "нет данных"
        a.addButton(withTitle: "Копировать")
        a.addButton(withTitle: "Закрыть")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(a.informativeText, forType: .string)
        }
    }
    @objc private func addException(_ sender: NSMenuItem) {
        if let w = sender.representedObject as? String { coordinator.addToExceptions(w) }
    }
    @objc private func addWhitelist(_ sender: NSMenuItem) {
        if let w = sender.representedObject as? String { coordinator.addToWhitelist(w) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
