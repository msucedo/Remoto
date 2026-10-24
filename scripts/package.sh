#!/bin/zsh
# Builds dist/<Name>-<version>.dmg for GitHub Releases: the app signed with
# Developer ID and hardened runtime, notarized by Apple and stapled, so it
# opens with a double click and no Gatekeeper warning.
#
# One-time setup (stores the notary credentials in the keychain):
#   xcrun notarytool store-credentials remoto-notary --apple-id <email> --team-id <TEAM_ID>
# NOTARY_PROFILE picks another stored profile.
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/product.env"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\"$/\1/p" | head -1)}"
PROFILE="${NOTARY_PROFILE:-remoto-notary}"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity for team $TEAM_ID" >&2; exit 1; }

(cd "$ROOT" && swift test) || { echo "tests failed" >&2; exit 1; }
(cd "$ROOT/web" && npm test)
SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build.sh"

APP="$ROOT/build/$PRODUCT_NAME.app"
DMG="$ROOT/dist/$PRODUCT_NAME-$VERSION.dmg"
STAGE="$ROOT/build/dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE" "$ROOT/dist"
ditto "$APP" "$STAGE/$PRODUCT_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$PRODUCT_NAME" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> notarizing (a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"
shasum -a 256 "$DMG"
echo "==> done: $DMG"
