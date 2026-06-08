# Icons

Drop two source images here; `scripts/build_app.sh` embeds them into the .app.

| File | What | Notes |
|---|---|---|
| `AppIcon.png` | App icon (the purple "Я⇄A" keycap) | square, ideally 1024×1024; becomes `AppIcon.icns` |
| `MenuBarIcon.png` | Menu-bar glyph (the black line keycap) | square, ~512×512, transparent bg; rendered as a **template** (auto light/dark) |

`build_app.sh`:
- generates `AppIcon.icns` from `AppIcon.png` via `sips`/`iconutil` and sets `CFBundleIconFile`;
- copies `MenuBarIcon.png` into the bundle; `MenuBarController` loads it as a template image.

Both are optional — the build still works without them (menu bar falls back to a text badge).
