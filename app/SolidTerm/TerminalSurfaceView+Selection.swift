// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Selection for `TerminalSurfaceView`, split out of the single-file
// view along its existing MARKs: the keyboard arrow virtual keycodes
// (4.5), then the mouse + keyboard selection handlers — keyDown
// routing, drag-select with auto-scroll, the context menu and the
// look-up popover. Stored properties live in TerminalSurfaceView.swift
// because extensions cannot declare them.

import AppKit

extension TerminalSurfaceView {
    // MARK: 4.5 selection — keyboard arrow virtual keycodes
    //
    // Carbon kVK_* constants from <HIToolbox/Events.h>. Stable across
    // keyboard layouts and across the Carbon → AppKit transition; the
    // shift+arrow handler below routes against these.
    private static let kVKLeftArrow: UInt16 = 0x7B  // 123
    private static let kVKRightArrow: UInt16 = 0x7C  // 124
    private static let kVKDownArrow: UInt16 = 0x7D  // 125
    private static let kVKUpArrow: UInt16 = 0x7E  // 126

    // Selection-mode constants — mirror of `solidterm_ffi::kinds::
    // SELECTION_MODE_*` from `crates/solidterm-ffi/src/bridge.rs`.
    // swift-bridge 0.1.59 doesn't export `pub const`s to Swift, so
    // these are hand-mirrored numeric literals with cite-comments
    // (same precedent as `InputEventEncoding`'s discriminator enums).
    static let SELECTION_MODE_SIMPLE: UInt8 = 0  // kinds::SELECTION_MODE_SIMPLE
    static let SELECTION_MODE_WORD: UInt8 = 1  // kinds::SELECTION_MODE_WORD
    static let SELECTION_MODE_LINE: UInt8 = 2  // kinds::SELECTION_MODE_LINE

    /// Selection-span wire format mirroring `bridge.rs::TerminalSession::
    /// selection_span` — `[start_row, start_col, end_row, end_col,
    /// is_block]` when a selection is active, nil otherwise. The
    /// renderer reads this each frame to encode the selection-overlay
    /// quad; preferring the Swift mirror (when present) over the
    /// engine's span survives the alacritty-clears-on-write problem
    /// described on `pendingSelection`.
    ///
    /// `is_block` is always 0 here — the mouse handlers only produce
    /// Simple/Word/Line spans; Block-mode selection requires a yet-
    /// unwired modifier path (Option-drag in iTerm2) and is out of
    /// scope for this fix.
    var swiftSelectionSpan: [UInt32]? {
        guard let sel = pendingSelection else { return nil }
        // Anchor-only state (Simple mode, no drag yet) has zero-width
        // start==end — engine reports an empty span here, mirror must
        // too. Without this guard, single-click-to-clear leaves a
        // 1-cell tint at the click site because the renderer paints
        // every non-nil mirror. Word/Line spans never collapse to
        // zero-width (the engine expands them).
        if sel.mode == Self.SELECTION_MODE_SIMPLE
            && sel.start.row == sel.end.row
            && sel.start.col == sel.end.col
        {
            return nil
        }
        return [
            UInt32(sel.start.row),
            UInt32(sel.start.col),
            UInt32(sel.end.row),
            UInt32(sel.end.col),
            0,
        ]
    }

    /// Test seam — mouse-event synthesis is blocked headless (see
    /// `SelectionInputTests` preamble), so the round-trip test for the
    /// alacritty-clears-on-write recovery path needs a way to populate
    /// the mirror without going through `mouseDown` / `mouseDragged`.
    /// Drives the same mutation those handlers perform; nothing else.
    func setPendingSelectionForTesting(
        startRow: UInt16, startCol: UInt16,
        endRow: UInt16, endCol: UInt16,
        mode: UInt8 = TerminalSurfaceView.SELECTION_MODE_SIMPLE
    ) {
        pendingSelection = PendingSelection(
            start: (row: startRow, col: startCol),
            end: (row: endRow, col: endCol),
            mode: mode)
    }

