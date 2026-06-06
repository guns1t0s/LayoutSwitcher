import SwiftUI
import AppKit
import CoreGraphics
import Carbon
import SwitcherCore

/// Backs the settings window. Writes straight through to the Store and re-syncs
/// the engine on every change (FR-34/FR-35). All local, no network.
final class SettingsModel: ObservableObject {
    private let store: Store
    private weak var coordinator: ActionCoordinator?

    @Published var settings: SwitcherCore.Settings { didSet { persist() } }
    @Published var exceptionsText: String
    @Published var whitelistText: String
    @Published var snippetsText: String
    @Published var blacklistText: String

    /// Set by AppDelegate to re-bind global hotkeys live (scenario 9.3).
    var onHotkeysChanged: (() -> Void)?

    func setHotkey(_ action: HotkeyManager.Action, _ hk: Hotkey) {
        settings.hotkeys[action.id] = hk      // persisted via didSet
        onHotkeysChanged?()
    }
    func resetHotkey(_ action: HotkeyManager.Action) {
        settings.hotkeys[action.id] = nil
        onHotkeysChanged?()
    }

    init(store: Store, coordinator: ActionCoordinator) {
        self.store = store
        self.coordinator = coordinator
        self.settings = store.settings
        self.exceptionsText = store.data.exceptions.sorted().joined(separator: "\n")
        self.whitelistText = store.data.whitelistLatin.sorted().joined(separator: "\n")
        self.snippetsText = store.data.snippets.map { "\($0.key) = \($0.value)" }
            .sorted().joined(separator: "\n")
        self.blacklistText = store.settings.appBlacklist.joined(separator: "\n")
    }

    private func persist() {
        store.updateSettings { $0 = settings }
        LoginItem.set(enabled: settings.startAtLogin)
        coordinator?.syncFromStore()
    }

    func commitLexicons() {
        store.updateData {
            $0.exceptions = Set(tokens(exceptionsText))
            $0.whitelistLatin = Set(tokens(whitelistText))
            $0.snippets = parseSnippets(snippetsText)
        }
        settings.appBlacklist = blacklistText
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        coordinator?.syncFromStore()
    }

