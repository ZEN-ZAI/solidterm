# 16 — Restructure BoxDrawing's giant switch into per-range functions across files

Status: ready-for-agent
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
