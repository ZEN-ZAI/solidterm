#!/usr/bin/env bash
# Regenerate app/SolidTerm.xcodeproj from app/project.yml using XcodeGen.
# Run this whenever you edit app/project.yml; commit the regenerated
# .xcodeproj alongside the YAML change so a fresh clone builds out of the box.

set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
    cat >&2 <<'EOF'
error: xcodegen not found.

Install it with:

    brew install xcodegen

Or via mint, nix, or a precompiled binary from
https://github.com/yonaskolb/XcodeGen/releases.
EOF
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

xcodegen generate --spec app/project.yml --project app
