// Frame-delta application for `MetalRenderer`, split out of the
// single-file renderer by method cluster: the engine delta drain, the
// run-coalescing region uploads, the CPU-side shadow copy, and the
// cell-slot builders (glyph lookup, colour resolution, grapheme
// decoding). Stored properties live in MetalRenderer.swift because
// extensions cannot declare them.

import AppKit
import CoreText
import Metal
import QuartzCore

extension MetalRenderer {
    /// Out-of-tick mutators of the live cell textures (theme repaint):
    /// wait → mutate → signal immediately. No GPU work is submitted while
    /// the slot is held here; the next draw tick re-acquires it.
    func withCellTextureSlot<T>(_ body: () throws -> T) rethrows -> T {
        frameSlot.wait()
        defer { frameSlot.signal() }
        return try body()
    }

    /// P1: equality on the fields that drive the cursor overlay encode.
    /// `lastCursor` always reflects the latest engine snapshot; the
    /// "encoded" mirror only updates on a successful draw. Any field
    /// change between the two ticks must force a redraw — but updates
    /// that no-op visually (e.g. same position with a flipped reserved
    /// bit, should we add one) shouldn't.
    static func cursorEqual(_ a: CursorState?, _ b: CursorState?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let l?, let r?):
            return l.row == r.row && l.col == r.col
                && l.shape == r.shape && l.blink == r.blink
                && l.hidden == r.hidden
        default: return false
        }
    }

    /// Pull the latest `FrameDelta` from the Rust session, decode the
    /// `cells: Vec<u8>` payload via the zero-copy reader, and apply
    /// engine-driven cells through `pipeline.setRegion`. Called once
    /// per `CAMetalDisplayLink` tick from `draw(update:)` — Swift
    /// calls `take_frame_delta()` synchronously from that callback
    /// (ADR-0006).
    ///
    /// swift-bridge transfers ownership of the `Vec<u8>` allocation per
    /// call: the returned `FrameDelta` carries a Swift-owned `RustVec`
    /// that frees on `deinit`. The Rust-side buffer's lifetime is the
    /// `FrameDelta` value's lifetime — scoped to this function body.
    /// Decoding and application both happen before `frame` drops at
    /// function exit, so the zero-copy `RustVec.as_ptr()` reads are
    /// safe.
    ///
    /// **Region grouping (#57):** decoded cells are sorted by
    /// (row, col) and split into row-contiguous runs. Each run is
    /// pushed through `pipeline.setRegion` as a 1×N rect, collapsing
    /// 3·N `replace(region:)` calls into 3 calls per run. For typical
    /// PTY traffic (a handful of full lines + cursor moves) this is
    /// the dominant per-frame Metal driver cost on the FrameDelta
    /// path; the keystroke spike path (`pendingCellWrites`) keeps
    /// `setCell` since it always carries exactly one cell.
    ///
    /// `makeSlot(from:)` returns `nil` today (Phase 1 stub); the
    /// producer also returns 0 cells, so the inner loop runs zero
    /// times in practice. Both light up at M1 Week 1 task 1.6 (#56).
    @discardableResult
    func applyFrameDelta(pipeline: GridPipeline, atlas: GlyphAtlas) -> Bool {
        guard let session else { return false }
        let frame = session.take_frame_delta()
        // Cursor state is consumed by the Stage-2 overlay encode in
        // `draw(update:)`. Snapshot it BEFORE the decode + apply so a
        // malformed-cells early-return (`decodeCells throws`) can't
        // leave `lastCursor` pinned to a stale visibility state. The
        // engine's `display_offset == 0 && SHOW_CURSOR` gate (see
        // `engine.rs::cursor()`) flips this on every scroll-into-
        // history; without an unconditional refresh the cursor stays
        // drawn at the last live-grid row while the user pages
        // through scrollback.
        self.lastCursor = frame.cursor
        let decoded: [CellDeltaSwift]
        do {
            decoded = try FrameDeltaDecoding.decodeCells(frame.cells)
        } catch {
            NSLog(
                "MetalRenderer: frame delta decode failed: %@",
                String(describing: error))
            return false
        }
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
        // M7-2: cache scroll_top so the search-highlight overlay can
        // translate alacritty-absolute match lines into viewport rows
        // every frame (so highlights track content as the user scrolls
        // without re-running search).
        let scrollChanged =
            self.lastScrollTop != Int(frame.scroll_top)
            || self.lastScrollTotal != Int(frame.scroll_total)
        self.lastScrollTop = Int(frame.scroll_top)
        self.lastScrollTotal = Int(frame.scroll_total)
        if scrollChanged {
            // V1 scrollbar fade: bump activity so the thumb pops back
            // to full opacity. Also any new cell delta counts as
            // "user is scrolled into history and live tail moved"
            // implicitly via the engine's scroll-on-output snap,
            // but only the top/total changes are real scroll events.
            lastScrollActivityTime = now()
        }
        return !decoded.isEmpty || scrollChanged
    }

    /// Apply a decoded cell stream as row-contiguous region writes.
    /// Static + parameterized on `makeSlot` so unit tests can exercise
    /// the grouping logic without instantiating a full renderer.
    ///
    /// Algorithm:
    ///   1. Resolve each `CellDeltaSwift` to a `CellSlot` via `makeSlot`;
    ///      cells that resolve to `nil` (out-of-cascade glyph, malformed
    ///      grapheme) are dropped.
    ///   2. Sort the resolved (row, col, slot) triples by (row, col).
    ///      The Rust producer at #56 writes in row-major scan order, so
    ///      this is typically already-sorted; the sort is a safety net,
    ///      not the hot path.
    ///   3. Walk the sorted list emitting one `setRegion` per maximal
    ///      run of (same row, contiguous col).
    static func applyCellsAsRegions(
        _ decoded: [CellDeltaSwift],
        pipeline: GridPipeline,
        atlas: GlyphAtlas,
        shadow: inout [CellSlot],
        gridCols: Int,
        makeSlot: (CellDeltaSwift) -> CellSlot?
    ) {
        guard !decoded.isEmpty else { return }
        // Pin glyphs resolved this batch so a later cell can't evict an
        // earlier cell's atlas rect mid-frame (CJK/Thai garble).
        atlas.beginResolveBatch()
        var resolved: [(row: Int, col: Int, slot: CellSlot)] = []
        resolved.reserveCapacity(decoded.count)
        for cell in decoded {
            guard let slot = makeSlot(cell) else { continue }
            resolved.append((row: Int(cell.row), col: Int(cell.col), slot: slot))
        }
        guard !resolved.isEmpty else { return }
        Self.writeShadow(resolved, into: &shadow, gridCols: gridCols)
        resolved.sort { lhs, rhs in
            lhs.row != rhs.row ? lhs.row < rhs.row : lhs.col < rhs.col
        }

        // Coalesce maximal (row == prev.row && col == prev.col + 1) runs.
        // `runStart` indexes the first element of the current run,
        // `runEnd` is one-past-the-last (half-open).
        var runStart = 0
        while runStart < resolved.count {
            let start = resolved[runStart]
            var runEnd = runStart + 1
            while runEnd < resolved.count {
                let prev = resolved[runEnd - 1]
                let curr = resolved[runEnd]
                if curr.row == prev.row && curr.col == prev.col + 1 {
                    runEnd += 1
                } else {
                    break
                }
            }
            let width = runEnd - runStart
            var slots: [CellSlot] = []
            slots.reserveCapacity(width)
            for k in runStart..<runEnd {
                slots.append(resolved[k].slot)
            }
            let rect = GridPipeline.GridRect(
                col: start.col, row: start.row, width: width, height: 1)
            do {
                try pipeline.setRegion(
                    rect: rect, slots: slots,
                    atlasSize: GlyphAtlas.atlasSize,
                    colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            } catch {
                // Bounds errors from a misbehaving Rust producer are
                // logged but non-fatal — drop the run and continue;
                // the next frame's setRegion calls re-establish state.
                NSLog(
                    "MetalRenderer.applyCellsAsRegions: setRegion failed for "
                        + "rect=(%d,%d %dx%d): %@",
                    rect.col, rect.row, rect.width, rect.height,
                    String(describing: error))
            }
            runStart = runEnd
        }
    }

    /// ADR-0003 — coalesced-cell variant of
    /// `applyCellsAsRegions`. Each `CoalescedCell` expands to one
    /// primary slot at `(row, col)` carrying the cluster glyph (whose
    /// `AtlasEntry.cellSpan == cellSpan`, so GridPipeline packs the
    /// high byte of `cellAtlasSelector` accordingly) plus `cellSpan-1`
    /// continuation slots at `(row, col+1)..(row, col+cellSpan-1)`
    /// with `glyph = nil` — those pack as selector=0/cellSpan=0, which
    /// the fragment shader treats as continuation-of-primary-to-left.
    ///
    /// Run grouping logic is identical to the `CellDeltaSwift` variant
    /// above (sort by (row, col); emit maximal contiguous runs through
    /// `setRegion`). Primary + continuation cells of a single cluster
    /// land in the same run.
    static func applyCoalescedCellsAsRegions(
        _ coalesced: [CoalescedCell],
        pipeline: GridPipeline,
        atlas: GlyphAtlas,
        shadow: inout [CellSlot],
        gridCols: Int,
        makeSlot: (CoalescedCell) -> CellSlot?
    ) {
        guard !coalesced.isEmpty else { return }
        // Pin glyphs resolved this batch so a later cell can't evict an
        // earlier cell's atlas rect mid-frame (CJK/Thai garble).
        atlas.beginResolveBatch()
        var resolved: [(row: Int, col: Int, slot: CellSlot)] = []
        resolved.reserveCapacity(coalesced.count)
        for cell in coalesced {
            guard let primary = makeSlot(cell) else { continue }
            resolved.append(
                (
                    row: Int(cell.row), col: Int(cell.col), slot: primary
                ))
            // Emit cellSpan-1 continuation cells. Each carries the
            // primary's bg so the cluster row paints a contiguous
            // background; foreground is irrelevant (no glyph). The
            // shader's leftward primary-walk reads the glyph from the
            // primary's selector byte, not from continuations.
            let span = max(UInt8(1), cell.cellSpan)
            if span >= 2 {
                let continuation = CellSlot(
                    glyph: nil,
                    fgColorLinear: primary.fgColorLinear,
                    bgColorLinear: primary.bgColorLinear,
                    attrs: primary.attrs)
                for k in 1..<Int(span) {
                    resolved.append(
                        (
                            row: Int(cell.row),
                            col: Int(cell.col) + k,
                            slot: continuation
                        ))
                }
            }
        }
        guard !resolved.isEmpty else { return }
        Self.writeShadow(resolved, into: &shadow, gridCols: gridCols)
        resolved.sort { lhs, rhs in
            lhs.row != rhs.row ? lhs.row < rhs.row : lhs.col < rhs.col
        }

        var runStart = 0
        while runStart < resolved.count {
            let start = resolved[runStart]
            var runEnd = runStart + 1
            while runEnd < resolved.count {
                let prev = resolved[runEnd - 1]
                let curr = resolved[runEnd]
                if curr.row == prev.row && curr.col == prev.col + 1 {
                    runEnd += 1
                } else {
                    break
                }
            }
            let width = runEnd - runStart
            var slots: [CellSlot] = []
            slots.reserveCapacity(width)
            for k in runStart..<runEnd {
                slots.append(resolved[k].slot)
            }
            let rect = GridPipeline.GridRect(
                col: start.col, row: start.row, width: width, height: 1)
            do {
                try pipeline.setRegion(
                    rect: rect, slots: slots,
                    atlasSize: GlyphAtlas.atlasSize,
                    colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            } catch {
                NSLog(
                    "MetalRenderer.applyCoalescedCellsAsRegions: setRegion "
                        + "failed for rect=(%d,%d %dx%d): %@",
                    rect.col, rect.row, rect.width, rect.height,
                    String(describing: error))
            }
            runStart = runEnd
        }
    }

    /// Mirror resolved (row,col,slot) entries into the CPU-side `cells`
    /// shadow that `encodeTextUnderlineOverlay` (SGR `\e[4m`) and the IME
    /// preedit-restore walk read. The apply path otherwise writes only GPU
    /// textures, leaving the shadow blank (attrs=0) so underline never
    /// renders. Bounds-guarded so a stale delta arriving mid-resize is
    /// skipped, mirroring the tolerant `setRegion` catch above.
    private static func writeShadow(
        _ resolved: [(row: Int, col: Int, slot: CellSlot)],
        into shadow: inout [CellSlot],
        gridCols: Int
    ) {
        guard gridCols > 0 else { return }
        for entry in resolved {
            let idx = entry.row * gridCols + entry.col
            if idx >= 0 && idx < shadow.count {
                shadow[idx] = entry.slot
            }
        }
    }

    /// Engine's 16 compile-time ANSI hex values (matcha palette).
    /// Mirrors `cells.rs::encode_named` order:
    ///   0..7   = normal black/red/green/yellow/blue/magenta/cyan/white
    ///   8..15  = bright variants
    /// Hex stored in packed `R<<24 | G<<16 | B<<8 | 0xff` form so the
    /// override map can key directly on the u32 the renderer reads
    /// off `cell.fg` / `cell.bg`.
    private static let engineAnsiHex: [UInt32] = [
        0x2a34_24ff, 0xd470_70ff, 0xa8cc_8cff, 0xd4c0_78ff,
        0x6898_b0ff, 0xb890_a8ff, 0x70b8_a0ff, 0xc8d0_b8ff,
        0x3a4a_34ff, 0xe888_88ff, 0xb8dc_a0ff, 0xe8d8_90ff,
        0x80b0_c8ff, 0xd0a8_c0ff, 0x88d0_b8ff, 0xd8e0_ccff,
    ]

    static func buildAnsiOverride(
        file: ThemeFile
    ) -> [UInt32: SIMD4<Float>] {
        guard file.ansi.count == 16 else { return [:] }
        var out: [UInt32: SIMD4<Float>] = [:]
        out.reserveCapacity(16)
        for (i, hex) in engineAnsiHex.enumerated() {
            out[hex] = file.ansi[i]
        }
        return out
    }

    func makeSlot(from cell: CellDeltaSwift, atlas: GlyphAtlas) -> CellSlot? {
        Self.makeSlot(
            from: cell,
            atlas: atlas,
            commandQueue: commandQueue,
            palette: resolvedPalette,
            ansiOverride: ansiOverride,
            onAtlasMiss: { [weak self] scalar, error in
                self?.logMissingGlyphOnce(scalar: scalar, error: error)
            })
    }

    /// Pick the styled atlas entry for a (scalar, attrs) pair.
    /// Branches on alacritty `Flags::BOLD` (0x0002) / `Flags::ITALIC`
    /// (0x0004); plain text takes the unstyled fast path so the
    /// per-cell cost stays the same as pre-styled-text.
    static func lookupGlyph(
        scalar: Unicode.Scalar,
        attrs: UInt16,
        atlas: GlyphAtlas,
        commandQueue: MTLCommandQueue
    ) throws -> AtlasEntry {
        let bold = (attrs & 0x0002) != 0
        let italic = (attrs & 0x0004) != 0
        if !bold && !italic {
            return try atlas.entry(for: scalar, commandQueue: commandQueue)
        }
        let font = atlas.styledFont(bold: bold, italic: italic)
        return try atlas.entry(
            for: scalar, font: font, commandQueue: commandQueue)
    }

    /// Test-friendly static variant. Pure logic — no `self` capture, so
    /// `MetalRendererSGRColorTests` can drive it without standing up a
    /// renderer (which requires a window + display link). The instance
    /// method above is the production caller.
    ///
    /// Returns `Optional<CellSlot>` to fit the existing
    /// `applyCellsAsRegions` makeSlot closure signature, but the body
    /// here NEVER returns nil — even atlas-miss paths return a blank
    /// slot. Once 4.3 lands the closure signature can drop the optional.
    static func makeSlot(
        from cell: CellDeltaSwift,
        atlas: GlyphAtlas,
        commandQueue: MTLCommandQueue,
        palette: Theme.Palette,
        ansiOverride: [UInt32: SIMD4<Float>] = [:],
        onAtlasMiss: ((Unicode.Scalar, Error) -> Void)? = nil
    ) -> CellSlot? {
        var fg = resolveColor(
            packed: cell.fg, sentinel: 0xffff_ffff,
            fallback: palette.defaultFgLinear,
            override: ansiOverride)
        var bg = resolveColor(
            packed: cell.bg, sentinel: 0x0000_00ff,
            fallback: palette.defaultBgLinear,
            override: ansiOverride)

        // INVERSE (alacritty `Flags::INVERSE` = bit 0, value 0x0001)
        // swaps fg/bg. TUIs (Claude Code, vim selection, less status
        // line) draw their cursors and selections via `\e[7m` — without
        // this swap those reads as plain unstyled text.
        if (cell.attrs & 0x0001) != 0 {
            swap(&fg, &bg)
        }

        guard let clusterString = decodeGraphemeString(cell.grapheme),
            let scalar = clusterString.unicodeScalars.first
        else {
            // All-zero grapheme — engine emits this for blank cells
            // populated by the default empty-cell template. Paint bg
            // only; no glyph lookup.
            return CellSlot(glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        }

        // Fast path: ASCII space renders pure background. Skips the
        // atlas lookup entirely (it would resolve to a blank glyph
        // anyway, but no point burning the CoreText path on it).
        if clusterString.unicodeScalars.count == 1, scalar.value == 0x20 {
            return CellSlot(glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        }

        // Multi-codepoint grapheme cluster (Thai base + tone mark,
        // Devanagari + matra, Hangul jamo, emoji ZWJ sequences):
        // route through CTLine so CoreText applies shaping + mark
        // positioning. Single-scalar grapheme stays on the fast path.
        if clusterString.unicodeScalars.count > 1 {
            do {
                let entry = try atlas.entry(
                    forCluster: clusterString, commandQueue: commandQueue)
                return CellSlot(
                    glyph: entry, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
            } catch {
                onAtlasMiss?(scalar, error)
                return CellSlot(
                    glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
            }
        }

        do {
            let entry = try lookupGlyph(
                scalar: scalar, attrs: cell.attrs, atlas: atlas,
                commandQueue: commandQueue)
            return CellSlot(glyph: entry, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        } catch {
            onAtlasMiss?(scalar, error)
            return CellSlot(glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        }
    }

    /// ADR-0003 — resolve a `CoalescedCell` (coalescer output)
    /// to a `CellSlot` for the primary cell. Continuation cells are
    /// emitted separately as `slot.glyph = nil` so they pack as
    /// selector=0 / cellSpan=0 (continuation sentinel per atomic 3).
    ///
    /// Routing:
    ///   - `cellSpan >= 2`  → cluster atlas slot rasterized at
    ///     `cellSpan * cellW` wide via `entry(forCluster:cellSpan:)`.
    ///   - `cellSpan == 1` multi-scalar → existing cluster path (span=1).
    ///   - `cellSpan == 1` single-scalar → fast scalar atlas path.
    func makeSlot(
        from cell: CoalescedCell, atlas: GlyphAtlas
    ) -> CellSlot? {
        Self.makeSlot(
            from: cell,
            atlas: atlas,
            commandQueue: commandQueue,
            palette: resolvedPalette,
            ansiOverride: ansiOverride,
            onAtlasMiss: { [weak self] scalar, error in
                self?.logMissingGlyphOnce(scalar: scalar, error: error)
            })
    }

    /// Test-friendly static variant for the coalesced-cell slot. Mirrors
    /// the `CellDeltaSwift` static above; pure logic so unit tests can
    /// drive it without a live renderer.
    static func makeSlot(
        from cell: CoalescedCell,
        atlas: GlyphAtlas,
        commandQueue: MTLCommandQueue,
        palette: Theme.Palette,
        ansiOverride: [UInt32: SIMD4<Float>] = [:],
        onAtlasMiss: ((Unicode.Scalar, Error) -> Void)? = nil
    ) -> CellSlot? {
        var fg = resolveColor(
            packed: cell.fg, sentinel: 0xffff_ffff,
            fallback: palette.defaultFgLinear,
            override: ansiOverride)
        var bg = resolveColor(
            packed: cell.bg, sentinel: 0x0000_00ff,
            fallback: palette.defaultBgLinear,
            override: ansiOverride)
        if (cell.attrs & 0x0001) != 0 {
            swap(&fg, &bg)
        }

        let clusterString = cell.grapheme
        guard let scalar = clusterString.unicodeScalars.first else {
            return CellSlot(glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        }
        if clusterString.unicodeScalars.count == 1,
            scalar.value == 0x20, cell.cellSpan <= 1
        {
            return CellSlot(glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        }

        let span = max(UInt8(1), cell.cellSpan)
        // Multi-cell cluster or multi-scalar grapheme → cluster atlas.
        if span >= 2 || clusterString.unicodeScalars.count > 1 {
            do {
                let entry = try atlas.entry(
                    forCluster: clusterString,
                    cellSpan: span,
                    commandQueue: commandQueue)
                return CellSlot(
                    glyph: entry, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
            } catch {
                onAtlasMiss?(scalar, error)
                return CellSlot(
                    glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
            }
        }

        // Single-scalar, single-cell: fast scalar atlas path.
        do {
            let entry = try lookupGlyph(
                scalar: scalar, attrs: cell.attrs, atlas: atlas,
                commandQueue: commandQueue)
            return CellSlot(glyph: entry, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        } catch {
            onAtlasMiss?(scalar, error)
            return CellSlot(glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        }
    }

    /// Decode the full UTF-8 grapheme buffer to a Swift String, trimming
    /// trailing nulls. Returns `nil` on all-zero/malformed input.
    /// Used by both the single-scalar and the cluster atlas paths.
    static func decodeGraphemeString(_ grapheme: [UInt8]) -> String? {
        var end = grapheme.count
        for (i, byte) in grapheme.enumerated() where byte == 0 {
            end = i
            break
        }
        guard end > 0 else { return nil }
        return String(bytes: grapheme.prefix(end), encoding: .utf8)
    }

    /// Resolve a packed RGBA8 color (engine `pack_rgba` layout) to a
    /// linear-space `SIMD4<Float>`. Sentinels (`0xffff_ffff` foreground,
    /// `0x0000_00ff` background — see `cells.rs:224-225`) bypass the
    /// LUT and use the active palette's default. Any other value goes
    /// through `SRGBLinearLUT.unpackLinear` for the sRGB→linear
    /// conversion.
    @inline(__always)
    static func resolveColor(
        packed: UInt32, sentinel: UInt32, fallback: SIMD4<Float>,
        override: [UInt32: SIMD4<Float>] = [:]
    ) -> SIMD4<Float> {
        if packed == sentinel { return fallback }
        // Theme-file ANSI override: cells the engine baked with its
        // compile-time encode_named values get redirected to the
        // user's theme-file palette. Truecolor SGR (`38;2;r;g;b`)
        // values almost never collide with the 16 named hexes so
        // this is safe in practice.
        if let mapped = override[packed] {
            return mapped
        }
        return SRGBLinearLUT.unpackLinear(packed)
    }

    /// Pin the `CURSOR_SHAPE_*` u8 → `OverlayKind` mapping. Static so
    /// `OverlayPipelineTests` can drive it without instantiating a
    /// renderer.
    static func cursorKind(forShape shape: UInt8) -> OverlayKind {
        switch shape {
        case 0: return .cursorBlock  // CURSOR_SHAPE_BLOCK
        case 1: return .cursorBeam  // CURSOR_SHAPE_BEAM
        case 2: return .cursorUnderline  // CURSOR_SHAPE_UNDERLINE
        default: return .cursorBlock  // unknown shape → safe default
        }
    }

    /// Decode the first `Unicode.Scalar` from a UTF-8 grapheme buffer.
    /// `cell.grapheme` is fixed-size 8 bytes, null-padded; we trim
    /// trailing zeros and run String's UTF-8 decoder. Returns nil on
    /// all-zero or malformed input — caller renders bg-only.
    static func firstScalar(in grapheme: [UInt8]) -> Unicode.Scalar? {
        // Find the first null terminator; everything after is padding.
        var end = grapheme.count
        for (i, byte) in grapheme.enumerated() where byte == 0 {
            end = i
            break
        }
        guard end > 0 else { return nil }
        // Decode the prefix as UTF-8. Single multi-byte scalars (BMP +
        // astrals) decode here in one step; clusters return their first
        // scalar and the atlas handles the BMP-only path.
        let bytes = grapheme.prefix(end)
        if let s = String(bytes: bytes, encoding: .utf8), let first = s.unicodeScalars.first {
            return first
        }
        return nil
    }

    private func logMissingGlyphOnce(scalar: Unicode.Scalar, error: Error) {
        guard loggedMissingScalars.count < Self.loggedMissingCap else { return }
        if loggedMissingScalars.insert(scalar.value).inserted {
            NSLog(
                "MetalRenderer.makeSlot: atlas miss for U+%04X (%@) — %@",
                scalar.value, String(scalar), String(describing: error))
        }
    }
}
