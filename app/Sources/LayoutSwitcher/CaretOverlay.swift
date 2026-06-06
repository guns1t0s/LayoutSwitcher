import AppKit
import SwitcherCore

/// Caret-anchored visuals (E5.2/E5.5). A persistent layout badge near the caret
/// (FR-1), a transient switch toast (FR-2), and a flash on conversion (E5.5).
/// Each is independently toggleable (FR-3); if the caret position is
/// unavailable, the badge simply hides and the menu-bar indicator stands in.
final class OverlayController {
    private let badge = OverlayController.makePanel()
    private let toast = OverlayController.makePanel()
    private let badgeLabel = OverlayController.makeLabel()
    private let toastLabel = OverlayController.makeLabel()
    private var toastWork: DispatchWorkItem?

    init() {
        (badge.contentView as? CapsuleView)?.embed(badgeLabel)
        (toast.contentView as? CapsuleView)?.embed(toastLabel)
    }

    /// Refresh the persistent badge to the current layout (FR-1/FR-3).
    func refresh(layout: Layout?, settings: Settings) {
        guard settings.showCaretIndicator, let layout, let rect = AXText.caretRect() else {
            badge.orderOut(nil); return
        }
        badgeLabel.stringValue = layout.short
        badgeLabel.textColor = .secondaryLabelColor
        sizeToFit(badge, label: badgeLabel)
        let size = badge.frame.size
        badge.setFrameOrigin(NSPoint(x: rect.minX, y: rect.minY - size.height - 2))
        badge.orderFrontRegardless()
    }

    /// Switch happened → toast (FR-2) and/or flash (E5.5).
    func notifySwitch(to layout: Layout, settings: Settings) {
        if settings.flashOnConvert { flashBadge() }
        guard settings.showSwitchToast else { return }
        toastLabel.stringValue = "▸ \(layout.short)"
        toastLabel.textColor = .labelColor
        sizeToFit(toast, label: toastLabel)
        let size = toast.frame.size
        if let rect = AXText.caretRect() {
            toast.setFrameOrigin(NSPoint(x: rect.minX, y: rect.maxY + 6))
        } else if let screen = NSScreen.main {
            toast.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2,
                                         y: screen.frame.maxY - 120))
        }
        toast.alphaValue = 1
        toast.orderFrontRegardless()
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut(self?.toast) }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func hide() { badge.orderOut(nil); toast.orderOut(nil) }

    // MARK: - effects

    private func flashBadge() {
        guard let view = badge.contentView as? CapsuleView else { return }
        view.flash()
        badge.orderFrontRegardless()
    }

    private func fadeOut(_ panel: NSPanel?) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func sizeToFit(_ panel: NSPanel, label: NSTextField) {
        label.sizeToFit()
        let w = max(34, label.frame.width + 16)
        let h = max(20, label.frame.height + 8)
        panel.setContentSize(NSSize(width: w, height: h))
    }

    // MARK: - factory

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 22),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = CapsuleView()
        return panel
    }

    private static func makeLabel() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.alignment = .center
        l.backgroundColor = .clear
        l.isBezeled = false
        l.isEditable = false
        return l
    }
}

/// Rounded translucent capsule background for the overlay panels.
private final class CapsuleView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func embed(_ label: NSTextField) {
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func flash() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        anim.toValue = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        anim.duration = 0.35
        layer?.add(anim, forKey: "flash")
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
    }
}
