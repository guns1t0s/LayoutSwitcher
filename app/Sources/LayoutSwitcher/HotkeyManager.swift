import Carbon
import AppKit
import SwitcherCore

/// Global hotkeys via Carbon `RegisterEventHotKey` — reliable system-wide and
/// independent of the CGEventTap. Bindings are rebindable (scenario 9.3): each
/// action falls back to a sensible default unless overridden in Settings.
/// Defaults avoid ⌘Z so undo never collides with native undo (FR-15).
final class HotkeyManager {

    enum Action: UInt32, CaseIterable {
        case toggleAuto = 1, fixLastWord, undoConversion, transliterate, caseCycle, fixCaps, convertLine

        var id: String { String(describing: self) }   // stable key for Settings
        var title: String {
            switch self {
            case .toggleAuto: return "Переключить автоконвертацию"
            case .fixLastWord: return "Исправить последнее слово"
            case .undoConversion: return "Отменить конвертацию"
            case .transliterate: return "Транслитерация выделения"
            case .caseCycle: return "Сменить регистр выделения"
            case .fixCaps: return "Исправить Caps выделения"
            case .convertLine: return "Конвертировать строку"
            }
        }
        var defaultHotkey: Hotkey {
            let m = UInt32(controlKey | optionKey)
            switch self {
            case .toggleAuto: return Hotkey(keyCode: UInt32(kVK_ANSI_A), mods: m)
            case .fixLastWord: return Hotkey(keyCode: UInt32(kVK_ANSI_Z), mods: m)
            case .undoConversion: return Hotkey(keyCode: UInt32(kVK_ANSI_X), mods: m)
            case .transliterate: return Hotkey(keyCode: UInt32(kVK_ANSI_T), mods: m)
            case .caseCycle: return Hotkey(keyCode: UInt32(kVK_ANSI_C), mods: m)
            case .fixCaps: return Hotkey(keyCode: UInt32(kVK_ANSI_U), mods: m)
            case .convertLine: return Hotkey(keyCode: UInt32(kVK_ANSI_L), mods: m)
            }
        }
    }

    struct Handlers {
        let toggle, fix, undo, transliterate, caseCycle, fixCaps, convertLine: () -> Void
        func closure(for a: Action) -> () -> Void {
            switch a {
            case .toggleAuto: return toggle
            case .fixLastWord: return fix
            case .undoConversion: return undo
            case .transliterate: return transliterate
            case .caseCycle: return caseCycle
            case .fixCaps: return fixCaps
            case .convertLine: return convertLine
            }
        }
    }

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var handlers: Handlers?

    private static var actions: [UInt32: () -> Void] = [:]

    func register(_ h: Handlers, custom: [String: Hotkey]) {
        handlers = h
        installHandler()
        bind(custom: custom)
    }

    /// Re-bind after the user changes a hotkey (scenario 9.3): old combo stops, new works.
    func reload(custom: [String: Hotkey]) {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        bind(custom: custom)
    }

    private func bind(custom: [String: Hotkey]) {
        guard let h = handlers else { return }
        for action in Action.allCases {
            HotkeyManager.actions[action.rawValue] = h.closure(for: action)
            let hk = custom[action.id] ?? action.defaultHotkey
            add(keyCode: hk.keyCode, mods: hk.mods, action: action)
        }
    }

    static func describe(_ action: Action, custom: [String: Hotkey] = [:]) -> String {
        describe(custom[action.id] ?? action.defaultHotkey)
    }

    static func describe(_ hk: Hotkey) -> String {
        var s = ""
        if hk.mods & UInt32(controlKey) != 0 { s += "⌃" }
        if hk.mods & UInt32(optionKey)  != 0 { s += "⌥" }
        if hk.mods & UInt32(shiftKey)   != 0 { s += "⇧" }
        if hk.mods & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + keyName(hk.keyCode)
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotkeyManager.actions[hk.id]?()
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func add(keyCode: UInt32, mods: UInt32, action: Action) {
        let id = EventHotKeyID(signature: OSType(0x4C535754 /* LSWT */), id: action.rawValue)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    func unregister() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    // Minimal keyCode → label map for display (ANSI).
    private static let names: [UInt32: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",
        14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",
        45:"N",46:"M",18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",
        44:"/",47:".",43:",",27:"-",24:"=",49:"Space",36:"↩",48:"⇥",53:"⎋"
    ]
    static func keyName(_ code: UInt32) -> String { names[code] ?? "key\(code)" }
}
