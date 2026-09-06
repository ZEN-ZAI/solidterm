// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// `NSTextInputClient` for `TerminalSurfaceView`, split out of the
// single-file view along its existing MARKs: the load-bearing protocol
// methods, then the composition state (4.9) and the backing-layer /
// window / live-resize plumbing that followed them in the single file.
// Stored properties live in TerminalSurfaceView.swift because
// extensions cannot declare them.

import AppKit
import QuartzCore

extension TerminalSurfaceView {
    // MARK: NSTextInputClient — load-bearing methods

    /// Receives committed text from the IME stack (printable typing,
    /// dead-key resolution, CJK candidate confirmation, macOS
    /// Dictation). Routes to `session.send_input` via the lower-level
    /// encoder overload — NSEvent isn't available here so we synthesize
    /// an InputEvent without keycode/modifiers. The IME-resolved
    /// `chars` IS the bytes the engine wants.
    ///
    /// 4.9: clears any active composition state (commit path) and
    /// invalidates the renderer's composition render so the preedit
    /// cells are replaced on the next frame. Honors
    /// `replacementRange.length > 0` (Japanese reconversion, where the
    /// IME re-picks a kanji candidate for already-committed kana) by
    /// prefixing the new bytes with `replacementRange.length` DEL
    /// (0x7F) bytes — xterm/iTerm2 convention. If a shell's readline
    /// echo doesn't tolerate DEL retraction we'll surface the
    /// regression in dogfood and revisit.
    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        switch string {
        case let s as String: chars = s
        case let attr as NSAttributedString: chars = attr.string
        default: return
        }
        insertTextFiredThisKeyDown = true

        // 4.9: commit clears composition. Capture whether we were
        // composing so we can invalidate the renderer's preedit cells
        // (next frame must repaint the underlying real cells where
        // we'd been showing preedit).
        let wasComposing = compositionState != nil
        compositionState = nil
        if wasComposing {
            renderer.invalidateCompositionRender()
        }

        guard let session = renderer.session else { return }

        // 4.9 reconversion path: IME asks us to replace `length`
        // already-committed cells with `chars`. Send DEL bytes first
        // to retract, then the new bytes — matches xterm / iTerm2.
        // `length == 0` (the common case) skips the retraction.
        let payload: String
        if replacementRange.location != NSNotFound, replacementRange.length > 0 {
            payload =
                String(repeating: "\u{7F}", count: replacementRange.length) + chars
        } else {
            payload = chars
        }

