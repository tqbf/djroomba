#!/usr/bin/env bash
# Build DJ Roomba with SwiftPM (no Xcode IDE / xcodebuild) and assemble a
# signed .app bundle. Cloned from tqbf/mdv's build.sh.
#
# Usage: ./build.sh [debug|release]   (default: debug)
#
# Signing differs from mdv on purpose. mdv adhoc-signs (`codesign -s -`).
# DJ Roomba cannot: an adhoc build gets an EMPTY MusicKit library at runtime
# (proven in roadmap Phase 1). The Phase-1-verified recipe is a real
# **Apple Development** signature + the sandbox entitlements +
# NSAppleMusicUsageDescription (in Info.plist). `make dist` re-signs the
# release bundle with Developer ID + hardened runtime + notarization.
#
# Override the dev signing identity with SIGN_IDENTITY=... if the cert
# rotates (codesign substring-matches, so the team id alone also works).
set -euo pipefail

CONFIG="${1:-debug}"
case "$CONFIG" in
  debug|release) ;;
  *) echo "usage: $0 [debug|release]"; exit 1 ;;
esac

cd "$(dirname "$0")"

APP_NAME="DJRoomba"
SRC_DIR="DJRoomba"
ENTITLEMENTS="$SRC_DIR/DJRoomba.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: Thomas Ptacek (7F2QE7P59D)}"

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[ -x "$BIN" ] || { echo "✗ binary missing at $BIN"; exit 1; }

APP="build/$APP_NAME.app"
echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN"           "$APP/Contents/MacOS/$APP_NAME"
cp "$SRC_DIR/Info.plist" "$APP/Contents/Info.plist"

# App icon. The bundle's only resource: a prebuilt .icns referenced by
# CFBundleIconFile (no asset catalog — consistent with the no-Xcode build).
# Regenerate from djroomba.png with ./scripts/make-appicon.sh.
ICON="$SRC_DIR/AppIcon.icns"
[ -f "$ICON" ] || { echo "✗ $ICON missing — run ./scripts/make-appicon.sh"; exit 1; }
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# Stamp the version from an exact git tag when one is present (mirrors
# mdv's "dist is built from a vX.Y.Z tag" philosophy). Falls back to the
# literal value already in Info.plist (0.1.0) for untagged dev builds.
VERSION="$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)"
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$APP/Contents/Info.plist" >/dev/null
  echo "  stamped CFBundleShortVersionString = $VERSION"
fi

# embedded.provisionprofile hook. Phase 1 proved library read/playback
# needs NO profile (Apple Development signature was sufficient). Whether a
# notarized Developer ID build needs a MusicKit-App-Service profile for
# *catalog* APIs is the open Phase-2/3 risk; when that's answered, set
# PROVISION_PROFILE=/path/to.provisionprofile and it gets embedded + the
# sign step picks it up. Until then this is a no-op.
if [ -n "${PROVISION_PROFILE:-}" ]; then
  [ -f "$PROVISION_PROFILE" ] || { echo "✗ PROVISION_PROFILE not found: $PROVISION_PROFILE"; exit 1; }
  cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
  echo "  embedded provisioning profile: $PROVISION_PROFILE"
fi

echo "→ codesigning as: $SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "✓ $APP"
