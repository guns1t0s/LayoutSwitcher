import Foundation

/// One recorded switching action — enough context to spot a false trigger later.
public struct LoggedEvent: Codable, Equatable, Sendable {
    public var t: Double           // epoch seconds (wall clock)
    public var kind: String        // auto | doubleShift | phantom | undo | blocked
    public var branch: String      // for doubleShift: which fix() path; else ""
    public var original: String    // text as typed (on screen)
    public var converted: String   // text after the action ("" for phantom/blocked)
    public var from: String        // layout before (ru/en/"")
    public var to: String          // layout after
    public var reason: String      // engine reason (auto) or gesture note
    public var confidence: Double
    public var app: String         // frontmost bundle id
    public var interval: Double     // for doubleShift: seconds between the two ⇧ taps (-1 if n/a)

    public init(t: Double, kind: String, branch: String = "", original: String = "",
                converted: String = "", from: String = "", to: String = "",
                reason: String = "", confidence: Double = 0, app: String = "",
                interval: Double = -1) {
        self.t = t; self.kind = kind; self.branch = branch; self.original = original
        self.converted = converted; self.from = from; self.to = to; self.reason = reason
        self.confidence = confidence; self.app = app; self.interval = interval
    }
}

/// Persistent, capped history of switching actions for offline analysis of
/// erroneous conversions and accidental double-⇧ gestures (opt-in; SEC-2 keeps
/// it OFF by default since it writes raw typed words). Local file only, never
/// the network. All access is serialized on a private queue; writes are atomic.
public final class EventLog: @unchecked Sendable {

    private let url: URL
    private let cap: Int
    private let q = DispatchQueue(label: "com.oateplov.layoutswitcher.eventlog")
    private var events: [LoggedEvent]

    /// Gate set from Settings.logHistory. When false, `record` is a no-op.
    public var enabled: Bool

    public init(directory: URL? = nil, cap: Int = 2000, enabled: Bool = false) {
        let base = directory ?? Store.defaultDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("events.json")
        self.cap = cap
        self.enabled = enabled
        self.events = EventLog.load(url) ?? []
    }

    public var fileURL: URL { url }

    public func record(_ e: LoggedEvent) {
        guard enabled else { return }
        q.async { [self] in
            events.append(e)
            if events.count > cap { events.removeFirst(events.count - cap) }
            flush()
        }
    }

    public func all() -> [LoggedEvent] { q.sync { events } }

    public func clear() {
        q.sync {
            events.removeAll()
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func count() -> Int { q.sync { events.count } }

    private func flush() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func load(_ url: URL) -> [LoggedEvent]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([LoggedEvent].self, from: data)
    }

    // MARK: - human-readable report (for the menu / clipboard export)

    /// A compact analysis report: summary counters first (the signals that
    /// matter — undos = confirmed false positives, phantoms = accidental
    /// gestures), then the most recent events newest-first.
    public func report(limit: Int = 200) -> String {
        let all = self.all()
        guard !all.isEmpty else { return "История пуста (включи запись в меню)." }

        var byKind: [String: Int] = [:]
        var byApp: [String: Int] = [:]
        var convertedFreq: [String: Int] = [:]
        for e in all {
            byKind[e.kind, default: 0] += 1
            if !e.app.isEmpty { byApp[e.app, default: 0] += 1 }
            if e.kind == "auto" { convertedFreq[e.original + " → " + e.converted, default: 0] += 1 }
        }

        var out = "LayoutSwitcher история — \(all.count) событий\n"
        out += "Сводка: " + byKind.sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ") + "\n"
        let undos = byKind["undo"] ?? 0
        let phantoms = byKind["phantom"] ?? 0
        out += "Сигналы: откатов(=ложные)=\(undos)  фантомных ⇧⇧=\(phantoms)\n"
        let topApps = byApp.sorted { $0.value > $1.value }.prefix(5)
        if !topApps.isEmpty {
            out += "Приложения: " + topApps.map { "\(short($0.key))=\($0.value)" }.joined(separator: " ") + "\n"
        }
        let repeats = convertedFreq.filter { $0.value > 1 }.sorted { $0.value > $1.value }.prefix(8)
        if !repeats.isEmpty {
            out += "Частые автоконверсии: " + repeats.map { "\"\($0.key)\"×\($0.value)" }.joined(separator: ", ") + "\n"
        }
        out += "—\n"

        for e in all.suffix(limit).reversed() {
            out += line(e) + "\n"
        }
        return out
    }

    private func line(_ e: LoggedEvent) -> String {
        let when = stamp(e.t)
        let dir = (e.from.isEmpty && e.to.isEmpty) ? "" : " [\(e.from)→\(e.to)]"
        let body: String
        switch e.kind {
        case "phantom":  body = "⇧⇧ впустую (нечего конвертировать)"
        case "blocked":  body = "⇧⇧ заблокировано: \(e.reason)"
        case "undo":     body = "ОТКАТ \"\(e.original)\" → \"\(e.converted)\""
        case "doubleShift": body = "⇧⇧ \(e.branch): \"\(e.original)\" → \"\(e.converted)\""
        default:         body = "авто \"\(e.original)\" → \"\(e.converted)\" [\(e.reason) \(String(format: "%.2f", e.confidence))]"
        }
        let iv = e.interval >= 0 ? String(format: " (%.0fms)", e.interval * 1000) : ""
        return "\(when) \(short(e.app)) \(body)\(dir)\(iv)"
    }

    private func short(_ bundle: String) -> String {
        bundle.split(separator: ".").last.map(String.init) ?? bundle
    }

    private func stamp(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
