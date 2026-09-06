// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// `NSDraggingDestination` for `TerminalSurfaceView`, split out of the
// single-file view along its existing MARK: Finder → terminal drops
// (including `shellQuote`), Quick Look, menu-item validation and the
// scroll-wheel handler that followed them in the single file.

import AppKit

extension TerminalSurfaceView {
    // MARK: NSDraggingDestination — Finder → terminal
    //
    // Dragging files from Finder onto the terminal inserts each
    // path at the cursor, POSIX-single-quote escaped and space-
    // separated. Matches iTerm2 / Terminal.app convention.
    // Byte path is the same `session.send_input` route as paste/IME
    // commit, so bracketed-paste and TUI snap-to-bottom both work.

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
            ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
            ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let session = renderer.session,
            let items = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                as? [URL], !items.isEmpty
        else { return false }

        let payload = items.map { Self.shellQuote($0.path) }
            .joined(separator: " ")
        session.scroll_to_bottom()
        dropPayloadSink?(payload)
        // Drag-drop payloads can be large (many paths × long names).
        // Use the same chunked feeder as paste so the main thread
        // doesn't stall on a PTY-buffer-full `write_all`.
        Self.feedChunked(payload, into: session)
        return true
    }

    /// Does `url` point at an image file the Kitty Graphics encoder
    /// can handle? `UTType.conforms(to: .image)` covers PNG, JPEG,
    /// HEIC, TIFF, GIF, BMP, plus less-common formats macOS knows
    /// about. Anything else (PDF, text, archives) gets shell-quoted
    /// as a path so the TUI can read or open it via its own tools.
    static func isImageFile(_ url: URL) -> Bool {
        guard
            let type = try? url.resourceValues(forKeys: [.contentTypeKey])
                .contentType
        else { return false }
        return type.conforms(to: .image)
    }

    /// POSIX-shell single-quote escape: wrap in `'...'`, replace any
    /// internal `'` with `'\''`. The result is safe to drop into any
    /// POSIX shell verbatim — covers spaces, quotes, `$`, `\`,
    /// glob characters, parens, etc.
    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Gray out menu items when there's nothing meaningful to act on.
    /// `copy:` is enabled only when a selection exists; `paste:` is
    /// enabled only when the pasteboard carries a string type. Other
    /// selectors (Cut / Select All / Undo / Redo) are left to the
    /// default chain — the surface view doesn't implement them, so
    /// AppKit's `noResponder(for:)` path correctly disables them at the
    /// menu level.
    /// macOS Look-Up gesture — Force Touch / three-finger tap on a
    /// word. AppKit's default NSResponder behavior routes the event up
    /// the chain; standard text views (NSTextField, WebKit) override
    /// this to show the dictionary popover. We override here so the
    /// terminal grid participates in the system gesture.
    ///
    /// Implementation: stash the user's current selection, run a
    /// SEMANTIC engine selection at the gesture location (alacritty's
    /// word-boundary logic), read the resulting text, restore the
    /// prior selection, then call `showDefinition(for:at:)` — the
    /// macOS dictionary popover API.
    override func quickLook(with event: NSEvent) {
        guard let session = renderer.session,
            let (row, col) = pointToCell(event.locationInWindow)
        else {
            super.quickLook(with: event)
            return
        }
        // Stash the user's current selection so the look-up gesture
        // doesn't destroy it. selection_span returns a `Vec<u32>` of
        // [startRow, startCol, endRow, endCol, mode] when active; empty
        // when there's no selection.
        let prev = session.selection_span()
        let stashed: (UInt16, UInt16, UInt16, UInt16)?
        if prev.len() == 5 {
            stashed = (
                UInt16(clamping: prev.get(index: 0) ?? 0),
                UInt16(clamping: prev.get(index: 1) ?? 0),
                UInt16(clamping: prev.get(index: 2) ?? 0),
                UInt16(clamping: prev.get(index: 3) ?? 0)
            )
        } else {
            stashed = nil
        }

        // WORD mode = alacritty's word-boundary logic (honors
        // semantic_escape_chars). Single-point click selects the word.
        session.start_selection(Self.SELECTION_MODE_WORD, row, col)
        session.update_selection(row, col)
        let word = session.selection_text().toString()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Snapshot the word's grid bounds BEFORE restoring the prior
        // selection so we can anchor the popover at the word's start
        // cell baseline (not the gesture point, which may have landed
        // off the word's first glyph).
        let wordSpan = session.selection_span()
        let wordStartRow: UInt16
        let wordStartCol: UInt16
        if wordSpan.len() == 5 {
            wordStartRow = UInt16(clamping: wordSpan.get(index: 0) ?? 0)
            wordStartCol = UInt16(clamping: wordSpan.get(index: 1) ?? 0)
        } else {
            wordStartRow = row
            wordStartCol = col
        }

        // Restore the prior selection — or clear if there wasn't one.
        if let s = stashed {
            session.start_selection(Self.SELECTION_MODE_SIMPLE, s.0, s.1)
            session.update_selection(s.2, s.3)
        } else {
            session.clear_selection()
        }

        guard !word.isEmpty else { return }
        let attr = NSAttributedString(
            string: word,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ])
        // `showDefinition(for:at:)` expects the **text baseline origin
        // of the first character** in the receiver's coordinate system
        // (bottom-up for unflipped NSViews). Anchor at the word's
        // start cell baseline — the popover's connector arrow then
        // points to the actual word, not wherever the user's finger
        // happened to land.
        //
        // Cell baseline in view coords:
        //   x = startCol * cellWidthPt + gutter
        //   y = bounds.height - (startRow + 1) * cellHeightPt + descent
        //
        // Descent ≈ cellHeight × 0.2 is a reasonable approximation that
        // doesn't require pulling CTFont metrics into the input path.
        let cellW = renderer.cellWidthPt ?? 0
        let cellH = renderer.cellHeightPt ?? 0
        if cellW > 0, cellH > 0 {
            let baselineX =
                CGFloat(wordStartCol) * cellW + Theme.Gutter.widthPt
            let baselineY =
                bounds.height - CGFloat(wordStartRow + 1) * cellH
                + cellH * 0.2
            showDefinition(for: attr, at: NSPoint(x: baselineX, y: baselineY))
        } else {
            // Fallback if cell metrics aren't available yet — anchor at
            // the gesture point (converted to view coords).
            let anchor = convert(event.locationInWindow, from: nil)
            showDefinition(for: attr, at: anchor)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        if action == #selector(copy(_:)) {
            // Prefer the Swift selection mirror. alacritty clears its own
            // `Term::selection` on any grid write intersecting the
            // selection rows, so under a live TUI (which repaints
            // constantly) the engine span empties almost immediately even
            // while the highlight is still on screen. `copy(_:)`
            // re-establishes from the mirror, so the menu item must agree —
            // otherwise Cmd+C is validated as disabled, the key equivalent
            // doesn't fire, and the keystroke falls through to `keyDown`,
            // leaking a literal "c" into the TUI.
            if swiftSelectionSpan != nil { return true }
            // Empty wire-format Vec means no active selection.
            return (renderer.session?.selection_span().len() ?? 0) > 0
        }
        if action == #selector(paste(_:)) {
            return NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil)
        }
        if action == #selector(pastePlain(_:)) {
            // Same gate as paste — enabled iff the pasteboard carries a
            // string. The wrap decision is the only difference between
            // the two selectors; both require usable clipboard content.
            return NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil)
        }
        if action == #selector(selectAll(_:)) {
            // UX2: Always enabled when there's a session — even an
            // empty viewport gets the selection rectangle (the user
            // can still confirm "nothing to copy" via the resulting
            // empty highlight).
            return renderer.session != nil
        }
        // Default: enable the item — NSResponder will route to the
        // first responder that can handle the selector, or fail
        // gracefully if none can.
        return true
    }

    /// Two-finger trackpad scroll. Accumulates `scrollingDeltaY` in
    /// points; flushes when the accumulator crosses a cell-height
    /// boundary. Sign convention: NSEvent.scrollingDeltaY is positive
    /// when content moves down under the user's fingers (i.e. the user
    /// wants to see content above — older content), which matches
    /// alacritty's `Scroll::Delta(positive)` = scroll back into
    /// history. The forward is therefore 1:1 with no sign flip.
    ///
    /// Mouse-wheel events (line-based, `hasPreciseScrollingDeltas ==
    /// false`) report `scrollingDeltaY` already pre-multiplied by line
    /// height in points — same accumulator path works.
    ///
    /// Task 4.4. Selection drag-scroll, momentum tuning, and rubber-
    /// band overshoot are M5 polish; the skeleton here just makes
    /// scrollback navigable.
    override func scrollWheel(with event: NSEvent) {
        guard let session = renderer.session,
            let cellHeightPt = renderer.cellHeightPt,
            cellHeightPt > 0
        else { return }

        accumulatedScrollPt += event.scrollingDeltaY
        let lines = Int(accumulatedScrollPt / cellHeightPt)
        if lines == 0 { return }
        accumulatedScrollPt -= CGFloat(lines) * cellHeightPt

        // PG1: forward wheel events to TUIs that have enabled mouse
        // reporting (vim/less/htop normal-mode pagers use this). Each
        // line of wheel delta becomes one button-press at the cursor
        // cell — button 64 = wheel-up, 65 = wheel-down (xterm
        // convention). Selection-side scroll snap is bypassed; the
        // TUI owns its scroll feel while in mouse mode.
        if MouseReporting.modeActive(session: session),
            let (row, col) = pointToCell(event.locationInWindow)
        {
            let wheelButton: UInt8 = lines > 0 ? 64 : 65
            for _ in 0..<abs(lines) {
                MouseReporting.sendButtonEvent(
                    session: session, event: event,
                    row: row, col: col,
                    button: wheelButton, pressed: true)
            }
            return
        }

        // Int → Int32: viewport scroll deltas are bounded by the
        // user's accumulated swipe length; saturating cast is safe.
        let clamped = Int32(clamping: lines)
        session.scroll_lines(clamped)

        // Selection follows content, not the screen. `pendingSelection`
        // caches viewport-relative rows captured at the previous display
        // offset; the scroll just moved the content under them, so without
        // a re-projection the highlight stays pinned to the old screen rows
        // (it "doesn't follow the scroll"). The engine's `Term::selection`
        // survives a wheel scroll — no grid write — so its freshly-projected
        // span is the source of truth: re-read it and refresh the mirror.
        // An empty span means the selection scrolled out of view; collapse
        // the mirror to a non-drawing zero-width anchor so the tint hides
        // while off-screen, yet stays live for the next scroll-back to
        // re-populate (re-reading on each tick restores it once it re-enters
        // the viewport).
        if let pending = pendingSelection {
            let span = session.selection_span()
            if span.count == 5 {
                pendingSelection = PendingSelection(
                    start: (row: UInt16(span[0]), col: UInt16(span[1])),
                    end: (row: UInt16(span[2]), col: UInt16(span[3])),
                    mode: pending.mode)
            } else {
                pendingSelection = PendingSelection(
                    start: (row: 0, col: 0),
                    end: (row: 0, col: 0),
                    mode: Self.SELECTION_MODE_SIMPLE)
            }
            needsDisplay = true
            renderer.markNeedsRedraw()
        }
    }
}
