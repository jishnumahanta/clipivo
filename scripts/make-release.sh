#!/bin/bash
# Builds a distributable Clipivo release zip.
#
#   VERSION=0.9.0 CODESIGN_IDENTITY="Clipivo Beta" scripts/make-release.sh
#
# Output: dist/release/Clipivo-<version>.zip and .sha256 (your dist/Clipivo.app is left untouched)
#
# Signing: use the same self-signed certificate for every beta so testers' Accessibility and
# Keychain permissions survive updates. With a paid Developer ID, also notarize (see CONTRIBUTING.md).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?Set VERSION, e.g. VERSION=0.9.0}"
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  echo "warning: no CODESIGN_IDENTITY set — the release will be ad-hoc signed and testers will" >&2
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

echo "==> Architectures: $(lipo -archs "$APP/Contents/MacOS/Clipivo")"
echo "==> Signature: $(codesign -dv "$APP" 2>&1 | grep -E '^Authority|Signature=' | head -1)"
echo "==> Release ready: $ZIP"
cat "$ZIP.sha256"
