# OSC sequence captures

Real byte streams emitted by shells + TUIs running on macOS. Used by `solidterm-engine`'s OSC router integration tests.

**Not committed yet** — captures need to be made on a real machine. Run the capture script and commit results.

## How to capture

```bash
# 1. Capture a session
./scripts/capture-osc.sh zsh-macos-default          # logs `script -q` output
./scripts/capture-osc.sh zsh-zenzai-integration     # zenzai's OSC 133 stream
./scripts/capture-osc.sh bash-preexec
./scripts/capture-osc.sh fish-3.7
./scripts/capture-osc.sh claude-code-exit
./scripts/capture-osc.sh neovim-startup
./scripts/capture-osc.sh tmux-passthrough

# 2. Verify (no real secrets, no real hostnames)
./scripts/verify-osc-capture.sh tests/fixtures/osc-sequences/zsh-macos-default.bin

# 3. Commit the .bin + .meta.json pair
git add tests/fixtures/osc-sequences/zsh-macos-default.{bin,meta.json}
git commit -m "test(fixtures): capture zsh OSC sequence on macOS 14.7"
```

## Expected captures (priority order)

| File | Why |
|---|---|
| `zsh-macos-default.bin` | baseline — zsh on macOS without integrations |
| `zsh-zenzai-integration.bin` | OSC 133 A/B/C/D + OSC 7 cwd from user's existing zenzai config |
| `claude-code-exit.bin` | `claude -p "hi"` complete byte stream — shows Kitty kbd pop, focus disable, modifyOtherKeys reset, OSC 9;4;0;BEL (iTerm progress reset), OSC 0 (title reset) |
| `neovim-startup.bin` | nvim launches → CSI u + focus reporting + alt-screen entry |
| `tmux-passthrough.bin` | OSC inside tmux (passthrough — `set -ag terminal-overrides ',xterm*:Tc'`) |
| `bash-preexec.bin` | bash with `bash-preexec` library (manual install) |
| `fish-3.7.bin` | fish native event handlers |

Each `.bin` carries a `.meta.json` siblings:

```json
{
  "captured_at": "2026-04-25T16:30:00+07:00",
  "macos_version": "14.7.1",
  "shell": "zsh 5.9 (arm64-apple-darwin23.6.0)",
  "claude_code_version": "2.1.119",
  "tmux_version": "3.5a",
  "neovim_version": "0.10.4",
  "redacted": false,
  "notes": "captured via script -q with TERM=xterm-256color; no PROMPT/ALIAS env"
}
```

## Test shape

```rust
let bin = include_bytes!("../tests/fixtures/osc-sequences/zsh-zenzai-integration.bin");
let mut engine = TerminalEngine::new(default_config())?;
engine.feed_input(bin);
let events = engine.take_osc_events();

assert!(events.iter().any(|e| matches!(e, OscEvent::PromptStart)));
assert!(events.iter().any(|e| matches!(e, OscEvent::Cwd(_))));
assert_no_parser_errors(&engine);
```

Privacy: captures are reviewed for hostnames + paths-with-usernames before commit. Redaction script: `scripts/redact-osc.sh`.
