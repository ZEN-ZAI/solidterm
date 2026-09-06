# ADR-0001 — SolidTerm ships zero telemetry

Status: accepted

## Context

A terminal emulator sees everything its user types and everything their
programs print. Any analytics, crash-upload or "anonymous metrics" channel in
such an app is a channel out of the most sensitive process on the machine, and
no aggregation promise makes that channel auditable from the outside. Users
cannot verify a privacy policy; they can verify that a binary opens no sockets.

The alternative — a crash reporter, or an opt-in usage counter — buys faster
triage of field crashes and a rough sense of which features are used. Both are
real, and both were rejected: the triage benefit is small for a single-
maintainer project whose users can attach a crash log to an email, and an
opt-in toggle still requires shipping the SDK, which is the part that has to be
trusted.

## Decision

SolidTerm makes no outbound network request of its own. No analytics SDK, no
usage tracking, no crash upload, no install ping, no anonymous identifier. The
only network traffic from a SolidTerm window is traffic the user's own shell
initiates.

This is enforced mechanically, not by review discipline:

- `scripts/check-no-analytics.sh` greps the tracked Rust, Swift, JavaScript,
  TypeScript and TOML sources for a list of analytics and crash-reporting SDK
  names, word-anchored so substrings don't produce false positives. It runs in
  the `custom-lints` CI job on every pull request and every push to `main`, and
  again in the `.githooks/pre-commit` hook.
- The pull-request template's stop-the-line list asks the author to confirm no
  new outbound network endpoint, or this ADR updated in the same change.
- `docs/SECURITY.md` states the policy publicly and invites a security report
  for any network call a user cannot account for.

Adding a network endpoint is therefore not a code review question. It is an ADR
change plus a lint change, and both are visible in the diff.

## Consequences

- Field crashes arrive as user reports or not at all. `docs/SECURITY.md` tells
  people what to include; the release runbook expects manual triage.
- Feature usage is unknown. Prioritisation runs on maintainer judgement and
  issue reports rather than measurement.
- Future features that inherently need the network (an update checker, a theme
  gallery) do not get a free pass from this ADR. They need their own ADR that
  supersedes or amends this one, and an explicit user-facing opt-in.
- The lint's forbidden list is a denylist over a fixed set of source file
  types, so it will lag a genuinely new SDK and will not see a shell script or
  a workflow file. It catches the realistic accident — a dependency or a
  snippet pulled in without thinking — not a determined author.
