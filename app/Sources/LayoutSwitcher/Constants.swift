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

    /// A ⇧⇧ landing this soon after an auto-conversion was started before the user
    /// could see it: it is aimed at the word as it looked, not at the result. All
    /// four reverts of 28.10-06.11 came 0.47-0.72 s after the conversion, and all
    /// four were undone by another ⇧⇧ within a second.
    static let fixAfterConversionGrace: TimeInterval = 1.0

    /// Where the EN→RU mid-word rule stays out: terminals, editors and remote
    /// sessions are where identifiers no dictionary knows are typed on purpose.
    static func isCodeApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return codeApps.contains(id) || id.hasPrefix("com.jetbrains.")
    }
    private static let codeApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "io.alacritty", "co.zeit.hyper", "com.apple.Console",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4",
        "com.microsoft.rdc.macos",
    ]

    static let appName = "LayoutSwitcher"
}
