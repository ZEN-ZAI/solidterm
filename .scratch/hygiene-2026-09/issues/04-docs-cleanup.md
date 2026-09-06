# 04 — Docs describe SolidTerm, not NextTerm

Status: ready-for-agent
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
