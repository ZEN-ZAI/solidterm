// Overlay encoding for `MetalRenderer`, split out of the single-file
// renderer by method cluster: the eight `encode*Overlay` passes
// (selection, cursor, IME underline, link underline, text underline,
// scrollbar, bell flash, search highlight), the per-frame cursor state
// they share, and the IME composition painting. Stored properties live
// in MetalRenderer.swift because extensions cannot declare them.

import AppKit
import Metal

extension MetalRenderer {
    /// 4.5 selection overlay tint. Selection is rendered at 0.35 alpha
    /// over the grid pass; the shader stays kind-agnostic and we
    /// modulate alpha CPU-side via `colorLinear.a`. Color comes from
    /// `Theme.Color.selectionBgLinear` — the locked `selection-bg`
    /// design token (ADR-0004).
    ///
    /// **Span shape (4.5 scope cut):** stream selections only.
    /// `is_block == true` is plumbed through the FFI but rendered as
    /// stream — block-mode rendering is paired with block-mode input
    /// (alt-drag), and the brief defers the input plumb. The renderer
    /// is shape-ready (the `is_block` flag is read; only the encode
    /// strategy is shared) so when block-mode lands it's a single
    /// branch in this method.
    ///
    /// Stream geometry, given a span `(start_row, start_col, end_row,
    /// end_col)`:
    ///   - Single row (`start_row == end_row`): one quad spanning
    ///     `[start_col, end_col]` × that row.
    ///   - Multi-row: first row covers `[start_col, viewportCols)`;
    ///     middle rows cover `[0, viewportCols)`; last row covers
    ///     `[0, end_col]`. One overlay quad per row.
    ///
    /// Spans are passed through `OverlayUniforms.cellSpanCols`; the
    /// vertex shader stretches the quad's x-extent so each row is one
    /// draw call regardless of width. Y-axis stays single-cell.
    // PG4 selection contrast: 0.35 was the original "soft tint" that
    // kept underlying glyphs visible but produced low contrast on
    // dark themes (matcha selection #2a3424 over bg-base #0e0d10 at
    // 35% looked like a barely-there green shadow). 0.55 reads as a
    // confident selection while still letting the glyph show
    // through. True reverse-video (swap fg/bg per cell) is shader
    // work — tracked separately. This is the 80% win.
    static let selectionAlpha: Float = 0.55
    func encodeSelectionOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        guard let session else { return }
        // Keep the mirror's viewport rows in step with the content
        // before reading it: output that scrolled the grid since the
        // last input event moved the selected cells without touching
        // any mouse handler. See `reprojectSelectionMirror`.
        hostView?.reprojectSelectionMirror(from: session)
        // Wire format: empty → no selection; 5 u32s otherwise per
        // bridge.rs::TerminalSession::selection_span.
        //
        // **Source of truth**: prefer the Swift-side `swiftSelectionSpan`
        // mirror over the engine's span when set. alacritty clears its
        // own `Term::selection` on grid writes that intersect the
        // selection's row range (term/mod.rs:1657,1773,1786,1803,1811);
        // TUIs that redraw rows on every render tick would otherwise
        // see the selection-tint vanish under their feet. The Swift
        // mirror is the authoritative UI-layer record of "what cells
        // does the user have selected" — see
        // `TerminalSurfaceView.pendingSelection` docs.
        let startRow: Int
        let startCol: Int
        let endRow: Int
        let endCol: Int
        let isBlock: Bool
        if let mirror = hostView?.swiftSelectionSpan, mirror.count == 5 {
            startRow = Int(mirror[0])
            startCol = Int(mirror[1])
            endRow = Int(mirror[2])
            endCol = Int(mirror[3])
            isBlock = mirror[4] != 0
        } else {
            let span = session.selection_span()
            guard span.len() == 5 else { return }
            startRow = Int(span.get(index: 0).map { $0 } ?? 0)
            startCol = Int(span.get(index: 1).map { $0 } ?? 0)
            endRow = Int(span.get(index: 2).map { $0 } ?? 0)
            endCol = Int(span.get(index: 3).map { $0 } ?? 0)
            isBlock = (span.get(index: 4).map { $0 } ?? 0) != 0
        }

