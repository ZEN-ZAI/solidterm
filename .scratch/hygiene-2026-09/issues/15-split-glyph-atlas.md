# 15 — Split GlyphAtlas.swift along its MARKs

Status: done — 2026-09-06
Blocked by: 02
Spec: ../spec.md (D8, D9)

## Target layout

| New file | Contents | Lines today |
|---|---|---|
| `GlyphAtlas.swift` | `AtlasEntry` 57, `GlyphKey` 95, class decl + stored state, init, cell-size derivation (967) | 1–1047 |
| `GlyphAtlas+Rasterization.swift` | glyph resolution + rasterization (1048), pinned blank slot (1305) | 1048–1381 |
| `GlyphAtlas+Packing.swift` | shelf packer + LRU eviction + blit upload (1382) | 1382–1581 |
| `GlyphAtlas+ColorAtlas.swift` | color atlas (1582) + color-atlas public surface / test seam (1849) | 1582–end |

## Rules

Same as ticket 13; 53 privates today. Regenerate `.xcodeproj` in the same commit.

## Verify

`xcodebuild test` — `GlyphAtlasTests` (983 lines), `GraphemeClusterCoalescerTests`, `GridPipelineTests`, `MetalRendererSGRColorTests`.

## Comments

### 2026-09-06 — landed

One commit: `refactor(app): split GlyphAtlas along its MARKs` (this commit).
`GlyphAtlas.swift` went from 1,902 lines to 1,058; the three new files are
+Rasterization 346, +Packing 211, +ColorAtlas 331.

The Target-layout table's line numbers are stale by exactly two lines — the
file grew from 1,900 to 1,902 after the spec's Facts were gathered — so the
boundaries were taken from the MARK lines themselves (969, 1050, 1307, 1384,
1584, 1851). Every section landed in the file the table names.

Pure move, verified order-preservingly: re-concatenating the four files in
their original order, minus the scaffolding, reproduces the pre-split file
line for line (1,902 in, 1,902 out) with exactly 34 differing lines, every one
of them an access widening. Nothing was reordered, reworded, renamed or
respaced.

34 access widenings of the 53 `private` members (the Rules ask for the count);
19 stay private. 20 are stored state the extension files read or write, 5 are
nested types they name (`Record`, `FreeRect`, `PinnedRegion`,
`RasterizedGlyph`, `RasterizedColorGlyph`) and 9 are methods with a caller
across a boundary (`cachedFontHash`, `resolveGlyph`, `resolveFont`,
`rasterize`, `pinBlankSlot`, `place`, `allocateOrigin`, `rasterizeColor`,
`placeColor`). Unlike ticket 13 there was no `private(set)` in the file, so
nothing lost write protection.

Tallies: `cargo test --workspace -j 8` 273 passed, 0 failed across eight
suites (run twice, same result); `xcodebuild test` Executed 482 tests, 3
skipped, 0 failures, first try, no flake. CI's `xcodebuild clean test
-configuration Debug` also passed. The four suites this ticket's Verify names
are inside that run: GlyphAtlasTests (41 tests), GraphemeClusterCoalescerTests
(18), GridPipelineTests (17), MetalRendererSGRColorTests (12). Also green:
`cargo fmt --all -- --check`, clippy with `-D warnings`, CI's `swift-format
lint --strict` over every non-generated Swift source, `check-ffi-drift.sh`
("FFI shims in sync" — no bridge change, `Generated/` untouched),
`check-no-analytics.sh` and the two lint stubs. `scripts/regen-xcodeproj.sh`
produced the committed `.xcodeproj` (+12 lines, exactly the three new files)
and is idempotent.

Judgement calls:

- **`fontHash` stayed private.** Its only match outside the main file is
  `fontHash:` in the `GlyphKey(...)` call in +ColorAtlas.swift — an argument
  label that shares the stored property's name, not a read of it. Both review
  axes independently confirmed the call.
- **Imports were computed per file.** +Packing.swift takes only Foundation
  (for `NSLog`) and Metal; the other two also take CoreText. The main file's
  three imports were left as they were.
- **The split follows the MARKs, not topic.** Calls cross the new boundaries
  in both directions and were left alone: `resetAtlas` (+Packing) calls
  `pinBlankSlot` (+Rasterization), the color rasterizer calls the shared
  `fitScale` that the rasterization MARK owns, and the cluster path in the
  main file calls `rasterize`, `place` and `placeColor`. Regrouping by caller
  would be the refactor the Rules forbid.
- **Nothing was tidied on the way past.** Doc comments that describe a member
  as private still say so, and the `spec/…` citations in the headers are
  untouched — ticket 19 owns the comment pass.

Noted for a future ticket, deliberately not acted on here: +Packing.swift and
+ColorAtlas.swift are near line-for-line mirrors of each other (`place` /
`placeColor`, `allocateOrigin` / `allocateColorOrigin`, and five more pairs).
The split did not create that duplication — it made an existing intra-file
duplication visible as two whole files. Collapsing it is a refactor and needs
its own ticket.
