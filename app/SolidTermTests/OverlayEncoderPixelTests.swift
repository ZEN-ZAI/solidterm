// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Pixel-level characterization of the eight overlay encoders on
// `MetalRenderer`, added ahead of the renderer split (hygiene ticket 08,
// spec D10) so the move of these methods into
// `MetalRenderer+Overlays.swift` has a behavioural net under it.
//
// Each test drives one encoder against the shared `MetalOffscreenHarness`
// on a deliberately tiny grid — 8 x 4 cells of 10 x 20 px, grid origin
// (0, 0), an 80 x 80 px target — reads the pixels back and asserts two
// things: the cell(s) the encoder should have painted carry the overlay
// colour composited over the clear colour, and a neighbouring cell is
// still exactly the clear colour.
//
// Where the expected values come from, so these stay tests rather than
// restatements of the code:
//
//   - Geometry (which cell, which band inside it) is written as explicit
//     pixel coordinates derived from the grid above and from the bands
//     the MSL `overlay_fragment` documents: bottom 15 % for kind 3/4,
//     bottom 8 % for kind 5, left 12 % for kind 1.
//   - Alphas are literals, because they are the contract: selection tints
//     at 0.55, search matches at 0.55 active / 0.25 inactive, the bell
//     peaks at 0.25, the scrollbar is solid inside its post-activity hold.
//     A change to any of them is a change in behaviour and should fail here.
//   - Colours are read from the theme tokens the encoders read, because a
//     palette edit is not a behaviour change and should not fail here. Where
//     the caller supplies the colour instead (the cursor state, an SGR run's
//     foreground) the test passes a synthetic one, so the assert still fails
//     if the encoder substitutes a default of its own.
//
// The composite itself is source-over straight alpha, per the blend state
// `OverlayPipeline` sets: `dst = src.rgb * a + dst.rgb * (1 - a)`.
//
// The clear colour is a non-grey (64, 26, 13) whose channels are exact
// 1/255 multiples: no rounding slack in the "unpainted" baseline, and a
// channel swap anywhere in the pipeline shows up as a failure.

import AppKit
import Metal
import XCTest

@testable import SolidTerm

@MainActor
final class OverlayEncoderPixelTests: XCTestCase {

    // MARK: - Fixture geometry

    private static let cols = 8
    private static let rows = 4
    private static let cellW: Float = 10
    private static let cellH: Float = 20
    private static let widthPx = 80
    private static let heightPx = 80

    private static let drawableSizePx = SIMD2<Float>(Float(widthPx), Float(heightPx))
    private static let cellSizePx = SIMD2<Float>(cellW, cellH)
    private static let gridOriginPx = SIMD2<Float>(0, 0)

    /// Clear colour as bytes and as the 0...1 floats the render pass takes.
    private static let clearBytes = SIMD3<UInt8>(64, 26, 13)
    private static let clearLinear = SIMD3<Float>(64.0 / 255.0, 26.0 / 255.0, 13.0 / 255.0)

    /// ±2/255 per the ticket: enough for the GPU's rounding of the
    /// source-over composite, tight enough that a wrong alpha fails.
    private static let tolerance: UInt8 = 2

