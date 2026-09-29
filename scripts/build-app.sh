#!/bin/bash
# Builds Clipivo.app from the Swift package.
#
#   scripts/build-app.sh                  release build for this Mac's architecture
#   UNIVERSAL=1 scripts/build-app.sh      arm64 + x86_64
#   CONFIG=debug scripts/build-app.sh     debug build
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# Output: dist/Clipivo.app (or $OUTPUT_DIR/Clipivo.app)
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCT_NAME="${PRODUCT_NAME:-Clipivo}"
BUNDLE_ID="${BUNDLE_ID:-in.jishnumahanta.clipivo}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
CONFIG="${CONFIG:-release}"
# Signing: an explicit identity wins; otherwise use an Apple Development certificate if one exists
# (a stable identity keeps the Accessibility permission across rebuilds); otherwise ad-hoc.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -oE '"Apple Development: [^"]+"' | tr -d '"' || true)"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "note: ad-hoc signing — macOS will ask for Accessibility again after each rebuild." >&2
fi

# Prefer a full Xcode toolchain when the active developer dir is only the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> Building $PRODUCT_NAME ($CONFIG)"
swift build -c "$CONFIG" --product Clipivo ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})"

OUTPUT_DIR="${OUTPUT_DIR:-dist}"
APP="$OUTPUT_DIR/$PRODUCT_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Clipivo" "$APP/Contents/MacOS/$PRODUCT_NAME"

sed -e "s/__PRODUCT_NAME__/$PRODUCT_NAME/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon: Resources/AppIcon.png (1024×1024, transparent) is the source of truth.
# The .icns is regenerated whenever the PNG is newer.
if [[ ! -f Resources/AppIcon.icns || Resources/AppIcon.png -nt Resources/AppIcon.icns ]]; then
  echo "==> Generating app icon"
  WORK="$(mktemp -d)"
  ICONSET="$WORK/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$WORK"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing ($IDENTITY)"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/Clipivo.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "==> Built $APP ($(du -sh "$APP" | cut -f1))"
