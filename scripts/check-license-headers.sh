#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Zen Kiattikhunnawong

# Verify the SPDX license header on every tracked source file (ADR-0007).
#
# CI invocation: .github/workflows/ci.yml `custom-lints` job.
#
# Every .swift / .rs / .metal / shell file must open with
#   SPDX-License-Identifier: GPL-3.0-or-later
# within its first three lines — three, not one, because a `#!` shebang comes
# first where one exists and the marker is the second or third line there.
# app/SolidTerm/Generated/ is excluded: build-rust.sh rewrites those
# swift-bridge shims on every build, so a header would not survive.
# Theme TOMLs carry a palette attribution comment instead of an SPDX header.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

offenders=()
while IFS= read -r file; do
    case "$file" in app/SolidTerm/Generated/*) continue ;; esac
    [ -f "$file" ] || continue
    if ! head -3 "$file" | grep -q 'SPDX-License-Identifier: GPL-3.0-or-later'; then
        offenders+=("$file")
    fi
done < <(git ls-files '*.swift' '*.rs' '*.metal' '*.sh' '*.zsh' '*.bash' '*.fish')

if [ ${#offenders[@]} -ne 0 ]; then
    echo "::error:: missing SPDX header (see docs/adr/0007-license-gpl-3.0-or-later.md):"
    printf '  %s\n' "${offenders[@]}"
    echo ""
    echo "Add these two lines at the top of each file (after a #! shebang),"
    echo "with # as the comment marker in shell files:"
    echo "  // SPDX-License-Identifier: GPL-3.0-or-later"
    echo "  // Copyright © 2026 Zen Kiattikhunnawong"
    exit 1
fi

echo "check-license-headers: OK"