        // Defensive bounds: clamp to viewport so a misbehaving
        // producer can't drive an off-screen quad. Real out-of-range
        // inputs are clamped engine-side; this is belt-and-braces.
        let maxCol = max(0, gridCols - 1)
        let maxRow = max(0, gridRows - 1)
        let sR = min(max(startRow, 0), maxRow)
        let eR = min(max(endRow, 0), maxRow)
        let sC = min(max(startCol, 0), maxCol)
        let eC = min(max(endCol, 0), maxCol)

        // Per-row encode helper.
        func encodeRow(row: Int, fromCol: Int, toCol: Int) {
            guard fromCol <= toCol else { return }
            let spanCells = toCol - fromCol + 1
            let originPx = SIMD2<Float>(
                gridOriginPx.x + Float(fromCol) * cellSizePx.x,
                gridOriginPx.y + Float(row) * cellSizePx.y)
            var color = resolvedSelection
            color.w = Self.selectionAlpha
            let uniforms = OverlayUniforms(
                screenSizePx: drawableSizePx,
                cellOriginPx: originPx,
                cellSizePx: cellSizePx,
                colorLinear: color,
                kind: OverlayKind.selection.rawValue,
                alpha: 1.0,
                cellSpanCols: UInt32(spanCells))
            overlay.encode(uniforms: uniforms, encoder: encoder)
        }

