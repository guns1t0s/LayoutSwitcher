#!/bin/bash
# Live check: real key events into a window of the app, with the running instance
# stopped for the time of the run and started again afterwards, whatever happens.
#
#   bash scripts/live_check.sh [report] [timeout-s] [--only <name part>] [--repeat N] [--trace]
#   (the report defaults to $TMPDIR/livecheck.txt, the timeout to 240 s)
#   CHECK_APP=/path/to/Other.app bash scripts/live_check.sh ...   # an A/B build under test
#
# It takes the screen for a while (about a minute for all scenarios): keep the hands
# off the keyboard and mouse. A locked screen stops it before anything is posted.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/LayoutSwitcher.app"
CHECK_APP="${CHECK_APP:-$APP}"
REPORT="${TMPDIR:-/tmp}/livecheck.txt"
LIMIT=240
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then REPORT="$1"; shift; fi
if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then LIMIT="$1"; shift; fi

# The working build, and nothing else, runs afterwards: a build under test started by
# the second open (when the run ended early) is stopped too.
back() {
    pkill -f 'LayoutSwitcher --livecheck' 2>/dev/null
    for _ in $(seq 1 30); do pgrep -f 'LayoutSwitcher --livecheck' >/dev/null || break; sleep 0.2; done
    pkill -9 -f 'LayoutSwitcher --livecheck' 2>/dev/null
    for pid in $(pgrep -x LayoutSwitcher); do
        case "$(ps -o command= -p "$pid")" in
            "$APP/Contents/MacOS/"*) ;;
            *) kill "$pid" 2>/dev/null ;;
        esac
    done
    for _ in $(seq 1 30); do
        others=0
        for pid in $(pgrep -x LayoutSwitcher); do
            case "$(ps -o command= -p "$pid")" in "$APP/Contents/MacOS/"*) ;; *) others=1 ;; esac
        done
        [ "$others" = 0 ] && break
        sleep 0.2
    done
    pgrep -x LayoutSwitcher >/dev/null || open "$APP"
}
trap back EXIT

if python3 - <<'PY'
import plistlib, subprocess, sys
p = plistlib.loads(subprocess.run(['ioreg', '-n', 'Root', '-d1', '-a'], capture_output=True).stdout)
sys.exit(0 if any(u.get('CGSSessionScreenIsLocked') for u in p.get('IOConsoleUsers', [])) else 1)
PY
then
    echo "the screen is locked: nothing started"
    exit 3
fi

rm -f "$REPORT"
pkill -x LayoutSwitcher
for _ in $(seq 1 50); do pgrep -x LayoutSwitcher >/dev/null || break; sleep 0.1; done
open "$CHECK_APP" --args --livecheck "$REPORT" "$@"
sleep 2
# The second open brings the window of the run to the front; when the run is already
# over it would start the build under test in the ordinary way instead.
pgrep -f 'LayoutSwitcher --livecheck' >/dev/null && open "$CHECK_APP"
start=$(date +%s)
while :; do
    [ -s "$REPORT" ] && break
    pgrep -f 'LayoutSwitcher --livecheck' >/dev/null || { echo "the run ended without a report"; break; }
    [ $(( $(date +%s) - start )) -ge "$LIMIT" ] && { echo "timeout after $LIMIT s"; break; }
    sleep 0.5
done
sleep 1
back
trap - EXIT
cat "$REPORT" 2>/dev/null
grep -q ' 0 failed$' "$REPORT" 2>/dev/null