    private func parseSnippets(_ text: String) -> [String: String] {
        var map = [String: String]()
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !val.isEmpty { map[key] = val }
        }
        return map
    }

    func resetDefaults() {
        store.resetSettings()
        settings = store.settings
        coordinator?.syncFromStore()
        onHotkeysChanged?()
    }

    func importCorpus() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        // FR-22: latin terms from your own text → whitelist so they stop flipping.
        let latin = tokens(text).filter { $0.count >= 3 && $0.allSatisfy { $0.isLatinLetter } }
        store.importWords(latin, into: \.whitelistLatin)
        whitelistText = store.data.whitelistLatin.sorted().joined(separator: "\n")
        coordinator?.syncFromStore()
    }

    func exportData() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "layoutswitcher-data.json"
        guard panel.runModal() == .OK, let url = panel.url, let data = store.exportData() else { return }
        try? data.write(to: url)
    }

    private func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " })
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            general.tabItem { Text("Общие") }
            switching.tabItem { Text("Переключение") }
            lexicons.tabItem { Text("Словари") }
            textTools.tabItem { Text("Текст") }
            hotkeys.tabItem { Text("Хоткеи") }
        }
        .frame(width: 470, height: 440)
        .padding()
    }

    private var general: some View {
        Form {
            Toggle("Автоконвертация", isOn: $model.settings.autoConvertEnabled)
            Toggle("Shadow-mode (только лог, не меняет текст)", isOn: $model.settings.shadowMode)
            Toggle("Автозапуск при входе", isOn: $model.settings.startAtLogin)
            Divider()
            Toggle("Индикатор в строке меню", isOn: $model.settings.showMenuBarIndicator)
            Toggle("Индикатор у курсора", isOn: $model.settings.showCaretIndicator)
            Toggle("Всплывающее уведомление при переключении", isOn: $model.settings.showSwitchToast)
            Divider()
            Toggle("Запоминать раскладку по приложению", isOn: $model.settings.rememberLayoutPerApp)
            Toggle("Латиница для url/email/поиск/пароль", isOn: $model.settings.latinForUrlEmailSearch)
            Toggle("Отключаться в полноэкранных приложениях", isOn: $model.settings.disableInFullscreen)
            Divider()
            Toggle("Звук при конвертации", isOn: $model.settings.soundOnConvert)
            Toggle("Вспышка при конвертации", isOn: $model.settings.flashOnConvert)
            Button("Сброс к умолчаниям") { model.resetDefaults() }
        }
    }

    private var switching: some View {
        Form {
            VStack(alignment: .leading) {
                Text("Порог уверенности: \(model.settings.threshold, specifier: "%.2f")")
                Slider(value: $model.settings.threshold, in: 0.5...0.95, step: 0.01)
                Text("Ниже порога — текст не меняется (при сомнении бездействие).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Stepper("Мин. длина слова: \(model.settings.minWordLength)",
                    value: $model.settings.minWordLength, in: 2...8)
            Toggle("Конвертировать неоднозначные (валидно в обеих)", isOn: $model.settings.convertAmbiguous)
            Toggle("Двойной ⇧ — переключить раскладку", isOn: $model.settings.doubleShiftSwitchLayout)
            Toggle("Глушить автоконвертацию при удержании Fn", isOn: Binding(
                get: { model.settings.holdToSuppressModifier != 0 },
                set: { model.settings.holdToSuppressModifier = $0
                    ? UInt(CGEventFlags.maskSecondaryFn.rawValue) : 0 }))
        }
    }

    private var lexicons: some View {
        VStack(alignment: .leading) {
            Text("Исключения (не конвертировать), по одному в строке:")
            TextEditor(text: $model.exceptionsText).font(.system(.body, design: .monospaced))
                .frame(height: 110).border(.secondary)
            Text("Белый список «всегда латиница» (API, sprint, PR…):")
            TextEditor(text: $model.whitelistText).font(.system(.body, design: .monospaced))
                .frame(height: 90).border(.secondary)
            Text("Чёрный список приложений (bundle id), по одному в строке:")
            TextEditor(text: $model.blacklistText).font(.system(.body, design: .monospaced))
                .frame(height: 60).border(.secondary)
            HStack {
                Button("Применить") { model.commitLexicons() }
                Button("Импорт текста…") { model.importCorpus() }
                Button("Экспорт данных…") { model.exportData() }
            }
        }
    }

    private var textTools: some View {
        VStack(alignment: .leading) {
            Toggle("Раскрывать сниппеты (FR-26)", isOn: $model.settings.expandSnippets)
            Toggle("Исправлять 2 заглавные на границе слова", isOn: $model.settings.autoFixCapitals)
            Text("Сниппеты — по строке «ключ = раскрытие»:")
            TextEditor(text: $model.snippetsText).font(.system(.body, design: .monospaced))
                .frame(height: 150).border(.secondary)
            Text("Пример: брб = буду рядом быстро")
                .font(.caption).foregroundStyle(.secondary)
            Button("Применить") { model.commitLexicons() }
        }
    }

    private var hotkeys: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(HotkeyManager.Action.allCases, id: \.rawValue) { action in
                HStack {
                    Text(action.title).frame(width: 230, alignment: .leading)
                    HotkeyRecorder(
                        label: HotkeyManager.describe(model.settings.hotkeys[action.id] ?? action.defaultHotkey),
                        onCapture: { model.setHotkey(action, $0) })
                    Button("⟲") { model.resetHotkey(action) }.help("Сбросить к умолчанию")
                }
            }
            Text("Кликни поле и нажми сочетание. ⌘Z не используется (не конфликтует).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Click → captures the next key-combo into a `Hotkey` (scenario 9.3).
struct HotkeyRecorder: NSViewRepresentable {
    let label: String
    let onCapture: (Hotkey) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton(); b.onCapture = onCapture; b.title = label; return b
    }
    func updateNSView(_ b: RecorderButton, context: Context) {
        b.onCapture = onCapture
        if !b.recording { b.title = label }
    }
}

final class RecorderButton: NSButton {
    var onCapture: ((Hotkey) -> Void)?
    private(set) var recording = false

    override init(frame: NSRect) { super.init(frame: frame); setButtonType(.momentaryPushIn); bezelStyle = .rounded }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        recording = true; title = "нажми сочетание…"; window?.makeFirstResponder(self)
    }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option)  { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift)   { mods |= UInt32(shiftKey) }
        recording = false
        onCapture?(Hotkey(keyCode: UInt32(event.keyCode), mods: mods))
    }
}

/// Hosts the SwiftUI settings in a normal window from a menu-bar-only app.
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) { self.model = model }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "\(K.appName) — Настройки"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
