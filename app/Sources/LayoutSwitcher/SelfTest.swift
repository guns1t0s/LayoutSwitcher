import Foundation
import SwitcherCore

/// Headless smoke test: verifies the bundled dictionaries load from the .app
/// and the engine behaves, without needing GUI or Accessibility permissions.
/// Run: `LayoutSwitcher.app/Contents/MacOS/LayoutSwitcher --selftest`
enum SelfTest {
    static func run() -> Never {
        let d = Dictionaries.loadBundled()
        print("ru words: \(d.ru.wordCount), en words: \(d.en.wordCount)")
        guard d.ru.wordCount > 0, d.en.wordCount > 0 else {
            print("FAIL: dictionaries did not load from bundle"); exit(1)
        }
        let e = DetectionEngine(dictionaries: d)
        var ok = true
        func check(_ token: String, expectConvert: Bool, expect: String? = nil) {
            let r = e.evaluate(token)
            let pass = r.shouldConvert == expectConvert && (expect == nil || r.converted == expect)
            ok = ok && pass
            print("\(pass ? "ok  " : "FAIL") \(token) -> convert=\(r.shouldConvert) '\(r.converted)' [\(r.reason)]")
        }
        check("ghbdtn", expectConvert: true, expect: "привет")
        check("trust", expectConvert: false)
        check("fetch", expectConvert: false)
        check("ntrcn", expectConvert: true, expect: "текст")
        check("api", expectConvert: false)
        check("пшерги", expectConvert: true, expect: "github")
        check("dhjlt", expectConvert: true, expect: "вроде")       // common word now in dict
        check("ybxtuj", expectConvert: true, expect: "ничего")
        check("Cajhvekbheq", expectConvert: true, expect: "Сформулируй")  // imperative form
        check("dt;kbdjt", expectConvert: true, expect: "вежливое")        // ж(;) inside word
        check("j,hfnyj", expectConvert: true, expect: "обратно")   // comma(б) kept in word
        check("vbhjds[", expectConvert: true, expect: "мировых")   // trailing х([) as letter
        check("gjybvfybz", expectConvert: true, expect: "понимания")
        check("njkmrj", expectConvert: true, expect: "только")
        check("lheubt", expectConvert: true, expect: "другие")
        check("rjulf", expectConvert: true, expect: "когда")
        check("ghbdtn.", expectConvert: true, expect: "привет.")   // trailing period preserved
        check("СУЩ", expectConvert: true, expect: "CEO")            // caps acronym (bundled list)
        check("УК", expectConvert: false)                            // Russian abbreviation kept
        check("ну;но", expectConvert: true, expect: "нужно")         // ⇧4-for-ж slip
        check("цуи", expectConvert: true, expect: "web")             // short EN word
        check("HRBP", expectConvert: false)                          // EN acronym typed right stays
        check("ФТ", expectConvert: false)                            // short RU caps abbreviation
        check("Я1185954Ч", expectConvert: true, expect: "Z1185954X") // NIE code in RU layout
        check("Й4", expectConvert: true, expect: "Q4")               // code with a digit
        eq("early срф", e.evaluatePrefix("срф")?.converted ?? "nil", "cha")   // mid-word EN on RU layout
        eq("early привет", e.evaluatePrefix("при")?.converted ?? "nil", "nil")
        check("kjubhjdfybt", expectConvert: true, expect: "логирование")  // tech word in dict
        check("rjvgjytyns", expectConvert: true, expect: "компоненты")
        check("gjhzlrt", expectConvert: true, expect: "порядке")     // noun case form (paradigm fill)
        check("ghjgecnbv", expectConvert: true, expect: "пропустим") // verb 1pl form
        check("jrnz,hz", expectConvert: true, expect: "октября")     // month genitive
        check("dsltkbk", expectConvert: true, expect: "выделил")   // past tense (paradigm fill)
        check("bnjub", expectConvert: true, expect: "итоги")
        check("rjnjhst", expectConvert: true, expect: "которые")
        check("сдфгву", expectConvert: true, expect: "claude")     // ru->en brand name in dict

        func eq(_ label: String, _ got: String, _ want: String) {
            let pass = got == want; ok = ok && pass
            print("\(pass ? "ok  " : "FAIL") \(label): '\(got)'")
        }
        eq("translit", Transliterator.transliterate("привет"), "privet")
        eq("case", CaseConverter.cycle("hello"), "HELLO")
        eq("fixcaps", TextFixes.fixCapsLock("tHE"), "The")
        eq("snippet", Snippets.expand("брб", using: ["брб": "буду рядом быстро"]) ?? "nil", "буду рядом быстро")
        eq("mention", KeyMap.convert("\"фтшлщтщкщм", to: .en), "@anikonorov")
        exit(ok ? 0 : 1)
    }
}
