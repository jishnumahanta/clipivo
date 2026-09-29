#!/usr/bin/env bash
# Captures the README screenshots from the real app running in demo mode, over a freshly seeded
# library of sample clips. Demo mode never reads your clipboard, your history, your settings or the
# Keychain (see Sources/ClipivoMacKit/App/DemoMode.swift).
#
# Usage: scripts/demo-screenshots.sh            # writes assets/screenshots/*.png
#        scripts/demo-screenshots.sh --keep     # also leaves a demo instance running for manual shots
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Work under ~/Library/Caches: writing to other volumes can trigger a macOS privacy prompt mid-run.
WORK="$HOME/Library/Caches/ClipivoDemo"
LIBRARY="$WORK/library"
SHOTS="$WORK/shots"
OUT="assets/screenshots"
rm -rf "$LIBRARY" "$SHOTS"
mkdir -p "$LIBRARY" "$SHOTS" "$OUT"

echo "==> Seeding sample library"
CLIPIVO_DEMO_LIBRARY="$LIBRARY" swift test --filter DemoLibrarySeeder >/dev/null

echo "==> Building app"
scripts/build-app.sh >/dev/null

demo() { open -n -W dist/Clipivo.app --args -ClipivoDemoLibrary "$LIBRARY" "$@"; }

echo "==> Capturing"
demo -ClipivoSnapshotPath "$SHOTS/warmup.png"   # first launch generates thumbnails and OCR text
demo -appearance light -panelLayout shelf -ClipivoSnapshotPath "$SHOTS/shelf-light.png"
demo -appearance dark  -panelLayout shelf -ClipivoSnapshotPath "$SHOTS/shelf-dark.png"
demo -appearance light -panelLayout list  -ClipivoSnapshotPath "$SHOTS/list-light.png"
demo -appearance dark  -panelLayout list  -ClipivoSnapshotPath "$SHOTS/list-dark.png"
demo -appearance light -panelLayout list  -ClipivoSearch "weekly review" -ClipivoSnapshotPath "$SHOTS/search-ocr.png"
demo -appearance light -panelLayout shelf -ClipivoQuickLook 5 -ClipivoSnapshotPath "$SHOTS/quick-look.png"
demo -appearance light -ClipivoSettings privacy -ClipivoSnapshotPath "$SHOTS/settings-privacy.png"

for name in shelf-light shelf-dark list-light list-dark search-ocr quick-look settings-privacy; do
    cp "$SHOTS/$name.png" "$OUT/$name.png"
done
echo "==> Wrote $(ls "$OUT" | wc -l | tr -d ' ') screenshots to $OUT/"

if [[ "${1:-}" == "--keep" ]]; then
    echo "==> Starting a demo instance for manual screenshots (for example the menu bar menu)."
    echo "    Quit your normal Clipivo first so only the demo icon is in the menu bar; quit the demo from its menu when done."
    open -n dist/Clipivo.app --args -ClipivoDemoLibrary "$LIBRARY"
fi
