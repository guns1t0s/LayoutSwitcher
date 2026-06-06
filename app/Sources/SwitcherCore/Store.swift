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

    public init(directory: URL? = nil) {
        let base = directory ?? Store.defaultDirectory()
        self.dir = base
        self.settingsURL = base.appendingPathComponent("settings.json")
        self.dataURL = base.appendingPathComponent("userdata.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.settings = Store.decode(Settings.self, from: settingsURL) ?? Settings()
        self.data = Store.decode(UserData.self, from: dataURL) ?? UserData()
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
        save(data, to: dataURL)
    }

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
        updateData { $0.layoutMemory["\(bundleID)|\(role)"] = layout }
    }
    public func recalledLayout(bundleID: String, role: String = "") -> Layout? {
        data.layoutMemory["\(bundleID)|\(role)"]
    }

    // MARK: learned reverts (FR-18)

    public func recordRevert(_ word: String) {
        let w = word.lowercased()
        updateData { $0.learnedReverts[w, default: 0] += 1 }
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
