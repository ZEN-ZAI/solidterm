# 14 — Split MetalRenderer.swift by method cluster

Status: ready-for-agent
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
