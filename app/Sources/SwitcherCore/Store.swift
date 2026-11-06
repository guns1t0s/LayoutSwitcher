import Foundation

/// Local, atomic persistence for `Settings` and `UserData` (REL-8, SEC-3).
/// Files live under Application Support; writes are atomic to survive crashes.
/// No network, ever.
public final class Store: @unchecked Sendable {
    public private(set) var settings: Settings
    public private(set) var data: UserData

    private let dir: URL
    private let settingsURL: URL
    private let dataURL: URL
    /// Serializes every userdata.json write. `rememberLayout` runs on the keystroke
    /// path, where a file write must not happen (see `saveDataLater`).
    private let io = DispatchQueue(label: "com.oateplov.layoutswitcher.store")
    private var pendingData: UserData?      // guarded by `io`

    public init(directory: URL? = nil) {
        let base = directory ?? Store.defaultDirectory()
        self.dir = base
        self.settingsURL = base.appendingPathComponent("settings.json")
        self.dataURL = base.appendingPathComponent("userdata.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.settings = Store.decode(Settings.self, from: settingsURL) ?? Settings()
        self.data = Store.decode(UserData.self, from: dataURL) ?? UserData()
        // Migration: older builds persisted a raw manual-fix tally
        // ("learnedWordCounts") with typed fragments. Re-save once to scrub it
        // (the field no longer exists, so re-encoding drops it from disk).
        if let raw = try? String(contentsOf: dataURL, encoding: .utf8),
           raw.contains("learnedWordCounts") {
            save(data, to: dataURL)
        }
    }

    public static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("LayoutSwitcher", isDirectory: true)
    }

    // MARK: mutate + persist

    public func updateSettings(_ mutate: (inout Settings) -> Void) {
        mutate(&settings)
        save(settings, to: settingsURL)
    }

    public func updateData(_ mutate: (inout UserData) -> Void) {
        mutate(&data)
        let snapshot = data
        // A complete snapshot supersedes any deferred one, which must not land later.
        io.sync { pendingData = nil; save(snapshot, to: dataURL) }
    }

    /// Write a snapshot of the data shortly, off the calling thread. Layout memory
    /// changes on every switch between languages, on the thread that services the
    /// event tap, and an atomic file write there can stall typing (more so under an
    /// endpoint agent). Writes coalesce; a crash loses at most the last second of it.
    private func saveDataLater() {
        let snapshot = data
        io.async { [self] in
            let armed = pendingData != nil
            pendingData = snapshot
            guard !armed else { return }
            io.asyncAfter(deadline: .now() + 1) { [self] in writePending() }
        }
    }

    private func writePending() {
        if let d = pendingData { pendingData = nil; save(d, to: dataURL) }
    }

    /// Write out anything deferred (at quit).
    public func flush() { io.sync { writePending() } }

    public func resetSettings() {
        settings = Settings()
        save(settings, to: settingsURL)
    }

    // MARK: import / export (FR-22, FR-34)

    /// Merge a personal corpus into exceptions or whitelist.
    public func importWords(_ words: [String], into target: WritableKeyPath<UserData, Set<String>>) {
        updateData { d in
            for w in words {
                let t = w.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { d[keyPath: target].insert(t) }
            }
        }
    }

    public func exportData() -> Data? {
        try? JSONEncoder().encode(data)
    }

    // MARK: layout memory (FR-4)

    public func rememberLayout(_ layout: Layout, bundleID: String, role: String = "") {
        data.layoutMemory["\(bundleID)|\(role)"] = layout
        saveDataLater()
    }
    public func recalledLayout(bundleID: String, role: String = "") -> Layout? {
        data.layoutMemory["\(bundleID)|\(role)"]
    }

    // MARK: learn words from repeated manual fixes

    /// Ephemeral manual-fix tally — IN MEMORY ONLY, never written to disk (SEC-2:
    /// raw typed words must not be persisted). Cleared on quit.
    private var manualFixCounts: [String: Int] = [:]

    /// Rebuild the manual-fix tally from an external source (the opt-in event
    /// history) so app restarts don't reset learning progress. Only counts below
    /// the learning threshold are seeded; already-learned words are skipped.
    /// SEC-2 note: this READS the user-enabled history, it never writes new raw
    /// words to disk itself.
    public func seedManualFixTally(_ counts: [String: Int]) {
        let n = settings.learnAfterManualFixes
        guard n > 0 else { return }
        for (word, c) in counts {
            let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard w.count >= 2, w.contains(where: { $0.isLetter }),
                  !w.contains(" "), !data.learnedWords.contains(w) else { continue }
            manualFixCounts[w] = min(c, n - 1)   // next real fix can promote it
        }
    }

