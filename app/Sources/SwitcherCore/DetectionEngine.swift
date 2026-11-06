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
    case capsGuard               // short ALL-CAPS token: abbreviation-shaped, generic paths stand down
    case idCode                  // caps letter(s) glued to 5+ digits, typed in RU layout (NIE "Я1234567Ч")
    case early                   // converted mid-word: the letters so far cannot start a Russian word
    case mention                 // "<letters> typed on the RU layout where @<login> was meant
    case brackets                // "хъ" typed on the RU layout where "[]" was meant
    case ambiguousResolved       // valid both ways, resolved by frequency + context
    case morphology              // OOV, but a plausible inflection of a known stem
    case login                   // latin token behind "@": a login, whatever it spells
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
        case .typedIsValidWord, .ambiguousBothValid, .excepted, .whitelistedLatin, .acronym, .slipRepaired,
             .capsGuard, .idCode, .early, .mention, .brackets, .login:
            return false                                  // already known / conflicted
        default:
            return true                                   // genuinely new vocabulary
        }
    }

    /// Characters a shifted number key produces in either layout. Between two
    /// letters they are never punctuation — only a slip or a layout artifact.
    static let shiftSymbols: Set<Character> = ["$", "^", "&", "#", "@", "№", ";", ":", "?", "\""]

    /// All letters uppercase, at least two of them (a single capital is a sentence start).
    static func isAllCapsWord(_ s: String) -> Bool {
        let letters = s.filter { $0.isLetter }
        return letters.count >= 2 && letters.allSatisfy { $0.isUppercase }
    }

    /// "Я1234567Ч" → "Z1234567X": 1-2 caps cyrillic letters, 5-9 digits, 0-2 caps
    /// cyrillic letters, and every letter must land on a latin letter (Б/Ю/Ж/Х/Э
    /// map to punctuation — then it is not a code). nil when the shape differs.
    static func latinIDCode(_ core: String) -> String? {
        let c = Array(core)
        var i = 0
        func runLetters(_ max: Int) -> Int {
            var n = 0
            while i < c.count, n < max, c[i].isCyrillic, c[i].isUppercase { i += 1; n += 1 }
            return n
        }
        let lead = runLetters(2)
        var digits = 0
        while i < c.count, c[i].isASCII, c[i].isNumber { i += 1; digits += 1 }
        let trail = runLetters(2)
        guard i == c.count, lead >= 1, (5...9).contains(digits), lead + trail <= 3 else { return nil }
        let latin = KeyMap.convert(core, to: .en)
        guard latin.allSatisfy({ ($0.isASCII && $0.isLetter) || $0.isNumber }) else { return nil }
        return latin
    }

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
        // ⇧4 comes out as ";" on Russian – PC and as "%" on the macOS Russian layout.
        for i in 1..<(c.count - 1) where (c[i] == ";" || c[i] == "%") && c[i - 1].isCyrillic && c[i + 1].isCyrillic {
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

    /// "подготовьб" → "подготовь,": on the macOS Russian layout the comma is ⇧6, and
    /// the key where English keeps it gives б. Six manual retypes in ten days, all
    /// of them a known word followed by б. A stem of five letters or more only:
    /// the shorter ones are where real words live ("зуб", "столб", "колб").
    static func repairCommaSlip(_ token: String, core: String) -> String? {
        guard core.count >= 6, core.last == "б", core.allSatisfy({ $0.isCyrillic && $0.isLetter }),
              let r = token.range(of: core) else { return nil }
        return String(token[..<r.lowerBound]) + core.dropLast() + "," + String(token[r.upperBound...])
    }

    // MARK: - Early (mid-word) conversion

    /// Shortest prefix early conversion may act on, and the n-gram gap it needs.
    public var earlyMinLength = 3
    public var earlyMinMargin = 1.0
    /// "Can these letters still start a Russian word?" from a source far larger
    /// than the bundled lists (the app wires the system Russian spell checker).
    /// Consulted last, only for a candidate that passed every other check. The
    /// bundled dictionary alone let "пше" through to "git" — "пшеница" is not in
    /// it; neither were "рун…" (Рунет) or "суте…" (сутенер).
    public var ruPrefixOracle: ((String) -> Bool)?
    /// The same question for English ("can these letters still start a word?"),
    /// asked of `evaluatePrefixEN`'s candidates before they turn Russian.
    public var enPrefixOracle: ((String) -> Bool)?
    /// "Is this a correct word of that language?" from the system spell checker, the
    /// last check before a dictionary or n-gram conversion. Our lists are small: a
    /// replay over real chat text turned "штук" into "iner" and "exe" into "учу".
    public var ruWordOracle: ((String) -> Bool)?
    public var enWordOracle: ((String) -> Bool)?
    /// May the speller be asked right now? Its answer comes from another process,
    /// and a cold one blocks the caller, here the keyboard, for hundreds of ms. When
    /// not, nothing that needed its word is rewritten: the mid-word rules stand aside,
    /// and so does a boundary rewrite of cyrillic text. Latin text keeps converting by
    /// the dictionaries alone, or "ghbdtn" would wait for the first answer of the day.
    public var spellerReady: () -> Bool = { true }
    /// Gap the EN→RU direction needs. Higher than the other way: on the EN layout
    /// people also type logins and identifiers no dictionary knows.
    public var earlyRuMinMargin = 1.0
    /// Lowercase letters needed in that direction. Three lowercase letters are
    /// what abbreviations look like ("pdf", "rfc", "cfg"); a capital starts a sentence.
    public var earlyRuMinLowercase = 4

    private lazy var ruPrefixes: Set<String> = dicts.model(for: .ru).prefixSet(minLength: earlyMinLength)
    private lazy var enPrefixes: Set<String> = dicts.model(for: .en).prefixSet(minLength: earlyMinLength)
    /// First one and two letters of every Russian word the app knows.
    private lazy var ruHeads: Set<String> = dicts.model(for: .ru).prefixSet(minLength: 1, maxLength: 2)

    /// Build the lazy prefix sets now. The first mid-word check otherwise builds
    /// them inside the event-tap callback (~80 ms, the "slowest key callback" in
    /// the 24.10 diagnostics) — the app calls this at launch, off the tap path.
    public func warmUp() {
        _ = ruPrefixes.count; _ = enPrefixes.count; _ = ruHeads.count
    }

    /// Letters after the quote that NO Russian word can start with: the quote is
    /// not a quotation mark but Shift+2 typed on the RU layout where "@" was meant.
    ///
    /// History 15-24.10: 46 manual "\"" → "@" fixes, 43 of them in Mattermost,
    /// plus "\"ыв" → "@sd", "\"лф" → "@ka"... A quote cannot be swapped for
    /// "@" on sight — the user does quote Russian words there ("\"гасятся\"") —
    /// but a quotation starts a Russian word, and "ы", "ь", "тш", "дф", "лф", "зщ"
    /// start none. So: one letter only for ы/ь (no Russian word starts with
    /// them); two or more when neither the dictionaries nor the system spell
    /// checker know a Russian word starting with them. The twin must be a login
    /// (latin letters / digits). A reverted or excepted prefix blocks it.
    public func evaluateMention(_ token: String) -> Decision? {
        // "@" already there, Russian letters behind it: the layout flipped under the
        // login. No Russian reading exists, so the first letter is enough.
        if token.first == "@" {
            let letters = String(token.dropFirst())
            guard !letters.isEmpty, letters.allSatisfy({ $0.isCyrillic && $0.isLetter }),
                  !learnedReverts.contains(where: { $0.hasPrefix(letters.lowercased()) }) else { return nil }
            let twin = KeyMap.convert(letters, to: .en)
            guard twin.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            return Decision(shouldConvert: true, from: .ru, to: .en, original: token,
                            converted: "@" + twin, confidence: 1.0, reason: .mention)
        }
        guard token.first == "\"" else { return nil }
        let core = String(token.dropFirst())
        // Logins are lowercase and give themselves away in the first letters (the
        // history: 23 of 24 caught by the 2nd letter). Capitalised tokens and later
        // letters are where quoted Russian lives — names ("Пупкин"), abbreviations
        // ("НРД", "РФ"), typos ("Прс") — so the window is 1-3 lowercase letters.
        guard (1...3).contains(core.count),
              core.allSatisfy({ $0.isCyrillic && $0.isLetter && $0.isLowercase }) else { return nil }
        let lc = core.lowercased()
        let twin = KeyMap.convert(core, to: .en)
        guard twin.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        func starts(_ set: Set<String>) -> Bool { set.contains { $0.hasPrefix(lc) } }
        if starts(learnedReverts) || starts(exceptions) { return nil }
        if lc.count == 1 {
            guard lc == "ы" || lc == "ь" else { return nil }
        } else {
            if lc.count == 2 ? ruHeads.contains(lc) : ruPrefixes.contains(lc) { return nil }
            if starts(learnedWords) { return nil }
            if let oracle = ruPrefixOracle, !spellerReady() || oracle(lc) { return nil }
        }
        return Decision(shouldConvert: true, from: .ru, to: .en, original: token,
                        converted: KeyMap.convert(token, to: .en),
                        confidence: 0.9, reason: .mention)
    }

    /// Is a quote typed right after `text` (what precedes the caret) a mention?
    ///
    /// A lone quote is the most frequent manual fix there is (36 of 105 in ten
    /// days), and it cannot wait for letters: the user wants "@" to open the
    /// autocomplete. In the middle of a sentence it stays a guess, the user's own
    /// posts have 936 mentions against 207 quotes there. But at the start of a
    /// message it is 590 against 5, at the start of a line 93 against 1, right after
    /// a mention 113 against 0, after "cc" 32 against 0.
    public static func quoteStartsMention(before text: String) -> Bool {
        let line = text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let tail = line.trimmingCharacters(in: .whitespaces)
        if tail.isEmpty || tail == "-" { return true }
        guard line.last?.isWhitespace == true,
              let last = tail.split(whereSeparator: { $0.isWhitespace }).last?.lowercased() else { return false }
        return last.hasPrefix("@") || last == "cc" || last == "сс" || last == "fyi"
    }

    /// The conversion of a quote that `quoteStartsMention` called a mention.
    public func mentionFromQuote() -> Decision {
        Decision(shouldConvert: true, from: .ru, to: .en, original: "\"", converted: "@",
                 confidence: 0.9, reason: .mention)
    }

    /// Decide whether a word STILL BEING TYPED in the Russian layout is really an
    /// English word typed on the wrong layout — before its boundary arrives.
    ///
    /// The history showed the user fixing such words by hand after 3-4 letters
    /// ("срф" → "cha", "швь" → "idm", "пкф" → "gra": 95 mid-word ⇧⇧ in nine days),
    /// because the boundary rule only ever sees whole words. Conditions, all
    /// required (when in doubt, do nothing):
    ///  - at least `earlyMinLength` letters, all cyrillic, typed in the RU layout;
    ///  - NO Russian word the app knows (bundled, the user's lexicon, learned)
    ///    starts with them, and they are not the start of a protected Russian
    ///    abbreviation, an exception or a word the user reverted;
    ///  - the latin twin is all letters and starts an English word or a curated
    ///    term (whitelist / acronym / learned); for a caps token only the curated
    ///    terms count, since caps tokens are abbreviations;
    ///  - unless it matched a curated term, the twin must look clearly more
    ///    English than the original looks Russian (n-gram gap >= earlyMinMargin).
    /// A wrong call is self-healing for longer words: the user keeps typing in
    /// the new layout, and at the boundary the ordinary rules convert a Russian
    /// word back.
    public func evaluatePrefix(_ token: String) -> Decision? {
        // "хъ" starts no Russian word: it is "[]" typed on the RU layout (six
        // manual fixes, all followed by Russian text — so no layout switch).
        if token == "хъ" || token == "ХЪ", !isRefused(token.lowercased()) {
            return Decision(shouldConvert: true, from: .ru, to: .en, original: token,
                            converted: token == "хъ" ? "[]" : "{}", confidence: 1.0, reason: .brackets)
        }
        // The code fence on the key left of 1. The macOS Russian layout gives "]"
        // there, so "```" comes out as "]]]" (fixed by hand three times in ten days,
        // and the fix did nothing before the real layouts were installed). Nothing
        // else types three of them on this layout. Russian follows: no switch.
        if token == "]]]", KeyMap.convert(token, to: .en) == "```", !isRefused(token) {
            return Decision(shouldConvert: true, from: .ru, to: .en, original: token,
                            converted: "```", confidence: 1.0, reason: .brackets)
        }
        // A code with a digit that EXACTLY spells a curated term ("Й4" → Q4,
        // "ы3" → s3): no Russian reading, and the list decides — fixed by hand
        // mid-word three times because the boundary rule only fires on the space.
        if token.contains(where: { $0.isNumber }) {
            guard token.count >= 2, token.count <= 8,
                  token.allSatisfy({ ($0.isCyrillic && $0.isLetter) || ($0.isASCII && $0.isNumber) }),
                  token.contains(where: { $0.isLetter }) else { return nil }
            let lc = token.lowercased()
            let tl = KeyMap.convert(lc, to: .en)
            guard tl.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                  dicts.acronymsEN.contains(tl) || whitelistLatin.contains(tl) || learnedWords.contains(tl),
                  !dicts.acronymsRU.contains(lc), !learnedReverts.contains(lc), !exceptions.contains(lc)
            else { return nil }
            return Decision(shouldConvert: true, from: .ru, to: .en, original: token,
                            converted: KeyMap.convert(token, to: .en), confidence: 1.0, reason: .early)
        }
        var letters = Substring(token)
        if letters.first == "\"" { letters = letters.dropFirst() }   // mention: "тшл → @nik
        let core = String(letters)
        guard core.count >= earlyMinLength,
              core.allSatisfy({ $0.isCyrillic && $0.isLetter }) else { return nil }
        let lc = core.lowercased()
        if ruPrefixes.contains(lc) { return nil }
        func starts(_ set: Set<String>) -> Bool { set.contains { $0.hasPrefix(lc) } }
        if starts(learnedWords) || starts(exceptions) || starts(learnedReverts)
            || starts(dicts.acronymsRU) { return nil }
        let twin = KeyMap.convert(core, to: .en)
        guard twin.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let tl = twin.lowercased()
        // In lowercase an acronym counts only whole: "куе" is the start of "кует", not
        // of RETN. In caps its beginning will do, Russian is not typed that way.
        let curated = whitelistLatin.contains { $0.hasPrefix(tl) }
            || (Self.isAllCapsWord(core) ? dicts.acronymsEN.contains { $0.hasPrefix(tl) } : dicts.acronymsEN.contains(tl))
            || learnedWords.contains { $0.hasPrefix(tl) }
        if Self.isAllCapsWord(core) {
            guard curated else { return nil }
        } else if !curated {
            guard enPrefixes.contains(tl) else { return nil }
            let margin = dicts.model(for: .en).scorePrefix(tl) - dicts.model(for: .ru).scorePrefix(lc)
            guard margin >= earlyMinMargin else { return nil }
        }
        if let oracle = ruPrefixOracle, !spellerReady() || oracle(lc) { return nil }
        return Decision(shouldConvert: true, from: .ru, to: .en, original: token,
                        converted: KeyMap.convert(token, to: .en),
                        confidence: 0.9, reason: .early)
    }

    /// The mirror of `evaluatePrefix`: Russian typed on the EN layout, caught before
    /// its boundary. The user fixes those by hand after 3-5 letters ("Xth" → "Чер",
    /// "Dkf" → "Вла", "Gth" → "Пер"), mostly in the browser's search field, which the
    /// app itself sets to EN. A wrong call here costs more than the other way, since
    /// logins and identifiers are typed on EN, so the bar is higher; all required:
    ///  - plain letters, at most the first one a capital (no acronyms, no camelCase),
    ///    and four of them unless they start with a capital;
    ///  - the surrounding text is not English;
    ///  - no English word, curated term, exception or revert starts with them;
    ///  - the Russian twin starts a Russian word the app knows;
    ///  - it reads clearly more Russian than English (`earlyRuMinMargin`);
    ///  - the system English speller knows no word starting with them.
    public func evaluatePrefixEN(_ token: String, context: Layout?) -> Decision? {
        guard context != .en, let first = token.first,
              token.count >= (first.isUppercase ? earlyMinLength : earlyRuMinLowercase),
              token.allSatisfy({ $0.isASCII && $0.isLetter }),
              token.dropFirst().allSatisfy({ $0.isLowercase }) else { return nil }
        let lc = token.lowercased()
        if enPrefixes.contains(lc) { return nil }
        func starts(_ set: Set<String>, _ p: String) -> Bool { set.contains { $0.hasPrefix(p) } }
        if starts(whitelistLatin, lc) || starts(dicts.acronymsEN, lc) || starts(learnedWords, lc)
            || starts(exceptions, lc) || starts(learnedReverts, lc) { return nil }
        let twin = KeyMap.convert(lc, to: .ru)
        guard twin.allSatisfy({ $0.isCyrillic && $0.isLetter }), ruPrefixes.contains(twin),
              !starts(learnedReverts, twin), !starts(exceptions, twin) else { return nil }
        let margin = dicts.model(for: .ru).scorePrefix(twin) - dicts.model(for: .en).scorePrefix(lc)
        guard margin >= earlyRuMinMargin else { return nil }
        if let oracle = enPrefixOracle, !spellerReady() || oracle(lc) { return nil }
        return Decision(shouldConvert: true, from: .en, to: .ru, original: token,
                        converted: KeyMap.convert(token, to: .ru), confidence: 0.9, reason: .early)
    }

    /// n-gram gap for a prefix (diagnostics / tuning).
    public func earlyMargin(_ prefix: String) -> Double {
        let lc = prefix.lowercased()
        return dicts.model(for: .en).scorePrefix(KeyMap.convert(lc, to: .en))
            - dicts.model(for: .ru).scorePrefix(lc)
    }

    public func evaluate(_ token: String,
                         typedLayout: Layout? = nil,
                         context: Layout? = nil) -> Decision {

        let core = token.trimmingCharacters(in: Self.outerCharacters)
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
        // "j,hfnyj"→"обратно" and "\"гыук"→"@user" both work.
        let fullConverted = Self.convertPreservingOuterPunct(token, to: target)

        // A "conversion" that changes nothing but the layout is never wanted — it
        // is the desync no-op above. Guard against it directly, so no path can flip
        // the layout without actually rewriting text.
        if fullConverted == token {
            return .noop(token, layout: current, reason: .typedIsValidWord)
        }

        // A latin token behind "@" is a login, whatever its letters spell on the
        // other layout: "@evs" came out as "\"умы" because "умы" is a word.
        if current == .en, token.drop(while: { Self.softPunct.contains($0) }).first == "@" {
            return .noop(token, layout: current, reason: .login)
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
        // A known English acronym typed in caps on the EN layout is exactly what
        // the user meant ("HRBP" was turned into "РКИЗ" by the n-gram path and
        // reverted by hand — the only false positive of the 28.09-08.10 history).
        if current == .en, Self.isAllCapsWord(core), dicts.acronymsEN.contains(lc) {
            return .noop(token, layout: current, reason: .typedIsValidWord)
        }
        // The mirror case: a RUSSIAN abbreviation typed in caps on the EN layout
        // inside Russian text ("ER" → "УК", "LRG" → "ДКП", "YAN" → "НФТ", all fixed
        // by hand). Only protected abbreviations, only with Russian context, and
        // never when the latin form is itself a known term.
        if current == .en, context == .ru, Self.isAllCapsWord(core), core.count <= 6,
           !whitelistLatin.contains(lc), !learnedWords.contains(lc),
           !dicts.model(for: .en).contains(lc),            // "HR" stays HR, not "РК"
           dicts.acronymsRU.contains(KeyMap.convert(lc, to: .ru)) {
            return Decision(shouldConvert: true, from: .en, to: .ru, original: token,
                            converted: fullConverted, confidence: 1.0, reason: .acronym)
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

        // --- Foreign ID codes typed in the RU layout ------------------------------
        // A caps cyrillic letter glued to 5+ digits has no Russian reading — no
        // document, plate or abbreviation looks like that — but it is exactly a
        // Spanish NIE/DNI or a booking code typed with the wrong layout on
        // ("Я1234567Ч" → "Z1234567X", fixed by hand four times in a week).
        if current == .ru, let code = Self.latinIDCode(core) {
            guard let r = token.range(of: core) else { return .noop(token, layout: current, reason: .noLetters) }
            return Decision(shouldConvert: true, from: .ru, to: .en,
                            original: token,
                            converted: String(token[..<r.lowerBound]) + code + String(token[r.upperBound...]),
                            confidence: 1.0, reason: .idCode)
        }

        // --- ALL-CAPS acronym typed in the RU layout -----------------------------
        // Short acronyms never reach the n-gram path (tooShort), so "СУЩ" stayed
        // "СУЩ" instead of "CEO" and was fixed by hand every time. Caps-only on
        // purpose: lowercase twins sit next to real Russian typos ("ешу"~"еду"),
        // while nobody types a Russian word in all caps mid-sentence except an
        // abbreviation — and those are protected (acronymsRU) and pre-gated.
        let capsShape = core.allSatisfy({ ($0.isLetter && $0.isUppercase) || $0.isNumber })
            && core.filter({ $0.isLetter }).count >= 2
        // A digit makes it a code, never a Russian word ("Й4" → Q4, "ы3" → S3), so
        // there the case does not matter — the curated list still has to match.
        let codeShape = core.contains(where: { $0.isNumber })
            && core.allSatisfy({ $0.isLetter || $0.isNumber })
        if current == .ru, core.count >= 2, core.count <= 8, capsShape || codeShape,
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
        // A capital on a punctuation key (":tyobyf") needs a real word behind it:
        // "<SRE", "{V" and ":LB" are markup and names, not "БЫКУ" or "ХМ".
        let shiftedCapital = token.first.map { KeystrokeBuffer.shiftedLetters.contains($0) } ?? false
        // Nor is a short caps token's period the letter ю: "LF." is not "ДАю".
        let shortCaps = current == .en && Self.isAllCapsWord(core) && core.letterCount <= 4
        if token != core, !shortCaps, !shiftedCapital || (core.count >= 3 && core.allSatisfy { $0.isLowercase }) {
            let fullAlt = KeyMap.convert(token, to: target)
            // Guard against corrupting correct current-layout text that merely
            // isn't in our (smaller) current dictionary: the alt reading must be
            // a dictionary word AND genuinely more native by the n-gram margin.
            if altModel.contains(fullAlt.lowercased()) && !curModel.contains(lc),
               altModel.score(fullAlt.lowercased()) - curModel.score(lc) > 0, !spellerKnows(lc, current) {
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

        if !curIsWord, !altIsWord, current == .ru,
           let fixed = Self.repairCommaSlip(token, core: core),
           curModel.contains(String(lc.dropLast())) || learnedWords.contains(String(lc.dropLast())) {
            return Decision(shouldConvert: true, from: .ru, to: .ru,
                            original: token, converted: fixed,
                            confidence: 1.0, reason: .slipRepaired)
        }

        // --- Dictionary decisions (high confidence) -----------------------------
        if curIsWord && !altIsWord {
            return .noop(token, layout: current, reason: .typedIsValidWord)
        }
        // A short ALL-CAPS cyrillic token is a Russian abbreviation far more often
        // than a mistyped English word ("ФТ" → "AN" was a false positive: the user
        // was typing "НФТ"). Only the curated acronym and whitelist paths above may
        // turn such a token into English.
        if altIsWord && !curIsWord, current == .ru, Self.isAllCapsWord(core), core.letterCount <= 4 {
            return .noop(token, layout: current, reason: .capsGuard)
        }
        // The same on the EN layout: "VS", "DS", "CTR" are not "МЫ", "ВЫ", "СЕК". Only
        // a Russian abbreviation may come out of a short caps token there, and not
        // among English: "WAF" next to English words is not "ЦФА".
        if altIsWord, current == .en, Self.isAllCapsWord(core), core.letterCount <= 4,
           !dicts.acronymsRU.contains(altLC) || context == .en {
            return .noop(token, layout: current, reason: .capsGuard)
        }
        if altIsWord && !curIsWord {
            // One letter beside a markup sign is markup: ":D", "<b>", "C#".
            if core.letterCount == 1, shiftedCapital || token.contains("#") {
                return .noop(token, layout: current, reason: .tooShort)
            }
            if spellerKnows(lc, current) { return .noop(token, layout: current, reason: .typedIsValidWord) }
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
        // Short ALL-CAPS tokens are abbreviations, not words: the n-gram has no say
        // ("HRBP" scored as Russian "РКИЗ"). Real caps words are long or in the
        // dictionary, and both of those are decided above.
        if Self.isAllCapsWord(core), core.letterCount <= 5 {
            return .noop(token, layout: current, reason: .capsGuard)
        }
        // A real word never carries a shifted-number symbol between two letters
        // ("ye$yj", "так;е"). If that is what converting produces, the token is not a
        // wrong-layout word — refuse before the n-gram gets a vote on garbage.
        // The same goes for a Russian word with ж, whose other reading has ";" inside.
        if Self.hasInnerSymbol(altForm) {
            return Decision(shouldConvert: false, from: current, to: current, original: token,
                            converted: token, confidence: 0.01, reason: .belowThreshold)
        }
        // Three of a letter in a row is a drawn-out interjection ("нууу", "аааа"),
        // and the n-gram has nothing to say about it: those came out as "yeee", "ffff".
        if Self.hasTripleLetter(lc) {
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
        var speller = margin > 0 && spellerKnows(lc, current)
        // Four letters on the EN layout are too few for an n-gram to tell Russian
        // from a code ("xbrl", "lqdt", "dpkg"), and a dot inside is a domain or a file
        // name ("vk.com", "next.js"): there the speller has to know the Russian word
        // too. Other tokens keep the benefit of the doubt, which is how names and
        // typos typed on the wrong layout still convert.
        if current == .en, core.letterCount <= 4 || core.contains("."), let known = ruWordOracle,
           !spellerReady() || !known(altLC.filter { $0.isLetter }) { speller = true }
        if margin >= config.ngramMinMargin && confidence >= config.threshold && !speller {
            return Decision(shouldConvert: true, from: current, to: target,
                            original: token, converted: fullConverted,
                            confidence: confidence, reason: .ngramMargin)
        }
        // Morphology rescue: the alt reading is a plausible inflection of a KNOWN
        // stem and the typed reading is not, and the n-gram already leans target.
        // Lowers the bar for genuine inflected forms without raising FP (the stem
        // must be real and the typed form must NOT look native in its layout).
        if margin > 0, !speller,
           altModel.looksLikeInflection(altLC), !curModel.looksLikeInflection(lc) {
            return Decision(shouldConvert: true, from: current, to: target,
                            original: token, converted: fullConverted,
                            confidence: max(0.7, confidence), reason: .morphology)
        }
        // The score goes with the refusal: it tells a near miss from a plain Russian
        // word when the history is read later.
        return Decision(shouldConvert: false, from: current, to: current, original: token,
                        converted: token, confidence: confidence, reason: .belowThreshold)
    }

    // MARK: - helpers

    /// Short words stay out of it: to the English speller "r", "ye" and "tot" are
    /// words, and they are also how "к", "ну" and "еще" come out on the EN layout.
    /// So do tokens with inner punctuation, which it splits and passes in pieces: that
    /// "k.lb" looks fine to it says nothing about "люди". An apostrophe stays, English
    /// has words with it. A speller that cannot be asked counts as knowing a cyrillic
    /// word: a correct word nobody vouched for must not be rewritten on a guess.
    private func spellerKnows(_ word: String, _ layout: Layout) -> Bool {
        guard word.count >= (layout == .ru ? 3 : 4), word.allSatisfy({ $0.isLetter || $0 == "'" }),
              let oracle = layout == .ru ? ruWordOracle : enWordOracle else { return false }
        guard spellerReady() else { return layout == .ru }
        return oracle(word)
    }

    private func isRefused(_ word: String) -> Bool {
        learnedReverts.contains(word) || exceptions.contains(word)
    }

    static func hasTripleLetter(_ s: String) -> Bool {
        var run = 0
        var previous: Character?
        for c in s {
            run = c == previous ? run + 1 : 1
            previous = c
            if run >= 3 && c.isLetter { return true }
        }
        return false
    }

    /// What surrounds the core of a token.
    static let outerCharacters = CharacterSet.punctuationCharacters
        .union(.whitespacesAndNewlines).union(.symbols)

    private func sigmoid(_ x: Double) -> Double { 1.0 / (1.0 + exp(-x)) }

    /// Letter-mapping punctuation kept word-internal by KeystrokeBuffer. As the
    /// OUTER char of a token it's real sentence punctuation → preserve it.
    private static let softPunct: Set<Character> = [",", ".", ";", "'", "[", "]", "`", "\\",
                                                    ":", "<", ">", "{"]

    static func convertPreservingOuterPunct(_ token: String, to target: Layout) -> String {
        var lead = "", trail = "", mid = Substring(token)
        // Brackets on the RU layout come from the key left of 1 (macOS Russian):
        // that is "`" and "~" on the way to English, not sentence punctuation. On
        // Russian – PC they cannot be typed, and KeyMap leaves them as they are. A pair
        // around a word is a pair, whatever the keys: "~broker`" means nothing.
        let paired = token.first == "[" && token.last == "]"
        func keep(_ c: Character) -> Bool {
            softPunct.contains(c) && (paired || !(target == .en && (c == "[" || c == "]")))
        }
        while let f = mid.first, keep(f) { lead.append(f); mid = mid.dropFirst() }
        while let l = mid.last, keep(l) { trail = String(l) + trail; mid = mid.dropLast() }
        // Converting to Russian, a "[" right after the word is the х key, not a
        // bracket: plural genitives end in -х all the time ("lt;ehys[" →
        // "дежурных", not "дежурны["), while a bracket would need an opening one.
        if target == .ru, !mid.isEmpty, !lead.contains("["), trail.first == "[" {
            trail.removeFirst()
            return lead + KeyMap.convert(String(mid) + "[", to: target) + trail
        }
        return lead + KeyMap.convert(String(mid), to: target) + trail
    }
}
