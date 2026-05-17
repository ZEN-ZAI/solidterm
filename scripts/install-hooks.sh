#!/usr/bin/env bash
# One-time setup: point git at our custom hooks directory.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

git config core.hooksPath .githooks
chmod +x .githooks/*

echo "Hooks installed: .githooks/"
echo "Verify with: git config --get core.hooksPath"
echo ""
echo "Optional: install gitleaks for secret-scanning:"
echo "  brew install gitleaks"
