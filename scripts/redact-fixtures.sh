#!/usr/bin/env bash
# Redact secrets from stream-JSON capture(s) before committing.
# Phase 0 stub — full implementation lands when we capture from real Claude sessions.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <path-to-jsonl>"
  exit 1
fi

f="$1"
echo "redact-fixtures: skipped on $f (stub — implement when first stream-json capture lands)"
echo "planned redactions:"
echo "  • sk-ant-[A-Za-z0-9_-]+              → sk-ant-REDACTED"
echo "  • /Users/<name>/...                  → /Users/USER/..."
echo "  • <real-hostname>                    → host.example.com"
echo "  • session UUIDs                      → aaaaaaaa-... / bbbbbbbb-... etc."
echo "  • total_cost_usd                     → 0.001"
echo
echo "Manual review until then: less + eyeball."
exit 0
