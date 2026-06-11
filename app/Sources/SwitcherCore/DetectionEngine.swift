import Foundation

/// Why a given token was / was not converted. Surfaced in shadow-mode review.
public enum DetectionReason: String, Sendable {
    case typedIsValidWord        // already a real word as-typed — leave it
    case altIsWord               // converted form is a real word, typed form is not
    case ngramMargin             // neither is a dictionary word; n-gram favoured the swap
    case ambiguousBothValid      // valid in both layouts — when in doubt, don't touch
    case belowThreshold          // some signal, but under the confidence threshold
    case tooShort
    case noLetters
    case excepted                // in user exceptions / learned reverts
    case whitelistedLatin        // forced to latin by whitelist
    case suppressed              // hold-to-suppress / global toggle off
}

public struct Decision: Sendable, Equatable {
    public let shouldConvert: Bool
    public let from: Layout
    public let to: Layout
    public let original: String
    public let converted: String
    public let confidence: Double          // 0…1
    public let reason: DetectionReason

    public static func noop(_ token: String, layout: Layout, reason: DetectionReason) -> Decision {
        Decision(shouldConvert: false, from: layout, to: layout,
                 original: token, converted: token, confidence: 0, reason: reason)
    }
}

/// Pure, deterministic detector (FR-7…FR-10). Decides whether a finished word
/// was typed in the wrong layout, *erring hard toward no-op* — a false
/// conversion corrupts already-correct text and is the one thing acceptance
/// criteria forbid (≤0.5% false positives), whereas a miss is tolerable.
public final class DetectionEngine: @unchecked Sendable {
    private let dicts: Dictionaries

    public struct Config: Sendable {
        public var threshold: Double          // 0…1 confidence gate for the n-gram path
        public var minWordLength: Int         // letters required for the n-gram path
        public var ngramSteepness: Double     // sigmoid slope over the log-prob margin
        public var ngramMinMargin: Double     // REQUIRED log-prob gap before n-gram converts
        public var convertAmbiguous: Bool     // convert when valid in BOTH layouts (off)
        public init(threshold: Double = 0.8,
                    minWordLength: Int = 4,
                    ngramSteepness: Double = 2.5,
                    ngramMinMargin: Double = 0.6,
                    convertAmbiguous: Bool = false) {
            self.threshold = threshold
            self.minWordLength = minWordLength
            self.ngramSteepness = ngramSteepness
            self.ngramMinMargin = ngramMinMargin
            self.convertAmbiguous = convertAmbiguous
        }
    }

    public var config: Config

    /// User-tunable lexicons (FR-16/17/18). Lowercased keys.
    public var exceptions: Set<String> = []        // never convert
    public var whitelistLatin: Set<String> = []    // always latin
    public var learnedReverts: Set<String> = []    // manually reverted → stop converting
    public var learnedWords: Set<String> = []      // learned from manual fixes → treat as dictionary words

    public init(dictionaries: Dictionaries, config: Config = Config()) {
        self.dicts = dictionaries
        self.config = config
    }

