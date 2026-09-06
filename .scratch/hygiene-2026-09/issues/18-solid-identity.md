# 18 — SolidTerm stands on its own: identity, agents, vault cut, compat shims

Status: ready-for-agent
Blocked by: 03, 04, 05
Spec: ../spec.md (D13)

## Why

After 03/04/05 the repo still describes itself as "NextTerm minus Claude" (41 files:
identity prose, About panel, copyright string, six agent definitions, fixture prose,
two compat shims) and points at a design vault that no longer exists (`~/Vaults/NextTerm`
was removed 2026-09-06; the `.gitignore` symlink target `~/Vaults/SolidTerm` never
existed). Target state: the word NextTerm survives only in git history, in the bytes of
`tests/fixtures/osc-sequences/*.bin`, and in `.scratch/`.

Runs immediately after 05 (before 06) so the rewritten agents are the ones that serve the
split work, and so `CHANGELOG.md` is touched once per concern (05 writes `[0.4.12]` +
`[Unreleased]`, this ticket rewrites `[0.1.0]`).

## Commit 1 — identity: docs, CHANGELOG, app strings

- `CLAUDE.md:3` → "A native macOS terminal emulator. Minimal, fast, solid. Terminal only."
  §"What's IN this fork" → "What's in SolidTerm". §"What's NOT in this fork" → "Out of
  scope", phrased as scope, list kept: no AI-agent integration or stream parsers, no block
  model, no auth / credential storage, no hook runner, no agent-team orchestration, no
  sidebar / HUD, no Kitty graphics protocol, no block overlay / diff viewer / permission
  modal. Keep the closing rule as "If an AI-integration feature comes up: out of scope for
  SolidTerm." No "fork" / "stripped" wording anywhere in the file.
- `AGENTS.md:3` → one positive line. `:7` "This fork's value…" → "SolidTerm's value is its
  small surface area. Don't add AI-agent integration, block models, hooks, or rate-limit
  UI." `:36` "Pitfalls (carried over from NextTerm)" → "Pitfalls". `:39` keep the lesson,
  drop the version lineage ("an early emoji UV bug hid for four releases because…").
- `README.md`: delete §Origin. Add §"Built on": alacritty_terminal (PTY / VT engine),
  swift-bridge (FFI), CoreText + Apple Color Emoji (shaping). §License → "GPL-3.0-or-later — see `LICENSE`" (the file itself is added by ticket 20 in this
  branch; the branch merges as a whole).
- `CHANGELOG.md` `[0.1.0]`: header → `## [0.1.0] — 2026-05-17 — initial release`; intro →
  "First SolidTerm build: a native macOS terminal on alacritty_terminal + Metal."; keep
  "What works" (reword "fixed UV 2x scaling bug inherited from NextTerm" → "fixed emoji UV
  2× scaling"); delete "What's stripped (vs NextTerm base)"; Stats drop "(was 7)" and
  "(was ~98)".
- `app/SolidTerm/AppDelegate.swift:267`: drop the "Forked from NextTerm — …" line; credits =
  description + "Built on alacritty_terminal + swift-bridge."
- `app/project.yml:93` copyright → "Copyright © 2026 Zen Kiattikhunnawong." then
  `cd app && xcodegen generate`. Verified 2026-09-06 that pbxproj is byte-identical to a
  fresh generate, so the diff must be exactly the two copyright lines.
- `crates/solidterm-engine/src/engine.rs:2429` "NextTerm's Thai user" → "SolidTerm's Thai
  user"; `:3155-3236` OSC 2 title-test string "NextTerm" → "SolidTerm" (doc comment, input
  bytes, expected value, assertion message).
- `tests/fixtures/osc-sequences/README.md:3` `nextterm-engine` → `solidterm-engine`;
  `fish-default.meta.json:9`, `zsh-macos-default.meta.json:20` prose → SolidTerm.
  Do NOT edit `*.bin`: they are redacted captures and the `/Users/USER/Projects/nextterm`
  path inside is the capture cwd, not identity.

## Commit 2 — agents

- Delete `.claude/agents/spec-keeper.md` (its remit was the vault; `/domain-modeling`
  owns `docs/adr/` now).
- Rewrite the other five against the current tree. Every file drops: vault paths,
  `~/Projects/nextterm/`, `NextTermApp.swift`, `NextTermTests/`, `NEXTTERM_E2E`, the
  nine-crate table, `nextterm-blocks/claude/auth/hooks/config/mcp`, coverage targets on
  crates that don't exist. Frontmatter `description:` must not say NextTerm (it is what the
  Agent tool shows).
  - `rust-expert`: remit = `crates/solidterm-engine` (alacritty_terminal wrapper + OSC
    routing) and `crates/solidterm-ffi` (swift-bridge, data-only). Rules kept: `unsafe`
    needs a SAFETY comment, no Metal types in Rust, an FFI signature change updates
    `bridge.rs` and the Swift decoder in the same change.
  - `swift-metal-expert`: remit = `app/SolidTerm/` (35 sources; derive the tree with
    `ls app/SolidTerm`). Build / test commands use scheme `SolidTerm`. CoreText / IME /
    Metal pitfalls kept.
  - `test-writer`: tiers unchanged; Swift tests live in `app/SolidTermTests/` (40 files);
    fixtures `font-corpus/`, `vttest/`, `osc-sequences/` (note: no test reads
    osc-sequences today); coverage targets only for `solidterm-engine`.
  - `code-reviewer`, `security-reviewer`: "read the spec first" → read `CONTEXT.md` and
    `docs/adr/` when present (per `docs/agents/domain.md`). Threat surface = ticket 04's
    `docs/SECURITY.md` list: OSC 7 / 8 / 52 / 133 injection, PTY + shell integration,
    clipboard writes, theme / keybinding file parsing.