    override func keyDown(with event: NSEvent) {
        insertTextFiredThisKeyDown = false
        // The user beat the restore to the prompt — abandon the pre-fill
        // rather than injecting it mid-typing.
        cancelPendingPrefill()

        // Synchronous input-source-change check. macOS's
        // keyboardSelectionDidChangeNotification can land a few frames
        // after the user's first post-switch keystroke; without this
        // check, that keystroke gets eaten by the outgoing IME's stale
        // marked-text state. Compare the cached ID against TIS's
        // current source — if it rotated, run the same reset path the
        // notification observer does, then continue processing this
        // keystroke against the new IME context.
        let currentID = Self.currentInputSourceID()
        if let currentID, currentID != lastInputSourceID {
            // Seed-on-first-keystroke is intentional: when
            // `lastInputSourceID` is nil (first keyDown after view
            // creation) we still want to record the ID, but don't
            // tear down composition state that may already exist
            // from a legitimate setMarkedText call.
            if lastInputSourceID != nil {
                handleInputSourceChange()
            } else {
                lastInputSourceID = currentID
            }
        }

        // 4.5: shift+arrow extends the selection from the cursor (or
        // current selection-end). Runs BEFORE the IME / inputContext
        // routing so the keystroke isn't double-handled. Skipped on
        // alt-screen — interactive apps (vim, less) own their own
        // shift+arrow semantics.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift),
            let session = renderer.session,
            !session.is_alt_screen(),
            Self.isArrowKeycode(event.keyCode)
        {
            extendSelectionByArrow(keyCode: event.keyCode, session: session)
            renderer.recordKeystroke(eventTimestamp: event.timestamp)
            return
        }

        // Thai-aware backspace (Task #16): when the cell just left of the
        // cursor carries a multi-codepoint Thai cluster (e.g. `ก่` = ก +
        // ่), users expect the trailing tone mark to come off
        // independently — ก stays, ่ goes — in ONE backspace rather than
        // codepoint-by-codepoint. Intercept BS on the primary screen,
        // peek at the cell, and re-emit `cluster minus last codepoint`
        // after the standard DEL. Skipped on alt-screen (vim/less own
        // backspace semantics) and when the trailing codepoint isn't a
        // Thai combining mark.
        //
        // NOTE (shell-dependent): on shells that delete one CODEPOINT per
        // DEL (default zsh without `setopt COMBINING_CHARS`) the re-type
        // can double the base. If you hit that, enable COMBINING_CHARS or
        // tell me your shell so this can be tuned per-config.
        if event.keyCode == Self.kVKDelete, !modifiers.contains(.shift),
            let session = renderer.session,
            !session.is_alt_screen(),
            tryThaiAwareBackspace(session: session)
        {
            renderer.recordKeystroke(eventTimestamp: event.timestamp)
            return
        }

        // 4.4: PgUp / PgDn drive scrollback navigation on the primary
        // screen. In alt-screen mode (vim, less, man, htop) the app
        // owns paging — forward the keystroke to the PTY through the
        // normal direct-send path so the app's own bindings fire.
        if let session = renderer.session, !session.is_alt_screen() {
            if event.keyCode == Self.kVKPageUp || event.keyCode == Self.kVKPageDown {
                let page = Int32(renderer.viewportRows)
                let delta: Int32 = event.keyCode == Self.kVKPageUp ? page : -page
                session.scroll_lines(delta)
                renderer.recordKeystroke(eventTimestamp: event.timestamp)
                return
            }

            // 4.4: any "real" keystroke (printable or terminal-meaningful
            // control like Return / Tab / Esc / Backspace) snaps the
            // viewport back to the live tail. Matches iTerm2 /
            // Terminal.app — typing into a scrolled-back buffer would
            // otherwise put the user's input out of view. Modifier-only
            // events (just ⌘ / ⌥ / ⌃ / ⇧ pressed) leave the viewport
            // alone; they have no `characters` payload.
            //
            // We snap eagerly, before IME routing. If the user is
            // mid-IME-composition while scrolled up, the marked-text
            // anchor (firstRectForCharacterRange — currently a stub,
            // 4.9) would be wrong anyway; snapping first puts the
            // cursor cell back into the viewport so when 4.9 lands the
            // anchor is correct.
            if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                session.scroll_to_bottom()
            }
        }

        // Option-as-meta: when the preference is on and Option is held on
        // a printable key, bypass the IME entirely (it would otherwise
        // compose é/∑/… via insertText) and direct-send ESC+<base char>
        // so readline / emacs / zsh Meta bindings (M-b, M-f, M-d) work.
        // `metaCharacters` returns nil for non-Option / Control+Option /
        // Command+Option / special-key (arrow, fn, Delete) events, so
        // those fall through to the normal IME + encode path below. Skip
        // while composing (`hasMarkedText`) so we never interrupt an
        // in-flight Thai/CJK preedit. Sits after the scroll-snap block so
        // Option+key still snaps a scrolled-back viewport, matching typing.
        if TerminalInputSettings.optionAsMeta,
            !hasMarkedText(),
            let session = renderer.session,
            InputEventEncoder.metaCharacters(
                base: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags,
                optionAsMeta: true) != nil
        {
            session.send_input(
                InputEventEncoder.encode(
                    event,
                    kittyFlags: session.kitty_keyboard_flags(),
                    appCursor: session.app_cursor_active(),
                    optionAsMeta: true))
            renderer.recordKeystroke(eventTimestamp: event.timestamp)
            return
        }

