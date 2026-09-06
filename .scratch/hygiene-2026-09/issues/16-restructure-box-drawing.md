# 16 — Restructure BoxDrawing's giant switch into per-range functions across files

Status: done — 2026-09-06
Blocked by: 11
Spec: ../spec.md (D8)

## Today

`enum BoxDrawing` (32–1248) has two statics, `handles` (37) and `rasterize` (52); `rasterize` is one `switch` over Unicode ranges (section comments at 82, 100, 137, …, 869, …) followed by geometry helpers (1249–1411), `ArcQuadrant` (1412), `DiagonalDirection` (1511). 0 private members, no stored state.

## Target layout

| New file | Contents |
|---|---|
| `BoxDrawing.swift` | `handles`, `rasterize` as a dispatcher calling one function per range |
| `BoxDrawing+Lines.swift` | U+2500–U+254F light/heavy/dashed lines, corners, tees, crosses |
| `BoxDrawing+Double.swift` | U+2550–U+256C double and single/double mixes |
| `BoxDrawing+Blocks.swift` | U+2580–U+259F blocks, shades, quadrants; arcs/diagonals (U+256D–U+2573) if present |
| `BoxDrawing+Geometry.swift` | geometry helpers, `ArcQuadrant`, `DiagonalDirection` |

Each range function takes the same `(scalar, cell, scale)` inputs the `switch` arms use today and returns the same raster; the dispatcher keeps the range order so unhandled scalars still return `nil`.

## Verify

`BoxDrawingGoldenTests` (11) passes unchanged — every codepoint hash identical; `BoxDrawingTests` 15 tests pass.

## Comments

### 2026-09-06 — landed

One commit: `refactor(app): split the BoxDrawing switch into range files`
(this commit). `BoxDrawing.swift` went from 1,548 lines to 132; the four new
files are +Lines 749, +Blocks 282, +Geometry 312, +Double 250.

The switch's five range functions are `static func`s on `extension
BoxDrawing`, each taking the same `(bitmap, scalar, widthPx, heightPx, light,
heavy, cx, cy)` the arms read today, and `rasterize` keeps the guards, the
bitmap allocation and the stroke/anchor metrics before dispatching in the old
range order. Because a switch arm sat at the same indentation depth inside
`rasterize` as it now does inside a range function, the arms moved with zero
reindentation: 1,448 of the pre-split file's 1,548 lines are byte-identical in
the new files, checked by extracting each function's arms and diffing them
against `HEAD:app/SolidTerm/BoxDrawing.swift` at the original line numbers.
The other 100 are the file's own scaffolding — header, `handles`, the
`rasterize` doc, signature and preamble, the closing braces — plus the new
prose.

Judgement calls:

- **U+2574–U+257F went to `+Lines.swift`.** The Target-layout table names
  U+2500–U+254F, U+2550–U+256C, U+256D–U+2573 and U+2580–U+259F but assigns
  the half-strokes and mixed light/heavy halves to no file. They are hLine /
  vLine geometry, so they joined the lines file as a second function,
  `rasterizeHalfStrokes`, rather than the blocks they sit beside in the code
  chart. The five ranges tile `handles()` exactly, so the dispatcher's
  `default:` is unreachable and the nil return still belongs to the guards.
- **Geometry helpers stayed file-scope, widened to internal.** D9 says
  "`private` members that must cross a file boundary become `internal` (still
  module-private)", which for a file-scope `private func` means dropping the
  keyword — 12 declarations (ten helpers with a sibling-file caller, plus
  `ArcQuadrant` and `DiagonalDirection`, which two of those signatures name);
  `plotArcPixel` stays private because `arcCorner` in the same file is its
  only caller. Both review axes argued for nesting them as `static` members of
  `extension BoxDrawing` instead, to keep `block` / `shade` / `diagonal` out
  of the module namespace. That is a reasonable follow-up but it would
  reindent all 300 lines and cost the byte-identical property above, so the
  literal D9 reading won. Call sites are unchanged either way.
- **The uniform signature carries parameters some ranges don't read.**
  `heavy` is unused by `rasterizeDouble` and `rasterizeArcsAndDiagonals`, and
  `rasterizeBlocks` reads none of `light`, `heavy`, `cx`, `cy`. The ticket
  asks for "the same … inputs the `switch` arms use today"; trimming each
  signature to its own range would be a design choice this ticket doesn't
  own.
- **`Verify`'s "BoxDrawingGoldenTests (11)" is stale prose.** The suite
  ticket 11 landed has three test methods, one of them the skipped
  regenerator; between them they hash all 160 handled scalars at three cell
  geometries and pin the table's key set against `handles`. Both passed
  unchanged, which is what the line asks for.
- **Nothing was tidied on the way past.** The design-archive citations and
  the doc comments are untouched — ticket 19 owns that pass — and no arm was
  reordered, reworded or renamed.

Tallies: `cargo test --workspace -j 8` 273 passed, 0 failed across eight
suites; `xcodebuild test -scheme SolidTerm -destination 'platform=macOS'`
Executed 482 tests, 3 skipped, 0 failures, no flake and no rerun needed —
`BoxDrawingGoldenTests` 3 tests (1 skipped) and `BoxDrawingTests` 15 tests
both green inside that run. Also green: `cargo fmt --all -- --check`, clippy
with `-D warnings`, `swift-format lint --strict` over every non-generated
Swift source, `scripts/check-ffi-drift.sh` ("FFI shims in sync" —
`app/SolidTerm/Generated` untouched), `check-no-analytics.sh` and the two
lint stubs. `xcodegen generate` added 16 pbxproj lines, exactly the four new
files.

Not done here: the design-archive citations in these files' headers are
ticket 19, and the SPDX license headers are ticket 20.
