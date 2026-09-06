# 04 — Docs describe SolidTerm, not NextTerm

Status: done — 2026-09-06
Blocked by: 01
Spec: ../spec.md (D5)

## Delete

- `docs/BETA.md` (no external testers)
- `.github/ISSUE_TEMPLATE/beta_feedback.md`
- `docs/prompts/` (session kickoff prompt from June)
- `tests/fixtures/claude-md/`, `tests/fixtures/stream-json/`, `tests/fixtures/settings/` (unreferenced); update `tests/fixtures/README.md` if it lists them.

## Rewrite / edit

- `docs/SECURITY.md`: keep the disclosure policy (email, 72 h ack, coordinated disclosure), drop lines about Claude Code, hooks, credentials; threat classes become: OSC injection (7/8/52/133), PTY/shell integration, clipboard writes, theme/keybinding file parsing.
- `docs/release-runbook.md`: `NEXTTERM_NOTARY` → `SOLIDTERM_NOTARY` (3 lines); `defaults write dev.solidterm.app` → `com.zenzai.SolidTerm`; add a one-line "Status: target state, not yet implemented — current release path is `scripts/build-release-dmg.sh`" under the title.
- `.github/ISSUE_TEMPLATE/bug_report.md:27`: replace the Claude-session line with "If it involves a specific TUI (vim, htop, claude, …), name it and the terminal size."
- `.github/pull_request_template.md:25`: drop the "codeaashu/claude-code leaked source" checkbox. Keep line 48 (AI-authored disclosure).
- `CONTRIBUTING.md`: lines 3, 9, 50, 67 point at the retired design vault (`vault/ROADMAP.md`, `vault/decisions/`, its `_template.md`). Rewrite them: roadmap + issues live in `.scratch/` (per `docs/agents/issue-tracker.md`), architecture decisions in `docs/adr/` (format per `docs/agents/domain.md`); drop the `cp vault/...` step. Lines 60 (`spec/testing-strategy.md`) and 78 (license pointer) stay for ticket 18 (D13c/D13h). No fork / vault wording added anywhere (D13).

## Verify

```
grep -rn -i 'claude\|nextterm' docs README.md CONTRIBUTING.md .github | grep -v 'Forked from\|forked from\|AI-authored\|CLAUDE.md'   # review each remaining hit; 'Forked from' + other identity prose is ticket 18's — leave it
grep -n -i 'vault' CONTRIBUTING.md   # expect no output (lines 60/78 do not say vault)
scripts/check-no-analytics.sh && scripts/check-license-headers.sh && scripts/check-ai-authored-tests.sh
```

## Comments

### 2026-09-06 — landed

One commit: `docs: describe SolidTerm as it is today` (this commit).

Everything in `## Delete` landed: `docs/BETA.md`, `.github/ISSUE_TEMPLATE/beta_feedback.md`,
`docs/prompts/`, and `tests/fixtures/{claude-md,stream-json,settings}` (39 files, confirmed
unreferenced by grep over `*.rs`, `*.swift`, `*.sh`, `*.yml`, `*.toml`, `*.md`).
`tests/fixtures/README.md` lost the three layout lines, the three refresh-table rows and the
`claude_code_version` field of the provenance example. Everything in `## Rewrite / edit` landed
as written; `CONTRIBUTING.md`'s real line numbers were 3, 9, 57 and 74 (ticket 02's reformat
shifted the last two by +7), so the edits were matched by content.

Judgement calls:

- The `§Scope` phase list in `CONTRIBUTING.md` (Phase 0 "now": scaffold, Metal spike) was a
  summary of the retired roadmap and three phases behind the tree, so it was removed together
  with its lead-in sentence rather than left dangling under the new `.scratch/` pointer.
- `§Proposing a decision` step 4 now says status `accepted` (the word ticket 18's ADRs carry)
  instead of `decided`.
- Two files outside this ticket's lists were touched because the deletions orphaned them:
  `scripts/build-release-dmg.sh:15` pointed at `docs/BETA.md` (sentence dropped; ticket 05 owns
  that script's real changes and will not collide with a comment line), and
  `scripts/redact-fixtures.sh` — a stub that redacts nothing and existed only for the
  `stream-json/` corpus — was deleted with the corpus it served. `scripts/redact-osc.sh` is the
  live redactor and is untouched.
- Left for ticket 18, deliberately: `tests/fixtures/README.md:3`, the fixture list in
  `.claude/agents/test-writer.md`, the `decisions/03-telemetry.md` citations in
  `docs/SECURITY.md` and the PR template, and the three remaining design-archive pointers in
  `docs/release-runbook.md`. D5 also names stale comments in `ci.yml`, `build-rust.sh` and
  `project.yml`: tickets 01/03 already cleared the first two and `app/project.yml:93` is
  ticket 18's copyright line.

Verify: the first grep leaves two hits, both reviewed and correct — `.github/CODEOWNERS:14`
(covers `.claude/settings.json`, a real tracked file) and `bug_report.md:27` (the replacement
text this ticket dictates). `grep -n -i 'vault' CONTRIBUTING.md` is empty. The three lint
scripts exit 0.

Tallies: `cargo test --workspace` 273 passed / 0 failed; `xcodebuild test` Executed 446 tests,
2 skipped, 0 failures. Also green: `cargo fmt --check`, `clippy` with `-D warnings`,
`scripts/check-ffi-drift.sh`. One intermediate Swift run reported 2 failures whose names were
not captured; the suite then passed twice in a row on this exact tree and
`testPasteConsultsBracketedPasteFlag` passed in isolation, so it is recorded as the documented
under-load flake, not a regression.
