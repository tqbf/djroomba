#!/usr/bin/env bash
# Regenerate DJRoomba/AppIcon.icns from djroomba.png.
#
# Applies Apple's modern (Big Sur+) macOS app-icon grid so the icon feels
# native in the Dock / Finder / Launchpad instead of a full-bleed square:
#
#   - 1024x1024 canvas
#   - 824x824 rounded-rectangle tile, centered (=> 100px margin all round)
#   - continuous-ish corner radius ~185 (0.2237 * 824 — the squircle
#     approximation that visually matches Apple's continuous corners at
#     icon sizes)
#   - one restrained, soft drop shadow contained within the 100px margin
#     (macos-design: shadows subtle/layered, never a single heavy drop)
#
# The source's off-white field becomes the tile color; the character keeps
# its built-in breathing room. All 10 iconset sizes are downscaled from the
# single styled 1024 master, then iconutil packs the .icns.
#
# Deps: ImageMagick (`magick`), iconutil. Run from the repo root:
#   ./scripts/make-appicon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="djroomba.png"
OUT="DJRoomba/AppIcon.icns"
CANVAS=1024
TILE=824
RADIUS=185

[ -f "$SRC" ] || { echo "✗ $SRC not found (run from repo root)"; exit 1; }
command -v magick   >/dev/null || { echo "✗ ImageMagick (magick) required"; exit 1; }
command -v iconutil >/dev/null || { echo "✗ iconutil required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Source -> tile-sized square (cover-fit, centered).
magick "$SRC" -resize "${TILE}x${TILE}^" -gravity center \
  -extent "${TILE}x${TILE}" "$WORK/art.png"

# Rounded-rectangle mask, then keep only the art inside it.
magick -size "${TILE}x${TILE}" xc:none \
  -draw "roundrectangle 0,0,$((TILE-1)),$((TILE-1)),$RADIUS,$RADIUS" \
  "$WORK/mask.png"
magick "$WORK/art.png" "$WORK/mask.png" \
  -alpha set -compose DstIn -composite "$WORK/tile.png"

# Compose on a transparent 1024 canvas: soft shadow first (derived from
# the tile silhouette), then the crisp tile on top, both centered so they
# register. 22% opacity / sigma 11 / +8 down — soft, low, inside the
# margin.
magick -size "${CANVAS}x${CANVAS}" xc:none \
  \( "$WORK/tile.png" -background black -shadow 22x11+0+8 \) \
    -gravity center -compose over -composite \
  "$WORK/tile.png" -gravity center -compose over -composite \
  "$WORK/icon_1024.png"

# All iconset entries, downscaled from the one styled master.
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in \
  "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
  "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
  "512:512x512" "1024:512x512@2x"; do
  px="${spec%%:*}"; name="${spec##*:}"
  magick "$WORK/icon_1024.png" -resize "${px}x${px}" \
    "$ICONSET/icon_${name}.png"
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "✓ wrote $OUT ($(du -h "$OUT" | cut -f1))"
