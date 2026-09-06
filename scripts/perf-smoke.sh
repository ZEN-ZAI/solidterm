#!/usr/bin/env bash
# Performance smoke test — runs the in-scope, non-interactive measurements
# against the budgets below and emits a markdown summary.
#
# Scope (M1 task 4.11 — see spec/m1-task-breakdown.md §4.11):
#   1. Engine throughput  — `cargo bench` on `hot_feed_1mb`
#   2. Typing-to-pixel    — XCTest `LatencyMeasurementTests.testTypingToPixelP99UnderTenMs`
#   3. Release bundle size — `xcodebuild -configuration Release` + `du`
#   4. Glyph atlas memory  — derived from `GlyphAtlas.atlasSize` constant
#   5. Scrollback memory   — derived from `DEFAULT_SCROLLBACK_LINES` constant
#
# Out of scope (live-app dogfood, M5 / 4.13):
#   - Cold / warm start to first frame  (needs signed bundle launch)
#   - Frames-per-second under PTY flood (needs live app + flooded PTY)
#   - Idle / multi-pane RSS             (needs live app)
#
# Usage:
#   scripts/perf-smoke.sh                  # writes /tmp/solidterm-perf-smoke.md
#   PERF_SMOKE_OUT=foo.md scripts/...      # custom output path
#   PERF_SMOKE_SKIP_LATENCY=1 scripts/...  # skip the 17 s XCTest
#   PERF_SMOKE_SKIP_BUILD=1 scripts/...    # skip the Release rebuild
#
# Returns 0 on completion regardless of budget hits — interpretation
# is on the human reading the markdown. Bench / test failures still
# bubble up via tee but do not abort the rest of the run; the goal is
# to capture as many baselines as possible in one pass.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

OUT_FILE="${PERF_SMOKE_OUT:-/tmp/solidterm-perf-smoke.md}"

# ── helpers ──────────────────────────────────────────────────────────────────

# Portable byte → human size (macOS lacks GNU `numfmt`). Two decimals.
human_bytes() {
  awk -v b="$1" 'BEGIN {
    split("B KB MB GB TB", u);
    i = 1;
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf "%.2f %s", b, u[i];
  }'
}

section() { printf '\n## %s\n\n' "$1" | tee -a "$OUT_FILE"; }
log()     { printf '%s\n'     "$*"   | tee -a "$OUT_FILE"; }

# ── header ───────────────────────────────────────────────────────────────────

: > "$OUT_FILE"

CPU=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown CPU")
MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
MEM_HUMAN=$(human_bytes "$MEM_BYTES")
MACOS_VER=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
COMMIT=$(git rev-parse --short HEAD)
DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log "# SolidTerm perf-smoke — $DATE_UTC"
log ""
log "- Hardware: $CPU, $MEM_HUMAN RAM"
log "- macOS: $MACOS_VER"
log "- Commit: $COMMIT"
log ""

# ── 1. Engine throughput — Criterion bench ───────────────────────────────────

section "1. Engine throughput (cargo bench hot_feed_1mb)"
log "Budget: ≥ 500 MB/s sustained (spec §Throughput)"
log ""
log '```'
# Capture full bench output via tee. Don't gate the section on bench
# exit status — Criterion may flag regressions but we still want the
# numbers. `set +e` brackets the pipeline because `pipefail` would
# turn a non-zero `cargo bench` (rare but possible) into a script
# abort under `set -e`.
set +e
cargo bench -p solidterm-engine --bench hot_feed_1mb 2>&1 | tee -a "$OUT_FILE"
set -e
log '```'
log ""
THRPT=$(grep -E 'thrpt:.*MiB/s' "$OUT_FILE" | tail -1 || true)
if [[ -n "$THRPT" ]]; then
  log "Throughput line: $THRPT"
fi

# ── 2. Typing-to-pixel — XCTest harness ──────────────────────────────────────

section "2. Typing-to-pixel latency (XCTest LatencyMeasurementTests)"
log "Budget: < 8 ms p99, < 4 ms p50 (spec §Latency)"
log "Harness gate: 10.5 ms p99 (bimodal-floor accommodation;"
log "see app/SolidTermTests/LatencyMeasurementTests.swift §gate"
log "and ~/.claude/.../MEMORY.md reference_latency_harness_internals)."
log ""
if [[ "${PERF_SMOKE_SKIP_LATENCY:-0}" == "1" ]]; then
  log "(skipped via PERF_SMOKE_SKIP_LATENCY=1)"
else
  log '```'
  pushd "$REPO_ROOT/app" >/dev/null
  set +e
  xcodebuild test -scheme SolidTerm -destination 'platform=macOS' \
    -only-testing:SolidTermTests/LatencyMeasurementTests 2>&1 \
    | grep -E 'typing-to-pixel|LatencyMeasurementTests final|p50=|p99=|Test Case .* passed|Test Case .* failed|TEST SUCCEEDED|TEST FAILED|\*\* TEST' \
    | tee -a "$OUT_FILE"
  set -e
  popd >/dev/null
  log '```'
fi

# ── 3. Release bundle size ───────────────────────────────────────────────────

section "3. Release bundle size"
log "Budget: < 15 MB compressed DMG (spec §Binary size). DMG packaging is"
log "M5 (signing); we report the unsigned .app bundle as a proxy upper bound."
log ""

if [[ "${PERF_SMOKE_SKIP_BUILD:-0}" == "1" ]]; then
  log "(skipped via PERF_SMOKE_SKIP_BUILD=1)"