    private var device: MTLDevice!
    private var renderer: MetalRenderer!
    private var overlay: OverlayPipeline!
    private var harness: MetalOffscreenHarness!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        renderer = MetalRenderer(device: device)
        // The renderer's own overlay pipeline is built for
        // `.bgra8Unorm_srgb`; the harness renders into `.rgba8Unorm` so
        // linear colours read back as the bytes the shader wrote. The
        // encoders take the pipeline as a parameter for exactly this.
        overlay = try OverlayPipeline(device: device, pixelFormat: .rgba8Unorm)
        harness = try MetalOffscreenHarness(
            device: device, widthPx: Self.widthPx, heightPx: Self.heightPx,
            clear: MTLClearColor(
                red: Double(Self.clearLinear.x),
                green: Double(Self.clearLinear.y),
                blue: Double(Self.clearLinear.z),
                alpha: 1))
        // Production seam for grid dimensions: also re-blanks `cells` at
        // 8 x 4, which the text-underline test writes into.
        renderer.resizeGrid(cols: Self.cols, rows: Self.rows)
    }

    override func tearDown() {
        harness = nil
        overlay = nil
        renderer = nil
        device = nil
    }

    // MARK: - Helpers

    /// Centre pixel of a grid cell.
    private func centre(col: Int, row: Int) -> (x: Int, y: Int) {
        (
            x: col * Int(Self.cellW) + Int(Self.cellW) / 2,
            y: row * Int(Self.cellH) + Int(Self.cellH) / 2
        )
    }

    /// A pixel inside the bottom underline band of a cell. The band is the
    /// bottom 15 % (kinds 3 / 4) or bottom 8 % (kind 5) of a 20 px cell;
    /// row 19 — the last pixel row — is inside both.
    private func bottomBand(col: Int, row: Int) -> (x: Int, y: Int) {
        (
            x: col * Int(Self.cellW) + Int(Self.cellW) / 2,
            y: row * Int(Self.cellH) + Int(Self.cellH) - 1
        )
    }

    /// Source-over straight alpha against the clear colour, as bytes.
    /// `alpha` is the composite's source alpha — the product of the
    /// uniform's `colorLinear.a` and its `alpha` field, which the encoders
    /// set independently — so each caller states the one number it means.
    private func composited(_ color: SIMD4<Float>, alpha: Float) -> SIMD3<UInt8> {
        func channel(_ src: Float, _ dst: Float) -> UInt8 {
            UInt8(max(0, min(255, (src * alpha + dst * (1 - alpha)) * 255 + 0.5)))
        }
        return SIMD3<UInt8>(
            channel(color.x, Self.clearLinear.x),
            channel(color.y, Self.clearLinear.y),
            channel(color.z, Self.clearLinear.z))
    }

    private func assertPainted(
        _ pixels: PixelBuffer, _ point: (x: Int, y: Int), _ expected: SIMD3<UInt8>,
        _ label: String, file: StaticString = #file, line: UInt = #line
    ) {
        pixels.assertCellColor(
            x: point.x, y: point.y, expected, tolerance: Self.tolerance, label,
            file: file, line: line)
    }

    /// Tolerance 0, not `Self.tolerance`: the ±2 slack exists for pixels the
    /// blend rounded, and nothing blended here. An unpainted pixel still
    /// holds the exact bytes the clear wrote.
    private func assertClear(
        _ pixels: PixelBuffer, _ point: (x: Int, y: Int), _ label: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        pixels.assertCellColor(
            x: point.x, y: point.y, Self.clearBytes, tolerance: 0, label,
            file: file, line: line)
    }

    /// /bin/cat at the fixture's grid size — the deterministic-echo child
    /// the rest of the suite uses. Attached through the renderer's test
    /// seam so `encodeSelectionOverlay` finds a session to read.
    private static func makeSession() -> TerminalSession {
        let envPayload = "TERM=xterm-256color\nLANG=en_US.UTF-8\n"
        let envVec = RustVec<UInt8>()
        for byte in envPayload.utf8 { envVec.push(value: byte) }
        let config = SessionConfig(
            rows: UInt16(rows),
            cols: UInt16(cols),
            pixel_w: 0,
            pixel_h: 0,
            command: "/bin/cat".intoRustString(),
            cwd: "/tmp".intoRustString(),
            env: envVec,
            scrollback_lines: 0)
        // Force-unwrap: a /bin/cat spawn must succeed in the test env.
        return TerminalSession.new(config)!
    }

    // MARK: - 1. Selection

    /// A one-row drag over columns 2...5 tints exactly those cells with
    /// the theme's selection colour at `selectionAlpha`.
    func testSelectionOverlayTintsTheDraggedSpan() throws {
        let session = Self.makeSession()
        renderer.attachSessionForTesting(session)
        session.start_selection(TerminalSurfaceView.SELECTION_MODE_SIMPLE, 1, 2)
        session.update_selection(1, 5)
        XCTAssertEqual(session.selection_span().len(), 5, "session must report a live span")

        let pixels = try harness.render { encoder in
            renderer.encodeSelectionOverlay(
                encoder: encoder,
                drawableSizePx: Self.drawableSizePx,
                cellSizePx: Self.cellSizePx,
                gridOriginPx: Self.gridOriginPx,
                overlay: overlay)
        }

        let tint = composited(renderer.resolvedSelection, alpha: 0.55)
        assertPainted(pixels, centre(col: 2, row: 1), tint, "selection: first selected cell")
        assertPainted(pixels, centre(col: 5, row: 1), tint, "selection: last selected cell")
        assertClear(pixels, centre(col: 1, row: 1), "selection: cell left of the span")
        assertClear(pixels, centre(col: 6, row: 1), "selection: cell right of the span")
        assertClear(pixels, centre(col: 3, row: 0), "selection: row above the span")
    }

    // MARK: - 2. Cursor

    /// BEAM lights the left 12 % of its cell; UNDERLINE the bottom 15 %.
    /// BLOCK draws nothing here — the grid pass reverse-videos it — and
    /// neither does a nil state.
    func testCursorOverlayDrawsBeamAndUnderlineButNotBlock() throws {
        func render(_ state: MetalRenderer.CursorBlockState?) throws -> PixelBuffer {
            try harness.render { encoder in
                renderer.encodeCursorOverlay(
                    state: state,
                    encoder: encoder,
                    drawableSizePx: Self.drawableSizePx,
                    cellSizePx: Self.cellSizePx,
                    gridOriginPx: Self.gridOriginPx,
                    overlay: overlay)
            }
        }
        // Synthetic, deliberately not `Theme.Color.cursorDefaultLinear`: the
        // encoder must carry *this* colour through from `state.color`, and an
        // assert pinned to the renderer's own default could not tell the
        // difference if it substituted one.
        let color = SIMD4<Float>(0.15, 0.85, 0.45, 1.0)
        func state(_ kind: OverlayKind, alpha: Float) -> MetalRenderer.CursorBlockState {
            MetalRenderer.CursorBlockState(
                col: 3, row: 1, kind: kind, color: color, alpha: alpha)
        }

        // Beam at full blink phase: only the cell's first pixel column.
        let beam = try render(state(.cursorBeam, alpha: 1.0))
        assertPainted(
            beam, (x: 30, y: 30), composited(color, alpha: 1.0), "beam: cell's left edge")
        assertClear(beam, (x: 33, y: 30), "beam: cell's interior")
        assertClear(beam, centre(col: 2, row: 1), "beam: neighbouring cell")

        // Underline at a mid-blink phase: the uniform alpha rides through
        // to the composite, so half-faded is half-blended.
        let underline = try render(state(.cursorUnderline, alpha: 0.5))
        assertPainted(
            underline, bottomBand(col: 3, row: 1), composited(color, alpha: 0.5),
            "underline: bottom band")
        assertClear(underline, centre(col: 3, row: 1), "underline: cell's middle")
        assertClear(underline, bottomBand(col: 2, row: 1), "underline: neighbouring cell")

        // Block is the grid pass's job, and nil means no cursor at all.
        let block = try render(state(.cursorBlock, alpha: 1.0))
        assertClear(block, centre(col: 3, row: 1), "block: not drawn by the overlay pass")
        let none = try render(nil)
        assertClear(none, centre(col: 3, row: 1), "nil state: nothing drawn")
    }

    // MARK: - 3. IME underline

    /// One underline quad per preedit scalar, starting at the cursor cell.
    func testImeUnderlineOverlayMarksOneCellPerPreeditScalar() throws {
        let view = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.setMarkedText(
            "abc",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNotNil(view.activeComposition, "composition must be live before the encode")
        renderer.attachHostView(view)
        renderer.lastCursor = CursorState(row: 2, col: 1, shape: 0, blink: false, hidden: false)

        // `hostView` is weak, so the encode has to happen while this
        // scope still holds the only strong reference to the view.
        let pixels = try withExtendedLifetime(view) {
            try harness.render { encoder in
                renderer.encodeImeUnderlineOverlay(
                    encoder: encoder,
                    drawableSizePx: Self.drawableSizePx,
                    cellSizePx: Self.cellSizePx,
                    gridOriginPx: Self.gridOriginPx,
                    overlay: overlay)
            }
        }

        let mark = composited(Theme.Color.imeUnderlineLinear, alpha: 1.0)
        for col in 1...3 {
            assertPainted(pixels, bottomBand(col: col, row: 2), mark, "ime: preedit cell \(col)")
        }
        assertClear(pixels, bottomBand(col: 0, row: 2), "ime: cell before the preedit")
        assertClear(pixels, bottomBand(col: 4, row: 2), "ime: cell after the preedit")
        assertClear(pixels, centre(col: 2, row: 2), "ime: above the underline band")
    }

    // MARK: - 4. Link underline

    /// `linkHover` underlines one row of `span` cells in the link tint.
    func testLinkUnderlineOverlayCoversTheHoveredSpan() throws {
        renderer.linkHover = MetalRenderer.LinkHover(row: 1, startCol: 2, span: 3)

        let pixels = try harness.render { encoder in
            renderer.encodeLinkUnderlineOverlay(
                encoder: encoder,
                drawableSizePx: Self.drawableSizePx,
                cellSizePx: Self.cellSizePx,
                gridOriginPx: Self.gridOriginPx,
                overlay: overlay)
        }

        let mark = composited(Theme.Color.linkUnderlineLinear, alpha: 1.0)
        assertPainted(pixels, bottomBand(col: 2, row: 1), mark, "link: first hovered cell")
        assertPainted(pixels, bottomBand(col: 4, row: 1), mark, "link: last hovered cell")
        assertClear(pixels, bottomBand(col: 1, row: 1), "link: cell before the span")
        assertClear(pixels, bottomBand(col: 5, row: 1), "link: cell after the span")
        assertClear(pixels, centre(col: 3, row: 1), "link: above the underline band")
    }

    // MARK: - 5. SGR text underline

    /// Cells carrying alacritty's UNDERLINE flag coalesce into one run,
    /// tinted with the run's foreground colour.
    func testTextUnderlineOverlayPaintsTheUnderlinedRun() throws {
        let runFg = SIMD4<Float>(0.9, 0.2, 0.6, 1.0)
        let underlineFlag: UInt16 = 0x0008
        XCTAssertEqual(
            renderer.cells.count, Self.cols * Self.rows,
            "resizeGrid must have re-blanked the shadow grid")
        for col in 1...3 {
            let idx = 2 * Self.cols + col
            renderer.cells[idx].attrs |= underlineFlag
            renderer.cells[idx].fgColorLinear = runFg
        }

        let pixels = try harness.render { encoder in
            renderer.encodeTextUnderlineOverlay(
                encoder: encoder,
                drawableSizePx: Self.drawableSizePx,
                cellSizePx: Self.cellSizePx,
                gridOriginPx: Self.gridOriginPx,
                overlay: overlay)
        }

        let mark = composited(runFg, alpha: 1.0)
        assertPainted(pixels, bottomBand(col: 1, row: 2), mark, "text underline: run start")
        assertPainted(pixels, bottomBand(col: 3, row: 2), mark, "text underline: run end")
        assertClear(pixels, bottomBand(col: 0, row: 2), "text underline: cell before the run")
        assertClear(pixels, bottomBand(col: 4, row: 2), "text underline: cell after the run")
        assertClear(pixels, bottomBand(col: 2, row: 1), "text underline: row above the run")
        assertClear(pixels, centre(col: 2, row: 2), "text underline: above the band")
    }

    // MARK: - 6. Scrollbar

    /// The thumb hugs the right edge and slides with `lastScrollTop`:
    /// bottom at the live tail, top at the oldest history.
    func testScrollbarOverlayThumbTracksScrollTop() throws {
        // Freeze the clock at the activity timestamp so the fade is inside
        // its hold window and the thumb renders solid.
        renderer.now = { 0 }
        renderer.lastScrollTotal = 40

        func render(scrollTop: Int) throws -> PixelBuffer {
            renderer.lastScrollTop = scrollTop
            return try harness.render { encoder in
                renderer.encodeScrollbarOverlay(
                    encoder: encoder,
                    drawableSizePx: Self.drawableSizePx,
                    cellSizePx: Self.cellSizePx,
                    gridOriginPx: Self.gridOriginPx,
                    overlay: overlay)
            }
        }

        let solid = composited(Theme.Color.scrollbarThumbLinear, alpha: 1.0)
        // 8 px resting width against an 80 px drawable → x ∈ [72, 80).
        // Track is the 80 px viewport, thumb clamps to its 24 px minimum.
        let inThumbX = 76
        let leftOfStrip = 60

        // Live tail: thumb at the bottom of the track, y ∈ [56, 80).
        let tail = try render(scrollTop: 0)
        assertPainted(tail, (x: inThumbX, y: 70), solid, "scrollbar: thumb at the tail")
        assertClear(tail, (x: inThumbX, y: 10), "scrollbar: track above the tail thumb")
        assertClear(tail, (x: leftOfStrip, y: 70), "scrollbar: left of the strip")

        // Oldest history: thumb at the top of the track, y ∈ [0, 24).
        let top = try render(scrollTop: 40)
        assertPainted(top, (x: inThumbX, y: 10), solid, "scrollbar: thumb at oldest history")
        assertClear(top, (x: inThumbX, y: 70), "scrollbar: track below the raised thumb")

        // No history worth a thumb: nothing drawn at all.
        renderer.lastScrollTotal = 0
        let hidden = try render(scrollTop: 0)
        assertClear(hidden, (x: inThumbX, y: 70), "scrollbar: hidden without scrollback")
    }

    // MARK: - 7. Bell flash

    /// Full-viewport tint at the flash's peak alpha, gone once the
    /// duration has elapsed.
    func testBellFlashOverlayFadesOutOverItsDuration() throws {
        let started: CFTimeInterval = 100
        renderer.bellFlashStartTime = started

        func render(at now: CFTimeInterval) throws -> PixelBuffer {
            renderer.now = { now }
            return try harness.render { encoder in
                renderer.encodeBellFlashOverlay(
                    encoder: encoder,
                    drawableSizePx: Self.drawableSizePx,
                    overlay: overlay)
            }
        }

        let peak = composited(renderer.resolvedPalette.defaultFgLinear, alpha: 0.25)

        // 0 % of the duration: the whole viewport carries the peak tint.
        let onset = try render(at: started)
        assertPainted(onset, centre(col: 0, row: 0), peak, "bell: top-left of the viewport")
        assertPainted(onset, centre(col: 7, row: 3), peak, "bell: bottom-right of the viewport")

        // 100 %: the encoder drops the quad entirely.
        let over = try render(at: started + MetalRenderer.bellFlashDurationSec)
        assertClear(over, centre(col: 0, row: 0), "bell: top-left after the flash")
        assertClear(over, centre(col: 7, row: 3), "bell: bottom-right after the flash")

        // No flash in flight is the common path and draws nothing.
        renderer.bellFlashStartTime = nil
        let idle = try render(at: started)
        assertClear(idle, centre(col: 4, row: 2), "bell: no flash in flight")
    }

    // MARK: - 8. Search highlights

    /// The active match tints at 0.55, the others at 0.25, and each span
    /// lands on `line + lastScrollTop`.
    func testSearchHighlightOverlaySeparatesActiveFromInactive() throws {
        renderer.lastScrollTop = 0
        renderer.searchHighlights = MetalRenderer.SearchHighlights(
            spans: [
                .init(line: 0, startCol: 1, span: 2),
                .init(line: 3, startCol: 5, span: 2),
            ],
            activeIndex: 1)

        let pixels = try harness.render { encoder in
            renderer.encodeSearchHighlightOverlay(
                encoder: encoder,
                drawableSizePx: Self.drawableSizePx,
                cellSizePx: Self.cellSizePx,
                gridOriginPx: Self.gridOriginPx,
                overlay: overlay)
        }

        let accent = Theme.Color.accentRunningLinear
        let active = composited(accent, alpha: 0.55)
        let inactive = composited(accent, alpha: 0.25)
        assertPainted(pixels, centre(col: 5, row: 3), active, "search: active match")
        assertPainted(pixels, centre(col: 6, row: 3), active, "search: active match, second cell")
        assertPainted(pixels, centre(col: 1, row: 0), inactive, "search: inactive match")
        assertClear(pixels, centre(col: 3, row: 0), "search: unmatched cell on the same row")
        assertClear(pixels, centre(col: 4, row: 3), "search: cell before the active match")
    }
}
