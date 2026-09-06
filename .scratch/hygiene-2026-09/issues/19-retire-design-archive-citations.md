# 19 — Retire `spec/…`, `decisions/…`, `research/…` citations in code comments

Status: done — 2026-09-06
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

### 2026-09-06

Landed in five commits, one per area, docs first so the ADRs exist in
history before code points at them:

- `e207efd docs: give three durable rules an ADR home`
- `fc7cfd2 docs(app): replace archive citations with what they carried`
- `88d28b4 test(app): replace archive citations in the Swift tests`
- `0455229 refactor(engine): replace archive citations in the Rust crates`
- the commit carrying this note — the stragglers plus the review fixes

Three rules cited from code had no home outside the retired archive, so
they got one before the citations went: ADR-0004 (design tokens in
Swift), ADR-0005 (keybinding grammar), ADR-0006 (the FFI wire ABI).
Everything else was carried in place — the section title, the value, the
constraint the citation stood for.

Judgement calls:

- The `## Verify` grep is too narrow twice over. `spec/[a-z-]+\.md` cannot
  match the digit in `spec/m1-task-breakdown.md`, and the path list omits
  `.githooks/`, `tests/fixtures/` and extensionless forms (`spec/m7`,
  `spec §Throughput`). Eleven files were only found by widening it. The
  ticket's grep is left as written and now returns nothing; the wider
  sweep `git grep -InE 'spec/|decisions/|research/'` also returns nothing
  outside `.scratch/` and `Cargo.lock`.
- Five citations carried a rationale not recoverable from the code or the
  tests. Those end in `(design archive)` per the rule rather than getting
  an invented reason, and `CLAUDE.md` now says what that marker means.
- Four "the spec" mentions in `osc.rs` and `vttest_corpus.rs` mean ECMA-48
  / the DEC VT documents, not the archive. Left alone.
- Two citations quoted a hex that had drifted from the constant beside it
  (`selection-bg`, `cursor-default`). The replacement names the token and
  lets the code hold the value rather than repeating a stale number.
- Non-comment text changed in five places, all of them a citation inside a
  string a person reads: the `ScrollbackTooLarge` error in `config.rs`, a
  pre-commit hook error line, two XCTest failure messages, and six budget
  lines in `perf-smoke.sh`. No test asserts on any of them.
- `bridge.rs:8` still carries wording the identity tickets own. Untouched
  here.
- Several `ThemeTokenTests` doc-comments quote palette hexes that have
  drifted, on lines that carry no citation. Out of scope; not touched.

Gates before every commit: `cargo test --workspace -j 8` → 273 passed;
`xcodebuild test -scheme SolidTerm -destination 'platform=macOS'` →
Executed 482 tests, 3 skipped, 0 failures. `cargo fmt --check`, `cargo
clippy -D warnings`, `check-ffi-drift.sh` and `check-no-analytics.sh` all
clean. `selection_text_rejoins_reflowed_lines` flaked once under load
during the Rust crates commit and passed alone and on rerun; no test was
changed to get green.