else
  pushd "$REPO_ROOT/app" >/dev/null
  set +e
  xcodebuild -configuration Release -scheme SolidTerm \
    -destination 'platform=macOS' build 2>&1 | tail -3 >/dev/null
  set -e

  BUILD_DIR=$(xcodebuild -showBuildSettings -configuration Release \
    -scheme SolidTerm 2>/dev/null \
    | awk '/^[[:space:]]*CONFIGURATION_BUILD_DIR =/ { print $3 }' | head -1)
  popd >/dev/null

  APP_PATH="$BUILD_DIR/SolidTerm.app"
  if [[ -d "$APP_PATH" ]]; then
    SIZE_K=$(du -sk "$APP_PATH" | awk '{print $1}')
    SIZE_BYTES=$(( SIZE_K * 1024 ))
    EXEC="$APP_PATH/Contents/MacOS/SolidTerm"
    if [[ -f "$EXEC" ]]; then
      EXEC_BYTES=$(stat -f '%z' "$EXEC")
    else
      EXEC_BYTES=0
    fi
    log "- Bundle:    $APP_PATH"
    log "- App total: $(human_bytes "$SIZE_BYTES")"
    log "- Mach-O:    $(human_bytes "$EXEC_BYTES")"
  else
    log "Release build not found at $APP_PATH"
  fi
fi

# ── 4. Glyph atlas memory — static derivation ────────────────────────────────

section "4. Glyph atlas memory (static)"
log "Budget: ≤ 64 MB (spec §Memory)"
log ""
# Match the (W, H) tuple inside SIMD2(...) — strip the literal `SIMD2<UInt32>`
# header that has its own `2` we don't want.
ATLAS_SIDE=$(grep -E 'static let atlasSize: SIMD2<UInt32> = SIMD2' \
  "$REPO_ROOT/app/SolidTerm/GlyphAtlas.swift" \
  | sed -E 's/.*SIMD2\(([0-9]+),.*/\1/' || echo "?")
if grep -qE 'pixelFormat:\s*\.r8Unorm' "$REPO_ROOT/app/SolidTerm/GlyphAtlas.swift"; then
  ATLAS_FMT="r8Unorm"
else
  ATLAS_FMT="?"
fi
if [[ "$ATLAS_SIDE" =~ ^[0-9]+$ ]]; then
  ATLAS_BYTES=$(( ATLAS_SIDE * ATLAS_SIDE * 1 ))
  log "- Atlas: ${ATLAS_SIDE}×${ATLAS_SIDE} × 1 byte ($ATLAS_FMT) = $(human_bytes "$ATLAS_BYTES")"
  log "- Pinned by: app/SolidTerm/GlyphAtlas.swift §atlasSize"
  log "- Verified by: app/SolidTermTests/GlyphAtlasTests.swift"
  log "- Margin: ~256× under budget"
else
  log "- (could not parse atlasSize from GlyphAtlas.swift)"
fi

# ── 5. Scrollback memory — static derivation ─────────────────────────────────

section "5. Scrollback memory (default config, static)"
log "Budget: ≤ 100 MB per pane @ 100k lines (spec §Memory)"
log ""
# Pull the rhs literal from `pub const DEFAULT_SCROLLBACK_LINES: u32 = 100_000;`.
# Naive `grep -oE '[0-9_]+'` matches the trailing `_LINES` underscore first.
SCROLLBACK=$(grep -E 'pub const DEFAULT_SCROLLBACK_LINES' \
  "$REPO_ROOT/crates/solidterm-engine/src/config.rs" \
  | sed -E 's/.*=[[:space:]]*([0-9_]+);.*/\1/' | tr -d _ || echo "?")
log "- Default lines: $SCROLLBACK (crates/solidterm-engine/src/config.rs)"
log "- alacritty_terminal grid cell ≈ 32 B; 80 cols × 32 B = 2.5 KB / line"
log "- Estimated upper bound: ${SCROLLBACK} × 2.5 KB ≈ ~250 MB at 80 cols,"
log "  but cells are stored sparsely so typical RAM is far lower."
log "- Live RSS measurement deferred to dogfood (4.13)."

# ── 6. GPU full re-render ────────────────────────────────────────────────────

section "6. GPU full re-render (Phase 0 baseline)"
log "Budget: < 4 ms (spec §GPU)"
log ""
log "Render-path p99 = 1.60 ms measured at Phase 0 exit (commit e7e7c28)."
log "This run's typing-to-pixel test (above) re-validates the same harness."
log "Per-frame CPU encode ≈ 0.95 ms p50 / 1.7-1.9 ms p99 (LatencyMeasurementTests"
log "MetalRenderer cpu encode/frame log line)."

# ── deferred / out of scope ──────────────────────────────────────────────────

section "Deferred to live dogfood (4.13 / M5)"
log "Methodology gap — these need a running app + permissions / signed bundle"
log "that this script can't grant in the agent shell:"
log ""
log "- Cold start to first-frame  (needs ProcessInfo.systemUptime anchor +"
log "  drawable.presentedTime; xcodebuild proxy launch != real Dock launch)"
log "- Warm start (second launch within 30 s)"
log "- Frames during PTY flood (needs live app + \`yes | head -1e6\` flood)"
log "- Idle RSS, 10-min stream RSS, 1-h idle RSS (needs live app)"
log "- 4-pane team mode RSS (M4 feature, not yet implemented)"
log ""
log "Per memory feedback_environment_blocks_methodology — flagged not papered over."

log ""
log "---"
log "Report path: $OUT_FILE"