## Commit 3 — vault cut, ADRs, license pointers

- Live-location pointers (21 lines): reword or delete every `vault/…`,
  `/Users/zen/Vaults/…`, "(vault)" mention — `deny.toml:3,6,42`,
  `scripts/check-no-analytics.sh:3,81`, `scripts/check-license-headers.sh:5`,
  `scripts/check-ai-authored-tests.sh:3`, `scripts/bench-gate.sh:3`,
  `scripts/perf-smoke.sh:3,66`, `scripts/capture-osc.sh:11`, `.github/workflows/ci.yml:6`,
  `.github/CODEOWNERS:3`, `.github/pull_request_template.md:22`,
  `.github/ISSUE_TEMPLATE/decision_proposal.md` (2 lines → point at `docs/adr/`),
  `docs/release-runbook.md:3,67,102-104`, `docs/SECURITY.md:51`, `CONTRIBUTING.md:60,78` (lines 3, 9, 50, 67 are rewritten by ticket 04),
  `app/SolidTerm/InputEventEncoding.swift:32`, `.gitignore:37-38` (delete both lines).
- `docs/agents/domain.md` §Project note → "Design decisions live in `docs/adr/`. Older
  code comments cite `spec/…`, `decisions/…`, `research/…` sections of a retired pre-1.0
  design archive; code and tests are authoritative (ticket 19 retires those citations)."
- `CLAUDE.md`: add one paragraph under Architecture with the same sentence.
- New ADRs (`docs/adr/`, format per `docs/agents/domain.md`, Status: accepted), written
  from what the repo enforces — nothing is ported from the vault:
  - `0001-no-telemetry.md` — zero outbound analytics or crash upload; enforced by
    `scripts/check-no-analytics.sh` in CI; the PR template asks for an ADR update on any
    new endpoint.
  - `0002-distribution-direct-dmg.md` — releases are ad-hoc-signed DMGs from
    `scripts/build-release-dmg.sh`, tag-driven (D6); notarization / Sparkle / Homebrew
    cask are target state described in `docs/release-runbook.md`, not implemented.
  - `0003-cross-cell-shaping-swift-side.md` — CoreText is the only grapheme-cluster
    authority, so cross-cell shaping (Thai SARA AM, regional-indicator pairs, ZWJ
    spillover) is a Swift-side post-FFI coalescer emitting `cellSpan`; default on;
    `SOLIDTERM_SHAPING=0` for diagnosis. Sources: `GraphemeClusterCoalescer.swift` header,
    `GraphemeClusterCoalescerTests`, `GlyphAtlasTests` §cellSpan.
- `ADR-19` → `ADR-0003` (17 citations): `MetalRenderer.swift:421,426,1874,2179`,
  `GlyphAtlas.swift:54,559,632,681,719,747,782`, `GridPipeline.swift:68,442`,
  `Shaders.metal:154`, `GraphemeClusterCoalescer.swift:7`,
  `GraphemeClusterCoalescerTests.swift:60`, `GlyphAtlasTests.swift:789`. Drop the
  "atomic N" qualifiers. Leave neighbouring `spec/cross-cell-shaping.md` citations for 19.
- License wording (D13h, decided as D15 = GPL-3.0-or-later): `CONTRIBUTING.md:78` →
  "SolidTerm is licensed under GPL-3.0-or-later (see `LICENSE`). Contributions are accepted
  under the same license, and by contributing you grant the maintainer the right to
  relicense your contribution." (no DCO); `deny.toml:6,42` → "Workspace crates are
  GPL-3.0-or-later and not published (`private.ignore`)"; `scripts/check-license-headers.sh:5`
  comment → "SPDX header check — enforced from ticket 20". Do not add `LICENSE`,
  `license =` fields, or headers here — ticket 20 does.

## Commit 4 — behaviour: retire the compat shims

- `app/SolidTerm/MetalRenderer.swift:430-433`: doc comment drops the legacy sentence;
  `return env["SOLIDTERM_SHAPING"] != "0"`.
- `solidterm.zsh:15-16`, `solidterm.bash:20-21`, `solidterm.fish:19-22`: the guard tests
  only `_SOLIDTERM_INTEGRATION_LOADED`; delete the "Legacy _NEXTTERM_ …" comment lines.
- Commit message states this is the branch's single behaviour change and why it is safe:
  no NextTerm install exists, no rc file sources a nextterm integration, and
  `ShellIntegrationInstaller` overwrites `~/.config/solidterm/shell/*` on every install.

## Verify

```
grep -rIil 'nextterm' . --exclude-dir=.git --exclude-dir=target --exclude-dir=dist --exclude-dir=.scratch
#   expected: exactly the six tests/fixtures/osc-sequences/*.bin
grep -rIEn 'vault/|Vaults/|\(vault\)|ADR-19|NEXTTERM' . --exclude-dir=.git --exclude-dir=target --exclude-dir=dist --exclude-dir=.scratch
#   expected: no output
ls docs/adr                                   # 0001 0002 0003
cd app && xcodegen generate && git diff --stat SolidTerm.xcodeproj    # 2 lines changed
cargo test --workspace && (cd app && xcodebuild test -scheme SolidTerm -destination 'platform=macOS')
scripts/check-no-analytics.sh && scripts/check-license-headers.sh && scripts/check-ai-authored-tests.sh
# manual (Release build): SolidTerm ▸ About shows the new credits; typing `ทำ` still
# renders as one cluster (shaping default ON with the fallback gone).
```

## Comments
