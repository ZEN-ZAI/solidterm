# 14 — Split MetalRenderer.swift by method cluster

Status: done — 2026-09-06
Blocked by: 07, 08, 09
Spec: ../spec.md (D8, D9)

## Target layout (method clusters found 2026-09-06)

| New file | Methods (line today) |
|---|---|
| `MetalRenderer.swift` | class decl + stored state, `init`, `attach` 630, `attachHostView` 644, `invalidateCompositionRender` 654, `markNeedsRedraw` 664, `windowChanged` 809, `resizeGrid` 940, display link + idle pump 1196–1268, `draw` 1269–1736, `metalDisplayLink` 3226, `MetalDisplayLinkProxy` 3219, latency (`didMeasureKeystrokeLatency` 3034, `recordFrameTime` 3038, `recordKeystroke` 3158), `makeDefaultSession` 3071, `makeBlankGrid` 3128 |
| `MetalRenderer+Font.swift` | `makeEffectiveFont` 135, `refreshClearColor` 529, `srgbU32` 621, font observer 696–715, `bumpFontSize` 716, `dropFontSize` 725, `resetFontSize` 737, `reloadFont` 756 |
| `MetalRenderer+TitleCwd.swift` | `applyLatestTitleIfAny` 1009, `nextTitleOwner` 1081, `displayCwd` 1096, `applyLatestCwdIfAny` 1113, `currentCwd` 1161, `cwdForPid` 1173 |
| `MetalRenderer+FrameDelta.swift` | `withCellTextureSlot` 399, `cursorEqual` 674, `applyFrameDelta` 1737, `applyCellsAsRegions` 1808, `applyCoalescedCellsAsRegions` 1887, `writeShadow` 1973, `buildAnsiOverride` 2057, `makeSlot` ×4 2069–2206, `lookupGlyph` 2085, `decodeGraphemeString` 2267, `resolveColor` 2284, `cursorKind` 2984, `firstScalar` 2997, `logMissingGlyphOnce` 3022 |
| `MetalRenderer+Overlays.swift` | the 8 `encode*Overlay` 2333–2983, `computeCursorBlockState` 2452, `applyCompositionStateIfNeeded` 2578, `restoredSlot` 2630, `paintPreeditCells` 2647 |

Adjust cluster membership if a method turns out to be tightly bound to `draw` state; record the final table in the commit message.

## Rules

Same as ticket 13. 103 privates today; those crossing files become `internal`. Keep `MetalDisplayLinkProxy` `private` in the main file. Regenerate `.xcodeproj` in the same commit.

## Verify

`xcodebuild test` full suite; `LatencyMeasurementTests` in Release (`xcodebuild test -configuration Release -only-testing:SolidTermTests/LatencyMeasurementTests`) to confirm no p99 regression from cross-file inlining loss.

## Comments

### 2026-09-06 — landed

One commit: `refactor(app): split MetalRenderer by method cluster` (this
commit). `MetalRenderer.swift` went from 3,275 lines to 1,591; the four new
files are +FrameDelta 625, +Overlays 695, +Font 254, +TitleCwd 167.

The final table matches the one above method for method — nothing turned out to
be tightly enough bound to `draw` to need moving. `CursorBlockState` travelled
with `computeCursorBlockState` into +Overlays.swift; the other two nested
structs (`LinkHover`, `SearchHighlights`) stayed with the stored properties they
document.

The table's line numbers are stale — they were gathered when the file was 3,230
lines and it was 3,275 at the fixed point — so members were located by name with
a brace-matching scan of the class body rather than by line, the same way ticket
13 handled its drifted table.

Pure move, verified mechanically: the multiset of non-blank lines across the
five files equals the original's, with nothing removed, and member order inside
each new file is strictly ascending against the original line numbers. The only
new text is the five file headers, the per-file imports, four
`extension MetalRenderer {` lines and their closing braces.

47 access widenings out of the 86 `private` declarations in the file at the
fixed point (39 remain; the ticket's "103" counts something else). 45 were
`private`; two were `private(set)` and lost write protection because Swift has
no cross-file-but-not-module setter — `atlasDirty`, written from +Font.swift,
and `lastCwd`, written from +TitleCwd.swift. Every widening has a real
cross-file caller found with comment text removed; `srgbU32`, `displayCwd`,
`cwdForPid`, `writeShadow`, `logMissingGlyphOnce`, `restoredSlot` and
`paintPreeditCells` stayed private because their only out-of-file mentions are
prose. `gridCols`, `gridRows` and `session` kept `private(set)`.
`MetalDisplayLinkProxy` stays `private` in the main file, as the Rules require.

Tallies: `cargo test --workspace -j 8` 273 passed, 0 failed (207 + 3 + 1 + 1 + 3
+ 44 + 14 + 0 across eight suites); `xcodebuild test` Executed 482 tests, with 3
tests skipped and 0 failures. The Verify block's Release check passed as well:
`-configuration Release -only-testing:SolidTermTests/LatencyMeasurementTests`
with `TEST_RUNNER_SOLIDTERM_RUN_PERF=1` (the perf case is opt-in and otherwise
skips) reported n=1000 p50=9.632 ms p99=10.701 ms against the 11.5 ms
assertion, so the split cost no frame to lost cross-file inlining. Also green:
`cargo fmt --all -- --check`, clippy with `-D warnings`,
`scripts/check-ffi-drift.sh` ("FFI shims in sync"; `app/SolidTerm/Generated`
untouched), `check-no-analytics.sh`, the two lint stubs, and CI's
`swift-format lint --strict` over every non-generated Swift source.
`scripts/regen-xcodeproj.sh` added the four files to the `.xcodeproj`, committed
alongside.

Judgement calls:

- **Placement follows the table even where the caller is elsewhere.**
  `cursorEqual` and `cursorKind` are in +FrameDelta.swift though `draw` and an
  overlay encoder call them, and `buildAnsiOverride` is there though +Font.swift
  calls it — which is what forces its widening. Regrouping by caller would be a
  refactor.
- **Imports were computed per new file; the main file's were left alone.**
  `MetalRenderer.swift` still imports CoreText and Darwin although the last
  `CTFont` and `proc_pidinfo` uses left with +Font and +TitleCwd. Removing them
  is a cleanup, and a pure move stays pure.
- **Nothing was tidied on the way past.** Inter-member blank lines are
  reproduced exactly. The header comments still cite the retired design archive
  and the main file's `// MARK:` banners still name sections that moved —
  ticket 19 owns the comment pass.
