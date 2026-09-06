# Security disclosure policy

SolidTerm is a native macOS terminal: it spawns shells on a PTY, parses whatever bytes they emit, and writes to the system clipboard on their behalf. Security reports are taken seriously; this document tells you how to disclose responsibly.

## Reporting a vulnerability

**Do not file a public GitHub issue for security vulnerabilities.**

Email the maintainer directly: `zen.kiattikhunnawong@gmail.com` with subject `[SolidTerm SECURITY]` followed by a one-line summary.

Include in the report:
- Affected SolidTerm version (output of `defaults read /Applications/SolidTerm.app/Contents/Info.plist CFBundleShortVersionString`)
- macOS version
- Vulnerability class (e.g. code injection via an OSC sequence, clipboard write the user never asked for)
- Reproduction steps + observed behavior + expected behavior
- Proof-of-concept payload if applicable (avoid testing against systems you don't own)
- Suggested fix if you have one (optional)

You'll receive an acknowledgment within 72 hours. Coordinated disclosure timeline is negotiated case-by-case based on severity + complexity of fix.

## Scope

In-scope vulnerability classes:

- **OSC injection** — OSC 7 (cwd), OSC 8 (hyperlinks), OSC 52 (clipboard) or OSC 133 (prompt markers) escaping the parser into shell-executable code, or forging state the user is asked to trust
- **PTY / shell integration** — the shell-integration snippets (`solidterm.zsh` / `.bash` / `.fish`) or the PTY spawn path letting untrusted output run commands, alter the environment, or survive the session
- **Clipboard writes** — remote or scrollback content writing the system pasteboard without user intent (OSC 52 is the obvious vector; selection sync is the subtle one)
- **Theme / keybinding file parsing** — a malicious TOML theme or keybinding file causing anything worse than a parse error

Out-of-scope (SolidTerm doesn't own these):
- macOS itself, Apple Silicon firmware, Metal driver
- `alacritty_terminal` upstream parser (report to alacritty/alacritty)
- `swift-bridge` (report to chinedufn/swift-bridge)
- Third-party shells / TUIs the user happens to run inside SolidTerm

## Beta-release security posture

Phase 1 / Phase 2 beta builds are **unsigned** (no Apple Developer ID, no notarization). This is a deliberate beta-only choice; the 1.0 release will:
- Apple Developer ID Application certificate
- Notarized via `notarytool`
- Hardened runtime re-enabled
- Sparkle appcast for signed auto-updates

Until then: only run SolidTerm beta builds on a Mac you control + only install DMGs delivered by the maintainer or downloaded over HTTPS from a URL the maintainer provided.

## What SolidTerm does NOT do (zero-telemetry)

Per `docs/adr/0001-no-telemetry.md`:
- No analytics SDKs (Mixpanel, Sentry, Rollbar, etc.)
- No usage tracking, crash uploads, anonymous metrics, or UUIDs
- No outbound network calls except those the user initiates from their own shell (e.g. `curl`)
- The CI gate `scripts/check-no-analytics.sh` enforces this on every commit

Found a network call you can't account for? That's a security report — please send one.

## Hall of fame

(Empty — your name could go here.)

Acknowledged researchers will be listed by name + handle at their request, after the disclosed vulnerability is fixed in a public release.
