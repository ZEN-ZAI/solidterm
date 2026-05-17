# Security disclosure policy

NextTerm is a native macOS terminal that handles shell sessions, Claude Code interactions, and credentials in flight. Security reports are taken seriously; this document tells you how to disclose responsibly.

## Reporting a vulnerability

**Do not file a public GitHub issue for security vulnerabilities.**

Email the maintainer directly: `zen.kiattikhunnawong@gmail.com` with subject `[NextTerm SECURITY]` followed by a one-line summary.

Include in the report:
- Affected NextTerm version (output of `defaults read /Applications/NextTerm.app/Contents/Info.plist CFBundleShortVersionString`)
- macOS version
- Vulnerability class (e.g. credential exposure, sandbox escape, code-injection via OSC sequence)
- Reproduction steps + observed behavior + expected behavior
- Proof-of-concept payload if applicable (avoid testing against systems you don't own)
- Suggested fix if you have one (optional)

You'll receive an acknowledgment within 72 hours. Coordinated disclosure timeline is negotiated case-by-case based on severity + complexity of fix.

## Scope

In-scope vulnerability classes:

- **Credential exposure** — secrets in environment variables, Keychain entries, or session files leaking to logs / unauthenticated processes / other panes
- **Code injection** — OSC / DCS / CSI sequences that escape parsing into shell-executable code
- **Sandbox escape** — JavaScript-style runtime escapes from the SwiftUI host into arbitrary process exec
- **Data integrity** — terminal output rewriting, scrollback poisoning, permission-prompt spoofing
- **Hook abuse** — `.claude/settings.json` hook scripts running with privileges they shouldn't have
- **FFI memory safety** — bridge.rs `unsafe` blocks (deliberately scoped per `feedback_directive_precision_flagging_not_authorizing`'s wider `unsafe_code = "warn"` policy)

Out-of-scope (NextTerm doesn't own these):
- macOS itself, Apple Silicon firmware, Metal driver
- `alacritty_terminal` upstream parser (report to alacritty/alacritty)
- `swift-bridge` (report to chinedufn/swift-bridge)
- The `claude` CLI itself (report to Anthropic)
- Third-party shells / TUIs the user happens to run inside NextTerm

## Beta-release security posture

Phase 1 / Phase 2 beta builds are **unsigned** (no Apple Developer ID, no notarization). This is a deliberate beta-only choice; the 1.0 release will:
- Apple Developer ID Application certificate
- Notarized via `notarytool`
- Hardened runtime re-enabled
- Sparkle appcast for signed auto-updates

Until then: only run NextTerm beta builds on a Mac you control + only install DMGs delivered by the maintainer or downloaded over HTTPS from a URL the maintainer provided.

## What NextTerm does NOT do (zero-telemetry)

Per `decisions/03-telemetry.md`:
- No analytics SDKs (Mixpanel, Sentry, Rollbar, etc.)
- No usage tracking, crash uploads, anonymous metrics, or UUIDs
- No outbound network calls except those the user initiates (e.g. running `claude` which talks to Anthropic, or `curl` in their shell)
- The CI gate `scripts/check-no-analytics.sh` enforces this on every commit

Found a network call you can't account for? That's a security report — please send one.

## Hall of fame

(Empty — your name could go here.)

Acknowledged researchers will be listed by name + handle at their request, after the disclosed vulnerability is fixed in a public release.
