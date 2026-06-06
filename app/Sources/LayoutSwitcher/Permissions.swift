import AppKit
import ApplicationServices
import IOKit.hid

/// Accessibility + Input Monitoring onboarding (E6.4). Both are granted once,
/// by hand, in System Settings. We detect the missing grant and guide the user
/// rather than failing silently.
///
/// These are TWO separate permissions: Accessibility alone lets us read the
/// focused field, but a keyboard CGEventTap delivers NO events without Input
/// Monitoring — so we check/prompt for it explicitly via IOKit.
enum Permissions {

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Input Monitoring (kTCCServiceListenEvent), checked via IOKit HID.
    static var isInputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Prompt for Input Monitoring and register the app in the System Settings
    /// list. Safe to call repeatedly; no-op once granted.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        if isInputMonitoringGranted { return true }
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Prompts the system Accessibility dialog if not yet trusted.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    /// Shown when the CGEventTap could not be created (Input Monitoring off).
    static func showInputMonitoringAlert() {
        let a = NSAlert()
        a.messageText = "Нужно разрешение Input Monitoring"
        a.informativeText = """
        \(K.appName) перехватывает ввод через CGEventTap. Включите его в \
        Системные настройки → Конфиденциальность и безопасность → \
        Мониторинг ввода (и Универсальный доступ), затем перезапустите приложение.
        """
        a.addButton(withTitle: "Открыть настройки")
        a.addButton(withTitle: "Позже")
        if a.runModal() == .alertFirstButtonReturn { openInputMonitoringSettings() }
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}