        // Control-byte intercept (correct-by-construction Ctrl-C / SIGINT).
        // A Control-modified key that maps to a C0 control byte (Ctrl-A..Z,
        // Ctrl-[ \ ] ^ _, Ctrl-Space) is NEVER IME composition input — it
        // is terminal input every terminal forwards raw. We short-circuit
        // it HERE, before `inputContext?.handleEvent(event)`, so it can't
        // be gated by `hasMarkedText()`. That matters because this view is
        // a custom NSTextInputClient: a ⌘-shortcut fired mid-composition
        // can leave `compositionState` orphaned non-nil (AppKit won't
        // auto-cancel a custom client's preedit), and that stuck state
        // would otherwise make the post-handleEvent gate
        // (`!insertTextFiredThisKeyDown && !hasMarkedText()`) block Ctrl-C
        // forever — the exact "Ctrl-C suddenly stops interrupting Claude"
        // report. Mirrors the Option-as-Meta early-intercept above.
        //
        // We `return` after sending, so the fall-through gate below never
        // runs for this event — no double-send. The encoder is the SAME
        // `InputEventEncoder.encode(...)` the normal path uses, fed the
        // live Kitty-keyboard flags + DECCKM state, so the bytes are
        // byte-identical to what would have gone out absent the wedge; we
        // only change WHEN, not WHAT (e.g. Ctrl-C still emits 0x03).
        //
        // If a composition is in flight when a control key arrives, cancel
        // it first: it can never be the target of a control byte, and
        // leaving stale preedit on screen (or a stuck `compositionState`)
        // is precisely the failure this fix exists to prevent.
        if Self.isControlByteKey(event), let session = renderer.session {
            cancelComposition()
            session.send_input(
                InputEventEncoder.encode(
                    event,
                    kittyFlags: session.kitty_keyboard_flags(),
                    appCursor: session.app_cursor_active()))
            renderer.recordKeystroke(eventTimestamp: event.timestamp)
            return
        }

        // Discard handleEvent's return value — see method-level comment.
        // NSTextInputContext semantics make it unreliable for the gate.
        _ = inputContext?.handleEvent(event)

