#!/bin/zsh
# Builds the phone client and the Swift app, then assembles build/<Name>.app.
#
#   scripts/build.sh               # release, universal (arm64 + x86_64)
#   scripts/build.sh --debug       # debug, this Mac's architecture only
#   SKIP_WEB=1 scripts/build.sh    # reuse web/dist as it is
#   SIGN_IDENTITY="..." scripts/build.sh
#
# Signing: SIGN_IDENTITY, else the first "Apple Development" identity in the
# keychain, else ad-hoc. A real identity keeps the Accessibility permission
# across rebuilds; with ad-hoc signing macOS forgets it on every build.
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/product.env"
APP="$ROOT/build/$PRODUCT_NAME.app"

CONFIG=release
ARCHS=(--arch arm64 --arch x86_64)
if [[ "${1:-}" == "--debug" ]]; then
  CONFIG=debug
  ARCHS=()
fi

if [[ -z "${SKIP_WEB:-}" ]]; then
  echo "==> web client"
  (cd "$ROOT/web" && { [[ -d node_modules ]] || npm ci; } && npm run build)
fi

echo "==> swift build ($CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG" "${ARCHS[@]}" --product "$PRODUCT_NAME"
BIN_DIR=$(swift build --package-path "$ROOT" -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$PRODUCT_NAME" "$APP/Contents/MacOS/$PRODUCT_NAME"
sed -e "s/__PRODUCT_NAME__/$PRODUCT_NAME/g" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    -e "s/__VERSION__/$VERSION/g" \
    -e "s/__BUILD_NUMBER__/$BUILD_NUMBER/g" \
    -e "s/__MIN_MACOS__/$MIN_MACOS/g" \
    "$ROOT/Support/Info.plist" > "$APP/Contents/Info.plist"
cp "$ROOT/Support/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/"
[[ -f "$ROOT/Support/AppIcon.icns" ]] && cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/"
for lproj in "$ROOT"/Support/*.lproj(N); do cp -R "$lproj" "$APP/Contents/Resources/"; done
# SwiftPM resource bundles (dependencies ship their own privacy manifests).
for bundle in "$BIN_DIR"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done
if [[ -f "$ROOT/web/dist/index.html" ]]; then
  cp -R "$ROOT/web/dist" "$APP/Contents/Resources/web"
else
  echo "==> web/dist not found: the app will run without the phone client"
fi

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: .*\)"$/\1/p' | head -1)
fi
echo "==> codesign (${SIGN_IDENTITY:-ad-hoc})"
TIMESTAMP=--timestamp=none
[[ "${SIGN_IDENTITY:-}" == Developer\ ID* ]] && TIMESTAMP=--timestamp
codesign --force --options runtime $TIMESTAMP \
  --entitlements "$ROOT/Support/Remoto.entitlements" \
  --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict --deep "$APP"
echo "==> done: $APP"
