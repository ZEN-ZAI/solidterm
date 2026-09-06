// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Verifies M1 Week 4 task 4.1: 24-bit + 256-indexed + named SGR color
// rendering. Drives `MetalRenderer.makeSlot` (the static, test-friendly
// variant) end-to-end and confirms:
//
//   1. Packed RGBA8 fg/bg → linear `SIMD4<Float>` matches the
//      closed-form sRGB transfer function.
//   2. The two `NamedColor` sentinels (`0xffff_ffff` / `0x0000_00ff`)
//      resolve to `Theme.Color.textPrimaryLinear` /
//      `Theme.Color.bgBaseLinear`, NOT to a literal sRGB unpack of the
//      bit pattern.
//   3. The `SRGBLinearLUT` table matches the closed-form formula at
//      sampled byte values — guards against drift between the
//      reference helper and the precomputed table.
//   4. Blank graphemes (space, all-zero) return a `CellSlot` with
//      `glyph == nil` rather than the previous `nil` Optional — the
//      regression guard against the original stub's drop-cell behavior
//      that left stale texture content.

import CoreText
import Metal
import XCTest
import simd

@testable import SolidTerm

final class MetalRendererSGRColorTests: XCTestCase {

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var atlas: GlyphAtlas!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 14, nil)
        atlas = try GlyphAtlas(device: device, font: font, contentsScale: 2.0)
    }

    override func tearDown() {
        atlas = nil
        queue = nil
        device = nil
    }

    // MARK: - Color decoding

    /// `pack_rgba(0x12, 0x34, 0x56)` from `cells.rs:214` →
    /// `0x12 << 24 | 0x34 << 16 | 0x56 << 8 | 0xff = 0x123456_ff`.
    /// Each channel goes through the standard sRGB transfer; alpha
    /// stays straight.
    func testDecodes24BitSpecColor() throws {
        let packed: UInt32 = 0x1234_56ff
        let cell = makeCell(fg: packed, bg: 0x0000_00ff)
        let slot = try XCTUnwrap(invokeMakeSlot(cell))

        let r = SRGBLinearLUT.referenceLinear(forByte: 0x12)
        let g = SRGBLinearLUT.referenceLinear(forByte: 0x34)
        let b = SRGBLinearLUT.referenceLinear(forByte: 0x56)
        assertSIMDClose(slot.fgColorLinear, SIMD4<Float>(r, g, b, 1.0), tol: 1e-5)
    }

    /// xterm palette index 9 (BrightRed) packs as `pack_rgba(0xff, 0x00,
    /// 0x00)` = `0xff0000_ff`. Pure-saturated channels through the sRGB
    /// transfer are also pure in linear space (1.0/0.0/0.0).
    func testDecodesIndexedColor() throws {
        let packed: UInt32 = 0xff00_00ff
        let cell = makeCell(fg: packed, bg: 0x0000_00ff)
        let slot = try XCTUnwrap(invokeMakeSlot(cell))

        assertSIMDClose(
            slot.fgColorLinear,
            SIMD4<Float>(1.0, 0.0, 0.0, 1.0),
            tol: 1e-6)
    }

    func testResolvesDefaultFgSentinel() throws {
        let cell = makeCell(fg: 0xffff_ffff, bg: 0x0000_00ff)
        let slot = try XCTUnwrap(invokeMakeSlot(cell))
        assertSIMDClose(
            slot.fgColorLinear,
            Theme.Color.textPrimaryLinear,
            tol: 1e-6)
    }

    func testResolvesDefaultBgSentinel() throws {
        let cell = makeCell(fg: 0xffff_ffff, bg: 0x0000_00ff)
        let slot = try XCTUnwrap(invokeMakeSlot(cell))
        assertSIMDClose(
            slot.bgColorLinear,
            Theme.Color.bgBaseLinear,
            tol: 1e-6)
    }

    /// Defends against the trap where `0x0000_00ff` (background
    /// sentinel) gets incorrectly literally-decoded as
    /// `(R=0, G=0, B=0, A=1)`. The Ghostty default `bg-base` is
    /// `#282c34` — a non-black grey — so a literal decode would
    /// produce R=G=B=0, distinguishable from the theme value.
    /// (Foreground sentinel + Ghostty `text-primary #ffffff` would
    /// collapse with the literal decode, so we use the bg path.)
    func testBackgroundSentinelDoesNotCollideWithLiteralDecode() throws {
        let cell = makeCell(fg: 0xffff_ffff, bg: 0x0000_00ff)
        let slot = try XCTUnwrap(invokeMakeSlot(cell))
        // Theme.Color.bgBaseLinear is #282c34 → linear non-zero.
        // Literal decode would be (0, 0, 0, 1). Verify theme value.
        // zenzai-v2 bg `#0f0f12` is dim — pin against 0.003 (linear of
        // 0x0f ≈ 0.0056) rather than the prior 0.005.
        XCTAssertGreaterThan(
            slot.bgColorLinear.x, 0.003, "bg.R should be theme #0f, not literal 0x00")
        XCTAssertGreaterThan(
            slot.bgColorLinear.y, 0.003, "bg.G should be theme #0f, not literal 0x00")
        XCTAssertGreaterThan(
            slot.bgColorLinear.z, 0.003, "bg.B should be theme #12, not literal 0x00")
    }

    // MARK: - sRGB LUT integrity

    /// `\e[7m` (SGR 7 — reverse video) sets alacritty `Flags::INVERSE`
    /// (bit 0, value 0x0001). The renderer must swap fg ↔ bg so the
    /// cell paints with inverted colors. TUIs (Claude Code's drawn
    /// cursor, vim selection, less status line) rely on this; without
    /// the swap inverse cells render as plain unstyled text.
    func testInverseAttrSwapsFgAndBg() throws {
        // fg=red, bg=blue truecolor, INVERSE bit set.
        let cell = makeCell(
            fg: 0xff00_00ff, bg: 0x0000_ffff, attrs: 0x0001)
        let slot = try XCTUnwrap(invokeMakeSlot(cell))
        // Expect fg = original bg (blue), bg = original fg (red).
        let expectedFg = SRGBLinearLUT.unpackLinear(0x0000_ffff)
        let expectedBg = SRGBLinearLUT.unpackLinear(0xff00_00ff)
        assertSIMDClose(slot.fgColorLinear, expectedFg, tol: 1e-6)
        assertSIMDClose(slot.bgColorLinear, expectedBg, tol: 1e-6)
    }

    /// Without the INVERSE bit, fg/bg pass through unswapped.
    /// Regression guard so the swap doesn't fire on unrelated attrs.
    func testNoInverseAttrPreservesFgAndBg() throws {
        // BOLD (bit 1 = 0x0002) but NOT INVERSE.
        let cell = makeCell(
            fg: 0xff00_00ff, bg: 0x0000_ffff, attrs: 0x0002)
        let slot = try XCTUnwrap(invokeMakeSlot(cell))
        assertSIMDClose(
            slot.fgColorLinear,
            SRGBLinearLUT.unpackLinear(0xff00_00ff),
            tol: 1e-6)
        assertSIMDClose(
            slot.bgColorLinear,
            SRGBLinearLUT.unpackLinear(0x0000_ffff),
            tol: 1e-6)
    }

    func testSRGBToLinearLUTMatchesReference() {
        // Sample across the piecewise boundary (0.04045 ≈ byte 10) and
        // mid/high-range values where the power curve dominates.
        for byte: UInt8 in [0, 5, 10, 11, 64, 128, 200, 255] {
            let lut = SRGBLinearLUT.table[Int(byte)]
            let ref = SRGBLinearLUT.referenceLinear(forByte: byte)
            XCTAssertEqual(
                lut, ref, accuracy: 1e-7,
                "LUT drifted at byte=\(byte): lut=\(lut) ref=\(ref)")
        }
    }

    /// Spot-check a precomputed value to guard against the formula
    /// itself silently changing (e.g., someone swapping the exponent).
    func testSRGBReferenceFormulaIsCorrect() {
        // From spec sanity table: 0xd6 → 0.67244316 (8 decimals).
        XCTAssertEqual(
            SRGBLinearLUT.referenceLinear(forByte: 0xd6),
            0.672_443_16,
            accuracy: 1e-6)
        // 0x0c → 0.00367651.
        XCTAssertEqual(
            SRGBLinearLUT.referenceLinear(forByte: 0x0c),
            0.003_676_51,
            accuracy: 1e-6)
        // Pure black/white must map to 0/1 exactly.
        XCTAssertEqual(SRGBLinearLUT.referenceLinear(forByte: 0), 0.0, accuracy: 1e-7)
        XCTAssertEqual(SRGBLinearLUT.referenceLinear(forByte: 255), 1.0, accuracy: 1e-7)
    }

    // MARK: - Grapheme handling

    func testBlankGraphemeYieldsBlankSlotNotNil() throws {
        // ASCII space (0x20) padded with zeros — the engine's blank
        // cell template encodes this for cleared cells.
        let cell = makeCell(
            fg: 0xffff_ffff, bg: 0x0000_00ff,
            grapheme: [0x20, 0, 0, 0, 0, 0, 0, 0])
        let slot = invokeMakeSlot(cell)
        // Regression guard for the original stub's drop-cell bug:
        // returning nil here drops the cell from `applyCellsAsRegions`,
        // leaving stale texture contents from the previous frame. We
        // MUST get a real CellSlot back, with `glyph == nil` so the
        // shader paints bg only.
        XCTAssertNotNil(slot, "blank-grapheme cells must NOT return nil")
        XCTAssertNil(slot?.glyph, "blank-grapheme cells must have nil glyph")
    }

    func testAllZeroGraphemeYieldsBlankSlotNotNil() throws {
        let cell = makeCell(
            fg: 0xffff_ffff, bg: 0x0000_00ff,
            grapheme: [0, 0, 0, 0, 0, 0, 0, 0])
        let slot = invokeMakeSlot(cell)
        XCTAssertNotNil(slot)
        XCTAssertNil(slot?.glyph)
    }

    func testPrintableASCIIGetsAtlasEntry() throws {
        // 'A' is in BMP and resolves through the spike's atlas path.
        let cell = makeCell(
            fg: 0xffff_ffff, bg: 0x0000_00ff,
            grapheme: [0x41, 0, 0, 0, 0, 0, 0, 0])  // 'A'
        let slot = try XCTUnwrap(invokeMakeSlot(cell))
        XCTAssertNotNil(slot.glyph, "printable scalar should resolve in the atlas")
    }

    // MARK: - Helpers

    private func makeCell(
        fg: UInt32,
        bg: UInt32,
        grapheme: [UInt8] = [0x41, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],  // 'A' default
        attrs: UInt16 = 0,
        width: UInt8 = 1,
        row: UInt16 = 0,
        col: UInt16 = 0
    ) -> CellDeltaSwift {
        CellDeltaSwift(
            row: row, col: col, grapheme: grapheme,
            fg: fg, bg: bg, attrs: attrs, width: width)
    }

    private func invokeMakeSlot(_ cell: CellDeltaSwift) -> CellSlot? {
        MetalRenderer.makeSlot(
            from: cell,
            atlas: atlas,
            commandQueue: queue,
            palette: Theme.Color.defaultPalette)
    }

    private func assertSIMDClose(
        _ actual: SIMD4<Float>, _ expected: SIMD4<Float>, tol: Float,
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: tol, "R", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: tol, "G", file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: tol, "B", file: file, line: line)
        XCTAssertEqual(actual.w, expected.w, accuracy: tol, "A", file: file, line: line)
    }
}
