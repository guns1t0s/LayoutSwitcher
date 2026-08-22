import Foundation

enum K {
    /// Tag stamped on synthetic events we post, so our own CGEventTap ignores
    /// them (otherwise backspaces/inserts would re-enter the pipeline).
    static let syntheticTag: Int64 = 0x4C53_5754   // "LSWT"

    /// Double-tap window for the ⇧⇧ manual-fix gesture.
    static let doubleShiftWindow: TimeInterval = 0.30

    /// How long after OUR layout switch the event tap may still report keystrokes
    /// resolved with the PREVIOUS layout (see ActionCoordinator.aligned).
    static let layoutSkewWindow: TimeInterval = 1.0

    static let appName = "LayoutSwitcher"
}
