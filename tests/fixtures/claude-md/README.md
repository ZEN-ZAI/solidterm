# CLAUDE.md hierarchy fixtures

Verifies `nextterm-claude::context` walks CLAUDE.md discovery correctly per `raw/cc-docs-c-settings-hosted.md` (cwd → `/` → `~/.claude/CLAUDE.md`, with `@imports` resolved).

## Cases

| Dir | What it covers | Expected result |
|---|---|---|
| `simple/` | cwd has CLAUDE.md; user-level CLAUDE.md exists | merged: cwd content + user-level content |
| `nested-project/` | workspace root + subdir override | walked up from `proj/sub/`; both files contribute |
| `imports/` | `@other.md` references with cycles + missing | cycles broken; missing imports logged + skipped |
| `large/` | 100+ line CLAUDE.md to test 200-line truncation in agent memory | full content for context; truncated for agent memory injection |
| `encoding/` | UTF-8 / BOM / CRLF variants | normalized to LF + UTF-8-no-BOM |

Each case has `expected.md` showing the merged result the parser should produce.

## How tests use them

```rust
let context = ClaudeContext::resolve("tests/fixtures/claude-md/nested-project/proj/sub")?;
let actual = context.merged_claude_md();
let expected = fs::read_to_string("tests/fixtures/claude-md/nested-project/expected.md")?;
assert_eq!(actual.trim(), expected.trim());
```
