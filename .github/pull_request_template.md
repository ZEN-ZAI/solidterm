<!--
PR template for SolidTerm.
Keep it short; most fields are optional for trivial PRs.
Drop sections that don't apply.
-->

## What changed

<!-- One paragraph. The "what" is for skim-reading; the "why" matters more. -->

## Why

<!-- Link to the ADR (`docs/adr/`), issue, or ticket that motivated this.
     If this is a first-of-its-kind change, propose a decision (see CONTRIBUTING.md). -->

## Risk + scope

<!--
- Blast radius: which crates / modules / screens
- Stop-the-line checks:
  - [ ] No `unsafe` without `// SAFETY:` comment
  - [ ] No new outbound network endpoint (or docs/adr/0001-no-telemetry.md updated)
  - [ ] No perf regression >5% (or explicit // PERF-REGRESSION: comment)
  - [ ] No new dep introduced (or justified below)
-->

## Tests

<!--
- Which tests cover this change?
- Any test type deliberately skipped? Why?
- Manual verification steps (for UI changes — type-checks don't prove correctness)
-->

## Alternatives considered

<!-- Optional. Helpful for non-trivial design choices. -->

## Decision updates

<!-- If this changes decided behavior, the ADR update is in this same PR.
     List the `docs/adr/` files touched. -->

---

<!-- AI-authored PRs: include this note verbatim so reviewers know the provenance -->
<!-- AI-authored: yes — drafted by Claude Code, reviewed by @ZEN-ZAI -->
