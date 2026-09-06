#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Generate the SolidTerm app icon as a 1024×1024 PNG.
// Design: solid/minimal isometric cube on a dark rounded-square background.
// Output: $REPO/app/SolidTerm/Resources/AppIcon.png — fed into sips for
// asset-catalog sizes by scripts/gen-icon.sh.

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let cornerRadius: CGFloat = 225  // ~22% — Apple's macOS app-icon convention

// ── Palette (linear sRGB hex) ────────────────────────────────────────
// Background: a two-stop dark gradient pulled from the bundled theme
// (bg-base → bg-elevated) so the icon visually belongs to the app's
// own world rather than feeling like a separate brand asset.
let bgTop = NSColor(srgbRed: 0x1a / 255, green: 0x1b / 255, blue: 0x26 / 255, alpha: 1)
let bgBottom = NSColor(srgbRed: 0x24 / 255, green: 0x28 / 255, blue: 0x3b / 255, alpha: 1)

// Cube faces — flat shading, no per-face gradients. Three values keep
// the depth cue legible at 16px without relying on outlines.
let faceTop = NSColor(srgbRed: 0xc0 / 255, green: 0xca / 255, blue: 0xf5 / 255, alpha: 1)
let faceRight = NSColor(srgbRed: 0x7a / 255, green: 0xa2 / 255, blue: 0xf7 / 255, alpha: 1)
let faceLeft = NSColor(srgbRed: 0x3d / 255, green: 0x59 / 255, blue: 0xa1 / 255, alpha: 1)
let faceEdge = NSColor(srgbRed: 0x1a / 255, green: 0x1b / 255, blue: 0x26 / 255, alpha: 1)

// ── Render ────────────────────────────────────────────────────────────

guard
    let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    fputs("error: failed to create CGContext\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

// Rounded-square background with vertical gradient.
let bgPath = NSBezierPath(
    roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
    xRadius: cornerRadius,
    yRadius: cornerRadius)
bgPath.addClip()
let bgGradient = NSGradient(
    colors: [bgTop, bgBottom],
    atLocations: [0.0, 1.0],
    colorSpace: .sRGB)!
bgGradient.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)

// Isometric cube. Edge length L picked so the cube fits with comfortable
// padding around all sides (~12% margin). Hex vertices are computed from
// the iso projection (30° tilt → cos30 ≈ 0.866, sin30 = 0.5).
let cx = size / 2
let cy = size / 2
let L: CGFloat = 320
let cos30 = CGFloat(0.86602540378)
let sin30: CGFloat = 0.5

let vTop = CGPoint(x: cx, y: cy + L)
let vTR = CGPoint(x: cx + L * cos30, y: cy + L * sin30)
let vBR = CGPoint(x: cx + L * cos30, y: cy - L * sin30)
let vBot = CGPoint(x: cx, y: cy - L)
let vBL = CGPoint(x: cx - L * cos30, y: cy - L * sin30)
let vTL = CGPoint(x: cx - L * cos30, y: cy + L * sin30)
let vCen = CGPoint(x: cx, y: cy)

func fillFace(
    _ points: [CGPoint], color: NSColor, strokeWidth: CGFloat = 6
) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for p in points.dropFirst() {
        path.line(to: p)
    }
    path.close()
    color.setFill()
    path.fill()
    faceEdge.setStroke()
    path.lineWidth = strokeWidth
    path.lineJoinStyle = .miter
    path.stroke()
}

// Order: bottom-most face first (left), then right, then top — so the
// stroke seams sit on top and read as crisp edges.
fillFace([vCen, vTL, vBL, vBot], color: faceLeft)
fillFace([vCen, vBot, vBR, vTR], color: faceRight)
fillFace([vCen, vTR, vTop, vTL], color: faceTop)

NSGraphicsContext.restoreGraphicsState()

// ── Write PNG ─────────────────────────────────────────────────────────

guard let cgImage = context.makeImage() else {
    fputs("error: makeImage failed\n", stderr)
    exit(1)
}
let bitmap = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("error: PNG encode failed\n", stderr)
    exit(1)
}

let outPath = CommandLine.arguments.dropFirst().first
    ?? "app/SolidTerm/Resources/AppIcon.png"
let outURL = URL(fileURLWithPath: outPath)
try pngData.write(to: outURL)
print("✓ wrote \(outPath) (\(pngData.count) bytes)")
