#!/bin/bash
# Builds a distributable Clipivo release zip.
#
#   VERSION=0.9.0 scripts/make-release.sh     (signs with "Clipivo Beta" when that certificate is installed)
#
# Output: dist/release/Clipivo-<version>.dmg and .zip, each with a .sha256 (your dist/Clipivo.app is left untouched)
#
# Signing: use the same self-signed certificate for every beta so testers' Accessibility and
# Keychain permissions survive updates. With a paid Developer ID, also notarize (see CONTRIBUTING.md).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?Set VERSION, e.g. VERSION=0.9.0}"
if [[ -z "${CODESIGN_IDENTITY:-}" ]] && ! security find-identity -v -p codesigning 2>/dev/null | grep -q '"Clipivo Beta"'; then
  echo "warning: no CODESIGN_IDENTITY or \"Clipivo Beta\" certificate — the release will be ad-hoc signed and testers will" >&2
  echo "         have to re-grant Accessibility after every update. See INSTALL.md › For maintainers." >&2
fi

echo "==> Running tests"
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift test 2>&1 | tail -1

echo "==> Building universal app"
OUTPUT_DIR=dist/release UNIVERSAL=1 VERSION="$VERSION" BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}" scripts/build-app.sh

APP=dist/release/Clipivo.app
ZIP="dist/release/Clipivo-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist/release && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

echo "==> Building disk image"
DMG="dist/release/Clipivo-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Clipivo.app"
ln -s /Applications "$STAGE/Applications"   # drag Clipivo onto this to install
rm -f "$DMG" "$DMG.sha256"
hdiutil create -quiet -volname "Clipivo $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
# Only a Developer ID signature helps on a disk image. Gatekeeper checks a *signed* DMG when it's
# opened and rejects self-signed ones, while an unsigned DMG opens normally and only the app inside
# is checked (the single "Open Anyway" step). So sign the DMG only with Developer ID.
SIGNER="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ "$SIGNER" == "Developer ID Application:"* ]]; then codesign --force --sign "$SIGNER" --timestamp "$DMG"; fi
(cd dist/release && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "==> Architectures: $(lipo -archs "$APP/Contents/MacOS/Clipivo")"
echo "==> Signature: $(codesign -dvv "$APP" 2>&1 | grep -E '^Authority|Signature=adhoc' | head -1)"
echo "==> Release ready: $DMG and $ZIP"
cat "$DMG.sha256" "$ZIP.sha256"
