// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// ⌘-hover / ⌘-click link opening for `TerminalSurfaceView`, split out
// of the single-file view along its existing MARKs: M6-2 file paths and
// M7-1 OSC 8 hyperlinks. Stored properties live in
// TerminalSurfaceView.swift because extensions cannot declare them.

import AppKit

extension TerminalSurfaceView {
    // MARK: - M6-2 ⌘+hover / ⌘+click file-path open
    // MARK: - M7-1 ⌘+hover / ⌘+click OSC 8 hyperlink open

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = fileClickTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        fileClickTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // V1 scrollbar hover: push the latest pointer position to the
        // renderer so the encode path can decide whether to grow the
        // thumb and pin opacity. `convert(_:from:)` with nil source
        // maps window-space → view-space.
        renderer.hoverPointInView = convert(event.locationInWindow, from: nil)
        recomputeFileClickHover(at: event.locationInWindow, modifiers: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        renderer.hoverPointInView = nil
        clearFileClickHover()
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let mouseInWindow = window?.mouseLocationOutsideOfEventStream ?? .zero
        recomputeFileClickHover(at: mouseInWindow, modifiers: event.modifierFlags)
    }

    // Internal (not private) so Osc8HoverPolicyTests can drive the hover policy
    // without synthesizing NSEvents (blocked in headless XCTest).
    func recomputeFileClickHover(at windowPoint: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.contains(.command),
            let session = renderer.session,
            let (row, col) = pointToCell(windowPoint)
        else {
            clearFileClickHover()
            return
        }

        // OSC 8 hyperlink is the only supported ⌘-hover surface in
        // solidterm. `uri == ""` is the sentinel for "no link at this cell".
        // The URI is remote-controlled byte-for-byte, so it must pass the
        // same scheme allowlist as plain-text links; a denied scheme falls
        // through to the plain-text detector below, which sees only the
        // VISIBLE text (anti-spoofing: the user opens what they can read,
        // or nothing).
        let hit = session.hyperlink_at(row, col)
        let hyperUri = hit.uri.toString()
        if !hyperUri.isEmpty,
            let url = PlainLinkDetector.sanctionedURL(fromTerminalContent: hyperUri)
        {
            renderer.linkHover = MetalRenderer.LinkHover(
                row: Int(row),
                startCol: Int(hit.start_col),
                span: Int(hit.span))
            hoveredHyperlink = url
            hoveredPath = nil
            NSCursor.pointingHand.set()
            return
        }

        // No OSC 8 here — fall back to detecting a plain URL or an
        // existing file path in the row's text, gated on the user's
        // "Detect file paths under the cursor" toggle (default on; the
        // key is unset until first changed, so treat nil as true). URLs
        // land in `hoveredHyperlink` (opened via NSWorkspace on ⌘-click),
        // file paths in `hoveredPath` (opened in the configured editor) —
        // the same fields the OSC 8 branch and `mouseDown` already use.
        let detectionEnabled =
            UserDefaults.standard.object(forKey: AppearanceTab.Keys.detectionEnabled) as? Bool
            ?? true
        if detectionEnabled {
            let rowText = session.row_text(row).toString()
            if let link = PlainLinkDetector.shared.detect(
                in: rowText, hoveredCol: Int(col), terminalCols: renderer.viewportCols)
            {
                renderer.linkHover = MetalRenderer.LinkHover(
                    row: Int(row), startCol: link.startCol, span: link.span)
                switch link.kind {
                case .url(let url):
                    hoveredHyperlink = url
                    hoveredPath = nil
                case .filePath(let url):
                    hoveredPath = url
                    hoveredHyperlink = nil
                }
                NSCursor.pointingHand.set()
                return
            }
        }
        clearFileClickHover()
    }

    private func clearFileClickHover() {
        if renderer.linkHover != nil {
            renderer.linkHover = nil
            hoveredPath = nil
            hoveredHyperlink = nil
            NSCursor.iBeam.set()
        }
    }

    /// Default mouse cursor over the terminal text area is the I-beam
    /// (`text cursor`), matching Terminal.app / iTerm2 / VS Code's
    /// integrated terminal. Hyperlink + ⌘-hover paths override to
    /// `pointingHand` via explicit `.set()` calls and restore I-beam
    /// when the hover clears. AppKit calls `resetCursorRects()`
    /// whenever the view geometry changes — the rect covers the
    /// entire bounds so the cursor switches the moment the mouse
    /// enters the surface.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    func launchEditor(forPath url: URL) {
        let cmd = EditorChoice.currentCommand()
        let proc = Process()
        // Resolve via `/usr/bin/env` for non-absolute commands so
        // `code`, `cursor`, `subl`, `zed` pick up the user's PATH.
        if cmd.hasPrefix("/") {
            proc.executableURL = URL(fileURLWithPath: cmd)
            proc.arguments = [url.path]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [cmd, url.path]
        }
        do { try proc.run() } catch {
            NSLog("M6-2 launchEditor failed: \(error)")
        }
    }
}
