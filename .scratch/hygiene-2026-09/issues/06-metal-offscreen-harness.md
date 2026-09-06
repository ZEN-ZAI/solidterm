# 06 — Shared Metal offscreen render + readback harness for tests

Status: done — 2026-09-06
Blocked by: 02
Spec: ../spec.md (D10)

## Goal

One helper that renders into an offscreen `.rgba8Unorm` target, blits to a shared-storage texture, and returns `[UInt8]` plus `pixel(x:y:)` / `assertCellColor` helpers, used by the existing two tests and the new overlay tests (08).

## Steps

1. Add `app/SolidTermTests/MetalOffscreenHarness.swift` extracted from `OverlayPipelineTests.testCursorShapesRenderExpectedGeometry` (~127-200) and `GridCursorReverseVideoTests.renderGrid` (~170-250). API sketch:
   ```swift
   struct MetalOffscreenHarness {
       init(device: MTLDevice, widthPx: Int, heightPx: Int, clear: MTLClearColor) throws
       func render(_ body: (MTLRenderCommandEncoder) throws -> Void) throws -> PixelBuffer
   }
   struct PixelBuffer { let width, height: Int; func rgba(x: Int, y: Int) -> SIMD4<UInt8> }
   ```
2. Refactor the two existing tests to use it; assertions unchanged.
3. Keep `PixelVerifyHelpers` (SwiftUI) as is.

## Verify

`xcodebuild test` — same 446 tests, 0 failures; the two refactored tests still pass in isolation:
`xcodebuild test -only-testing:SolidTermTests/OverlayPipelineTests -only-testing:SolidTermTests/GridCursorReverseVideoTests`.

## Comments

### 2026-09-06 — landed

One commit: `test(app): share one Metal offscreen render harness` (this commit).

`app/SolidTermTests/MetalOffscreenHarness.swift` is new: `MetalOffscreenHarness`
owns a private-storage `.rgba8Unorm` render target, its shared-storage readback
twin and a command queue, and `render(_:)` clears the target, runs the caller's
closure against a render encoder, blits, waits and returns a `PixelBuffer`
(`width`, `height`, the raw `bytes`, plus `rgba(x:y:)`, `matchesColor(...)` and
`assertCellColor(...)`). Both hand-rolled copies are gone:
`OverlayPipelineTests.testCursorShapesRenderExpectedGeometry` and
`GridCursorReverseVideoTests.renderGrid` lost 159 lines between them and gained
54. `app/SolidTerm.xcodeproj/project.pbxproj` is the 4-line `xcodegen generate`
delta for the new file; `PixelVerifyHelpers.swift` is untouched, per step 3.

Judgement calls:

- The API sketch names the accessor `rgba(x:y:)` and the Goal prose calls it
  `pixel(x:y:)`; they are one accessor and it is spelled as the sketch has it.
- "Assertions unchanged" was read strictly as *the same sample points and the
  same numeric thresholds*, not the same call shape. `assertCellColor` compares
  each of R/G/B against an expected byte within a tolerance, and every threshold
  survives exactly: `< 60` / `> 195` is `±59` around 0 / 255, and the overlay
  test's `< 20` clear band is `±19` around 0. `matchesColor` exists because
  `XCTAssertFalse(isGreen(...))` needs a predicate, not an assertion.
- `OverlayPipelineTests.isCursor` (`> 200`, `< 50`, `> 200`) has bands that are
  not symmetric around one tolerance, so it stays a local predicate reading
  through `rgba(x:y:)`. Folding it into `assertCellColor` would have tightened
  R and B from 201 to 206 — a change to an assertion, however harmless.
- `render(_:)` ends the encoder before rethrowing a closure error; Metal traps on
  a command buffer left holding an open encoder, and the closure is `throws`.
- Alpha is deliberately not compared: the targets clear to alpha 1 and no pass
  under test writes a meaningful alpha. Both originals ignored it too.
- `testEncodeDoesNotRaise` in the same file still builds its own target. It is a
  `.bgra8Unorm_srgb` encode-only smoke test that never reads pixels back, so the
  readback harness does not fit it and the ticket names only the two readback
  sites.

Deliberately not done: no app-target member was promoted from `private` to
`internal` — ticket 08 step 1 owns the eight overlay encoders, and ticket 07 owns
the renderer clock.

Review (fixed point `3be2502`, standards + spec axes) found no missed requirement
and no wrong behaviour. Its one actionable finding was a stored `device` property
on the harness that no caller reads; it was dropped, which shrank the diff. The
remaining findings were a rename the ticket's own naming forbids and API the diff
has no use for yet.

Gates before the commit, both re-run after that fix: `cargo test --workspace -j 8`
→ 273 passed, 0 failed; `xcodebuild test -scheme SolidTerm -destination
'platform=macOS'` → `** TEST SUCCEEDED **`, Executed 446 tests, 2 skipped, 0
failures. The ticket's isolation check
(`-only-testing:SolidTermTests/OverlayPipelineTests
-only-testing:SolidTermTests/GridCursorReverseVideoTests`) → Executed 11 tests, 0
failures. Also green: `cargo fmt --all -- --check`, `cargo clippy --workspace
--all-targets --all-features` under `-D warnings`, `scripts/check-ffi-drift.sh`
(shims in sync), the three custom lint scripts, and the CI `swift-format lint
--strict` sweep over every source outside `Generated/`.
