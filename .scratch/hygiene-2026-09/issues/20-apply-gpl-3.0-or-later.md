# 20 — Apply GPL-3.0-or-later: LICENSE, SPDX headers, notices, About

Status: ready-for-agent
Blocked by: 18, 19
Spec: ../spec.md (D15); decision record: ../../choose-license/spec.md

## Why

Decided 2026-09-06 (license grilling): SolidTerm is open source under GPL-3.0-or-later for
the whole repo. The GitHub repo is already public with no `LICENSE`, so today nobody has
the right to use, modify or redistribute it. Runs after 19 so headers land on the final
file layout, and after 18 so the license wording written there (`CONTRIBUTING.md:78`,
`deny.toml`, `check-license-headers.sh` comment) is completed, not rewritten.

## Commit 1 — LICENSE, manifests, docs, ADR

- `LICENSE`: verbatim GPL-3.0 text from <https://www.gnu.org/licenses/gpl-3.0.txt>.
- Root `Cargo.toml` `[workspace.package]`: add `license = "GPL-3.0-or-later"`; both crates
  already inherit via `*.workspace = true` — add `license.workspace = true` to each.
  `publish = false` stays.
- `deny.toml`: `[licenses] private.ignore = true` stays (workspace crates are not
  published); comment text was finalised by 18.
- `README.md` §License: "GPL-3.0-or-later — see `LICENSE`. Third-party components are
  listed in `THIRD_PARTY_NOTICES.md`."
- `CONTRIBUTING.md` §License (wording finalised by 18; verify it reads): inbound
  contributions are GPL-3.0-or-later; contributors grant the maintainer the right to
  relicense; no DCO / sign-off required.
- `docs/adr/000N-license-gpl-3.0-or-later.md` (next free number after 18/19's ADRs,
  Status: accepted): context (public repo, permissive deps, "anyone may use and modify,
  nobody may take it proprietary"), decision (GPL-3.0-or-later, whole repo, relicense
  clause kept, no DCO), consequences (Apache-2.0 deps compatible with GPLv3 but not GPLv2;
  `solidterm-engine` / `solidterm-ffi` reusable by others only under GPL; Mac App Store
  redistribution by third parties effectively excluded; notices must ship with binaries).
- `app/project.yml`: no license key exists in Info.plist conventions — nothing to add.

## Commit 2 — SPDX headers + lint

- Header, first two lines of every tracked source file (after a `#!` shebang where one
  exists):
  ```
  // SPDX-License-Identifier: GPL-3.0-or-later
  // Copyright © 2026 Zen Kiattikhunnawong
  ```
  (`#` comment marker for `.sh` / `.zsh` / `.bash` / `.fish`). Files: 82 `.swift`
  (`app/SolidTerm`, `app/SolidTermTests`, excluding `app/SolidTerm/Generated/`), 21
  `.rs`, 1 `.metal`, 17 shell files under `scripts/`, `app/scripts/`,
  `app/SolidTerm/Resources/Shell/`. Rust files that open with `//!` keep the doc comment
  after the header (a plain `//` comment before `//!` is legal).
- Apply with a one-off script (not committed) and check `swift-format lint` still passes
  (`NoBlockComments` / `OrderedImports` are unaffected by leading line comments).
- `scripts/check-license-headers.sh`: replace the stub — `git ls-files` over the extensions
  above minus `app/SolidTerm/Generated/`, require `SPDX-License-Identifier:
  GPL-3.0-or-later` within the first 3 lines, print every offender, exit 1 on any. It is
  already called by the `custom-lints` CI job.
- Theme TOMLs (20): first line becomes an attribution comment, e.g.
  `# Palette: Catppuccin Mocha — MIT, https://github.com/catppuccin/catppuccin`. Verify
  each palette's origin before writing it; palettes designed for SolidTerm (`dark`,
  `dark-green`, `dusty-mauve`, `light`, `matcha`, `sakura-night`, `soft-navy`,
  `warm-cream` are the candidates) say `# Palette: SolidTerm original`. Known upstreams:
  ayu, catppuccin, dracula, everforest, gruvbox, kanagawa, moonlight, nord, one-dark,
  rosepine, solarized, tokyo-night — all MIT.

## Commit 3 — third-party notices, bundle, About

- `scripts/gen-third-party-notices.sh`: writes `THIRD_PARTY_NOTICES.md` from
  `cargo tree -e normal -p solidterm-ffi --prefix none --format '{p}|{l}' | sort -u`
  (only crates linked into the binary; dev-deps such as criterion excluded), appending
  each crate's `LICENSE*` text from `~/.cargo/registry/src/*/<name>-<version>/`; then a
  section for swift-bridge's generated Swift runtime (`app/SolidTerm/Generated/`,
  MIT OR Apache-2.0) and one for the theme palettes (name, upstream URL, MIT).
  `alacritty_terminal` ships `LICENSE-APACHE` only (no NOTICE) — the Apache text once,
  attributed to every Apache-licensed crate.
- Commit the generated `THIRD_PARTY_NOTICES.md` at the repo root.
- CI (`custom-lints` job): run the generator to a temp path and `diff` against the
  committed file; fail if stale. Needs the Rust toolchain in that job — move the check to
  the `rust-test` job if `custom-lints` stays toolchain-free.
- `app/project.yml`: add `THIRD_PARTY_NOTICES.md` and `LICENSE` to the app target's
  resources (`type: file`, `buildPhase: resources`); regenerate the project.
- `AppDelegate.showAboutPanel`: append an "Acknowledgements" line to the credits
  attributed string with a `.link` attribute pointing at the bundled
  `THIRD_PARTY_NOTICES.md` (`Bundle.main.url(forResource:withExtension:)`); the About
  panel opens links via `NSWorkspace`. Keep 18's credits text.

## Verify

```
head -2 LICENSE                                   # "GNU GENERAL PUBLIC LICENSE" / "Version 3, 29 June 2007"
scripts/check-license-headers.sh                  # exit 0, no offenders
scripts/gen-third-party-notices.sh /tmp/n.md && diff -q /tmp/n.md THIRD_PARTY_NOTICES.md
cargo metadata --format-version 1 | jq -r '.packages[] | select(.name|startswith("solidterm")) | "\(.name) \(.license)"'   # both GPL-3.0-or-later
cd app && xcodegen generate && xcodebuild build -scheme SolidTerm -destination 'platform=macOS' \
  && ls "$(xcodebuild -showBuildSettings -scheme SolidTerm 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $3}')/SolidTerm.app/Contents/Resources/" | grep -E 'LICENSE|THIRD_PARTY'
xcrun swift-format lint --strict --configuration .swift-format --recursive SolidTerm SolidTermTests | grep -v Generated | wc -l   # 0
cargo test --workspace && xcodebuild test -scheme SolidTerm -destination 'platform=macOS'
```

## Comments
