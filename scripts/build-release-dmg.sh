#!/usr/bin/env bash
# Build an unsigned NextTerm.app and package it into a drag-to-Applications
# DMG for beta distribution.
#
# Usage:
#     ./scripts/build-release-dmg.sh <version>
#
# Example:
#     ./scripts/build-release-dmg.sh v1.0.0-beta1
#         → dist/NextTerm-1.0.0-beta1.dmg
#
# Phase 2 deferrals (intentional, NOT missing functionality):
# - No `codesign --sign "Developer ID Application"` — ad-hoc signing only.
# - No `notarytool` submit — Gatekeeper will warn on first launch; users
#   right-click → Open to bypass. Documented in docs/BETA.md (M6-7).
# - No homebrew tap — direct DMG download for M6 beta.
# - No CI release workflow — invoke this script manually.
#
# When signing lands (Phase 2):
# - Add `codesign --options runtime --sign <identity>` after archive export.
# - Re-enable `ENABLE_HARDENED_RUNTIME = YES` in app/project.yml (currently
#   disabled for the unsigned path).
# - Add `xcrun notarytool submit ... --wait` + `xcrun stapler staple`.
# - Pick a stable bundle ID (currently com.zenzai.NextTerm — TBD).

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <version>" >&2
    echo "  example: $0 v1.0.0-beta1" >&2
    exit 64
fi

VERSION_RAW="$1"
# Strip a leading `v` if present so the DMG / Info.plist carry a bare
# semver string (e.g. `v1.0.0-beta1` → `1.0.0-beta1`).
VERSION="${VERSION_RAW#v}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
APP_DIR="$REPO_ROOT/app"
DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$DIST_DIR/build-$VERSION"
ARCHIVE_PATH="$BUILD_DIR/NextTerm.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_STAGE="$BUILD_DIR/dmg-stage"
DMG_PATH="$DIST_DIR/NextTerm-$VERSION.dmg"

mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$DMG_STAGE"

echo "▶ Archiving NextTerm $VERSION (unsigned, ad-hoc)"
xcodebuild archive \
    -project "$APP_DIR/NextTerm.xcodeproj" \
    -scheme NextTerm \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO \
    DEVELOPMENT_TEAM="" \
    | tail -20

# Export the .app from the .xcarchive. We deliberately skip
# `xcodebuild -exportArchive` (which expects a signed `exportOptionsPlist`)
# and just copy the `.app` out of the archive — for an unsigned build
# this is functionally identical and avoids the export-options dance.
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/NextTerm.app"
if [[ ! -d "$ARCHIVED_APP" ]]; then
    echo "error: $ARCHIVED_APP not produced by archive step" >&2
    exit 1
fi

echo "▶ Staging DMG layout in $DMG_STAGE"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$ARCHIVED_APP" "$DMG_STAGE/NextTerm.app"
# Drag-to-Applications symlink. `hdiutil` preserves symlinks in the
# resulting image so the user sees a side-by-side `NextTerm.app` →
# `Applications` shortcut on mount.
ln -s /Applications "$DMG_STAGE/Applications"

echo "▶ Building DMG → $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "NextTerm $VERSION" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH" \
    | tail -5

echo
echo "✓ Built unsigned DMG: $DMG_PATH"
echo
echo "  Beta install: open the DMG, right-click NextTerm.app → Open"
echo "  (Gatekeeper will warn — this is expected for unsigned builds.)"
