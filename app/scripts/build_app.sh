#!/bin/bash
# Build LayoutSwitcher.app — a menu-bar agent bundle (LSUIElement), ad-hoc
# signed so Accessibility / Input Monitoring grants stick to a stable identity.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/LayoutSwitcher.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/LayoutSwitcher" "$APP/Contents/MacOS/LayoutSwitcher"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# RU/EN word lists as plain resources (loaded via Bundle.main at runtime).
# Avoids nesting an unsignable SwiftPM .bundle inside the app.
cp "$ROOT/Sources/SwitcherCore/Resources/ru_words.txt" "$APP/Contents/Resources/"
cp "$ROOT/Sources/SwitcherCore/Resources/en_words.txt" "$APP/Contents/Resources/"

# Prefer the stable self-signed identity (scripts/make_cert.sh) so TCC grants
# persist across rebuilds; fall back to ad-hoc (grants reset every build).
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "LayoutSwitcher Dev"; then
    IDENTITY="LayoutSwitcher Dev"
    echo "==> codesign (identity: $IDENTITY, hardened runtime)"
else
    echo "==> codesign (AD-HOC — run scripts/make_cert.sh once so grants survive rebuilds)"
fi
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/LayoutSwitcher"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign -d -r- "$APP" 2>&1 | grep -i "designated" || true

echo "==> self-test"
"$APP/Contents/MacOS/LayoutSwitcher" --selftest

echo ""
echo "Built: $APP"
echo "Run:   open \"$APP\"   (grant Accessibility + Input Monitoring on first launch)"
