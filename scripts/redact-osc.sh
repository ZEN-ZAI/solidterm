#!/usr/bin/env bash
# Redact secrets from an OSC capture before committing.
# Phase 0 stub — full implementation lands when we have actual captures.
set -euo pipefail
echo "redact-osc: skipped (stub — implement when first .bin captures land)"
echo "manual review steps:"
echo "  1. xxd tests/fixtures/osc-sequences/<file>.bin | less   # eyeball"
echo "  2. grep -aE '(api_key|sk-ant|/Users/[a-z]+|hostname=)' tests/fixtures/osc-sequences/<file>.bin"
echo "  3. if matches: rebuild capture in a clean environment OR rewrite manually"
exit 0
