# Stream-JSON fixtures

Recorded (or hand-crafted) Claude Code session traces, one event per line.

Used by `nextterm-claude::parser` integration tests as deterministic inputs — no `claude` subprocess needed in CI.

## Provenance

| File | Source | Notes |
|---|---|---|
| `hello-text-only.jsonl` | hand-crafted from spec | minimal session |
| `tool-use-bash.jsonl` | hand-crafted from spec | one Bash tool round-trip |
| `tool-use-edit.jsonl` | hand-crafted from spec | Edit tool → ClaudeDiff transform |
| `permission-prompt-allow.jsonl` | hand-crafted from spec | permission flow |
| `rate-limit-warning.jsonl` | hand-crafted from spec | mid-session rate_limit_event |

Real captures (when added) go through `scripts/redact-fixtures.sh` to scrub:
- API keys (`sk-ant-…`)
- Hostnames + paths containing usernames
- Session IDs (replaced with stable `aaaaaaaa-…` placeholders)
- Cost figures (set to `0.001`)

## Schema reference

See `vault/raw/cc-docs-a-cli-sdk.md` (event taxonomy) and `vault/raw/claude-code-ui-reference.md` (event schemas) for the canonical structures these fixtures conform to.

## Refresh

When Anthropic updates the stream-JSON schema:
1. Re-capture a representative session (`scripts/capture-stream-json.sh`)
2. Run redaction
3. Snapshot-diff against the prior fixture
4. Document the diff in `CHANGELOG.md` under `[Unreleased]`
5. Update affected parser tests