    /// - Parameters:
    ///   - token: the finished word, exactly as typed.
    ///   - typedLayout: layout known to be active while typing, if any.
    ///   - context: layout of the surrounding text, if known (FR-9).
    public func evaluate(_ token: String,
                         typedLayout: Layout? = nil,
                         context: Layout? = nil) -> Decision {

        let core = token.trimmingCharacters(in: punctuation)
        let lc = core.lowercased()

        // Layout the token currently reads as.
        guard let current = typedLayout ?? core.dominantLayout else {
            return .noop(token, layout: .en, reason: .noLetters)
        }
        let target = current.other
        let altForm = KeyMap.convert(core, to: target)
        let altLC = altForm.lowercased()
        // Convert the token, but preserve LEADING/TRAILING sentence punctuation
        // (a real trailing "." must stay "." — not become the letter "ю"). Inner
        // punctuation and word-symbols (@ " etc.) are still converted, so
        // "j,hfnyj"→"обратно" and "\"фтшлщтщкщм"→"@anikonorov" both work.
        let fullConverted = Self.convertPreservingOuterPunct(token, to: target)

        // --- Hard lexicon gates -------------------------------------------------
        // Never touch user exceptions or words the user reverted by hand.
        if exceptions.contains(lc) || exceptions.contains(altLC)
            || learnedReverts.contains(lc) || learnedReverts.contains(altLC) {
            return .noop(token, layout: current, reason: .excepted)
        }
        // "Always latin" terms: if the latin reading is whitelisted and we are
        // currently cyrillic, swap to latin; if already latin, leave it.
        if current == .ru, whitelistLatin.contains(altLC) {
            return Decision(shouldConvert: true, from: .ru, to: .en,
                            original: token, converted: fullConverted,
                            confidence: 1.0, reason: .whitelistedLatin)
        }
        if current == .en, whitelistLatin.contains(lc) {
            return .noop(token, layout: current, reason: .typedIsValidWord)
        }

        // --- Length gate --------------------------------------------------------
        if core.letterCount < 1 {
            return .noop(token, layout: current, reason: .noLetters)
        }

        let curModel = dicts.model(for: current)
        let altModel = dicts.model(for: target)

        // --- Outer soft-punct as LETTERS (dictionary-driven) ---------------------
        // Russian words commonly END in б ж х ъ э ё ю — on the EN layout those
        // are , ; [ ] ' ` . and get trimmed into `core` as "punctuation", so
        // "vbhjds[" lost its х and never matched "мировых". If converting the
        // FULL token (outer punct included as letters) yields a dictionary word,
        // prefer that reading; "ghbdtn." still falls through ("приветю" is no
        // word) and keeps its real period.
        if token != core {
            let fullAlt = KeyMap.convert(token, to: target)
            if altModel.contains(fullAlt.lowercased()) && !curModel.contains(lc) {
                return Decision(shouldConvert: true, from: current, to: target,
                                original: token, converted: fullAlt,
                                confidence: 1.0, reason: .altIsWord)
            }
        }
        let curIsWord = curModel.contains(lc) || learnedWords.contains(lc)
        let altIsWord = altModel.contains(altLC) || learnedWords.contains(altLC)

        // --- Dictionary decisions (high confidence) -----------------------------
        if curIsWord && !altIsWord {
            return .noop(token, layout: current, reason: .typedIsValidWord)
        }
        if altIsWord && !curIsWord {
            return Decision(shouldConvert: true, from: current, to: target,
                            original: token, converted: fullConverted,
                            confidence: 1.0, reason: .altIsWord)
        }
        if curIsWord && altIsWord {
            // Valid both ways (e.g. "ctj" vs "сей"): default to leaving it.
            if config.convertAmbiguous, let ctx = context, ctx == target {
                return Decision(shouldConvert: true, from: current, to: target,
                                original: token, converted: fullConverted,
                                confidence: 0.6, reason: .ngramMargin)
            }
            return .noop(token, layout: current, reason: .ambiguousBothValid)
        }

        // --- Out-of-vocabulary: character n-gram margin -------------------------
        if core.letterCount < config.minWordLength {
            return .noop(token, layout: current, reason: .tooShort)
        }
        var margin = altModel.score(altLC) - curModel.score(lc)
        // Context nudges the margin but cannot, alone, cross the threshold.
        if let ctx = context {
            margin += (ctx == target) ? 0.15 : (ctx == current ? -0.15 : 0)
        }
        let confidence = sigmoid(config.ngramSteepness * margin)
        // Require a CLEAR gap (not just margin>0): the OOV n-gram signal is noisy
        // on a small corpus, and a false conversion of correct text is the one
        // thing we must avoid. Misses are fine — double-⇧ fixes them by hand.
        if margin >= config.ngramMinMargin && confidence >= config.threshold {
            return Decision(shouldConvert: true, from: current, to: target,
                            original: token, converted: fullConverted,
                            confidence: confidence, reason: .ngramMargin)
        }
        return .noop(token, layout: current, reason: .belowThreshold)
    }

    // MARK: - helpers

    private let punctuation = CharacterSet.punctuationCharacters
        .union(.whitespacesAndNewlines).union(.symbols)

    private func sigmoid(_ x: Double) -> Double { 1.0 / (1.0 + exp(-x)) }

    /// Letter-mapping punctuation kept word-internal by KeystrokeBuffer. As the
    /// OUTER char of a token it's real sentence punctuation → preserve it.
    private static let softPunct: Set<Character> = [",", ".", ";", "'", "[", "]", "`"]

    static func convertPreservingOuterPunct(_ token: String, to target: Layout) -> String {
        var lead = "", trail = "", mid = Substring(token)
        while let f = mid.first, softPunct.contains(f) { lead.append(f); mid = mid.dropFirst() }
        while let l = mid.last, softPunct.contains(l) { trail = String(l) + trail; mid = mid.dropLast() }
        return lead + KeyMap.convert(String(mid), to: target) + trail
    }
}
