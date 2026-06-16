import Foundation

/// Compact per-language model built once at load from a bundled word list:
///  - a word set (exact-match high-confidence signal), and
///  - a character trigram log-probability table (handles out-of-vocabulary
///    words so detection still works on names/terms not in the list).
///
/// No network, no disk I/O after construction. Built from the same word list
/// it scores against, so it needs zero external corpora.
public final class LanguageModel: @unchecked Sendable {
    public let layout: Layout
    private let words: Set<String>
    // Raw character n-gram counts for linear interpolation (deletes the old
    // floor-dominated add-1 trigram, which barely discriminated OOV words).
    private var uni: [Character: Double] = [:]
    private var bi: [String: Double] = [:]
    private var tri: [String: Double] = [:]
    private var uniTotal: Double = 0
    private let vocab: Double                       // alphabet size for smoothing
    private let unkLogProb: Double                  // floor

    public init(layout: Layout, words rawWords: [String]) {
        self.layout = layout
        let normalized = rawWords
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.words = Set(normalized)
        self.vocab = (layout == .ru) ? 34 : 28      // letters + boundary symbol
        self.unkLogProb = log(1.0 / vocab)
        buildNgrams(from: normalized)
        buildMorphology(from: normalized)
    }

    // MARK: - morphology (generalize to unenumerated inflected forms)

    private var stems: Set<String> = []        // dictionary words + their suffix-stripped stems
    private var suffixes: Set<String> = []     // frequent 2–4 char endings of this language

    private func buildMorphology(from words: [String]) {
        guard words.count >= 200 else { return }   // need a real corpus to be safe
        var sufCount = [String: Int]()
        for w in words where w.count >= 5 {
            for k in 2...4 where w.count > k + 1 { sufCount[String(w.suffix(k)), default: 0] += 1 }
        }
        let minOccur = max(8, words.count / 300)
        suffixes = Set(sufCount.filter { $0.value >= minOccur }.keys)
        var st = Set(words)
        for w in words where w.count >= 5 {
            for s in suffixes where w.hasSuffix(s) {
                let stem = String(w.dropLast(s.count))
                if stem.count >= 4 { st.insert(stem) }
            }
        }
        stems = st
    }

    /// True if `word` is a plausible inflection of a KNOWN stem (its ending is a
    /// frequent native suffix and the remaining stem is in the dictionary's stem
    /// set). Lets the flat list generalize to forms it doesn't literally contain,
    /// grounded in real stems so it stays conservative.
    public func looksLikeInflection(_ word: String) -> Bool {
        let w = word.lowercased()
        guard w.count >= 6 else { return false }
        for s in suffixes where w.hasSuffix(s) {
            let stem = String(w.dropLast(s.count))
            if stem.count >= 4, stems.contains(stem) { return true }
        }
        return false
    }

    private func buildNgrams(from words: [String]) {
        // Pad with boundary sentinels (^ start, $ end) so word edges are modelled.
        for w in words {
            let chars = Array("^^" + w + "$")
            for c in chars { uni[c, default: 0] += 1; uniTotal += 1 }
            if chars.count >= 2 {
                for i in 0...(chars.count - 2) { bi[String(chars[i...(i + 1)]), default: 0] += 1 }
            }
            if chars.count >= 3 {
                for i in 0...(chars.count - 3) { tri[String(chars[i...(i + 2)]), default: 0] += 1 }
            }
        }
    }

    /// Exact word membership.
    public func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }

    /// Mean log-probability of `word` under a linearly-interpolated
    /// unigram+bigram+trigram character model. Higher = more native-looking. The
    /// interpolation avoids the old add-1 floor that collapsed seen/unseen
    /// trigrams together, so a genuine RU/EN word (even OOV) now scores clearly
    /// above gibberish — the key to converting inflected forms not in the list.
    public func score(_ word: String) -> Double {
        let chars = Array("^^" + word.lowercased() + "$")
        guard chars.count >= 3, uniTotal > 0 else { return unkLogProb }
        let l3 = 0.6, l2 = 0.3, l1 = 0.1
        var sum = 0.0, n = 0
        for i in 0...(chars.count - 3) {
            let c1 = chars[i], c2 = chars[i + 1], c3 = chars[i + 2]
            let ctx2 = String([c1, c2])
            let p3 = (bi[ctx2] ?? 0) > 0 ? (tri[String([c1, c2, c3])] ?? 0) / bi[ctx2]! : 0
            let p2 = (uni[c2] ?? 0) > 0 ? (bi[String([c2, c3])] ?? 0) / uni[c2]! : 0
            let p1 = (uni[c3] ?? 0) / uniTotal
            let p = l3 * p3 + l2 * p2 + l1 * p1
            sum += log(max(p, 1e-7))
            n += 1
        }
        return n > 0 ? sum / Double(n) : unkLogProb
    }

    public var wordCount: Int { words.count }
}