        session.send_input(
            InputEventEncoder.makeKeyInputEvent(
                characters: payload, keycode: 0, modifiers: []))
    }

    /// Empty body — absorb without forwarding to `super`. NSResponder's
    /// default `doCommand(by:)` walks the chain looking for an
    /// NSText-style editor; not finding one, it fires `noResponder(for:)`
    /// which calls `NSBeep`. For a terminal that's the wrong behavior:
    /// arrow keys, Esc, function keys all need to reach the engine as
    /// raw NSEvents. The flag gate in `keyDown` (above) catches them on
    /// fall-through and direct-sends. Don't switch this to
    /// `super.doCommand(by:)` without restructuring the keyDown gate.
    ///
    /// M1 Week 2 task 4.9 may extend this to map specific selectors
    /// (e.g., `cancelOperation:` → ESC) into terminal-specific escape
    /// sequences. Today's skeleton trusts the fall-through path.
    override func doCommand(by selector: Selector) {
        // Intentionally empty — see method-level comment.
    }

    // MARK: NSTextInputClient — composition state (4.9)
    //
    // Composition is Swift-side only — preedit bytes never cross the
    // FFI; only committed text from `insertText` reaches the engine.
    // This matches typical terminal IME (iTerm2 / Ghostty / Alacritty)
    // and is the pre-authorized architecture for task 4.9.
    //
    // Lifecycle:
    //   - setMarkedText: start (or refine) composition; renderer
    //     paints preedit cells next frame.
    //   - unmarkText: clear composition; renderer marks cells for
    //     repaint.
    //   - insertText: commit path (above) — clears composition AND
    //     routes the committed bytes through send_input.
    //   - hasMarkedText: load-bearing for keyDown's gate. When a
    //     composition is active, the gate suppresses raw direct-send
    //     so composition keystrokes don't leak to the PTY.
    //
    // `validAttributesForMarkedText` MUST include `.markedClauseSegment`
    // — macOS Dictation fails silently without it. Pinned by the
    // `IMETests` regression guard.

    func setMarkedText(
        _ string: Any, selectedRange: NSRange, replacementRange: NSRange
    ) {
        let text: String
        switch string {
        case let s as String: text = s
        case let attr as NSAttributedString: text = attr.string
        default:
            // Unknown payload (defensive — protocol declares Any).
            // Clear any active composition rather than silently
            // ignoring; better to drop preedit than to leave stale
            // marked-text on screen.
            if compositionState != nil {
                compositionState = nil
                renderer.invalidateCompositionRender()
            }
            return
        }
        if text.isEmpty {
            // Empty marked text is the IME's "unmark" signal — some
            // input sources call setMarkedText("") instead of
            // unmarkText(). Treat them identically.
            if compositionState != nil {
                compositionState = nil
                renderer.invalidateCompositionRender()
            }
        } else {
            compositionState = PreeditState(
                text: text,
                selectedRange: selectedRange,
                replacementRange: replacementRange)
            renderer.invalidateCompositionRender()
        }
    }

    func unmarkText() {
        guard compositionState != nil else { return }
        compositionState = nil
        renderer.invalidateCompositionRender()
    }

    func selectedRange() -> NSRange {
        // When composing, return the IME's selection-within-preedit
        // (caret position + selection length within the marked text).
        // When not composing, NSNotFound — we don't expose committed-
        // text selection through this API; that's a separate concern
        // tracked by the Term::selection state.
        if let s = compositionState {
            return s.selectedRange
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        guard let s = compositionState else {
            return NSRange(location: NSNotFound, length: 0)
        }
        // Marked range covers the full preedit text. Origin at 0 since
        // the engine never sees preedit, so there's no committed-text
        // offset to add.
        return NSRange(location: 0, length: (s.text as NSString).length)
    }

    func hasMarkedText() -> Bool {
        // Load-bearing: keyDown's `!insertTextFiredThisKeyDown &&
        // !hasMarkedText()` gate keeps composition keystrokes from
        // leaking to the PTY. When this returns true (active preedit),
        // raw direct-send is suppressed; only the IME stack's
        // insertText commit reaches the engine.
        compositionState != nil
    }

    func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        // Return the slice of the marked text inside `range`. macOS
        // asks for this when (a) showing reconversion candidates,
        // (b) Dictation processes partial output, (c) some IMEs
        // refresh their candidate window after a setMarkedText call.
        // Returning nil for ranges outside the composition is
        // conventional — same behavior as NSTextView before composition
        // begins.
        guard let s = compositionState else { return nil }
        let utf16 = s.text.utf16
        let total = utf16.count
        let clampedLoc = max(0, min(range.location, total))
        let clampedLen = max(0, min(range.length, total - clampedLoc))
        if clampedLen == 0 { return nil }
        let start = utf16.index(utf16.startIndex, offsetBy: clampedLoc)
        let end = utf16.index(start, offsetBy: clampedLen)
        let substring = String(utf16[start..<end]) ?? ""
        if let actual = actualRange {
            actual.pointee = NSRange(location: clampedLoc, length: clampedLen)
        }
        return NSAttributedString(string: substring)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        // Required minimum:
        // - `.underlineStyle`: standard preedit underline.
        // - `.markedClauseSegment`: macOS Dictation requires this; it
        //   fails silently otherwise (regression-guarded by
        //   `IMETests.testValidAttributesIncludesMarkedClauseSegment`).
        // - `.foregroundColor`: spec lists it; some IMEs set per-clause
        //   colors and we want to receive (even if we currently
        //   ignore) them so future per-clause rendering doesn't need
        //   to flip this list.
        [.underlineStyle, .markedClauseSegment, .foregroundColor]
    }

    func firstRect(
        forCharacterRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSRect {
        // CRITICAL: must return SCREEN-space rect of the cursor cell.
        // Wrong coords = IME candidate window anchors at screen-bottom
        // (the "Korean preedit lands at screen bottom" bug).
        //
        // Coordinate flow:
        //   cell (row, col) → view-local rect → window-local → screen.
        //
        // Returns `.zero` defensively when:
        //   - the view isn't in a window (XCTest harness path), OR
        //   - the atlas hasn't been built yet (no cellSizePt available),
        // matching the pre-4.9 sentinel behavior. Production launches
        // always have both ready by the time an IME engages.
        if let actual = actualRange {
            actual.pointee = range
        }
        guard let window = self.window,
            let cellWidthPt = renderer.cellWidthPt,
            let cellHeightPt = renderer.cellHeightPt
        else { return .zero }
        let cursor = renderer.lastSeenCursor
        // Top-down grid origin; AppKit bounds are bottom-up. Convert
        // by flipping y against bounds.height. Match the renderer's
        // grid origin convention (row 0 at top of view).
        // M5.5-3: cell grid origin is shifted right by the gutter
        // width — IME candidate window anchors must follow.
        let cellOriginViewX =
            Theme.Gutter.widthPt + CGFloat(cursor.col) * cellWidthPt
        let cellOriginViewY =
            self.bounds.height - CGFloat(Int(cursor.row) + 1) * cellHeightPt
        let viewRect = NSRect(
            x: cellOriginViewX, y: cellOriginViewY,
            width: cellWidthPt, height: cellHeightPt)
        let windowRect = self.convert(viewRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    func characterIndex(for point: NSPoint) -> Int {
        // Hit-test a screen point against composition cells. The
        // composition is a flat single-row sequence at the cursor row;
        // an in-composition cursor-move click would map to the column
        // within that row. Few IMEs rely on this (it's primarily a
        // Cocoa text-view affordance for click-to-position-caret-mid-
        // composition). For the atomic 4.9 brief we return 0
        // (composition start) — gracefully degrades to "treat clicks
        // as composition-start" without crashing. Surface as a polish
        // item if dogfood reveals an IME that depends on it.
        return 0
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.framebufferOnly = false  // 3.8+ atlas readback paths need this
        layer.isOpaque = true
        return layer
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderer.windowChanged(window: window)
        rebindWindowFocusObservers()
        updateDrawableSize()
        // 4.8 follow-up: any `setFrameSize` calls that ran during view
        // construction (initial-attach, autosaved-frame restore) hit
        // the `cellWidthPt == nil` early-return inside
        // `propagateGridSizeToRenderer`, leaving `gridCols` /
        // `gridRows` at the 80×24 defaults even when the contentView
        // is much larger. Now that `windowChanged` has built the
        // atlas, drive a one-shot propagation so the engine + grid
        // pipeline match the actual view size before the first frame.
        propagateGridSizeToRenderer(viewSize: bounds.size)
    }

    /// (Re)attach key-status observers to the current window so focus-
    /// event reporting tracks the right window after the view moves
    /// (tab tear-off, window close/reopen). Tears down the prior set
    /// first so we never double-fire or leak an observer on a dead
    /// window.
    private func rebindWindowFocusObservers() {
        for obs in windowFocusObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        windowFocusObservers.removeAll()
        guard let window else { return }
        let nc = NotificationCenter.default
        windowFocusObservers.append(
            nc.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window, queue: .main
            ) { [weak self] _ in self?.sendFocusEvent(focused: true) })
        windowFocusObservers.append(
            nc.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main
            ) { [weak self] _ in self?.sendFocusEvent(focused: false) })
    }

    /// Emit a focus in/out report to the PTY when the running program
    /// has enabled DECSET 1004. `\e[I` = focus gained, `\e[O` = focus
    /// lost (xterm convention). No-op when the mode is off, so programs
    /// that never asked for focus events see nothing. Routed through the
    /// same `send_input` byte path as keystrokes; does not snap the
    /// scrollback (out-of-band signal, not user typing).
    private func sendFocusEvent(focused: Bool) {
        guard let session = renderer.session, session.focus_events_enabled()
        else { return }
        let seq = focused ? "\u{1B}[I" : "\u{1B}[O"
        session.send_input(
            InputEventEncoder.makeKeyInputEvent(
                characters: seq, keycode: 0, modifiers: []))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        // P2 resize debounce: trackpad pinch-resize fires 10–50
        // setFrameSize events per gesture; each `resizeGrid` rebuilds
        // the GridPipeline (texture re-alloc + memcpy + FFI roundtrip)
        // and is the dominant per-event cost. Coalesce by deferring
        // the propagation through a short DispatchSourceTimer. Live
        // window-drag resize bypasses the debounce via
        // `windowDidEndLiveResize` so the post-drag frame is sharp.
        if inLiveResize {
            scheduleDebouncedResize(targetSize: newSize)
        } else {
            // Non-live resize (programmatic, viewDidMoveToWindow,
            // backing-scale change, …) — apply immediately for the
            // same-tick visual that callers expect.
            cancelDebouncedResize()
            propagateGridSizeToRenderer(viewSize: newSize)
        }
    }

    private func scheduleDebouncedResize(targetSize: NSSize) {
        pendingResizeSize = targetSize
        if pendingResizeTimer != nil { return }  // timer in flight
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.flushPendingResize()
        }
        timer.resume()
        pendingResizeTimer = timer
    }

    private func cancelDebouncedResize() {
        pendingResizeTimer?.cancel()
        pendingResizeTimer = nil
        pendingResizeSize = nil
    }

    private func flushPendingResize() {
        defer { pendingResizeTimer = nil }
        guard let size = pendingResizeSize else { return }
        pendingResizeSize = nil
        propagateGridSizeToRenderer(viewSize: size)
    }

    /// P2: window finished live-resize (mouse-up after edge drag).
    /// Flush immediately so the post-drag frame lands at the right
    /// dimensions without waiting for the debounce timer.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        pendingResizeTimer?.cancel()
        pendingResizeTimer = nil
        if let size = pendingResizeSize ?? Optional(bounds.size) {
            pendingResizeSize = nil
            propagateGridSizeToRenderer(viewSize: size)
        }
    }

    /// 4.8: compute floor-divided cell dimensions from the view's
    /// point-size and call `MetalRenderer.resizeGrid`. Floor (rather
    /// than round) avoids painting a partial trailing column / row
    /// when the window is fractionally larger than `n` cells. Clamp
    /// to ≥ 1 so a transient layout pass at zero size doesn't push
    /// invalid dimensions to alacritty.
    private func propagateGridSizeToRenderer(viewSize: NSSize) {
        guard let cellWidthPt = renderer.cellWidthPt,
            let cellHeightPt = renderer.cellHeightPt,
            cellWidthPt > 0, cellHeightPt > 0
        else { return }
        // M5.5-3: cell grid is sibling to the 24pt gutter — subtract
        // its width before computing cols so a window grown by `gutter +
        // 80 cols` still negotiates 80 cols (not 80 + extra). Resolved
        // trade-off: the cell grid loses space first when the window
        // narrows; the gutter stays at 24pt.
        let gridWidth = max(0, viewSize.width - Theme.Gutter.widthPt)
        let cols = max(1, Int((gridWidth / cellWidthPt).rounded(.down)))
        let rows = max(1, Int((viewSize.height / cellHeightPt).rounded(.down)))
        renderer.resizeGrid(cols: cols, rows: rows)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        // Rebuild the atlas at the new backing scale when it actually
        // changes (see `lastBackingScale`). Seed-on-first: the initial
        // callback only records the scale — `windowChanged` already built
        // the atlas — so we don't rebuild redundantly during setup.
        let scale = window?.backingScaleFactor ?? metalLayer.contentsScale
        if lastBackingScale != 0, scale != lastBackingScale {
            _ = renderer.reloadFont()
            propagateGridSizeToRenderer(viewSize: bounds.size)
        }
        lastBackingScale = scale
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? metalLayer.contentsScale
        metalLayer.contentsScale = scale
        let size = bounds.size
        metalLayer.drawableSize = CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale))
    }
}
