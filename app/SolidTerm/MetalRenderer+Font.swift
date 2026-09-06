// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Font + theme colour plumbing for `MetalRenderer`, split out of the
// single-file renderer by method cluster: the effective-font resolution,
// the theme observers' `refreshClearColor`, the font-size steps
// (⌘+ / ⌘- / ⌘0) and the atlas + pipeline rebuild in `reloadFont`.
// Stored properties live in MetalRenderer.swift because extensions
// cannot declare them.

import AppKit
import CoreText
import Metal
import QuartzCore

extension MetalRenderer {
    /// Build the `CTFont` this renderer should rasterize against —
    /// global family + per-window-resolved size. Replaces direct
    /// `FontSettings.shared.makeCTFont()` calls so the override can
    /// take effect.
    @MainActor
    func makeEffectiveFont() -> CTFont {
        FontSettings.makeCTFont(
            family: FontSettings.shared.family,
            size: effectiveFontSize)
    }

    /// M6-4a: re-resolve `clearColor` against the current theme mode.
    /// Called from the `themeDidChange` observer + on demand by tests.
    /// The `CAMetalDisplayLink` re-renders every vsync so the next
    /// frame picks up the new clear color without any additional
    /// invalidation hook.
    @MainActor
    func refreshClearColor() {
        // File-backed TOML theme (~/.config/solidterm/themes/<name>.toml)
        // wins over the built-in Theme.Mode cascade — same code path
        // the theme picker drives. The renderer honors the file's
        // bg/fg, cursor, selection, AND ANSI palette (mapped via the
        // engine's compile-time hex values).
        if let file = ThemeFileStore.shared.current {
            resolvedPalette = file.palette
            resolvedCursor = file.cursor
            resolvedSelection = file.selection
            ansiOverride = Self.buildAnsiOverride(file: file)
            clearColor = MTLClearColor(
                red: Double(file.background.x),
                green: Double(file.background.y),
                blue: Double(file.background.z),
                alpha: Double(file.background.w))
        } else {
            let mode = ThemeManager.shared.resolved
            clearColor = Theme.defaultClearMTL(for: mode)
            resolvedPalette = Theme.Color.defaultPalette(for: mode)
            resolvedCursor = Theme.Color.cursorDefaultLinear(for: mode)
            resolvedSelection = Theme.Color.selectionBgLinear(for: mode)
            ansiOverride = [:]
        }
        // Refresh the per-cell palette so existing visible cells re-
        // resolve against the live theme. Earlier versions blanked
        // `self.cells` and waited for the engine to re-emit damage on
        // the next PTY write — but an idle Claude Code session never
        // ticks PTY output, so text stayed invisible mid-theme-switch
        // until the user typed. `take_full_frame_delta` re-emits
        // every viewport row through the FFI without consuming
        // alacritty's damage state, so the renderer's resolver picks
        // up the new palette + `ansiOverride` map in the next frame.
        // No session yet (renderer still initialising) → fall back to
        // the blank-grid path so the new background color paints
        // immediately.
        withCellTextureSlot {
            if let session, let pipeline = gridPipeline, let atlas {
                let frame = session.take_full_frame_delta()
                self.lastCursor = frame.cursor
                if let decoded = try? FrameDeltaDecoding.decodeCells(frame.cells) {
                    if useShaping {
                        let coalesced = GraphemeClusterCoalescer.coalesce(decoded)
                        Self.applyCoalescedCellsAsRegions(
                            coalesced, pipeline: pipeline, atlas: atlas,
                            shadow: &self.cells, gridCols: gridCols,
                            makeSlot: { [weak self] cell in
                                self?.makeSlot(from: cell, atlas: atlas)
                            })
                    } else {
                        Self.applyCellsAsRegions(
                            decoded, pipeline: pipeline, atlas: atlas,
                            shadow: &self.cells, gridCols: gridCols,
                            makeSlot: { [weak self] cell in
                                self?.makeSlot(from: cell, atlas: atlas)
                            })
                    }
                }
            } else {
                self.cells = Self.makeBlankGrid(
                    cols: gridCols, rows: gridRows, palette: resolvedPalette)
                try? gridPipeline?.setGrid(
                    self.cells, atlasSize: GlyphAtlas.atlasSize,
                    colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            }
        }
        // Keep the engine's OSC 10/11/12 reply colors in lockstep with the
        // rendered theme: a child querying fg/bg/cursor (Claude Code's
        // `auto` light/dark detection, vim/delta `background` probes) must
        // see the real theme, not a hardcoded palette. The renderer works
        // in linear space; the OSC reply wants sRGB, so convert.
        if let session {
            let fgLinear: SIMD4<Float>
            let bgLinear: SIMD4<Float>
            if let file = ThemeFileStore.shared.current {
                fgLinear = file.foreground
                bgLinear = file.background
            } else {
                let mode = ThemeManager.shared.resolved
                fgLinear = Theme.Color.textPrimaryLinear(for: mode)
                bgLinear = Theme.Color.bgBaseLinear(for: mode)
            }
            session.set_theme_colors(
                Self.srgbU32(fromLinear: fgLinear),
                Self.srgbU32(fromLinear: bgLinear),
                Self.srgbU32(fromLinear: resolvedCursor))
        }
        pendingRedraw = true
    }

    /// Pack a linear-space color into sRGB `0x00RRGGBB` for the engine's
    /// OSC 10/11/12 color-query replies (xterm/kitty report sRGB). Inverse
    /// of the sRGB→linear decode the theme loader applies on parse.
    private static func srgbU32(fromLinear c: SIMD4<Float>) -> UInt32 {
        func enc(_ v: Float) -> UInt32 {
            let x = Double(max(0, min(1, v)))
            let s = x <= 0.003_130_8 ? x * 12.92 : 1.055 * pow(x, 1.0 / 2.4) - 0.055
            return UInt32((s * 255).rounded())
        }
        return (enc(c.x) << 16) | (enc(c.y) << 8) | enc(c.z)
    }

    /// M7-3: subscribe to `FontSettings.didChange` exactly once per
    /// renderer-lifetime so font family / size edits trigger an
    /// atlas regen on the next draw. Idempotent — re-installs only
    /// when the prior observer was torn down (e.g. the renderer is
    /// rehosted on a different window). Posts run on the main run
    /// loop, matching the rendering thread.
    /// Test seam — `MetalRendererFontTests` calls this after
    /// constructing a renderer-without-window so the `atlasDirty`
    /// flag wiring can be exercised without standing up a real
    /// `CAMetalLayer`. Production callers go through `windowChanged`.
    @MainActor
    func installFontObserverForTesting() {
        installFontObserverIfNeeded()
    }

    @MainActor
    func installFontObserverIfNeeded() {
        if fontObserver != nil { return }
        fontObserver = NotificationCenter.default.addObserver(
            forName: FontSettings.didChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.atlasDirty = true
        }
    }

    /// Per-window ⌘+ / ⌘- / ⌘0. Updates this renderer's font-size
    /// override and triggers an atlas regen on the next frame. Other
    /// windows are unaffected. Clamped via `FontSettings.clamp` so
    /// out-of-band hotkey presses are silently saturated.
    @MainActor
    func bumpFontSize() {
        let next = FontSettings.clamp(effectiveFontSize + 1)
        guard next != effectiveFontSize else { return }
        fontSizeOverride = next
        atlasDirty = true
        reloadFont()
    }

    @MainActor
    func dropFontSize() {
        let next = FontSettings.clamp(effectiveFontSize - 1)
        guard next != effectiveFontSize else { return }
        fontSizeOverride = next
        atlasDirty = true
        reloadFont()
    }

    /// ⌘0 — clears the per-window override so the window snaps back
    /// to the global Settings → Appearance default. Not "shrink to
    /// 14" — match the M7-3 spec where ⌘0 means "default size".
    @MainActor
    func resetFontSize() {
        guard fontSizeOverride != nil else { return }
        fontSizeOverride = nil
        atlasDirty = true
        reloadFont()
    }

    /// M7-3: rebuild the glyph atlas + grid pipeline against the
    /// current `FontSettings`. Also recomputes the host window's
    /// content-size so the cell grid matches the new metrics
    /// (without this, a font-size bump leaves the visible grid the
    /// same pixel size but with fewer / clipped cells until the next
    /// manual resize). Safe to call repeatedly; no-op when the
    /// renderer hasn't yet attached a window.
    @MainActor
    @discardableResult
    func reloadFont() -> Bool {
        guard let window = hostWindow else {
            atlasDirty = false
            return false
        }
        let scale = window.backingScaleFactor
        let font = makeEffectiveFont()
        do {
            let newAtlas = try GlyphAtlas(
                device: device, font: font, contentsScale: scale)
            for scalar in Self.randomGlyphs {
                _ = try newAtlas.entry(
                    for: scalar, commandQueue: commandQueue)
            }
            let newPipeline = try GridPipeline(
                device: device,
                pixelFormat: attachedPixelFormat,
                cols: gridCols,
                rows: gridRows)
            // No frameSlot needed: fresh pipeline — these textures have never been submitted; in-flight buffers retain the old set.
            try newPipeline.setGrid(
                self.cells, atlasSize: GlyphAtlas.atlasSize,
                colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            self.atlas = newAtlas
            self.gridPipeline = newPipeline
            // Keep the window size fixed; reflow the cell grid against
            // the new cell metrics instead. Bigger font ⇒ fewer cells
            // visible; smaller font ⇒ more cells. Matches iTerm2 /
            // Ghostty: ⌘+/⌘- changes typography only, not chrome.
            // We derive cols/rows from the unchanged content rect and
            // forward to `resizeGrid`, which propagates through to
            // alacritty via the FFI.
            let viewSize = window.contentRect(
                forFrameRect: window.frame
            ).size
            let cellW = newAtlas.cellSizePt.width
            let cellH = newAtlas.cellSizePt.height
            if cellW > 0, cellH > 0 {
                let gridWidth = max(0, viewSize.width - Theme.Gutter.widthPt)
                let cols = max(1, Int((gridWidth / cellW).rounded(.down)))
                let rows = max(1, Int((viewSize.height / cellH).rounded(.down)))
                resizeGrid(cols: cols, rows: rows)
            }
        } catch {
            NSLog(
                "MetalRenderer.reloadFont: rebuild failed: %@",
                String(describing: error))
            atlasDirty = false
            return false
        }
        atlasDirty = false
        return true
    }
}
