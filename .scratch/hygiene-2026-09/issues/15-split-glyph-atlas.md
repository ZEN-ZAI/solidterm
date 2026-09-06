# 15 — Split GlyphAtlas.swift along its MARKs

Status: ready-for-agent
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
