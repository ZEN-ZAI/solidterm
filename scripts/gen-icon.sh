#!/usr/bin/env bash
# Regenerate the AppIcon asset catalog from the master 1024px PNG.
#
#  1. Re-render the master PNG via gen-icon.swift.
#  2. Downsize to all macOS app-icon sizes via sips.
#  3. Write Contents.json mapping the file names to the asset slots.
#
# Re-run any time the icon design changes.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

MASTER="scripts/AppIcon-master.png"
ASSETS="app/SolidTerm/Assets.xcassets"
APPICON="$ASSETS/AppIcon.appiconset"

echo "▶ Rendering master 1024px icon"
./scripts/gen-icon.swift "$MASTER" >/dev/null

mkdir -p "$APPICON"

# (size_px, basename) pairs. macOS appiconset wants concrete file sizes;
# the @2x variants just point at the next-larger file.
SIZES=(16 32 64 128 256 512 1024)
for s in "${SIZES[@]}"; do
    out="$APPICON/icon_${s}.png"
    sips -Z "$s" "$MASTER" --out "$out" >/dev/null
done

cat > "$APPICON/Contents.json" <<'JSON'
{
  "images" : [
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16.png",   "scale" : "1x" },
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_32.png",   "scale" : "2x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32.png",   "scale" : "1x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_64.png",   "scale" : "2x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128.png",  "scale" : "1x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_256.png",  "scale" : "2x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256.png",  "scale" : "1x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_512.png",  "scale" : "2x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512.png",  "scale" : "1x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_1024.png", "scale" : "2x" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON

# Asset catalog needs its own Contents.json at the root.
cat > "$ASSETS/Contents.json" <<'JSON'
{
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON

echo "✓ AppIcon asset catalog written to $APPICON"
ls -1 "$APPICON"
