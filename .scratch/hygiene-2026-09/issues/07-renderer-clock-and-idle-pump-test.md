# 07 — Inject a clock into MetalRenderer; test the idle-pump watchdog

Status: done — 2026-09-06
Blocked by: 06
Spec: ../spec.md (D10)

## Steps

1. `MetalRenderer`: add `var now: () -> CFTimeInterval = CACurrentMediaTime` (internal). Replace direct `CACurrentMediaTime()` calls in `pumpIfDisplayLinkStalled` (~1254), `draw` (`lastDisplayLinkTick`, ~1270), bell-flash timing (`bellFlashStartTime`, ~2914) and any other call sites (`grep -n CACurrentMediaTime`). `blinkAlpha`/`easedBlinkAlpha` already take `elapsed`.
2. Promote `pumpIfDisplayLinkStalled()` and `lastDisplayLinkTick` from `private` to `internal`; keep `startIdlePump`/`stopIdlePump` private (timer wiring is not under test, per grilling: closure injection, no fake timer).
3. New `app/SolidTermTests/IdlePumpTests.swift`:
   - headless `MetalRenderer(device:)` + a real `TerminalSession` (pattern from `TerminalSessionLifecycleTests`);
   - `lastDisplayLinkTick = 0`, `now = { 10 }` → `pumpIfDisplayLinkStalled()` → `pendingFullRepaint == true`;
   - healthy link (`now = { lastTick + 0.01 }`) → `pendingFullRepaint` unchanged;
   - no session → no crash, no flag change.
   `pendingFullRepaint` becomes `internal private(set)` if needed.

## Verify

`xcodebuild test -only-testing:SolidTermTests/IdlePumpTests -only-testing:SolidTermTests/DisplayLinkIdlePumpTests` then the full suite.

## Comments

### 2026-09-06 — landed

One commit: `test(app): inject the renderer clock and cover the idle pump`
(this commit).

`MetalRenderer` gained `var now: () -> CFTimeInterval = CACurrentMediaTime`
next to `lastDisplayLinkTick`, and thirteen of the file's fifteen
`CACurrentMediaTime()` calls now read it: the pump's stall check, `draw`'s
tick stamp, both bell-flash sites (`bellFlashStartTime` and both `elapsed`
reads), both scrollbar-fade sites, the cwd proc-poll throttle, the blink
anchor, the keystroke stamp and the `cpuStart`/`cpuEnd` frame-time pair.
`pumpIfDisplayLinkStalled()` and `lastDisplayLinkTick` are internal;
`pendingFullRepaint` is `private(set)`; `startIdlePump` / `stopIdlePump`
stay private. `app/SolidTermTests/IdlePumpTests.swift` is new — three tests
on a headless `MetalRenderer(device:)` with a real engine-backed
`TerminalSession`: a stalled clock drains and flags a full repaint, a
10 ms-old tick is left alone, and a missing session is inert. `project.pbxproj`
is the 4-line `xcodegen generate` delta for the new file; `Generated/` did
not move (the bridge is untouched).

Judgement calls:

- **Two `CACurrentMediaTime()` calls deliberately survive**, against step 1's
  literal "any other call sites": `MetalRenderer.swift:1696` inside
  `addCompletedHandler` and `:3226` in the `recordKeystroke` diagnostic. Both
  are `NSLog`-only values printed beside `MTLDrawable.presentedTime` /
  `cb.gpuEndTime` and `NSEvent.timestamp` — mach-clock values a substituted
  clock would make incomparable, turning a diagnostic into a lie. The first
  also runs on the Metal completion thread, off the main actor, where reading
  a mutable closure property would be a new race that the direct call is not.
  The exception is documented on the property itself.
- **The session is attached through a test seam, not by opening its setter.**
  The ticket needs a real session on a renderer that never had a window, and
  D9's mechanism would say drop `private(set)` from `session`. That would let
  any file in the module clobber the live session; `attachSessionForTesting`
  is narrower and matches the file's own precedent
  (`installFontObserverForTesting`, `fontSizeOverrideForTesting`). Recorded
  as a deviation from D9's letter, taken for its intent.
- **Both negative tests carry a control.** "Unchanged" as written would have
  collapsed into "still at its default" — a renderer that never raises the
  flag would pass. Each negative test now moves one variable (the clock, or
  the session) and asserts the same renderer *does* pump, so the negative
  assertion means the pump declined.
- The timer wiring is untested, per step 2: closure injection only, no fake
  `DispatchSource`.

Deliberately not done: no method moved between files and no encoder was
promoted — ticket 08 owns the overlay encoders and ticket 14 owns the split.

Review (fixed point `32eef4c`, standards + spec axes) found no missed
requirement and no wrong behaviour. Three findings were taken: the two weak
negative assertions above, and `attachSessionForTesting` losing its Optional
parameter (AGENTS.md's "optional parameters that fall back to a different
meaningful value" pitfall — no caller passes `nil`). The rest were rejected as
things the ticket forbids: renaming `now` to `clock` (the ticket names the
property), calling the thirteen-site clock injection speculative (the ticket
asks for it), and hoisting a shared session fixture out of
`TerminalSessionLifecycleTests` (a refactor that would grow the diff).

Gates before the commit: `cargo test --workspace -j 8` → 273 passed, 0 failed;
`xcodebuild test -scheme SolidTerm -destination 'platform=macOS'` →
`** TEST SUCCEEDED **`, Executed 449 tests, 2 skipped, 0 failures. The
ticket's Verify pair
(`-only-testing:SolidTermTests/IdlePumpTests
-only-testing:SolidTermTests/DisplayLinkIdlePumpTests`) → Executed 6 tests, 0
failures. Also green: `cargo fmt --all -- --check`, `cargo clippy --workspace
--all-targets --all-features` under `-D warnings`, `scripts/check-ffi-drift.sh`,
the two custom lint scripts, and the CI `swift-format lint --strict` sweep over
every source outside `Generated/`.

One full Swift run early in the session reported 2 failures; its result bundle
failed to save, so the two names are not recoverable. Three subsequent full
runs were clean, and the production clock is byte-for-byte the old one
(`now` defaults to `CACurrentMediaTime`), so the change cannot alter timing —
the three new tests do add three `/bin/zsh` spawns to the suite, which is the
documented load condition for the PTY-echo flakes.
