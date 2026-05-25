// Settings-pane previews — font sample + theme color swatches.
//
// Lives alongside `AppearanceTab` because both views are pure presentation
// helpers driven by the same observable settings (`FontSettings`,
// `ThemeFileStore`, `ThemeManager`). Splitting them out keeps the tab
// itself focused on Form/Section composition.

import AppKit
import CoreText
import SwiftUI

// MARK: - Font preview

/// S2: live font preview rendering a short Latin + Thai sample at the
/// user's currently-selected family, size, and ligature setting. Wraps
/// an NSView so we can apply the CoreText kCTFontFeatureTypeIdentifierKey
/// dictionary that SwiftUI's `.font` modifier doesn't expose.
struct FontPreviewView: NSViewRepresentable {
    let family: String
    let size: CGFloat
    let ligatures: Bool

    func makeNSView(context: Context) -> FontPreviewNSView {
        let v = FontPreviewNSView()
        v.update(family: family, size: size, ligatures: ligatures)
        return v
    }

    func updateNSView(_ nsView: FontPreviewNSView, context: Context) {
        nsView.update(family: family, size: size, ligatures: ligatures)
    }
}

final class FontPreviewNSView: NSView {
    private static let sampleText =
        "The quick brown fox 0123 → ก่อน"

    private var family: String = ""
    private var fontSize: CGFloat = 13
    private var ligatures: Bool = false

    override var intrinsicContentSize: NSSize {
        // Roughly 28pt tall regardless of font size; the renderer
        // measures and centers the glyph row inside this bound.
        NSSize(width: NSView.noIntrinsicMetric, height: max(28, fontSize + 12))
    }

    func update(family: String, size: CGFloat, ligatures: Bool) {
        let changed = family != self.family
            || size != self.fontSize
            || ligatures != self.ligatures
        guard changed else { return }
        self.family = family
        self.fontSize = size
        self.ligatures = ligatures
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let ctFont = FontSettings.makeCTFont(family: family, size: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: ctFont,
            .ligature: ligatures ? 1 : 0,
            .foregroundColor: NSColor.labelColor,
        ]
        let str = NSAttributedString(string: Self.sampleText, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        // Vertical center inside the view bounds.
        let y = (self.bounds.height - bounds.height) / 2 - bounds.minY
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: 4, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

// MARK: - Theme color swatches

/// S3: 16 ANSI swatches + bg/fg/cursor preview for the active theme.
/// When a `ThemeFile` is selected we render its palette directly;
/// otherwise we fall back to the engine's compile-time matcha palette
/// (mirrored in `crates/solidterm-engine/src/cells.rs::encode_named`).
struct ThemeSwatchesView: View {
    let file: ThemeFile?
    let mode: Theme.Mode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 16 ANSI colors — two rows of 8 (normal / bright).
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(0..<8, id: \.self) { i in swatch(ansi[i]) }
                }
                HStack(spacing: 4) {
                    ForEach(8..<16, id: \.self) { i in swatch(ansi[i]) }
                }
            }
            // Status swatches: background / foreground / cursor.
            HStack(spacing: 10) {
                statusSwatch(label: "bg", color: bgFg.bg)
                statusSwatch(label: "fg", color: bgFg.fg)
                statusSwatch(label: "cursor", color: bgFg.cursor)
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        }
    }

    private func swatch(_ rgba: SIMD4<Float>) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color(linear: rgba))
            .frame(width: 18, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
    }

    private func statusSwatch(label: String, color: SIMD4<Float>) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(linear: color))
                .frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
            Text(label)
        }
    }

    private var ansi: [SIMD4<Float>] {
        if let file, file.ansi.count == 16 { return file.ansi }
        return Self.engineMatchaAnsi
    }

    private var bgFg: (bg: SIMD4<Float>, fg: SIMD4<Float>, cursor: SIMD4<Float>) {
        if let file {
            return (file.background, file.foreground, file.cursor)
        }
        let resolved = mode.resolved
        let palette = Theme.Color.defaultPalette(for: resolved)
        return (
            bg: palette.defaultBgLinear,
            fg: palette.defaultFgLinear,
            cursor: Theme.Color.cursorDefaultLinear(for: resolved))
    }

    /// Engine's compile-time 16-color matcha palette, mirrored from
    /// `crates/solidterm-engine/src/cells.rs::encode_named`. Used when
    /// no theme file is active so the preview still has something to
    /// show against the built-in mode.
    private static let engineMatchaAnsi: [SIMD4<Float>] = [
        // Normal
        SRGBLinearLUT.unpackLinear(0x2a34_24ff),  // black
        SRGBLinearLUT.unpackLinear(0xd470_70ff),  // red
        SRGBLinearLUT.unpackLinear(0xa8cc_8cff),  // green
        SRGBLinearLUT.unpackLinear(0xd4c0_78ff),  // yellow
        SRGBLinearLUT.unpackLinear(0x6898_b0ff),  // blue
        SRGBLinearLUT.unpackLinear(0xb890_a8ff),  // magenta
        SRGBLinearLUT.unpackLinear(0x70b8_a0ff),  // cyan
        SRGBLinearLUT.unpackLinear(0xc8d0_b8ff),  // white
        // Bright
        SRGBLinearLUT.unpackLinear(0x3a4a_34ff),
        SRGBLinearLUT.unpackLinear(0xe888_88ff),
        SRGBLinearLUT.unpackLinear(0xb8dc_a0ff),
        SRGBLinearLUT.unpackLinear(0xe8d8_90ff),
        SRGBLinearLUT.unpackLinear(0x80b0_c8ff),
        SRGBLinearLUT.unpackLinear(0xd0a8_c0ff),
        SRGBLinearLUT.unpackLinear(0x88d0_b8ff),
        SRGBLinearLUT.unpackLinear(0xd8e0_ccff),
    ]
}
