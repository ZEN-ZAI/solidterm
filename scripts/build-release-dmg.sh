#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Zen Kiattikhunnawong

# Build an unsigned SolidTerm.app and package it into a drag-to-Applications
# DMG for beta distribution.
#
# Usage:
#     ./scripts/build-release-dmg.sh <version>
#
# Example:
#     ./scripts/build-release-dmg.sh v1.0.0-beta1
#         → dist/SolidTerm-1.0.0-beta1.dmg
#
# The version argument is the single source of the version: `project.yml`
# keeps its own MARKETING_VERSION and is overridden per invocation. Around
# that, the script makes a build reproducible from git alone:
# - it refuses to build from a dirty working tree, so the DMG always
#   corresponds to a commit that exists;
# - it refuses to rebuild a version already tagged in this clone, so a
#   repeat run cannot produce a second binary for a tagged version;
# - it stamps the short HEAD sha into Info.plist as `SolidTermGitCommit`
#   and re-signs the bundle (editing Info.plist breaks the ad-hoc seal),
#   so a shipped .app can be traced back to its source;
# - it creates the annotated tag `v<version>` once the DMG is written, and
#   prints the push command rather than pushing it for you.
#
# Phase 2 deferrals (intentional, NOT missing functionality):
# - No `codesign --sign "Developer ID Application"` — ad-hoc signing only.
# - No `notarytool` submit — Gatekeeper will warn on first launch; users
#   right-click → Open to bypass.
# - No homebrew tap — direct DMG download for M6 beta.
# - No CI release workflow — invoke this script manually.
#
# When signing lands (Phase 2):
# - Add `codesign --options runtime --sign <identity>` after archive export.
# - Re-enable `ENABLE_HARDENED_RUNTIME = YES` in app/project.yml (currently
#   disabled for the unsigned path).
# - Add `xcrun notarytool submit ... --wait` + `xcrun stapler staple`.
# - Pick a stable bundle ID (currently com.zenzai.SolidTerm — TBD).

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

# A release must be reproducible from a commit, so refuse to build out of a
# tree that has uncommitted or untracked changes.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "refusing: working tree dirty" >&2
    echo "  commit or clean it, then re-run: $0 $VERSION_RAW" >&2
    exit 1
fi

# One tag, one binary: refuse to rebuild a version that has already been cut.
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "refusing: tag v$VERSION already exists" >&2
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
APP_DIR="$REPO_ROOT/app"
DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$DIST_DIR/build-$VERSION"
ARCHIVE_PATH="$BUILD_DIR/SolidTerm.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_STAGE="$BUILD_DIR/dmg-stage"
DMG_PATH="$DIST_DIR/SolidTerm-$VERSION.dmg"

mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$DMG_STAGE"

echo "▶ Archiving SolidTerm $VERSION (unsigned, ad-hoc)"
xcodebuild archive \
    -project "$APP_DIR/SolidTerm.xcodeproj" \
    -scheme SolidTerm \
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
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/SolidTerm.app"
if [[ ! -d "$ARCHIVED_APP" ]]; then
    echo "error: $ARCHIVED_APP not produced by archive step" >&2
    exit 1
fi

echo "▶ Staging DMG layout in $DMG_STAGE"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$ARCHIVED_APP" "$DMG_STAGE/SolidTerm.app"
# Drag-to-Applications symlink. `hdiutil` preserves symlinks in the
# resulting image so the user sees a side-by-side `SolidTerm.app` →
# `Applications` shortcut on mount.
ln -s /Applications "$DMG_STAGE/Applications"

# Record which commit produced this bundle. Info.plist is inside the ad-hoc
# code signature, so editing it invalidates the seal — re-sign afterwards.
GIT_COMMIT="$(git rev-parse --short=10 HEAD)"
echo "▶ Stamping SolidTermGitCommit = $GIT_COMMIT"
/usr/libexec/PlistBuddy \
    -c "Add :SolidTermGitCommit string $GIT_COMMIT" \
    "$DMG_STAGE/SolidTerm.app/Contents/Info.plist"
codesign --force --sign - --deep "$DMG_STAGE/SolidTerm.app"

echo "▶ Building DMG → $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "SolidTerm $VERSION" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH" \
    | tail -5

echo "▶ Tagging v$VERSION"
git tag -a "v$VERSION" -m "SolidTerm $VERSION"

echo
echo "✓ Built unsigned DMG: $DMG_PATH"
echo "  Built from $GIT_COMMIT, tagged v$VERSION"
echo "  push with: git push origin v$VERSION"
echo
echo "  Beta install: open the DMG, right-click SolidTerm.app → Open"
echo "  (Gatekeeper will warn — this is expected for unsigned builds.)"
