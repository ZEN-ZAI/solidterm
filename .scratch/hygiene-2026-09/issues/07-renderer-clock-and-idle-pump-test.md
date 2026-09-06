# 07 — Inject a clock into MetalRenderer; test the idle-pump watchdog

Status: ready-for-agent
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
