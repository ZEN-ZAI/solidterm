# 19 — Retire `spec/…`, `decisions/…`, `research/…` citations in code comments

Status: ready-for-agent
Blocked by: 13, 14, 15, 16, 18
Spec: ../spec.md (D14)

## Why

After 18 no live pointer to the retired design vault remains, but ~165 comment lines in
~55 files still cite sections of documents that no longer exist
(`spec/design-tokens.md §Surface levels`, `decisions/13 §Locks`, `research/04 §82`).
Counted 2026-09-06: `spec/*.md` 132, `decisions/NN` 24, `research/NN` 15 (`ADR-19` is
handled by 18). Runs after the splits so the edits land in the final file layout.

## Rule

Replace each citation with the information it carried; never just delete it.

- `// Implements spec/metal-renderer.md §Stage 1 Cell Pass` → `// Stage 1 cell pass:
  full-screen quad …` — say what the section said, one clause.
- Value pins in tests (`ThemeTokenTests`, `ThemeModeTests`): `per spec/design-tokens.md
  §"Text levels"` → `design token text-secondary (locked 2026-05)`; hex value and test stay.
- "SPEC DEVIATION (pre-authorized)" notes: keep the deviation explanation, drop the
  citation.
- Unrecoverable from code or tests → `(design archive)`. Never invent a rationale.
- Where code pins a durable rule that deserves a home, write `docs/adr/000N-….md` from
  the code and cite `ADR-000N`. Expected: `0004-design-tokens`,
  `0005-keybinding-grammar`, `0006-ffi-abi-versioning`. Do not exceed what the code pins.

## Files (counts 2026-09-06, pre-split paths)

Theme.swift 29 · ThemeTokenTests 24 · MetalRenderer 10 · TerminalSurfaceView 9 ·
GlyphAtlas 9 · KeybindingStore 6 · Shaders.metal 5 · engine.rs 4 · config.rs 4 ·
IMETests 4 · bridge.rs 3 · events.rs 3 · ThemeModeTests 3 · OverlayPipelineTests 3 ·
GridPipeline 3 · one or two each in ~40 more files (run the grep below).

## Verify

```
grep -rIEn 'spec/[a-z-]+\.md|decisions/[0-9]|research/[0-9]' app crates docs scripts deny.toml CONTRIBUTING.md README.md AGENTS.md CLAUDE.md .github
#   expected: no output
cargo test --workspace && (cd app && xcodebuild test -scheme SolidTerm -destination 'platform=macOS')   # counts unchanged
```

Comment-only. One commit per area (Swift app / Swift tests / Rust / docs + scripts).

## Comments