    /// Tally a manually-fixed word; once it crosses `learnAfterManualFixes`,
    /// promote it into the persisted dictionary. Returns true the moment it's learned.
    public func recordManualFix(_ word: String) -> Bool {
        let n = settings.learnAfterManualFixes
        guard n > 0 else { return false }
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard w.count >= 2, w.contains(where: { $0.isLetter }) else { return false }
        if data.learnedWords.contains(w) { return false }
        let c = (manualFixCounts[w] ?? 0) + 1
        if c >= n {
            manualFixCounts[w] = nil
            updateData { $0.learnedWords.insert(w) }     // only the promoted word touches disk
            return true
        }
        manualFixCounts[w] = c
        return false
    }

    // MARK: quote as mention

    /// Manual "\"" → "@" fixes an app needs before a quote converts by itself there.
    public static let mentionAppThreshold = 3
    /// The ceiling keeps a long-used app able to change its mind: three reverts of
    /// an automatic "@" switch the rule off there, however many fixes came before.
    private static let mentionAppCeiling = 12
    private static let mentionRevertPenalty = 4

    public func isMentionApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return (data.mentionApps[id] ?? 0) >= Store.mentionAppThreshold
    }

    public func recordMentionFix(bundleID: String?) {
        guard let id = bundleID else { return }
        updateData { $0.mentionApps[id] = min(($0.mentionApps[id] ?? 0) + 1, Store.mentionAppCeiling) }
    }

    public func recordMentionRevert(bundleID: String?) {
        guard let id = bundleID else { return }
        updateData { $0.mentionApps[id] = max(($0.mentionApps[id] ?? 0) - Store.mentionRevertPenalty, 0) }
    }

    /// Rebuild the per-app counters from the opt-in history on the first launch of
    /// a build that has them, so that an app with a long record of manual fixes
    /// does not have to earn them again. Existing counters are left alone.
    public func seedMentionApps(_ counts: [String: Int]) {
        guard data.mentionApps.isEmpty else { return }
        let seeded = counts.filter { !$0.key.isEmpty && $0.value > 0 }
            .mapValues { min($0, Store.mentionAppCeiling) }
        guard !seeded.isEmpty else { return }
        updateData { $0.mentionApps = seeded }
    }

    // MARK: learned reverts (FR-18)

    /// The form the engine compares: "ghbdtn," is reverted as "ghbdtn". A token of
    /// signs alone ("]]]") stays as it is.
    private static func revertKey(_ word: String) -> String {
        let core = word.trimmingCharacters(in: DetectionEngine.outerCharacters).lowercased()
        return core.isEmpty ? word.lowercased() : core
    }

    public func recordRevert(_ word: String) {
        let w = Store.revertKey(word)
        updateData { $0.learnedReverts[w, default: 0] += 1 }
    }
    /// The user converted `word` by hand, so a past revert of it no longer stands.
    /// One revert blocks a word for good and the mention and mid-word rules by
    /// prefix, while a ⇧⇧ pressed a moment after a conversion reverts it by accident:
    /// all four "reverts" of ten days were undone within a second, and each left a
    /// word the app then refused to convert. With `prefix`, also the reverts that
    /// start with `word`: a word still being typed is only the beginning of one.
    /// Returns true when something was forgiven.
    @discardableResult
    public func forgiveReverts(of word: String, prefix: Bool = false) -> Bool {
        let w = Store.revertKey(word)
        guard !w.isEmpty else { return false }
        let hits = data.learnedReverts.keys.filter { $0 == w || (prefix && w.count >= 2 && $0.hasPrefix(w)) }
        guard !hits.isEmpty else { return false }
        updateData { d in for h in hits { d.learnedReverts[h] = nil } }
        return true
    }

    /// Words reverted at least `min` times are treated as do-not-convert.
    public func revertedWords(min: Int = 1) -> Set<String> {
        Set(data.learnedReverts.filter { $0.value >= min }.keys)
    }

    // MARK: codec

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: raw)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        guard let encoded = try? JSONEncoder().encode(value) else { return }
        try? encoded.write(to: url, options: .atomic)   // atomic = crash-safe
    }
}
