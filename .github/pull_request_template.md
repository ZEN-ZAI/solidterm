<!--
PR template for SolidTerm.
Keep it short; most fields are optional for trivial PRs.
Drop sections that don't apply.
-->

## What changed

<!-- One paragraph. The "what" is for skim-reading; the "why" matters more. -->

## Why

<!-- Link to the vault decision, issue, or spec that motivated this.
     If this is a first-of-its-kind change, propose a decision (see CONTRIBUTING.md). -->

## Risk + scope

<!--
- Blast radius: which crates / modules / screens
- Stop-the-line checks:
  - [ ] No `unsafe` without `// SAFETY:` comment
  - [ ] No new outbound network endpoint (or decisions/03-telemetry.md updated)
  - [ ] No perf regression >5% (or explicit // PERF-REGRESSION: comment)
  - [ ] No new dep introduced (or justified below)
  - [ ] No copy of code from codeaashu/claude-code leaked source
-->

## Tests

<!--
- Which tests cover this change?
- Any test type deliberately skipped? Why?
- Manual verification steps (for UI changes — type-checks don't prove correctness)
-->

## Alternatives considered

<!-- Optional. Helpful for non-trivial design choices. -->

## Spec / decision updates

<!-- If this changes spec-defined behavior, the spec update is in this same PR.
     List the vault files touched. -->

---

<!-- AI-authored PRs: include this note verbatim so reviewers know the provenance -->
<!-- AI-authored: yes — drafted by Claude Code, reviewed by @ZEN-ZAI -->
