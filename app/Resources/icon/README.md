# Icons

Drop the source icon here; `scripts/build_app.sh` embeds it into the .app.

| File | What | Notes |
|---|---|---|
| `AppIcon.png` | App icon (the purple "Я⇄A" keycap) | square, ideally 1024×1024 |

`build_app.sh`:
- generates `AppIcon.icns` from `AppIcon.png` (`sips`/`iconutil`) and sets `CFBundleIconFile` — Finder / Get Info / About;
- generates a small colour `MenuBarIcon.png` (36²) from the same source; `MenuBarController` shows it in the menu bar (in colour, beside the RU/EN indicator).

Optional — without `AppIcon.png` the build still works (menu bar falls back to a text badge).
