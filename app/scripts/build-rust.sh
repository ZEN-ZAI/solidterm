#!/usr/bin/env bash
# Build nextterm-ffi as a static library and sync the swift-bridge-generated
# shims (Swift + C header) into $SRCROOT/NextTerm/Generated so Xcode's
# Compile Sources phase can see them.
#
# Invoked by the "Build Rust core" Run Script build phase in NextTerm.xcodeproj.
# Inputs:  $SRCROOT/../crates/nextterm-ffi/src/**
# Outputs: $BUILT_PRODUCTS_DIR/libnextterm_ffi.a + $SRCROOT/NextTerm/Generated/*

set -euo pipefail

# Resolve repo root (one level up from $SRCROOT=app/).
REPO_ROOT="${SRCROOT%/}/.."
cd "$REPO_ROOT"

# Map Xcode's CONFIGURATION to cargo's --release flag.
case "${CONFIGURATION:-Debug}" in
    Release) CARGO_PROFILE="release"; CARGO_FLAGS="--release" ;;
    *)       CARGO_PROFILE="debug";   CARGO_FLAGS="" ;;
esac

# PATH typically doesn't include ~/.cargo/bin under Xcode; add common locations.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# Build the whole workspace, not just `-p nextterm-ffi`: a bare
# per-package build doesn't always re-link when sources change in
# upstream crates (`nextterm-engine`, `nextterm-claude`, …), which
# leaves Xcode binding against stale `.a`. Surfaced 2026-05-09 (B13).
echo "▶ cargo build --workspace $CARGO_FLAGS (profile=$CARGO_PROFILE)"
# shellcheck disable=SC2086
cargo build --workspace $CARGO_FLAGS

STATIC_LIB="$REPO_ROOT/target/$CARGO_PROFILE/libnextterm_ffi.a"
if [[ ! -f "$STATIC_LIB" ]]; then
    echo "error: $STATIC_LIB not produced" >&2
    exit 1
fi

# The swift-bridge build.rs writes into $OUT_DIR, which lives under a hashed
# path (target/$profile/build/nextterm-ffi-<hash>/out/). Resolve it freshly
# every build since the hash can rotate.
OUT_DIR=$(find "$REPO_ROOT/target/$CARGO_PROFILE/build" \
    -maxdepth 2 -type d -name "out" -path "*nextterm-ffi*" \
    -print -quit)
if [[ -z "$OUT_DIR" ]]; then
    echo "error: could not locate swift-bridge OUT_DIR under target/$CARGO_PROFILE/build" >&2
    exit 1
fi

GEN_DIR="$SRCROOT/NextTerm/Generated"
mkdir -p "$GEN_DIR"

# Copy-if-changed so Xcode doesn't needlessly recompile.
for f in "$OUT_DIR/SwiftBridgeCore.swift" \
         "$OUT_DIR/SwiftBridgeCore.h" \
         "$OUT_DIR/nextterm_ffi/nextterm_ffi.swift" \
         "$OUT_DIR/nextterm_ffi/nextterm_ffi.h"; do
    dest="$GEN_DIR/$(basename "$f")"
    if [[ ! -f "$dest" ]] || ! cmp -s "$f" "$dest"; then
        cp "$f" "$dest"
        echo "  ✓ $(basename "$f")"
    fi
done

# Xcode expects the static library at $BUILT_PRODUCTS_DIR so the Link phase
# can find it via OTHER_LDFLAGS = -lnextterm_ffi + LIBRARY_SEARCH_PATHS.
mkdir -p "$BUILT_PRODUCTS_DIR"
cp "$STATIC_LIB" "$BUILT_PRODUCTS_DIR/libnextterm_ffi.a"
echo "▶ linked $BUILT_PRODUCTS_DIR/libnextterm_ffi.a"
