# LayoutSwitcher

A local, private macOS keyboard‑layout switcher for mixed **RU/EN** typing — a
native Swift menu‑bar agent that fixes text typed in the wrong layout, proactively
sets the right layout before you type, and never touches the network.

> Goal isn't "100% perfect auto‑detect" (impossible — the same keystrokes can be
> valid in both layouts). It's **zero corruption of already‑correct text** and
> **instant one‑key recovery**. When unsure, the app does nothing.

## Features

- **Auto‑convert** a word typed in the wrong layout (`ghbdtn ` → `привет `) using
  frequency dictionaries + a character‑trigram model, only at high confidence —
  never on doubt. English typed on the RU layout is caught mid‑word as soon as its
  first letters cannot start a Russian word (`срф` → `cha…`), mentions as soon as
  the letters after `"` cannot (`"тш` → `@ni…`); caps acronyms and codes convert
  from a curated list (`СУЩ` → `CEO`, `Й4` → `Q4`).
- **Proactive layout** before you type: per‑app / per‑field memory, latin for
  url / search / password fields.
- **One‑key correction loop**: fix the last word (`⌃⌥Z`), repeat to cycle back;
  double‑`⇧` switches layout manually; `⌃⌥X` undoes a conversion (no clash with `⌘Z`).
- **Mixed RU/EN safety**: exceptions list, "always latin" whitelist (API, sprint,
  PR…), and learning from your manual reverts.
- **Shadow‑mode** to calibrate the threshold without changing any text, plus a
  recent‑conversions review.
- **Text tools** on a selection: transliteration, case cycle, Caps‑Lock fix, snippets.
- **Reliable & private**: self‑healing event tap, fail‑open on any error, zero
  network, ephemeral keystroke buffer, password‑field stand‑down.

## Requirements

- macOS 13+ (Apple Silicon), Xcode / Swift 6 toolchain.

## Build & run

```bash
cd app
swift test                      # 66 unit tests (engine, mapping, buffer, store, text tools)

bash scripts/make_cert.sh       # ONCE: stable self‑signed identity so macOS
                                # permission grants survive rebuilds
bash scripts/build_app.sh       # → dist/LayoutSwitcher.app (+ headless self‑test)
open dist/LayoutSwitcher.app
```

On first launch grant **two** permissions, then quit & relaunch:

1. **Accessibility** (read focused field) — the app prompts.
2. **Input Monitoring** (the keyboard event tap) — System Settings → Privacy.
   Without it the tap is "active" but receives no events.

Optional crash/login auto‑restart: `bash scripts/install_launchagent.sh` (KeepAlive).

> Why `make_cert.sh`? Ad‑hoc signing changes the binary hash every build, so macOS
> treats each rebuild as a new app and drops the permission grants. A stable
> self‑signed identity fixes that. See [app/README.md](app/README.md).

## Hotkeys (rebindable in Settings → Хоткеи)

| Action | Default |
|---|---|
| Fix last word + switch layout | `⌃⌥Z` |
| Toggle auto‑convert | `⌃⌥A` |
| Undo conversion | `⌃⌥X` |
| Transliterate selection | `⌃⌥T` |
| Cycle case of selection | `⌃⌥C` |
| Fix Caps of selection | `⌃⌥U` |
| Convert current line | `⌃⌥L` |
| Fix last word + switch layout | double `⇧` (same as `⌃⌥Z`) |

## How detection works

For each finished word the engine compares the typed form against the form in the
other layout:

1. **Dictionary** — typed form is a real word, the other isn't → leave it; the other
   is a real word, typed isn't → convert (high confidence).
2. **Valid in both layouts** → leave it (when in doubt, do nothing).
3. **Out of vocabulary** → a character‑trigram language model (built from the same
   word lists) decides, and only converts above a configurable confidence threshold.

Exceptions / whitelist / learned reverts short‑circuit everything above.

Mid‑word, a word still being typed on the RU layout converts to English only when
no Russian word the app knows starts with its letters (bundled lists, your local
lexicon, and the system Russian spell checker) and the latin form starts an
English word or a curated term. A manual revert of any conversion is learned, so
the same word is never converted again.

## Privacy

No network code anywhere (no telemetry, no update checks). The current‑word buffer
is ephemeral and wiped at every boundary; only your settings and lexicons are stored
locally under `~/Library/Application Support/LayoutSwitcher/`. The switching
history (`events.json`, off by default, menu → История) and the personal lexicon
mined from it (`user_ru_words.txt`) contain words you typed, so they stay there and
never go into the repository.

## Project layout

```
app/        SwiftPM package — SwitcherCore (pure, tested) + LayoutSwitcher (agent)
req/        Requirements, decomposition, acceptance scenarios
app/ACCEPTANCE.md   Per‑scenario acceptance results
```

## Status

Implements the full requirement set (FR/NFR/REL/SEC) and passes all release‑critical
acceptance scenarios — see [app/ACCEPTANCE.md](app/ACCEPTANCE.md). Known limitations
(documented there): url/email field detection is limited by what Accessibility
exposes; web password fields lack a secure‑field role; display‑capture games may not
report fullscreen.

## License

MIT — see [LICENSE](LICENSE).

