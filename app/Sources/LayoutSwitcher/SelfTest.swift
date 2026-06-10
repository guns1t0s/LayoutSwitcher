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
        check("ghbdtn.", expectConvert: true, expect: "привет.")   // trailing period preserved

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