        if !insertTextFiredThisKeyDown && !hasMarkedText() {
            if let session = renderer.session,
                // Command-modified keys are macOS app shortcuts (Copy /
                // Paste / Find / Select All / …), never terminal input.
                // If one isn't consumed upstream (e.g. Copy validated as
                // disabled because the engine selection was cleared by a
                // TUI repaint), it falls through to here — forwarding it
                // would leak the bare letter (Cmd+C → "c"). Control /
                // Option / Shift still reach the PTY (Ctrl-C = SIGINT,
                // Option-as-Meta, …); only Command is withheld.
                !event.modifierFlags.contains(.command)
            {
                // Pass the live Kitty keyboard flags + DECCKM state so the
                // encoder can CSI-u-encode modified Enter (Shift+Enter →
                // \e[13;2u) under kitty mode, and emit SS3 cursor keys
                // (\eOA…) when a full-screen TUI has set app-cursor mode.
                session.send_input(
                    InputEventEncoder.encode(
                        event,
                        kittyFlags: session.kitty_keyboard_flags(),
                        appCursor: session.app_cursor_active()))
            }
        }
        renderer.recordKeystroke(eventTimestamp: event.timestamp)
    }

    // MARK: 4.5 selection — mouse + keyboard handlers
    //
    // Mouse: NSEvent.clickCount drives the mode dispatch (single =
    // simple drag, double = word, triple = line). NSEvent's own
    // double/triple-click timing is correct for terminal UX —
    // hand-rolling a click-streak detector here would just re-derive
    // the system threshold.
    //
    // Keyboard: shift+arrow extends from the current selection's end
    // (preferred) or from the cursor (when no selection is active).
    // Modifier-only refinements (shift+option for word-step, etc.)
    // are M5 polish; today's path covers the brief.
    //
    // Cell-coordinate translation: window coords are bottom-up
    // (NSWindow legacy); the terminal grid is top-down. The y-flip
    // happens inside `pointToCell` against the view's `bounds`.

    @inline(__always)
    private static func isArrowKeycode(_ keyCode: UInt16) -> Bool {
        keyCode == kVKLeftArrow || keyCode == kVKRightArrow
            || keyCode == kVKUpArrow || keyCode == kVKDownArrow
    }

    /// Thai-aware backspace handler. Returns `true` when this path fully
    /// owned the backspace event (caller should NOT also direct-send DEL);
    /// `false` means fall through to standard byte send.
    ///
    ///   1. Read the cell just left of the cursor via FFI
    ///      `cell_before_cursor()`. Empty bytes → not our case.
    ///   2. Decode as UTF-8. If only one Unicode scalar OR the trailing
    ///      scalar isn't a Thai combining mark → not our case.
    ///   3. Otherwise send DEL + (cluster without last scalar) so the
    ///      net visual effect is "trailing mark removed; base + earlier
    ///      marks remain" in a single backspace.
    private func tryThaiAwareBackspace(session: TerminalSession) -> Bool {
        let bytes = session.cell_before_cursor()
        let count = bytes.len()
        guard count > 0 else { return false }
        var swiftBytes = [UInt8](repeating: 0, count: Int(count))
        for i in 0..<Int(count) {
            swiftBytes[i] = bytes.get(index: UInt(i)).map { $0 } ?? 0
        }
        guard let cluster = String(bytes: swiftBytes, encoding: .utf8),
            !cluster.isEmpty
        else { return false }
        let scalars = Array(cluster.unicodeScalars)
        guard scalars.count > 1 else { return false }
        guard Self.isThaiCombiningMark(scalars.last!) else {
            return false
        }
        // Everything except the last scalar — may still be multi-scalar
        // when marks stack (ก + ั + ้ → after backspace: ก + ั).
        let truncated = String(String.UnicodeScalarView(scalars.dropLast()))
        let payload = "\u{7F}" + truncated
        session.scroll_to_bottom()
        session.send_input(
            InputEventEncoder.makeKeyInputEvent(
                characters: payload, keycode: 0, modifiers: []))
        return true
    }

    /// Thai combining marks: above-vowels U+0E30..U+0E3A and tone /
    /// other marks U+0E47..U+0E4E. Pinned by Unicode 15.1 Thai block
    /// general categories (Mn = Nonspacing Mark, Lo = Other Letter
    /// for the vowels SARA AM-not — see Unicode chart for ranges).
    static func isThaiCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x0E30...0x0E3A).contains(v) || (0x0E47...0x0E4E).contains(v)
    }

    /// Extend the active selection in the direction of `keyCode`. If
    /// no selection is active, anchor a new `Simple` selection at the
    /// cursor position and extend by one cell.
    private func extendSelectionByArrow(keyCode: UInt16, session: TerminalSession) {
        // Prefer the keyboard-selection end so successive shift+arrow
        // presses keep extending the same range. Fall back to the
        // cursor row/col (read from the engine via the last-seen
        // FrameDelta in the renderer) when no keyboard selection is
        // in flight.
        let cursor = renderer.lastSeenCursor
        let originRow = keyboardSelectionEnd?.row ?? cursor.row
        let originCol = keyboardSelectionEnd?.col ?? cursor.col

        var nextRow = Int(originRow)
        var nextCol = Int(originCol)
        switch keyCode {
        case Self.kVKLeftArrow: nextCol -= 1
        case Self.kVKRightArrow: nextCol += 1
        case Self.kVKUpArrow: nextRow -= 1
        case Self.kVKDownArrow: nextRow += 1
        default: return
        }
        // Clamp to viewport — engine clamps too, but tracking the
        // post-clamp value keeps `keyboardSelectionEnd` consistent
        // with what's visually selected.
        nextRow = max(0, min(renderer.viewportRows - 1, nextRow))
        nextCol = max(0, min(renderer.viewportCols - 1, nextCol))
        let r = UInt16(nextRow)
        let c = UInt16(nextCol)

        if keyboardSelectionEnd == nil {
            // Anchor a new selection at the cursor; the next call
            // extends to the new (r, c).
            session.start_selection(Self.SELECTION_MODE_SIMPLE, cursor.row, cursor.col)
            // Keyboard takes over from the mouse mirror. The engine
            // is now authoritative for shift+arrow's selection (the
            // alacritty-clears-on-write problem only bites
            // mouse-driven selections in TUIs that redraw rows
            // constantly — shift+arrow selections live in primary-
            // screen scrollback / static output where the grid is
            // stable).
            pendingSelection = nil
        }
        session.update_selection(r, c)
        keyboardSelectionEnd = (row: r, col: c)
        // Ensure the next frame paints the updated tint immediately.
        needsDisplay = true
        renderer.markNeedsRedraw()
    }

    /// Convert a window-space point into terminal grid `(row, col)`.
    /// Returns nil before the renderer's atlas is built (no cell
    /// metrics) or when the point falls outside the grid origin.
    func pointToCell(_ windowPoint: NSPoint) -> (row: UInt16, col: UInt16)? {
        guard
            let cellWidthPt = renderer.cellWidthPt,
            let cellHeightPt = renderer.cellHeightPt,
            cellWidthPt > 0, cellHeightPt > 0
        else { return nil }
        // Convert window-space → view-space. AppKit hands NSEvent's
        // location in window coords; convert(_:from:) into the view
        // gives bottom-up coords inside `bounds`.
        let viewPoint = convert(windowPoint, from: nil)
        // Y-flip: AppKit's bounds is bottom-up (origin at lower-left),
        // the terminal grid origin is top-down (row 0 at top of view).
        // M5.5-3: cell grid origin is shifted right by the gutter
        // width — subtract `Theme.Gutter.widthPt` from the view-local x
        // before snapping to cells. Negative values (clicks inside the
        // gutter) clamp to col 0 below.
        let xFromTopLeft = viewPoint.x - Theme.Gutter.widthPt
        let yFromTopLeft = bounds.height - viewPoint.y
        // Snap to cells; clamp to viewport bounds.
        let col = Int((xFromTopLeft / cellWidthPt).rounded(.down))
        let row = Int((yFromTopLeft / cellHeightPt).rounded(.down))
        let clampedCol = max(0, min(renderer.viewportCols - 1, col))
        let clampedRow = max(0, min(renderer.viewportRows - 1, row))
        return (row: UInt16(clampedRow), col: UInt16(clampedCol))
    }

    /// Inverse of `pointToCell` for tests: the window-coordinate midpoint
    /// of cell (row, col). Maintained next to `pointToCell` so the two
    /// stay in lockstep.
    func windowPoint(forRow row: UInt16, col: UInt16) -> NSPoint {
        let cellWidthPt = renderer.cellWidthPt ?? 0
        let cellHeightPt = renderer.cellHeightPt ?? 0
        // Cell midpoint in view-local top-left coords, then invert both
        // the gutter offset and the Y-flip that `pointToCell` applies.
        let xFromTopLeft = Theme.Gutter.widthPt + (CGFloat(col) + 0.5) * cellWidthPt
        let yFromTopLeft = (CGFloat(row) + 0.5) * cellHeightPt
        let viewPoint = NSPoint(
            x: xFromTopLeft,
            y: bounds.height - yFromTopLeft)
        // Convert view-space → window-space (inverse of `convert(_:from:nil)`).
        return convert(viewPoint, to: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let session = renderer.session,
            let (row, col) = pointToCell(event.locationInWindow)
        else {
            super.mouseDown(with: event)
            return
        }
        // PG1 mouse reporting — when a TUI has enabled DEC 1000/1002/1003
        // we forward the click as an xterm mouse sequence instead of
        // driving our own selection. Modifier-held clicks (⌘ for
        // hyperlink open, ⌥ for block-select) still own the gesture
        // so the user can override the TUI's mouse capture.
        let modKeysHeld = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option])
        if !modKeysHeld.contains(.command),
            !modKeysHeld.contains(.option),
            MouseReporting.modeActive(session: session)
        {
            mouseGestureOwner = .mouseReporting
            MouseReporting.sendButtonEvent(
                session: session, event: event, row: row, col: col,
                button: 0, pressed: true)
            return
        }
        // M7-1: ⌘+click → open the hovered OSC 8 hyperlink via
        // NSWorkspace (browser for http(s)://, default app per scheme
        // for everything else). Takes priority over the M6-2 path
        // open since `recomputeFileClickHover` already set
        // hoveredHyperlink in preference to hoveredPath.
        if event.modifierFlags.contains(.command),
            let hover = renderer.linkHover, hover.row == Int(row),
            let url = hoveredHyperlink
        {
            mouseGestureOwner = .consumed
            NSWorkspace.shared.open(url)
            return
        }
        // M6-2: ⌘+click → open the hovered file path in the configured
        // editor. Skips selection start so the click feels like a link
        // open, not a deselected click. `linkHover` is set by
        // mouseMoved when ⌘ is held + detector matched.
        if event.modifierFlags.contains(.command),
            let hover = renderer.linkHover, hover.row == Int(row),
            let path = hoveredPath
        {
            mouseGestureOwner = .consumed
            launchEditor(forPath: path)
            return
        }
        mouseGestureOwner = .selection

        // Reset keyboard-selection tracking on any new mouseDown — the
        // mouse is now the active selection driver. Subsequent
        // shift+arrow presses re-anchor against the cursor or the
        // mouse-driven selection's end.
        keyboardSelectionEnd = nil

        // I2 auto-copy: capture the click origin so `mouseUp` can
        // compute drag distance and only auto-copy on a real drag.
        mouseDownLocationInView = convert(event.locationInWindow, from: nil)

        // NSEvent.clickCount reflects macOS's own double/triple-click
        // detector (NSDoubleClickInterval-aware). Anything above 3 is
        // collapsed to triple — quad-clicks are not a terminal idiom.
        let mode: UInt8
        switch event.clickCount {
        case 2: mode = Self.SELECTION_MODE_WORD
        case let n where n >= 3: mode = Self.SELECTION_MODE_LINE
        default: mode = Self.SELECTION_MODE_SIMPLE
        }
        session.start_selection(mode, row, col)
        // Mirror Swift-side from the engine's computed span. Word/Line
        // modes expand to a semantic/line boundary that the click cell
        // alone can't represent; reading back from the engine also
        // normalizes RTL ordering (alacritty's `to_range` always yields
        // start ≤ end). For Simple mode at the anchor the engine span
        // is empty — fall back to the click cell so drag-extend has an
        // anchor to grow from.
        syncPendingSelection(
            from: session, fallback: (row: row, col: col), mode: mode)
        needsDisplay = true
        renderer.markNeedsRedraw()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let session = renderer.session else {
            super.mouseDragged(with: event)
            return
        }
        // PG1: forward as button-held motion to TUIs that subscribed
        // to mode 1002 / 1003. Mode 1000 (clicks only) drops drags.
        switch mouseGestureOwner {
        case .mouseReporting:
            let bits = session.mouse_mode_bits()
            let dragOn = (bits & 0x02) != 0 || (bits & 0x04) != 0
            if dragOn,
                let (row, col) = pointToCell(event.locationInWindow)
            {
                MouseReporting.sendMotionEvent(
                    session: session, event: event,
                    row: row, col: col, button: 0)
            }
            return
        case .consumed:
            // ⌘-click already opened a link / file; the rest of the
            // gesture belongs to nobody.
            return
        case .selection:
            break
        }
        // I4 auto-scroll: when the drag goes off the top/bottom edge,
        // start a repeating timer that scrolls the viewport and
        // re-extends the selection to the clamped (in-view) cell. When
        // the user drags back inside the viewport, kill the timer.
        let pointInView = convert(event.locationInWindow, from: nil)
        // Remembered for `autoScrollTick`: the timer fires between mouse
        // events (and keeps firing while the user holds the pointer
        // still outside the view), so it needs the last known pointer
        // position to extend the selection to the cell the user is
        // actually pointing at.
        lastDragPointInWindow = event.locationInWindow
        let viewportTop = bounds.maxY
        let viewportBottom = bounds.minY
        let edgeHysteresisPt: CGFloat = 12.0
        let aboveTop = pointInView.y > viewportTop - edgeHysteresisPt
        let belowBottom = pointInView.y < viewportBottom + edgeHysteresisPt
        if aboveTop || belowBottom {
            // UX7: tier the scroll cadence by distance past the
            // viewport edge — slow near the edge (60 ms / line) so
            // the user can stop precisely, fast when dragged far
            // outside (30 ms / line). Boundary at 30pt outside.
            let distPastEdge: CGFloat =
                aboveTop
                ? pointInView.y - viewportTop
                : viewportBottom - pointInView.y
            let intervalMs: Int = distPastEdge > 30 ? 30 : 60
            // Direction: above top → scroll content down (positive),
            // exposing earlier scrollback. Below bottom → scroll up
            // (negative), back toward live tail.
            let delta: Int32 = aboveTop ? 1 : -1
            startAutoScroll(direction: delta, session: session, intervalMs: intervalMs)
        } else {
            stopAutoScroll()
        }

        if let (row, col) = pointToCell(event.locationInWindow) {
            session.update_selection(row, col)
            let mode = pendingSelection?.mode ?? Self.SELECTION_MODE_SIMPLE
            syncPendingSelection(
                from: session, fallback: (row: row, col: col), mode: mode)
            needsDisplay = true
            renderer.markNeedsRedraw()
        }
    }

    private func startAutoScroll(
        direction: Int32,
        session: TerminalSession,
        intervalMs: Int = 60
    ) {
        // If a timer is already running in the same direction AND
        // at the same cadence, leave it. A cadence change (e.g.,
        // user drags farther past the edge) restarts the timer.
        if autoScrollTimer != nil
            && autoScrollDirection == direction
            && autoScrollIntervalMs == intervalMs
        {
            return
        }
        stopAutoScroll()
        autoScrollDirection = direction
        autoScrollIntervalMs = intervalMs
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let dti: DispatchTimeInterval = .milliseconds(intervalMs)
        timer.schedule(deadline: .now() + dti, repeating: dti)
        // Re-resolve the session via `self.renderer.session` on each
        // tick rather than capturing the parameter strongly. If the
        // window closes mid-drag and the view deallocates before
        // `mouseUp` fires, the strong capture would keep the
        // `TerminalSession` alive until the timer source releases —
        // wasted retention. `[weak self]` collapses the tick to a
        // no-op once `self` is gone, and `self.renderer.session`
        // tracks whatever session is currently bound.
        timer.setEventHandler { [weak self] in
            guard let self, let session = self.renderer.session else { return }
            self.autoScrollTick(session: session, direction: direction)
        }
        timer.resume()
        autoScrollTimer = timer
    }

    private func stopAutoScroll() {
        autoScrollTimer?.cancel()
        autoScrollTimer = nil
        autoScrollDirection = 0
        autoScrollIntervalMs = nil
    }

    private func autoScrollTick(session: TerminalSession, direction: Int32) {
        session.scroll_lines(direction)
        // Extend to the cell the pointer is over. `pointToCell` clamps
        // out-of-view points into the viewport, so a pointer held above
        // the top edge lands on row 0 and one below the bottom on the
        // last row — the edge the scroll is heading toward — while the
        // column keeps tracking the pointer's x.
        //
        // Reading the column back out of `selection_span()` (what this
        // used to do) took index 3, the *bottom* endpoint of the ordered
        // span. On an upward drag that's the anchor, not the moving end,
        // so every tick snapped the leading edge back to the anchor's
        // column and the selection stopped following the pointer.
        guard let dragPoint = lastDragPointInWindow,
            let (row, col) = pointToCell(dragPoint)
        else { return }
        session.update_selection(row, col)
        let mode = pendingSelection?.mode ?? Self.SELECTION_MODE_SIMPLE
        syncPendingSelection(
            from: session,
            fallback: (row: row, col: col),
            mode: mode)
        needsDisplay = true
        renderer.markNeedsRedraw()
    }

    /// Read the engine's current selection span and store it into
    /// `pendingSelection`. When the engine has no span (empty `Vec`
    /// — Simple at anchor, no extension yet), fall back to the
    /// supplied cell so drag-extend has an anchor.
    func syncPendingSelection(
        from session: TerminalSession,
        fallback: (row: UInt16, col: UInt16),
        mode: UInt8
    ) {
        let span = session.selection_span()
        if span.count == 5 {
            pendingSelection = PendingSelection(
                start: (row: UInt16(span[0]), col: UInt16(span[1])),
                end: (row: UInt16(span[2]), col: UInt16(span[3])),
                mode: mode)
        } else {
            pendingSelection = PendingSelection(
                start: fallback, end: fallback, mode: mode)
        }
    }

    /// Re-project the mirror's viewport rows from the engine's span.
    ///
    /// `pendingSelection` caches *viewport-relative* rows, so anything
    /// that moves content under the viewport leaves it pointing at the
    /// wrong screen rows and the tint stays glued to the old ones while
    /// the text slides away. `scrollWheel` re-projects for user scrolls;
    /// this covers the other source — output scrolling the grid on its
    /// own (a streaming TUI mid-selection), which reaches no input
    /// handler at all. Called once per encoded frame by the renderer's
    /// selection-overlay encode.
    ///
    /// No-op unless the engine still has a span of its own: the mirror
    /// exists precisely to outlive an engine selection dropped by a grid
    /// write (see `pendingSelection`), so an empty span must leave it
    /// alone rather than collapse it.
    func reprojectSelectionMirror(from session: TerminalSession) {
        guard let pending = pendingSelection else { return }
        let span = session.selection_span()
        guard span.count == 5 else { return }
        pendingSelection = PendingSelection(
            start: (row: UInt16(span[0]), col: UInt16(span[1])),
            end: (row: UInt16(span[2]), col: UInt16(span[3])),
            mode: pending.mode)
    }

    override func mouseUp(with event: NSEvent) {
        defer { super.mouseUp(with: event) }
        // I4: kill any active drag-select auto-scroll timer.
        stopAutoScroll()
        lastDragPointInWindow = nil
        let owner = mouseGestureOwner
        mouseGestureOwner = .selection
        // PG1 mouse reporting — if the press went through to the TUI,
        // the release does too. Selection logic skipped.
        if owner == .mouseReporting {
            if let session = renderer.session,
                let (row, col) = pointToCell(event.locationInWindow)
            {
                MouseReporting.sendButtonEvent(
                    session: session, event: event, row: row, col: col,
                    button: 0, pressed: false)
            }
            return
        }
        if owner == .consumed { return }
        // I2 auto-copy on selection: when the user just finished a
        // drag-select (clickCount==1 + non-trivial distance from the
        // anchor) or any word/line select (clickCount ≥ 2), populate
        // the system pasteboard. iTerm2-style — the user can paste
        // immediately without reaching for ⌘C, and the visible
        // selection highlight stays put as the source-of-truth.
        guard renderer.session != nil, pendingSelection != nil else {
            return
        }
        let isWordOrLine = event.clickCount >= 2
        var wasDrag = false
        if let origin = mouseDownLocationInView {
            let endInView = convert(event.locationInWindow, from: nil)
            let dx = endInView.x - origin.x
            let dy = endInView.y - origin.y
            wasDrag = (dx * dx + dy * dy) > Self.autoCopyMinDragSquared
        }
        guard isWordOrLine || wasDrag else { return }
        copy(nil)
    }

    /// I2: minimum drag distance (squared, in view-space points) to
    /// treat a click-drag as a selection worth auto-copying. 4 pt is
    /// roughly one cell width and rejects accidental jitter on a
    /// single click without rejecting deliberate one-cell drags.
    private static let autoCopyMinDragSquared: CGFloat = 16.0

    /// I3 right-click context menu. Reuses the existing `copy:` and
    /// `paste:` selectors so menu validation flows through the same
    /// `validateMenuItem` path as the Edit menu items.
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let copyItem = NSMenuItem(
            title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        m.addItem(copyItem)
        let pasteItem = NSMenuItem(
            title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        m.addItem(pasteItem)
        m.addItem(NSMenuItem.separator())
        // UX5: Select All — matches macOS HIG context-menu pattern
        // (Mail, TextEdit, Safari all expose Select All in right-click).
        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: #selector(selectAll(_:)),
            keyEquivalent: "")
        selectAllItem.target = self
        m.addItem(selectAllItem)
        // UX5: Look Up — uses NSResponder.quickLookPreviewItems / the
        // system Look-Up panel when text is selected. The action is
        // wired via the responder chain; AppKit auto-disables when
        // no text is selected, so no per-item validateMenuItem.
        let lookUpItem = NSMenuItem(
            title: "Look Up “Selection”",
            action: #selector(showLookUpPanel(_:)),
            keyEquivalent: "")
        lookUpItem.target = self
        m.addItem(lookUpItem)
        // UX5: Services submenu — wraps `NSApp.servicesMenu` so users
        // can route the selected text to Translate, Spotlight, custom
        // Automator workflows, etc. AppKit populates this submenu
        // lazily based on the pasteboard, so we just need to expose
        // the hook.
        let servicesItem = NSMenuItem(
            title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        m.addItem(servicesItem)
        m.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(
            title: "Clear Buffer",
            action: #selector(clearScrollbackBuffer(_:)),
            keyEquivalent: "")
        clearItem.target = self
        m.addItem(clearItem)
        return m
    }

    /// UX5: "Look Up" — populate `quickLookPreviewItems` and ask
    /// AppKit to show the dictionary panel for the current selection.
    /// Falls back to a no-op when nothing is selected.
    @objc func showLookUpPanel(_ sender: Any?) {
        guard let session = renderer.session else { return }
        let text = session.selection_text().toString()
        guard !text.isEmpty else { return }
        let range = NSRange(location: 0, length: (text as NSString).length)
        self.showDefinition(
            for: NSAttributedString(string: text),
            range: range,
            options: nil,
            baselineOriginProvider: nil)
    }

    /// NSView's `menu(for:)` is a hook — it doesn't auto-pop a
    /// contextual menu on right-click. We have to either set
    /// `self.menu` (static) or explicitly pop the menu from
    /// `rightMouseDown`. The static path doesn't let us validate
    /// items per-call against the live selection / pasteboard, so
    /// we pop dynamically here instead. Without this override, our
    /// `menu(for:)` was never reached and right-click silently did
    /// nothing (regression report 2026-05-19).
    override func rightMouseDown(with event: NSEvent) {
        guard let m = self.menu(for: event) else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }

    /// I3 "Clear Buffer" menu action. Sends FF (`\u{0C}`) — the same
    /// byte zsh / bash / fish bind to `clear-screen` (matches ⌘K in
    /// iTerm2 / Terminal.app). The shell's binding redraws the prompt
    /// on the cleared screen; we don't reach into the scrollback ring
    /// from here (alacritty owns it).
    @objc func clearScrollbackBuffer(_ sender: Any?) {
        guard let session = renderer.session else { return }
        session.send_input(
            InputEventEncoder.makeKeyInputEvent(
                characters: "\u{0C}", keycode: 0, modifiers: []))
    }
}
