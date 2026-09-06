#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Zen Kiattikhunnawong

# Enforce zero-telemetry policy — block any import of analytics SDKs in tracked files.
# Policy: docs/adr/0001-no-telemetry.md.
set -euo pipefail

FORBIDDEN=(
  "segment/analytics"
  "mixpanel"
  "amplitude"
  "posthog"
  "growthbook"
  "sentry"
  "bugsnag"
  "firebase/crashlytics"
  "rollbar"
)

# Wrap each entry in \b…\b word boundaries so substring collisions don't
# trigger a false positive. Without this, "scrollbar" matches "rollbar",
# "centrify" would match "ntrify", etc. `\b` is a PCRE feature (not POSIX
# ERE), so this script uses `git grep -P` and `grep -P` rather than
# `-E` — confirmed available on macOS git + GNU grep on Linux runners.
# Entries containing `/` (e.g. `segment/analytics`) still bind correctly
# because `\b` anchors against word-vs-non-word character transitions;
# `s` is a word character on each end of the entry.
anchored=()
for term in "${FORBIDDEN[@]}"; do
  anchored+=("\\b${term}\\b")
done
pattern=$(IFS='|'; echo "${anchored[*]}")

# ── self-check ────────────────────────────────────────────────────────────
# Sanity-test the matcher against known good/bad inputs before scanning the
# repo, so a future deny-list change can't silently break the matcher.
# Distinct exit code (2) so CI logs distinguish "matcher broken" from
# "analytics SDK reference detected" (exit 1).
self_check() {
  # Use Perl as the self-check matcher: the same PCRE engine semantics
  # as `git grep -P` so a pass here implies the live scanner will agree.
  # `grep -P` would be simpler but BSD grep on macOS doesn't support it;
  # Perl ships with macOS and every CI image.
  export ANALYTICS_PATTERN="$pattern"
  local label expect input got
  while IFS=$'\t' read -r expect label input; do
    [[ -z "$label" ]] && continue
    # Perl idiom: BEGIN { $found = 0 }, set $found on match, exit !$found
    # at END. `exit 0` from `-e` doesn't skip END, so we use the flag.
    if echo "$input" | perl -ne 'BEGIN { $f = 0 } $f = 1 if /$ENV{ANALYTICS_PATTERN}/i; END { exit !$f }'; then
      got="match"
    else
      got="no-match"
    fi
    if [[ "$got" != "$expect" ]]; then
      echo "::error::analytics-hook self-check failed: $label — expected $expect, got $got (input: $input)" >&2
      unset ANALYTICS_PATTERN
      return 1
    fi
  done <<EOF
no-match	scrollbar inside word	let scrollbar = view.scrollerStyle
no-match	enrollbar inside word	signupEnrollbar()
no-match	rollback comment	// rollback complete
match	bare rollbar lowercase	import rollbar
match	bare Rollbar capitalized	import Rollbar
match	rollbar.com URL	https://rollbar.com/api
match	segment/analytics	import { segment/analytics } from 'foo'
match	Sentry capitalized	import Sentry from 'foo'
EOF
  unset ANALYTICS_PATTERN
}

if ! self_check; then
  exit 2
fi

# Grep across Rust + Swift + TS source. -I skips binary files.
# -i is case-insensitive: real analytics SDKs surface in mixed casing
# (`import Rollbar`, `Sentry.init`, `Mixpanel.shared`); the original
# matcher missed all of those. -P enables PCRE so the `\b` boundaries
# in $pattern actually take effect (POSIX ERE doesn't support `\b`).
if git grep -iIP -- "$pattern" -- '*.rs' '*.swift' '*.ts' '*.tsx' '*.js' '*.toml' 2>/dev/null; then
  echo "::error::Analytics SDK reference detected — see docs/adr/0001-no-telemetry.md"
  exit 1
fi

echo "check-no-analytics: clean"
