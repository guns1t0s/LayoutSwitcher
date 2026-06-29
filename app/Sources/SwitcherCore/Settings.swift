import Foundation

/// Per-application behaviour rule (generalizes the all-or-nothing blacklist).
public struct AppRule: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case auto, shadow, off }
    public var mode: Mode
    public var forceLayout: Layout?     // set this layout when the app gets focus
    public init(mode: Mode = .auto, forceLayout: Layout? = nil) {
        self.mode = mode; self.forceLayout = forceLayout
    }
}

/// A rebindable global hotkey (Carbon virtual keyCode + modifier mask).
public struct Hotkey: Codable, Sendable, Equatable {
    public var keyCode: UInt32
    public var mods: UInt32
    public init(keyCode: UInt32, mods: UInt32) { self.keyCode = keyCode; self.mods = mods }
}

/// All user-facing knobs (FR-34). Plain Codable → JSON, persisted locally.
public struct Settings: Codable, Sendable, Equatable {
    // General
    public var autoConvertEnabled: Bool = true
    public var shadowMode: Bool = false              // FR-20: log-only, never edits
    public var startAtLogin: Bool = false

    // Switching policy
    public var threshold: Double = 0.8               // FR-10 confidence gate
    public var minWordLength: Int = 4
    public var convertAmbiguous: Bool = false

    // Indication (FR-1..FR-3)
    public var showMenuBarIndicator: Bool = true
    public var showCaretIndicator: Bool = false
    public var showSwitchToast: Bool = false

    // Proactive layout (FR-4/FR-5)
    public var rememberLayoutPerApp: Bool = true
    public var latinForUrlEmailSearch: Bool = true

    // Hotkeys (FR-13)
    public var doubleShiftConvertWord: Bool = true   // double-tap ⇧ = convert last word + switch
    public var holdToSuppressModifier: UInt = 0      // e.g. Fn; 0 = off (FR-14)

    /// Customisable global hotkeys (FR-34 / scenario 9.3). Carbon keyCode + modifier
    /// mask. Empty → HotkeyManager uses its defaults.
    public var hotkeys: [String: Hotkey] = [:]

    // Feedback (default off, FR-34)
    public var soundOnConvert: Bool = false
    public var flashOnConvert: Bool = false

    // Text tools (EPIC 7)
    public var autoFixCapitals: Bool = false         // FR-25 on word boundary
    public var expandSnippets: Bool = true           // FR-26

    /// Learn a word into the dictionary after this many manual fixes of it
    /// (double-⇧). 0 = off. Lets the lexicon grow from real corrections.
    public var learnAfterManualFixes: Int = 3

    // Fullscreen auto-disable (FR-31)
    public var disableInFullscreen: Bool = true

    // Blacklist (FR-32) — app bundle IDs where the agent stays silent.
    public var appBlacklist: [String] = []

    /// Opt-in diagnostics: persist a history of switching actions (auto-convert,
    /// double-⇧ fixes, undos) to disk for later analysis of false triggers.
    /// OFF by default — when on it writes raw typed words, which SEC-2 otherwise
    /// forbids; the user enables it knowingly to debug erroneous conversions.
    public var logHistory: Bool = false

    public init() {}
}

/// One entry in the shadow / recent-conversions review log (FR-21).
/// Ephemeral ring buffer — never persisted to disk (SEC-2).
public struct ShadowEntry: Sendable, Identifiable, Equatable {
    public let id: Int
    public let original: String
    public let converted: String
    public let from: Layout
    public let to: Layout
    public let confidence: Double
    public let reason: DetectionReason
    public let applied: Bool                          // false in shadow-mode
    public init(id: Int, original: String, converted: String, from: Layout, to: Layout,
                confidence: Double, reason: DetectionReason, applied: Bool) {
        self.id = id; self.original = original; self.converted = converted
        self.from = from; self.to = to; self.confidence = confidence
        self.reason = reason; self.applied = applied
    }
}

/// Persisted lexicons + layout memory (everything user-owned, FR-16/17/18, §3).
public struct UserData: Codable, Sendable, Equatable {
    public var exceptions: Set<String> = []
    public var whitelistLatin: Set<String> = ["api", "sprint", "backlog", "pr",
                                              "fetch", "commit", "merge", "release"]
    public var learnedReverts: [String: Int] = [:]   // word → revert count
    public var layoutMemory: [String: Layout] = [:]  // "bundleID|role" → layout
    public var snippets: [String: String] = [:]      // abbrev → expansion (FR-26)
    public var appRules: [String: AppRule] = [:]      // bundleID → per-app behaviour
    public var domainBlacklist: Set<String> = []      // browser hosts where the agent stands down (REL-6)
    public var learnedWords: Set<String> = []        // promoted to the dictionary
    // NB: the manual-fix tally is deliberately NOT stored here — it would write
    // raw typed words (incl. typos/secrets) to disk, violating SEC-2. The Store
    // keeps it in memory only and persists just the promoted `learnedWords`.
    public init() {}
}
