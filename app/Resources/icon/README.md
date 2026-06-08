# Icons

Source assets; `scripts/build_app.sh` embeds them into the .app.

| File | What | Notes |
|---|---|---|
| `AppIcon.png` | App icon — colour "ЯА" squircle | 1024×1024 → `AppIcon.icns`, `CFBundleIconFile` |
| `MenuBarIconTemplate.png` / `@2x` | Menu-bar glyph — monochrome **template** | 16 / 32 px; macOS recolours it for light/dark |
| `AppIcon.svg`, `MenuBarIcon.svg` | Vector sources (curves) | for re-export |

Design rule (from the asset author): **colour only in the app icon**; in the menu
bar it's a single tone + alpha and the system recolours it. `MenuBarController`
loads `MenuBarIconTemplate` as a template image beside the RU/EN indicator.

Without these files the build still works (menu bar falls back to a text badge).
