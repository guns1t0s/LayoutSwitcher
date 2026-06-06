#!/bin/bash
# Install a KeepAlive LaunchAgent so the menu-bar agent auto-restarts after a
# crash and at login (REL-8 / scenario 10.5). SMAppService alone is only a
# login item — it does NOT relaunch on crash; KeepAlive does.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/dist/LayoutSwitcher.app/Contents/MacOS/LayoutSwitcher"
LABEL="com.oateplov.layoutswitcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -x "$BIN" ]; then
    echo "Build the app first: bash scripts/build_app.sh"; exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$BIN</string></array>
    <key>RunAtLoad</key><true/>
    <!-- Relaunch only on a crash (non-zero exit), NOT on a clean user Quit.
         KeepAlive:true would relaunch even when you quit, so you could never
         close the app. SuccessfulExit:false = restart on crash only. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
echo "Installed: $PLIST"
echo "Agent now auto-restarts on crash + at login."
echo "Uninstall: launchctl unload \"$PLIST\" && rm \"$PLIST\""
