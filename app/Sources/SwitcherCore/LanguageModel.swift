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
    private var trigrams: [String: Double] = [:]   // log P(c3 | c1 c2)
    private var bigramTotals: [String: Double] = [:]
    private let vocab: Double                       // alphabet size for smoothing
    private let unkLogProb: Double                  // floor for unseen trigrams

    public init(layout: Layout, words rawWords: [String]) {
        self.layout = layout
        let normalized = rawWords
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.words = Set(normalized)
        self.vocab = (layout == .ru) ? 34 : 28      // letters + boundary symbol
        self.unkLogProb = log(1.0 / vocab)
        buildTrigrams(from: normalized)
    }

    private func buildTrigrams(from words: [String]) {
        // Pad each word with boundary markers so word-initial / word-final
        // sequences are modelled. "^" and "$" are out-of-alphabet sentinels.
        var triCounts = [String: Double]()
        var biCounts = [String: Double]()
        for w in words {
            let padded = "^^" + w + "$"
            let chars = Array(padded)
            guard chars.count >= 3 else { continue }
            for i in 0...(chars.count - 3) {
                let bi = String(chars[i...(i + 1)])
                let tri = String(chars[i...(i + 2)])
                biCounts[bi, default: 0] += 1
                triCounts[tri, default: 0] += 1
            }
        }
        bigramTotals = biCounts
        // Add-1 (Laplace) smoothed conditional log-probabilities.
        for (tri, c) in triCounts {
            let bi = String(tri.prefix(2))
            let denom = (biCounts[bi] ?? 0) + vocab
            trigrams[tri] = log((c + 1) / denom)
        }
    }

    /// Exact word membership.
    public func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }

    /// Mean trigram log-probability of `word` under this language.
    /// Higher (closer to 0) = more native-looking. Range roughly [-log(vocab), 0].
    public func score(_ word: String) -> Double {
        let w = word.lowercased()
        let padded = "^^" + w + "$"
        let chars = Array(padded)
        guard chars.count >= 3 else { return unkLogProb }
        var sum = 0.0
        var n = 0
        for i in 0...(chars.count - 3) {
            let tri = String(chars[i...(i + 2)])
            if let lp = trigrams[tri] {
                sum += lp
            } else {
                // Back off to add-1 over the (possibly unseen) bigram context.
                let bi = String(tri.prefix(2))
                let denom = (bigramTotals[bi] ?? 0) + vocab
                sum += log(1.0 / denom)
            }
            n += 1
        }
        return n > 0 ? sum / Double(n) : unkLogProb
    }

    public var wordCount: Int { words.count }
}
