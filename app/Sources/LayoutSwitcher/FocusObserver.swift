import AppKit
import ApplicationServices

/// Fires whenever the focused field or frontmost app changes, so the
/// coordinator can proactively set the layout *before* typing (FR-4/5/6) and
/// reset the word buffer. Uses an AXObserver rebound to each frontmost app.
final class FocusObserver {
    var onFocusChange: (() -> Void)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var activationToken: NSObjectProtocol?
    private var currentPID: pid_t = 0

    func start() {
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.bind(to: app.processIdentifier)
            self?.onFocusChange?()
        }
        if let front = NSWorkspace.shared.frontmostApplication { bind(to: front.processIdentifier) }
    }

    func stop() {
        if let token = activationToken { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        teardownObserver()
    }

    private func bind(to pid: pid_t) {
        guard pid != currentPID else { return }
        teardownObserver()
        currentPID = pid

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FocusObserver>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { me.onFocusChange?() }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let observer = obs else { return }
        self.observer = observer
        let app = AXUIElementCreateApplication(pid)
        self.appElement = app
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notif in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, app, notif as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func teardownObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        currentPID = 0
    }
}
