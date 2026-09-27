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
    case mixedScript             // token mixes RU+EN letters (mid-word switch) — leave it
    case mixedRepaired           // mixed token unified into a real word (layout flipped mid-word)
    case acronym                 // ALL-CAPS cyrillic token that spells a known English acronym
    case slipRepaired            // ⇧4 typed where ж was meant ("$"/";" between letters)
    case ambiguousResolved       // valid both ways, resolved by frequency + context
    case morphology              // OOV, but a plausible inflection of a known stem
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
    /// Should a manually-fixed word be LEARNED into the dictionary? No, when the
    /// engine already knows it (dictionary/whitelist/learned) or would convert it
    /// (i.e. it is the wrong-layout image of a real word). The user cycling a word
    /// back and forth with ⇧⇧ otherwise teaches garbage like "xnj,s" (the EN-layout
    /// spelling of "чтобы") as a "word", which then makes the REAL wrong-layout
    /// token ambiguous and blocks its auto-conversion.
    public func isLearnable(_ word: String) -> Bool {
        let d = evaluate(word)
        if d.shouldConvert { return false }              // wrong-layout image
        switch d.reason {
        case .typedIsValidWord, .ambiguousBothValid, .excepted, .whitelistedLatin, .acronym, .slipRepaired:
            return false                                  // already known / conflicted
        default:
            return true                                   // genuinely new vocabulary
        }
    }

    /// Characters a shifted number key produces in either layout. Between two
    /// letters they are never punctuation — only a slip or a layout artifact.
    static let shiftSymbols: Set<Character> = ["$", "^", "&", "#", "@", "№", ";", ":", "?", "\""]

    /// True when a shifted-number symbol sits BETWEEN two letters.
    static func hasInnerSymbol(_ s: String) -> Bool {
        let c = Array(s)
        guard c.count >= 3 else { return false }
        for i in 1..<(c.count - 1) where shiftSymbols.contains(c[i]) {
            if c[i - 1].isLetter && c[i + 1].isLetter { return true }
        }
        return false
    }

    /// Manual (⇧⇧) conversions go through KeyMap directly; a "$" slip then comes
    /// out as ";" between two Russian letters ("ye$ty" → "ну;ен"). Between letters
    /// that is never punctuation — it is the ж that was meant.
    public static func repairInnerZh(_ s: String) -> String {
        var c = Array(s)
        guard c.count >= 3 else { return s }
        for i in 1..<(c.count - 1) where c[i] == ";" && c[i - 1].isCyrillic && c[i + 1].isCyrillic {
            c[i] = "ж"
        }
        return String(c)
    }

    /// Read an inner "$" (EN layout) or ";" (RU layout) as the ж it was meant to
    /// be, returning the Russian token (outer punctuation kept) and its core.
    /// nil when the token has no such slip.
    static func repairZhSlip(_ token: String, core: String, current: Layout) -> (token: String, core: String)? {
        let slip: Character = current == .en ? "$" : ";"
        let c = Array(core)
        guard c.count >= 3 else { return nil }
        var hit = false
        var fixed = c
        for i in 1..<(c.count - 1) where c[i] == slip && c[i - 1].isLetter && c[i + 1].isLetter {
            fixed[i] = current == .en ? ";" : "ж"      // EN: the ж key is ";" → converts to ж
            hit = true
        }
        guard hit else { return nil }
        let fixedCore = String(fixed)
        let ruCore = current == .en ? KeyMap.convert(fixedCore, to: .ru) : fixedCore
        guard ruCore.allSatisfy({ $0.isLetter }) else { return nil }
        // Re-attach the outer punctuation exactly as typed.
        guard let r = token.range(of: core) else { return nil }
        let out = String(token[..<r.lowerBound]) + ruCore + String(token[r.upperBound...])
        return (out, ruCore)
    }

    public func evaluate(_ token: String,
                         typedLayout: Layout? = nil,
                         context: Layout? = nil) -> Decision {

        let core = token.trimmingCharacters(in: punctuation)
        let lc = core.lowercased()

        // Layout the token currently reads as. Trust the SCRIPT of the text
        // (dominantLayout) over the system keyboard layout: the system layout can
        // lag or be flipped out from under us, and if we believed it over the
        // actual cyrillic/latin characters we'd "convert" correct text to itself
        // (identity) while flipping the layout — a self-sustaining oscillation
        // that flickers the layout on every word ("мигание"). The system layout is
        // only a fallback for a token with no letters (script-ambiguous).
        guard let current = core.dominantLayout ?? typedLayout else {
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

        // A "conversion" that changes nothing but the layout is never wanted — it
        // is the desync no-op above. Guard against it directly, so no path can flip
        // the layout without actually rewriting text.
        if fullConverted == token {
            return .noop(token, layout: current, reason: .typedIsValidWord)
        }

        // --- Hard lexicon gates -------------------------------------------------
        // Never touch user exceptions or words the user reverted by hand.
        if exceptions.contains(lc) || exceptions.contains(altLC)
            || learnedReverts.contains(lc) || learnedReverts.contains(altLC) {
            return .noop(token, layout: current, reason: .excepted)
        }
        // "Always latin" terms: if the latin reading is whitelisted and we are
        // currently cyrillic, swap to latin; if already latin, leave it.
        // FP guard: when the cyrillic reading is itself a valid Russian word,
        // converting would corrupt correct text — stand down, UNLESS the token is
        // ALL-CAPS (acronym style: КАШ→RFI is wanted even though "каш" is a word;
        // a real Russian word is virtually never typed in all caps mid-chat).
        if current == .ru, whitelistLatin.contains(altLC) {
            let allCaps = core.count > 1 && core.allSatisfy { !$0.isLowercase }
            if allCaps || !dicts.model(for: .ru).contains(lc) {
                return Decision(shouldConvert: true, from: .ru, to: .en,
                                original: token, converted: fullConverted,
                                confidence: 1.0, reason: .whitelistedLatin)
            }
        }
        if current == .en, whitelistLatin.contains(lc) {
            return .noop(token, layout: current, reason: .typedIsValidWord)
        }

        // --- Length gate --------------------------------------------------------
        if core.letterCount < 1 {
            return .noop(token, layout: current, reason: .noLetters)
        }

        // --- Mixed-script guard -------------------------------------------------
        // A token with BOTH cyrillic and latin letters is a mid-word layout
        // switch (or homoglyph). Any conversion produces mojibake and its n-gram
        // score is meaningless → never touch it (zero-corruption principle).
        let hasRu = core.contains { $0.isCyrillic }
        let hasEn = core.contains { $0.isLatinLetter }
        if hasRu && hasEn {
            // Normally mojibake (homoglyphs, deliberate mixing) and unsafe to
            // touch. But the usual cause is benign and repairable: the layout
            // switched WHILE the word was being typed — after an auto-conversion
            // flipped it — so the first characters sit in one script and the rest
            // in the other ("пhbdtn", "Ht,енок"). Unifying the scripts restores
            // exactly what the user meant, because KeyMap passes through
            // characters already in the target script: "пhbdtn" → "привет",
            // "Ht,енок" → "Ребенок".
            //
            // Accept the repair only when EXACTLY ONE direction yields a real
            // dictionary word. That keeps the zero-corruption bar — no n-gram
            // guessing on genuinely mixed text, which stays untouched.
            // The repaired core must come out as PURE LETTERS. Otherwise a letter
            // of one script maps onto punctuation of the other ("iPhoneХ" → the
            // cyrillic Х becomes "[", and trimming that edge would sneak the token
            // past a dictionary check on "iphone") and we would corrupt real text.
            func repaired(_ target: Layout) -> String? {
                let body = KeyMap.convert(core, to: target)
                guard body.allSatisfy({ $0.isLetter }) else { return nil }
                let lc = body.lowercased()
                guard dicts.model(for: target).contains(lc) || learnedWords.contains(lc) else { return nil }
                return Self.convertPreservingOuterPunct(token, to: target)
            }
            let asRu = repaired(.ru)
            let asEn = repaired(.en)
            if let fixed = asRu, asEn == nil {
                return Decision(shouldConvert: true, from: .en, to: .ru,
                                original: token, converted: fixed,
                                confidence: 1.0, reason: .mixedRepaired)
            }
            if let fixed = asEn, asRu == nil {
                return Decision(shouldConvert: true, from: .ru, to: .en,
                                original: token, converted: fixed,
                                confidence: 1.0, reason: .mixedRepaired)
            }
            return .noop(token, layout: current, reason: .mixedScript)
        }

        // --- ALL-CAPS acronym typed in the RU layout -----------------------------
        // Short acronyms never reach the n-gram path (tooShort), so "СУЩ" stayed
        // "СУЩ" instead of "CEO" and was fixed by hand every time. Caps-only on
        // purpose: lowercase twins sit next to real Russian typos ("ешу"~"еду"),
        // while nobody types a Russian word in all caps mid-sentence except an
        // abbreviation — and those are protected (acronymsRU) and pre-gated.
        if current == .ru, core.count >= 2, core.count <= 8,
           core.allSatisfy({ ($0.isLetter && $0.isUppercase) || $0.isNumber }),
           core.filter({ $0.isLetter }).count >= 2,
           dicts.acronymsEN.contains(altLC), !dicts.acronymsRU.contains(lc) {
            return Decision(shouldConvert: true, from: .ru, to: .en,
                            original: token, converted: fullConverted,
                            confidence: 1.0, reason: .acronym)
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
            // Guard against corrupting correct current-layout text that merely
            // isn't in our (smaller) current dictionary: the alt reading must be
            // a dictionary word AND genuinely more native by the n-gram margin.
            if altModel.contains(fullAlt.lowercased()) && !curModel.contains(lc),
               altModel.score(fullAlt.lowercased()) - curModel.score(lc) > 0 {
                return Decision(shouldConvert: true, from: current, to: target,
                                original: token, converted: fullAlt,
                                confidence: 1.0, reason: .altIsWord)
            }
        }
        // --- Habitual slip: ⇧4 where ж was meant ----------------------------------
        // The history shows it again and again: "nfr$t" (также), "yf$bvf" (нажима),
        // "ye$ty" (нужен) on the EN layout, "ну;но" (нужно) on the RU one — ⇧4 gives
        // "$" / ";" instead of the ж key. A symbol between two letters is never real
        // punctuation, so when reading it as ж yields a Russian word, that word is
        // what was meant. Without this the EN form converted to garbage ("ну;ен")
        // and the RU form was even flipped to "ye$yj" by the n-gram path.
        if let fixed = Self.repairZhSlip(token, core: core, current: current),
           dicts.model(for: .ru).contains(fixed.core.lowercased()) || learnedWords.contains(fixed.core.lowercased()) {
            return Decision(shouldConvert: true, from: current, to: .ru,
                            original: token, converted: fixed.token,
                            confidence: 1.0, reason: .slipRepaired)
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
            // Valid both ways. Default: LEAVE IT (zero-corruption). Convert only
            // with strong, conservative evidence: the surrounding text is already
            // in the target layout AND the alt reading is a common word (so we
            // don't flip toward a rare/odd reading). Never convert on no context
            // — that would be a coin-flip on the very text we must not corrupt.
            let altCommon = dicts.freqRank(altLC, target).map { $0 <= 3000 } ?? false
            if context == target && (altCommon || config.convertAmbiguous) {
                return Decision(shouldConvert: true, from: current, to: target,
                                original: token, converted: fullConverted,
                                confidence: 0.7, reason: .ambiguousResolved)
            }
            return .noop(token, layout: current, reason: .ambiguousBothValid)
        }

        // --- Out-of-vocabulary: character n-gram margin -------------------------
        if core.letterCount < config.minWordLength {
            return .noop(token, layout: current, reason: .tooShort)
        }
        // A real word never carries a shifted-number symbol between two letters
        // ("ye$yj", "так;е"). If that is what converting produces, the token is not a
        // wrong-layout word — refuse before the n-gram gets a vote on garbage.
        if Self.hasInnerSymbol(altForm) {
            return .noop(token, layout: current, reason: .belowThreshold)
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
        // Morphology rescue: the alt reading is a plausible inflection of a KNOWN
        // stem and the typed reading is not, and the n-gram already leans target.
        // Lowers the bar for genuine inflected forms without raising FP (the stem
        // must be real and the typed form must NOT look native in its layout).
        if margin > 0,
           altModel.looksLikeInflection(altLC), !curModel.looksLikeInflection(lc) {
            return Decision(shouldConvert: true, from: current, to: target,
                            original: token, converted: fullConverted,
                            confidence: max(0.7, confidence), reason: .morphology)
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
