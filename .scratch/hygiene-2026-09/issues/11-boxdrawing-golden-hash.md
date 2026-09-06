# 11 — BoxDrawing golden hash over every handled codepoint

Status: done — 2026-09-06
Blocked by: 02
Spec: ../spec.md (D10)

## Goal

Lock the exact raster output of `BoxDrawing.rasterize` for each scalar that `BoxDrawing.handles` accepts (U+2500…U+259F today), so ticket 16 can restructure the giant `switch` with zero drift.

## Steps

1. Add to `BoxDrawingTests` (or new `BoxDrawingGoldenTests.swift`): for a fixed cell size (e.g. 10×20 px @1x and 20×40 @2x), rasterize every handled scalar, hash the bitmap bytes with FNV-1a 64, and compare against a generated table.
2. Generate the table once with a helper that prints `0x2500: 0x…,` lines; store it as `app/SolidTermTests/Fixtures/boxdrawing-golden.json` (`{"cell":"10x20","hashes":{"2500":"…"}}`) so a failure names the codepoint. Include the generator as a skipped test (`XCTSkip` unless `BOXDRAWING_REGEN=1`).
3. Fail with a message listing every mismatching codepoint, not just the first.

## Verify

`xcodebuild test -only-testing:SolidTermTests/BoxDrawingGoldenTests` — passes on the current code before any BoxDrawing change is made.

## Comments

### 2026-09-06 — landed

One commit: `test(app): lock every BoxDrawing raster with a golden hash
table` (this commit). `app/SolidTermTests/BoxDrawingGoldenTests.swift` (3
tests), `app/SolidTermTests/Fixtures/boxdrawing-golden.json` (480 rows), the
`project.yml` line that keeps the fixture out of the .xctest bundle, and the
xcodegen regen. `BoxDrawing.swift` is untouched — the ticket's Verify wants
this green on the code as it stands. Rust 273 passed / 0 failed; Swift
`Executed 482 tests, with 3 tests skipped and 0 failures`.

Judgement calls:

- **Three cell geometries, not the two in step 1.** `rasterize` derives its
  stroke width from `light = max(1, heightPx / 24)`, which is 1 at both
  h=20 and h=40, so a table of only 10x20 and 20x40 would have been 320
  light=1 rasters and the scaled-stroke arithmetic (`light` 2, `heavy` 4,
  the `double` gap) would have gone unwitnessed — exactly the drift ticket
  16 could introduce. 32x48 is the third row because
  `BoxDrawingTests.testHeavyHorizontalRule` already reaches for that size
  for the same reason. Step 1's sizes are prefixed "e.g."; this stays
  inside that latitude.
- **Fixture shape.** Step 2 specifies `{"cell":"10x20","hashes":{…}}`, which
  describes one geometry. The file is `{"cells":[{cell,hashes},…]}` — each
  element is exactly step 2's object.
- **Rows in codepoint order, hand-written.** `JSONSerialization`'s
  `.sortedKeys` compares numerically, which files "250A" before "2500" and
  makes a drift diff unreadable. The regenerator emits the JSON itself;
  `JSONSerialization` still parses it on the read side. Two consecutive
  regenerations produce byte-identical files.
- **Read via `#filePath`, not `Bundle`.** The regenerator writes the source
  path, so reading the same path keeps the table under test and the table
  under review as one set of bytes. xcodegen would otherwise have copied the
  JSON into the test bundle as a second, never-read copy, so `project.yml`
  now lists `SolidTermTests/Fixtures` with `buildPhase: none`; the pbxproj
  delta is the file reference and the new source, no resources phase.
- **Regen gate.** `BOXDRAWING_REGEN=1`, as step 2 asks. Under `xcodebuild`
  pass it as `TEST_RUNNER_BOXDRAWING_REGEN=1`, which xcodebuild forwards to
  the test process with the prefix removed; both spellings appear in the
  skip message and the doc comment.
- **A third test beyond steps 1-3.**
  `testGoldenTableCoversExactlyTheHandledScalars` compares the table's key
  set against what `BoxDrawing.handles` accepts, in both directions. Without
  it a truncated regen would shrink the lock silently. For the same reason
  the handled set is discovered by asking `handles` over every scalar rather
  than by restating `0x2500...0x259F` in the test.
- **Step 3 taken literally.** Every failure mode — nil raster, wrong bitmap
  length, missing table row, changed hash — appends to one list and the
  assertion fires once, so a run names every affected codepoint. The first
  draft used `XCTUnwrap` inside the loop, which would have stopped at the
  first nil; the code review caught it, along with a `guard … else
  { continue }` that let a missing table row pass as success.

Evidence the lock bites: with `case 0x2500` temporarily switched from
`thickness: light` to `thickness: heavy`, the test failed with `2
box-drawing raster(s) changed: U+2500 10x20: 0x6400… -> 0x2fa6…` and the
matching 20x40 line, then passed again once the edit was reverted. All 160
hashes are distinct within each geometry, so no two codepoints share a
raster at any of the three sizes — the table discriminates every arm of the
switch ticket 16 will restructure.

Not done here: the switch restructuring itself (ticket 16), and the
`0x2500: 0x…,` lines the regenerator prints are a convenience for reading a
regen run, not an input to anything.