        if isBlock {
            // Block-mode: each row covers [sC, eC]. Documented as
            // shape-ready scope-cut — the input side stays deferred.
            for r in sR...eR {
                encodeRow(row: r, fromCol: sC, toCol: eC)
            }
        } else if sR == eR {
            encodeRow(row: sR, fromCol: sC, toCol: eC)
        } else {
            // First row: [sC, lastCol]
            encodeRow(row: sR, fromCol: sC, toCol: maxCol)
            // Middle rows: full width
            if eR > sR + 1 {
                for r in (sR + 1)...(eR - 1) {
                    encodeRow(row: r, fromCol: 0, toCol: maxCol)
                }
            }
            // Last row: [0, eC]
            encodeRow(row: eR, fromCol: 0, toCol: eC)
        }
    }

    /// Resolved per-frame cursor presentation, shared by the grid pass
    /// (BLOCK reverse-video) and the overlay pass (BEAM / UNDERLINE quads).
    /// Computed once per tick by `computeCursorBlockState()` so the blink
    /// bookkeeping advances exactly once. `nil` means "draw no cursor this
    /// frame" — hidden, scrolled into history, off-screen, or blink-off.
    struct CursorBlockState {
        var col: Int
        var row: Int
        var kind: OverlayKind  // .cursorBlock / .cursorBeam / .cursorUnderline
        var color: SIMD4<Float>  // straight linear RGBA, .w forced to 1
        var alpha: Float  // blink phase, > 0 (callers gate on nil for off)
    }

    /// Resolve the cursor's draw state for this frame. Holds all the
    /// visibility gates (hidden / scrolled-into-history / off-screen /
    /// blink-off) and the blink + pause-on-type bookkeeping that used to
    /// live inline in `encodeCursorOverlay`. Pulled out so it can run
    /// BEFORE the grid encode — the grid pass needs the BLOCK cursor's
    /// cell + colour + alpha to reverse-video the glyph, and this helper
    /// mutates `blinkOriginTime` / `wasTypingLastFrame`, so it must run
    /// exactly once per tick. Returns `nil` when nothing should draw.
    func computeCursorBlockState() -> CursorBlockState? {
        guard let cursor = lastCursor, !cursor.hidden else { return nil }
        // UX3: don't draw the cursor while the user is scrolled into
        // history (display_offset > 0). It's misleading there — the
        // block on old output reads as "this line is editable" when it
        // isn't. Snap-to-bottom restores the cursor automatically on the
        // next input frame. Matches Terminal.app / iTerm2 behaviour.
        if lastScrollTop > 0 { return nil }
        // Defensive: a misbehaving producer could place the cursor
        // outside the grid; drop rather than reverse-video / encode an
        // off-screen cell.
        guard Int(cursor.row) < gridRows,
            Int(cursor.col) < gridCols
        else { return nil }

        let kind = Self.cursorKind(forShape: cursor.shape)

        // Lazily anchor the blink phase so blink starts from "visible"
        // the moment the renderer has work to do, not the moment the
        // process launched (which can be seconds before the first frame
        // on a cold start).
        let now = self.now()
        if blinkOriginTime == nil { blinkOriginTime = now }

        // V2 pause-on-type: hold solid while the user is actively typing.
        // The blink resumes ~500 ms after the last keystroke. Re-anchor
        // `blinkOriginTime` on resume so the cursor enters at the
        // visible-steady phase rather than mid-fade.
        let timeSinceKey = now - lastKeystrokeTime
        let typingActive =
            lastKeystrokeTime > 0
            && timeSinceKey < Self.blinkPauseAfterKeystrokeSec
        // UX6: re-anchor `blinkOriginTime` only on the typing → idle
        // transition. Continuously anchoring during typing made `elapsed`
        // jump to the pause duration the instant typing stopped — landing
        // the first post-pause frame in the hidden-steady phase, so the
        // cursor disappeared for ~150 ms right when the user finished
        // typing and expected to see it. Anchoring only at the boundary
        // guarantees the first idle frame enters the visible-steady phase.
        if !typingActive && wasTypingLastFrame {
            blinkOriginTime = now
        }
        wasTypingLastFrame = typingActive

        let alpha: Float
        if !cursor.blink || typingActive {
            alpha = 1.0
        } else {
            let elapsedNow = now - (blinkOriginTime ?? now)
            alpha = easedBlinkAlpha(
                elapsed: elapsedNow, period: Self.blinkPeriodSec)
        }

        // Blink-off phase: nothing draws.
        guard alpha > 0 else { return nil }

        var color = resolvedCursor
        // The uniform's `alpha` carries the blink phase; keep the colour
        // straight-RGBA with full opacity so the grid reverse-video mix
        // and the overlay's `colorLinear.a * alpha` term agree.
        color.w = 1.0

        return CursorBlockState(
            col: Int(cursor.col),
            row: Int(cursor.row),
            kind: kind,
            color: color,
            alpha: alpha)
    }

    /// Encode the Stage-2 cursor overlay quad for the BEAM / UNDERLINE
    /// shapes only. The BLOCK shape is no longer drawn here: it would
    /// paint an opaque quad over the glyph and hide the character. Instead
    /// the grid pass reverse-videos the cursor cell (see `grid_fragment` +
    /// `computeCursorBlockState`), keeping the character readable. Beam and
    /// underline don't cover the glyph, so they stay as overlay quads with
    /// the source-over blend exactly as before.
    ///
    /// `state` is the precomputed per-frame cursor presentation; `nil`
    /// means no cursor this frame (already gated in the helper).
    func encodeCursorOverlay(
        state: CursorBlockState?,
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        guard let state else { return }
        // BLOCK is handled by the grid-pass reverse-video; skip the quad.
        guard state.kind != .cursorBlock else { return }

        let originPx = SIMD2<Float>(
            gridOriginPx.x + Float(state.col) * cellSizePx.x,
            gridOriginPx.y + Float(state.row) * cellSizePx.y)

        let uniforms = OverlayUniforms(
            screenSizePx: drawableSizePx,
            cellOriginPx: originPx,
            cellSizePx: cellSizePx,
            colorLinear: state.color,
            kind: state.kind.rawValue,
            alpha: state.alpha,
            cellSpanCols: 1)
        overlay.encode(uniforms: uniforms, encoder: encoder)
    }

    /// 4.9: paint preedit cells over the grid texture, or restore the
    /// underlying real cells when composition just cleared.
    ///
    /// Strategy: composition state lives Swift-side only. We poll the
    /// host view's `activeComposition` each frame; when it's non-nil
    /// AND `compositionInvalidated` is set (avoids redundant uploads
    /// on stable composition frames), we upload preedit cells via
    /// `setRegion` at the cursor row. When composition just ended
    /// (`compositionInvalidated && composition == nil`), we restore
    /// the cells we'd been painting from the cached `cells` shadow
    /// array — the engine doesn't mark them dirty (we never sent
    /// preedit through the FFI), so without this restore the preedit
    /// glyphs would linger on screen until the next real PTY write
    /// touches those cells.
    ///
    /// The `cells` shadow may be empty post-resize (cleared by
    /// `resizeGrid`) — in that case we fall back to a blank-cell
    /// repaint with the theme's default background. Acceptable
    /// because resize triggers a full repaint from alacritty anyway
    /// on the next FrameDelta.
    func applyCompositionStateIfNeeded(
        pipeline: GridPipeline, atlas: GlyphAtlas
    ) {
        let composition = hostView?.activeComposition
        // Fast path: no composition AND nothing to clean up. Most
        // frames take this exit.
        if composition == nil && !compositionInvalidated
            && preeditPaintedCells.isEmpty
        {
            return
        }

        // Restore previously-painted preedit cells from the cached
        // grid state. Done unconditionally when there ARE painted
        // cells — covers two cases:
        //   - composition just ended: no new preedit overwrite, so
        //     restore puts real cells back.
        //   - composition refined to a SHORTER preedit: tail cells
        //     that the new preedit doesn't cover need their real
        //     content back.
        // For composition that grew or stayed same length, the
        // upcoming preedit upload overwrites the restored cells, so
        // the restore is wasted work. Acceptable cost — composition
        // typically refines once per word, well under any latency
        // budget concern.
        if !preeditPaintedCells.isEmpty {
            for (row, col) in preeditPaintedCells {
                let restoredSlot = restoredSlot(row: row, col: col)
                let rect = GridPipeline.GridRect(
                    col: col, row: row, width: 1, height: 1)
                try? pipeline.setRegion(
                    rect: rect, slots: [restoredSlot],
                    atlasSize: GlyphAtlas.atlasSize,
                    colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            }
            preeditPaintedCells.removeAll(keepingCapacity: true)
        }

        // Paint new preedit cells (if any).
        if let comp = composition, !comp.text.isEmpty {
            paintPreeditCells(
                text: comp.text, pipeline: pipeline, atlas: atlas)
        }

        compositionInvalidated = false
    }

    /// 4.9: resolve the underlying real cell at (row, col) from the
    /// renderer's cached shadow. Falls back to a blank cell with
    /// theme defaults when:
    ///   - the shadow is empty (post-resize, before next FrameDelta), or
    ///   - the index is out of range (defensive — preedit cells should
    ///     always sit inside the grid since we clamp at paint time).
    private func restoredSlot(row: Int, col: Int) -> CellSlot {
        let idx = row * gridCols + col
        if idx >= 0, idx < cells.count {
            return cells[idx]
        }
        return CellSlot(
            glyph: nil,
            fgColorLinear: Theme.Color.textPrimaryLinear,
            bgColorLinear: Theme.Color.bgBaseLinear)
    }

    /// 4.9: paint preedit `text` starting at the cursor cell. Each
    /// scalar maps to one cell. Truncated at the viewport's right
    /// edge — wrapping preedit to the next row would mismatch the
    /// IME's candidate-window anchor (which is fixed at the cursor
    /// cell). Records the painted cells in `preeditPaintedCells` so
    /// the next composition-state-change frame can restore them.
    private func paintPreeditCells(
        text: String, pipeline: GridPipeline, atlas: GlyphAtlas
    ) {
        guard let cursor = lastCursor else { return }
        let row = Int(cursor.row)
        let startCol = Int(cursor.col)
        guard row >= 0, row < gridRows, startCol >= 0, startCol < gridCols
        else { return }

        var slots: [CellSlot] = []
        var col = startCol
        for scalar in text.unicodeScalars {
            guard col < gridCols else { break }
            let glyph = try? atlas.entry(
                for: scalar, commandQueue: commandQueue)
            slots.append(
                CellSlot(
                    glyph: glyph,
                    fgColorLinear: Theme.Color.textPrimaryLinear,
                    bgColorLinear: Theme.Color.bgBaseLinear))
            col += 1
        }
        guard !slots.isEmpty else { return }

        let rect = GridPipeline.GridRect(
            col: startCol, row: row,
            width: slots.count, height: 1)
        do {
            try pipeline.setRegion(
                rect: rect, slots: slots,
                atlasSize: GlyphAtlas.atlasSize, colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            for i in 0..<slots.count {
                preeditPaintedCells.append((row: row, col: startCol + i))
            }
        } catch {
            NSLog(
                "MetalRenderer.paintPreeditCells: setRegion failed for "
                    + "rect=(%d,%d %dx%d): %@",
                rect.col, rect.row, rect.width, rect.height,
                String(describing: error))
        }
    }

    /// 4.9: encode one IME-underline quad per preedit cell at the
    /// cursor row. The shader's kind=3 case lights the bottom ~15%
    /// of each cell with `colorLinear` (`Theme.Color.imeUnderlineLinear`).
    /// Skipped when no composition is active.
    func encodeImeUnderlineOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        guard let comp = hostView?.activeComposition,
            !comp.text.isEmpty,
            let cursor = lastCursor
        else { return }
        let row = Int(cursor.row)
        let startCol = Int(cursor.col)
        guard row >= 0, row < gridRows, startCol >= 0, startCol < gridCols
        else { return }

        var color = Theme.Color.imeUnderlineLinear
        color.w = 1.0  // straight alpha; the shader gates by cellUV.y

        var col = startCol
        for _ in comp.text.unicodeScalars {
            guard col < gridCols else { break }
            let originPx = SIMD2<Float>(
                gridOriginPx.x + Float(col) * cellSizePx.x,
                gridOriginPx.y + Float(row) * cellSizePx.y)
            let uniforms = OverlayUniforms(
                screenSizePx: drawableSizePx,
                cellOriginPx: originPx,
                cellSizePx: cellSizePx,
                colorLinear: color,
                kind: OverlayKind.imeUnderline.rawValue,
                alpha: 1.0,
                cellSpanCols: 1)
            overlay.encode(uniforms: uniforms, encoder: encoder)
            col += 1
        }
    }

    /// M6-2: encode a single-row, N-cell underline at `linkHover` so a
    /// ⌘+hovered file path looks clickable. Reuses the kind=3 shader
    /// path (`imeUnderline`, bottom ~15% of cell) with a link-tint color
    /// so no shader change is needed. Skipped when `linkHover` is nil
    /// (not hovering, ⌘ not down, or detection disabled).
    func encodeLinkUnderlineOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        guard let hover = linkHover else { return }
        let row = hover.row
        let startCol = hover.startCol
        guard row >= 0, row < gridRows, startCol >= 0, startCol < gridCols,
            hover.span > 0
        else { return }
        let span = min(hover.span, gridCols - startCol)
        var color = Theme.Color.linkUnderlineLinear
        color.w = 1.0
        let originPx = SIMD2<Float>(
            gridOriginPx.x + Float(startCol) * cellSizePx.x,
            gridOriginPx.y + Float(row) * cellSizePx.y)
        let uniforms = OverlayUniforms(
            screenSizePx: drawableSizePx,
            cellOriginPx: originPx,
            cellSizePx: cellSizePx,
            colorLinear: color,
            kind: OverlayKind.imeUnderline.rawValue,
            alpha: 1.0,
            cellSpanCols: UInt32(span))
        overlay.encode(uniforms: uniforms, encoder: encoder)
    }

    /// SGR underline (`\e[4m`). Walks the cached `cells` array, coalescing
    /// adjacent cells in the same row that carry the UNDERLINE attr bit
    /// (alacritty `Flags::UNDERLINE` = 0x0008) into runs. One overlay
    /// quad per run, tinted with the run's fg color.
    func encodeTextUnderlineOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        let underlineBit: UInt16 = 0x0008
        guard gridCols > 0, gridRows > 0, cells.count == gridCols * gridRows
        else { return }
        for row in 0..<gridRows {
            var col = 0
            while col < gridCols {
                let idx = row * gridCols + col
                guard (cells[idx].attrs & underlineBit) != 0 else {
                    col += 1
                    continue
                }
                let runStart = col
                let runFg = cells[idx].fgColorLinear
                while col < gridCols
                    && (cells[row * gridCols + col].attrs & underlineBit) != 0
                {
                    col += 1
                }
                let span = col - runStart
                let originPx = SIMD2<Float>(
                    gridOriginPx.x + Float(runStart) * cellSizePx.x,
                    gridOriginPx.y + Float(row) * cellSizePx.y)
                let uniforms = OverlayUniforms(
                    screenSizePx: drawableSizePx,
                    cellOriginPx: originPx,
                    cellSizePx: cellSizePx,
                    colorLinear: runFg,
                    kind: OverlayKind.textUnderline.rawValue,
                    alpha: 1.0,
                    cellSpanCols: UInt32(span))
                overlay.encode(uniforms: uniforms, encoder: encoder)
            }
        }
    }

    /// Scrollbar thumb. Hidden when scrollback is empty (live tail with
    /// no history). Right-edge strip with a thumb whose height is
    /// proportional to (viewport / total) and whose y is proportional
    /// to (scroll_top / scroll_total). scroll_top == 0 means we're at
    /// the live tail, so the thumb sits at the bottom; scroll_top ==
    /// scroll_total means oldest history, thumb at the top.
    func encodeScrollbarOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        let total = lastScrollTotal
        guard total > 0, gridRows > 0 else { return }
        // V1: don't show the thumb at all until the buffer holds
        // meaningful history — a shell that hasn't yet exceeded one
        // viewport's worth of output doesn't need scrollback chrome.
        guard total >= gridRows else { return }

        let viewportPx = Float(gridRows) * cellSizePx.y
        let viewportRows = Float(gridRows)
        let totalRowsF = Float(total)
        let trackHeightPx = viewportPx
        // Thumb height: proportional to viewport / (viewport + history).
        // Min 24px so the thumb stays grabbable at very deep scrollback.
        let rawThumbH = trackHeightPx * (viewportRows / (viewportRows + totalRowsF))
        let thumbHPx = max(24, rawThumbH)
        // scroll_top is "rows scrolled up into history" — 0 at live
        // tail. Tail-anchored: fraction 1.0 puts the thumb at the
        // bottom of the track; fraction 0.0 at the top.
        let fractionFromTop = 1.0 - Float(lastScrollTop) / totalRowsF
        let thumbYPx = gridOriginPx.y + (trackHeightPx - thumbHPx) * fractionFromTop

        // V1 hover-grow: when the pointer sits within
        // `scrollbarHoverHitWidthPt` of the right edge AND vertically
        // overlaps the thumb, snap to the hover width and full opacity.
        // `hoverPointInView` is in view-points (not pixels); convert
        // by dividing drawableSize.x by `layer.contentsScale` to
        // compare. We approximate via the drawable-points conversion
        // here — for Retina (2×) the math is `drawableSizePx.x / 2`.
        let scale = Float((attachedLayer?.contentsScale) ?? 2.0)
        let viewWidthPt = drawableSizePx.x / scale
        let viewHeightPt = drawableSizePx.y / scale
        var hovering = false
        if let p = hoverPointInView {
            let xFromRight = viewWidthPt - Float(p.x)
            // AppKit y origin is bottom-left; convert to top-down so it
            // lines up with the drawable's pixel coords.
            let yFromTop = viewHeightPt - Float(p.y)
            let thumbYPt = thumbYPx / scale
            let thumbHPt = thumbHPx / scale
            if xFromRight >= 0
                && xFromRight <= Self.scrollbarHoverHitWidthPt
                && yFromTop >= thumbYPt - 4
                && yFromTop <= thumbYPt + thumbHPt + 4
            {
                hovering = true
            }
        }

        let widthPx: Float =
            hovering
            ? Self.scrollbarHoverWidthPx
            : Self.scrollbarRestingWidthPx

        // V1 fade: solid for `scrollbarHoldSec` post-activity, then
        // linear fade to `scrollbarRestingAlpha` over the next
        // `scrollbarFadeSec`. Hover overrides to full opacity.
        let elapsed = now() - lastScrollActivityTime
        let alpha: Float
        if hovering {
            alpha = 1.0
        } else if elapsed < Self.scrollbarHoldSec {
            alpha = 1.0
        } else {
            let fadeProgress = min(
                1.0,
                Float((elapsed - Self.scrollbarHoldSec) / Self.scrollbarFadeSec))
            alpha = 1.0 - (1.0 - Self.scrollbarRestingAlpha) * fadeProgress
        }

        let originPx = SIMD2<Float>(
            drawableSizePx.x - widthPx,
            thumbYPx)
        let sizePx = SIMD2<Float>(widthPx, thumbHPx)
        var color = Theme.Color.scrollbarThumbLinear
        color.w = 1.0
        let uniforms = OverlayUniforms(
            screenSizePx: drawableSizePx,
            cellOriginPx: originPx,
            cellSizePx: sizePx,
            colorLinear: color,
            kind: OverlayKind.cursorBlock.rawValue,  // kind=0: solid rect
            alpha: alpha,
            cellSpanCols: 1)
        overlay.encode(uniforms: uniforms, encoder: encoder)
    }

    /// I1 bell flash: full-viewport tint quad. Linear fade from
    /// `bellFlashPeakAlpha` to 0 over `bellFlashDurationSec`. No encode
    /// when no flash is in-flight — common path is a no-op.
    func encodeBellFlashOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        guard let started = bellFlashStartTime else { return }
        let elapsed = now() - started
        guard elapsed < Self.bellFlashDurationSec else { return }
        let progress = Float(elapsed / Self.bellFlashDurationSec)
        let alpha = Self.bellFlashPeakAlpha * (1.0 - progress)
        // Use the theme's primary text color as the flash tint —
        // contrasts with the background on both light and dark themes
        // without needing a dedicated theme token.
        var color = resolvedPalette.defaultFgLinear
        color.w = 1.0
        let uniforms = OverlayUniforms(
            screenSizePx: drawableSizePx,
            cellOriginPx: SIMD2<Float>(0, 0),
            cellSizePx: drawableSizePx,
            colorLinear: color,
            kind: OverlayKind.cursorBlock.rawValue,  // kind=0: solid rect
            alpha: alpha,
            cellSpanCols: 1)
        overlay.encode(uniforms: uniforms, encoder: encoder)
    }

    static let bellFlashPeakAlpha: Float = 0.25

    /// M7-2 ⌘F: encode one selection-style overlay quad per visible
    /// search match. Active match uses the accent-running color at full
    /// opacity; others use the same color at reduced alpha so the user
    /// can scan all matches without losing the active anchor.
    func encodeSearchHighlightOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        guard let highlights = searchHighlights else { return }
        for (idx, h) in highlights.spans.enumerated() {
            // Translate alacritty-absolute line → viewport row.
            // viewport spans `[-scrollTop, screen_lines - scrollTop)`.
            let row = h.line + lastScrollTop
            guard row >= 0, row < gridRows,
                h.startCol >= 0, h.startCol < gridCols,
                h.span > 0
            else { continue }
            let span = min(h.span, gridCols - h.startCol)
            let isActive = (idx == highlights.activeIndex)
            var color = Theme.Color.accentRunningLinear
            color.w = isActive ? 0.55 : 0.25
            let originPx = SIMD2<Float>(
                gridOriginPx.x + Float(h.startCol) * cellSizePx.x,
                gridOriginPx.y + Float(row) * cellSizePx.y)
            let uniforms = OverlayUniforms(
                screenSizePx: drawableSizePx,
                cellOriginPx: originPx,
                cellSizePx: cellSizePx,
                colorLinear: color,
                kind: OverlayKind.selection.rawValue,
                alpha: 1.0,
                cellSpanCols: UInt32(span))
            overlay.encode(uniforms: uniforms, encoder: encoder)
        }
    }
}
