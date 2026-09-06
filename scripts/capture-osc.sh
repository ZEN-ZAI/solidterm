#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Zen Kiattikhunnawong

# Capture an OSC byte stream for the test fixtures corpus.
#
# Usage: ./scripts/capture-osc.sh <name>
#   <name> — short slug for the capture (e.g. "zsh-macos-default")
#
# Produces:
#   tests/fixtures/osc-sequences/<name>.bin
#   tests/fixtures/osc-sequences/<name>.meta.json
#

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <slug>" >&2
  exit 1
fi

slug="$1"
out_dir="tests/fixtures/osc-sequences"
mkdir -p "$out_dir"
bin="$out_dir/$slug.bin"
meta="$out_dir/$slug.meta.json"

echo "Capturing OSC stream for: $slug"
echo "→ $bin"
echo
echo "Drive a session that exercises the OSC sequences you want recorded."
echo "Type 'exit' or press Ctrl-D when done."
echo

# Use script(1) to capture raw bytes including ANSI/OSC.
# -q quiet; -F flush after each write; -t 0 no timing file.
script -q -F "$bin" "${SHELL:-/bin/zsh}" || true

# Emit metadata.
cat > "$meta" <<EOF
{
  "captured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "macos_version": "$(sw_vers -productVersion)",
  "shell": "$($SHELL --version 2>/dev/null || echo unknown)",
  "claude_code_version": "$(claude --version 2>/dev/null || echo not-installed)",
  "term_program": "${TERM_PROGRAM:-unknown}",
  "term": "${TERM:-unknown}",
  "redacted": false,
  "notes": "captured via script -q; review for hostnames/paths before commit"
}
EOF

echo
echo "Wrote $bin ($(wc -c <"$bin") bytes) + $meta"
echo "Review for secrets/hostnames, then redact via scripts/redact-osc.sh if needed."
