# 11 — BoxDrawing golden hash over every handled codepoint

Status: ready-for-agent
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
