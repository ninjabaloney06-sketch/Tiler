#!/bin/bash
# Installs Tiler (SPEC §6): release build, copy to ~/Applications/Tiler.app, quit a running
# copy, open the installed one. Grant Accessibility to ~/Applications/Tiler.app only.
#
#   scripts/install.sh [build.sh options, e.g. --scratch-path <dir>]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications/Tiler.app"

# build.sh prints the app path last; show its output as it runs.
SRC="$("$ROOT/scripts/build.sh" "$@" | tee /dev/stderr | tail -n 1)"
[ -d "$SRC" ] || { echo "error: build did not produce an app ($SRC)" >&2; exit 1; }

# Quit a running copy first so its executable is not replaced while it runs.
if pgrep -f 'Tiler.app/Contents/MacOS/Tiler' >/dev/null; then
    echo "==> quitting the running Tiler"
    pkill -f 'Tiler.app/Contents/MacOS/Tiler' || true
    for _ in $(seq 1 50); do
        pgrep -f 'Tiler.app/Contents/MacOS/Tiler' >/dev/null || break
        sleep 0.1
    done
fi

echo "==> installing to $DEST"
mkdir -p "$HOME/Applications"
# Replace, not merge: a stale file left inside the bundle would break its signature.
rm -rf "$DEST"
ditto "$SRC" "$DEST"

echo "==> opening $DEST"
open "$DEST"

cat <<'NOTE'
Tiler is running in the menu bar. If its menu shows "Accessibility: missing", click that line
and enable Tiler (this installed copy) in System Settings > Privacy & Security > Accessibility.
NOTE
