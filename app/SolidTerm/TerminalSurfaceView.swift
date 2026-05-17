// Implements spec/swift-app-modules.md §TerminalSurfaceView and the host
// portion of spec/metal-renderer.md (CAMetalLayer presentation).
//
// Phase 0 Day 3-4 task 3.3: bring up the Metal-backed surface and clear it
// to the theme background color every frame. Phase 1 task 3.11 / #19:
// NSTextInputClient skeleton — protocol conformance + insertText routing,
// stubs on the rest. M1 Week 4 task 4.9: real preedit composition state,
// marked-text rendering via GridPipeline + OverlayPipeline kind=3, and
// screen-space `firstRectForCharacterRange` for IME candidate-window
// anchoring (Thai dead-key composition, CJK candidates, macOS Dictation).

import AppKit
import CoreText
import Metal
import QuartzCore
import SwiftUI

final class TerminalSurfaceView: NSView, NSTextInputClient, NSMenuItemValidation {
    /// Hardcoded `bg-base` background (warm-shifted Zenzai Dark
    /// `#0e0d10` per `decisions/13-visual-design-direction.md` §Locks
    /// + `spec/design-tokens.md`) until ThemeManager arrives in M5.
    /// The layer's pixel format is `.bgra8Unorm_srgb`, so
    /// `MTLClearColor` is interpreted as **linear** values — Metal
    /// applies the sRGB encode on store. The actual byte→linear
    /// conversion lives in `SRGBLinearLUT.unpackLinear`; this constant
    /// is now a thin alias of `Theme.defaultClearMTL` so the
    /// renderer's per-cell sentinel resolution and the drawable's
    /// clear color can never drift apart.
    static let defaultClearColor: MTLClearColor = Theme.defaultClearMTL

    /// Compute the content-rect size that fits a `cols × rows` grid at
    /// the user's currently-selected font + size (M7-3). Used by
    /// `TerminalWindowController` so the window snaps to the grid for
    /// 3.9; resizable cells land at task 4.4/4.5.
    static func gridContentSize(cols: Int, rows: Int) -> CGSize {
        gridContentSize(
            cols: cols, rows: rows, fontSize: FontSettings.shared.size)
    }

    /// Size variant — used by `MetalRenderer.reloadFont` so windows
    /// with a per-window font-size override don't snap back to the
    /// global picker's metrics on atlas regen.
    static func gridContentSize(
        cols: Int, rows: Int, fontSize: CGFloat
    ) -> CGSize {
        let font = FontSettings.makeCTFont(
            family: FontSettings.shared.family, size: fontSize)
        let cell = GlyphAtlas.cellSize(for: font)
        return CGSize(
            width: Theme.Gutter.widthPt + cell.width * CGFloat(cols),
            height: cell.height * CGFloat(rows))
    }

    private let renderer: MetalRenderer

    /// Active IME composition state. Lives entirely Swift-side; never
    /// crosses the FFI per the spec — only committed text reaches
    /// `session.send_input`. Set by `setMarkedText`, cleared on
    /// `unmarkText` / `insertText` (commit path) / explicit empty-marked
    /// reset. Read by the renderer each frame via `activeComposition`
    /// to paint preedit cells + the underline overlay.
    ///
    /// Architecture: matches typical terminal IME (iTerm2, Ghostty,
    /// Alacritty) and avoids piping transient state through FFI. The
    /// engine never sees preedit bytes; if the user cancels composition,
    /// nothing reached the PTY in the first place.
    struct PreeditState: Equatable {
        /// The composed text shown to the user. Updated with each
        /// setMarkedText call as the IME refines its candidate.
        let text: String
        /// Caret position within `text`. macOS uses NSRange; we honor
        /// `location` for caret rendering and `length` for selection-
        /// within-composition (rare; e.g. Korean syllable-level
        /// selection). UTF-16 indices, matching NSRange convention.
        let selectedRange: NSRange
        /// Range of pre-existing committed text the IME is asking us
        /// to replace on commit. Used by Japanese reconversion (re-pick
        /// a kanji candidate for already-committed kana). NSNotFound
        /// location = no replacement; just append.
        let replacementRange: NSRange
    }

    private(set) var compositionState: PreeditState?

    /// Holds the `NSTextInputContext.keyboardSelectionDidChangeNotification`
    /// observer so deinit can remove it. Posted by AppKit when the user
    /// switches input source (⌃Space / globe key / menu bar). Without
    /// clearing our composition state at that point, a stale
    /// `compositionState` from the outgoing IME keeps `hasMarkedText`
    /// returning true on the next keystroke, which the `keyDown` gate
    /// reads as "composition still active → suppress direct send" — the
    /// user sees their first post-switch keystroke (and any backspace
    /// that follows it) sit and wait until AppKit's internal IME
    /// handoff completes a few frames later.
    private var inputSourceObserver: NSObjectProtocol?

    /// Test-friendly read accessor. Returns nil when no composition is
    /// active. Called from the renderer each frame to paint preedit
    /// cells; tuple shape minimizes coupling so future composition
    /// shape changes (e.g., per-clause attribute spans) don't ripple
    /// into MetalRenderer.
    var activeComposition: (text: String, selectedRange: NSRange, replacementRange: NSRange)? {
        guard let s = compositionState else { return nil }
        return (s.text, s.selectedRange, s.replacementRange)
    }

    override init(frame frameRect: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is required; no default device available")
        }
        self.renderer = MetalRenderer(device: device)
        super.init(frame: frameRect)

        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        renderer.attach(layer: metalLayer)
        // 4.9: renderer reads `activeComposition` each frame to paint
        // preedit cells. Weak ref via `attachHostView` so the renderer
        // doesn't retain its host (the controller owns both).
        renderer.attachHostView(self)

        // Drag-and-drop: Finder → terminal inserts file paths at the
        // cursor, shell-escaped (POSIX single-quote form) and space-
        // separated. Matches iTerm2 / Terminal.app behavior. Same
        // PTY byte path as paste/IME-committed text.
        registerForDraggedTypes([.fileURL])

        // Input-source change (⌃Space / globe key / menu bar): clear
        // any stale composition state so the first keystroke after
        // switch doesn't get held by `hasMarkedText()` still being
        // true from the outgoing IME. See `inputSourceObserver`.
        inputSourceObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleInputSourceChange()
        }
    }

    /// Reset IME state on input-source change. Called from the
    /// `NSTextInputContext.keyboardSelectionDidChangeNotification`
    /// observer.
    private func handleInputSourceChange() {
        if compositionState != nil {
            compositionState = nil
            renderer.invalidateCompositionRender()
        }
        // Tell AppKit's IME machinery to drop any in-flight marked
        // text it's holding for the outgoing input source. Without
        // this, the next keyDown still routes through the old
        // context's residual state for a few hundred ms.
        inputContext?.discardMarkedText()
        // Force `hasMarkedText` to flip back to false next read so
        // the keyDown gate stops suppressing direct send.
        insertTextFiredThisKeyDown = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalSurfaceView is AppKit-only; storyboards are not supported")
    }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// Test seam: lets `LatencyMeasurementTests` (commit 2) reach the
    /// renderer without exposing it on the wider public surface.
    var rendererForTesting: MetalRenderer { renderer }

    /// Used by `TerminalWindowController` to plumb the source window's
    /// cwd into the renderer's pending-session slot. Called before
    /// `windowChanged` fires (which spawns the PTY); the renderer
    /// consumes it once in `makeDefaultSession` and clears the slot.
    func setInitialCwd(_ cwd: String) {
        renderer.pendingInitialCwd = cwd
    }

    // MARK: - Input — keyDown routing + NSTextInputClient (#19)
    //
    // Routing model (iTerm2-pattern, validated against spec/swift-app-
    // modules.md:215 + research/04-ffi-and-metal-rendering.md):
    //
    // 1. keyDown clears `insertTextFiredThisKeyDown` and forwards to
    //    `inputContext?.handleEvent(event)`. The IME stack synchronously
    //    fires one of: insertText (committed text), setMarkedText
    //    (preedit), doCommand (command-mapped key like arrows / Esc /
    //    fn keys), or nothing (event the IME stack ignored).
    //
    // 2. Post-handleEvent, keyDown gates the direct-send fall-through
    //    on `!insertTextFiredThisKeyDown && !hasMarkedText()`:
    //
    //    - Printable ASCII (no IME): insertText fires, flag set →
    //      keyDown skips direct send (insertText already routed bytes).
    //    - Arrow / Esc / fn keys: doCommand fires (empty body, see
    //      `doCommand(by:)` below), flag stays false, hasMarkedText
    //      false → keyDown direct-sends raw NSEvent. This is critical
    //      for shell usability — shells need to see arrow keys.
    //    - IME preedit (e.g. CJK composition in progress): setMarkedText
    //      fires, hasMarkedText becomes true → keyDown skips direct send
    //      (composition isn't committed yet).
    //    - IME commit: handleEvent dispatches insertText with composed
    //      string → flag set → keyDown skips direct send (committed
    //      text already routed via insertText).
    //
    // 3. handleEvent's return value is intentionally discarded.
    //    NSTextInputContext.handleEvent returns `true` even when
    //    doCommand was a no-op for an unhandled selector — too coarse
    //    to gate on. The flag + hasMarkedText combination is what
    //    iTerm2 / Alacritty / Ghostty all use.
    //
    // Latency: `recordKeystroke` always fires from keyDown's outer
    // scope so the harness measures real keystroke→pixel latency
    // regardless of whether bytes went through insertText or direct
    // send. The harness only synthesizes ASCII keystrokes; real
    // IME-commit latency is M1 Week 2 measurement work.
    //
    // Menu-bar-bound ⌘ shortcuts (Quit/Hide/New Window/Close per
    // `AppMenu`) are intercepted by AppKit before the responder chain,
    // so they never reach this method. Non-menu ⌘ keystrokes pass
    // through to the session as raw bytes — defensible for a terminal
    // (vim, etc. legitimately want them) until FocusStackManager arrives
    // at Week 4+ to make the routing decision principled.

    override var acceptsFirstResponder: Bool { true }

    /// Set by `insertText` when the IME synchronously dispatches a
    /// committed string from inside `inputContext?.handleEvent`.
    /// Cleared at the top of every `keyDown`. Read by keyDown's
    /// fall-through gate to avoid double-sending bytes that already
    /// went through the insertText path.
    private var insertTextFiredThisKeyDown = false

    // MARK: 4.4 scroll wiring — keyCodes + trackpad accumulator
    //
    // PgUp / PgDn keyCodes are stable across keyboard layouts (Carbon
    // virtual keycodes from `HIToolbox/Events.h` — `kVK_PageUp = 0x74`,
    // `kVK_PageDown = 0x79`). We could match on
    // `charactersIgnoringModifiers == NSPageUpFunctionKey`, but the
    // Carbon constants are cheaper and more idiomatic for terminal
    // input handling. They also stay correct when an IME or keyboard
    // remapper rewrites the produced characters.
    private static let kVKPageUp: UInt16 = 0x74
    private static let kVKPageDown: UInt16 = 0x79
    private static let kVKDelete: UInt16 = 0x33  // ⌫ backspace

    /// Pixel-precision trackpad accumulator. NSEvent.scrollingDeltaY
    /// arrives in points, often as fractional values (Magic Trackpad
    /// reports sub-cell precision); we accumulate and flush at line
    /// boundaries so a slow drag still produces predictable scroll
    /// stepping.
    private var accumulatedScrollPt: CGFloat = 0

    // MARK: 4.5 selection — keyboard arrow virtual keycodes
    //
    // Carbon kVK_* constants from <HIToolbox/Events.h>. Stable across
    // keyboard layouts and across the Carbon → AppKit transition; the
    // shift+arrow handler below routes against these.
    private static let kVKLeftArrow: UInt16 = 0x7B  // 123
    private static let kVKRightArrow: UInt16 = 0x7C  // 124
    private static let kVKDownArrow: UInt16 = 0x7D  // 125
    private static let kVKUpArrow: UInt16 = 0x7E  // 126

    // Selection-mode constants — mirror of `nextterm_ffi::kinds::
    // SELECTION_MODE_*` from `crates/nextterm-ffi/src/bridge.rs`.
    // swift-bridge 0.1.59 doesn't export `pub const`s to Swift, so
    // these are hand-mirrored numeric literals with cite-comments
    // (same precedent as `InputEventEncoding`'s discriminator enums).
    static let SELECTION_MODE_SIMPLE: UInt8 = 0  // kinds::SELECTION_MODE_SIMPLE
    static let SELECTION_MODE_WORD: UInt8 = 1  // kinds::SELECTION_MODE_WORD
    static let SELECTION_MODE_LINE: UInt8 = 2  // kinds::SELECTION_MODE_LINE

    /// Last cell the shift+arrow handler extended a selection to.
    /// Tracked so successive arrow keystrokes keep extending the
    /// existing selection rather than re-anchoring on each press —
    /// mirrors iTerm2 / Terminal.app keyboard-selection UX.
    /// Reset to nil whenever the mouse / clearSelection retires the
    /// selection.
    private var keyboardSelectionEnd: (row: UInt16, col: UInt16)? = nil

    /// Swift-side authoritative selection mirror. `alacritty_terminal`
    /// clears `Term::selection` whenever a grid write intersects the
    /// selection's row range (see `term/mod.rs:1657,1773,1786,1803,1811`
    /// in the 0.26 source). TUIs like Claude CLI (Ink-based) redraw
    /// rows on every render tick, so any mouse selection vanishes
    /// before the user can press ⌘C — the engine has dropped it by
    /// the time the menu fires the copy selector.
    ///
    /// iTerm avoids this by keeping the selection in the UI layer. We
    /// follow suit: the mouse handlers set `pendingSelection` (this
    /// field) AND call the engine's `start_selection` / `update_selection`
    /// to keep both views in sync where possible. The renderer's
    /// selection-overlay prefers this Swift-side span via
    /// `swiftSelectionSpan`; ⌘C consults it to re-establish the engine
    /// view if it's been cleared, then reads `selection_text()`.
    ///
    /// Lifecycle:
    ///  - `mouseDown` overwrites with a fresh single-point span
    ///    (click-elsewhere semantics — iTerm parity).
    ///  - `mouseDragged` extends the end-point.
    ///  - `extendSelectionByArrow` (shift+arrow) clears it; keyboard
    ///    takes over and the engine selection stays authoritative for
    ///    that mode.
    ///  - Explicit clear paths (programmatic select in `copyBlock`
    ///    restore, `quickLook` restore) clear it.
    struct PendingSelection {
        var start: (row: UInt16, col: UInt16)
        var end: (row: UInt16, col: UInt16)
        var mode: UInt8
    }
    private var pendingSelection: PendingSelection?

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

        // Thai-aware backspace (Task #16): when the cell just left of
        // the cursor carries a multi-codepoint Thai cluster (e.g.
        // `ก่` = ก + ่), users expect the trailing tone mark to come
        // off independently — ก stays, ่ goes. Most shells delete one
        // code point per DEL so this often works by default, but some
        // configurations + cluster-aware widgets erase the whole
        // grapheme on a single DEL ("backspace ate both"). The fix:
        // intercept BS on the primary screen, peek at the cell, and
        // re-emit `cluster minus last codepoint` after the standard
        // DEL so the visible result is consistent regardless of shell.
        // Skipped on alt-screen (vim/less own backspace semantics) and
        // when the trailing codepoint isn't a Thai combining mark.
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

        // Discard handleEvent's return value — see method-level comment.
        // NSTextInputContext semantics make it unreliable for the gate.
        _ = inputContext?.handleEvent(event)

        if !insertTextFiredThisKeyDown && !hasMarkedText() {
            if let session = renderer.session {
                session.send_input(InputEventEncoder.encode(event))
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

    /// Thai-aware backspace handler. Returns `true` when this path
    /// fully owned the backspace event (caller should NOT also direct-
    /// send DEL); `false` means fall through to standard byte send.
    ///
    /// Decision tree:
    ///   1. Read the cell just left of the cursor via FFI
    ///      `cell_before_cursor()`. Empty bytes → not our case.
    ///   2. Decode as UTF-8. If only one Unicode scalar OR the trailing
    ///      scalar isn't a Thai combining mark → not our case.
    ///   3. Otherwise send: DEL + (cluster without last scalar) as
    ///      UTF-8 text. Shell sees the whole cluster deleted (DEL) and
    ///      the partial cluster re-typed — net visual effect is "tone
    ///      mark removed; base + earlier marks remain".
    ///
    /// Skipped paths:
    ///   - alt-screen (caller pre-gated via `session.is_alt_screen()`)
    ///   - cursor at column 0 (empty bytes from FFI)
    ///   - cell isn't a Thai-combining-mark cluster
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
        // Compose the truncated cluster — everything except the last
        // scalar. May still be multi-scalar if multiple marks stack
        // (e.g. ก + ั + ้ → after backspace: ก + ั).
        let truncated = String(String.UnicodeScalarView(scalars.dropLast()))
        // Wire payload: DEL + truncated UTF-8.
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
    }

    /// Convert a window-space point into terminal grid `(row, col)`.
    /// Returns nil before the renderer's atlas is built (no cell
    /// metrics) or when the point falls outside the grid origin.
    private func pointToCell(_ windowPoint: NSPoint) -> (row: UInt16, col: UInt16)? {
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

    override func mouseDown(with event: NSEvent) {
        guard let session = renderer.session,
            let (row, col) = pointToCell(event.locationInWindow)
        else {
            super.mouseDown(with: event)
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
            launchEditor(forPath: path)
            return
        }
        // Reset keyboard-selection tracking on any new mouseDown — the
        // mouse is now the active selection driver. Subsequent
        // shift+arrow presses re-anchor against the cursor or the
        // mouse-driven selection's end.
        keyboardSelectionEnd = nil

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
    }

    override func mouseDragged(with event: NSEvent) {
        guard let session = renderer.session,
            let (row, col) = pointToCell(event.locationInWindow)
        else {
            super.mouseDragged(with: event)
            return
        }
        session.update_selection(row, col)
        // Mirror from the engine so RTL drag (end.col < start.col) lands
        // as a normalized [start, end] pair, matching what alacritty's
        // `selection_span()` produces after `Side::Right` update.
        let mode = pendingSelection?.mode ?? Self.SELECTION_MODE_SIMPLE
        syncPendingSelection(
            from: session, fallback: (row: row, col: col), mode: mode)
        needsDisplay = true
    }

    /// Read the engine's current selection span and store it into
    /// `pendingSelection`. When the engine has no span (empty `Vec`
    /// — Simple at anchor, no extension yet), fall back to the
    /// supplied cell so drag-extend has an anchor.
    private func syncPendingSelection(
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

    override func mouseUp(with event: NSEvent) {
        // Selection persists past mouseUp; the next non-extending
        // mouseDown clears it via `start_selection` replacing the
        // prior `Term::selection`. 4.6 hooks copy via the Edit menu's
        // ⌘C selector (NSResponder routing through `copy(_:)` below)
        // — auto-copy-on-select is iTerm2 polish deferred per the
        // atomic 4.6 brief.
        super.mouseUp(with: event)
    }

    // MARK: 4.6 copy / paste — system pasteboard
    //
    // ⌘C and ⌘V land here via NSResponder chain dispatch from the
    // Edit menu items in `AppMenu.swift`. The menu items target the
    // first responder (no explicit `target` set — the
    // `#selector(NSText.copy(_:))` literal exists for compile-time
    // selector validation, not runtime targeting); when the surface
    // view is key responder these methods take the call.
    //
    // **Bracketed paste**: when the running app has enabled DECSET
    // 2004 (zsh ZLE, vim insert mode, fish, modern bash with
    // bind 'set enable-bracketed-paste on'), we wrap the pasted
    // payload in `\x1b[200~ ... \x1b[201~` so the app can distinguish
    // typed vs pasted bytes — pasted code into vim insert mode
    // doesn't get double-indented, ZLE doesn't auto-execute pasted
    // commands ending in `\n`, etc. Mode bit comes from
    // `session.bracketed_paste_enabled()` which surfaces alacritty's
    // `TermMode::BRACKETED_PASTE`.
    //
    // **Out of scope** for the atomic 4.6 brief: rich-text / HTML /
    // RTF copy, copy-on-select (iTerm2-style auto-copy when selection
    // ends), middle-click paste, image paste, paste-bracket-stripping
    // (when an app sets bracketed paste BUT the user pastes content
    // that itself contains `\x1b[201~` — paranoid handling deferred
    // to M5 polish).

    /// Copy the current selection to the system pasteboard. Reads the
    /// selection's text content via the FFI; empty strings (no-selection
    /// sentinel) leave the pasteboard untouched so the user's prior
    /// clipboard contents are preserved across stray ⌘C presses.
    ///
    /// **Engine-selection re-establish**: when the Swift mirror
    /// (`pendingSelection`) is non-nil but the engine has dropped its
    /// own selection (alacritty's `Term::selection` clears on any grid
    /// write intersecting the selection's row range — see
    /// `pendingSelection` docs for the source citation), we replay the
    /// mirror's anchor + extent through `start_selection` /
    /// `update_selection` before reading `selection_text()`. The engine
    /// then re-computes its span over the current grid, which is
    /// exactly the visible state the user wants to copy. Post-copy the
    /// engine span stays set so the visible overlay-tint persists; the
    /// mirror is the source-of-truth for which cells are highlighted.
    @objc func copy(_ sender: Any?) {
        guard let session = renderer.session else { return }
        // Detect engine-dropped selection: mirror present, engine span
        // empty. Re-establish so `selection_text()` has cells to read.
        if let sel = pendingSelection, session.selection_span().len() != 5 {
            session.start_selection(sel.mode, sel.start.row, sel.start.col)
            session.update_selection(sel.end.row, sel.end.col)
        }
        let text = session.selection_text().toString()
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// M2-6 — "Copy focused block" (⌘⇧C). Establishes a programmatic
    /// engine selection over the focused block's row range, reads the
    /// resulting cell text, restores the previous selection, and writes
    /// the text to the system pasteboard. When no block is focused,
    /// falls through to the standard `copy(_:)` path so the binding is
    /// not a dead-key when invoked outside a focused block.
    ///
    /// **Architectural note**: the selection round-trip leverages
    /// alacritty's existing range → text path inside the engine — no
    /// new FFI surface is needed. The "clean text" guarantee (no block
    /// chrome, no AppKit overlay characters) follows for free from
    /// Stack A: `selection_text()` returns alacritty grid cell content;
    /// the SwiftUI block UI is a sibling NSHostingView that doesn't
    /// touch the cell store. Pinned by Part A's contract tests.
    ///
    /// **Selection restore**: if the user had a manual selection active
    /// when they invoked Copy Block, we restore it after extracting the
    /// block's text so ⌘⇧C is non-destructive to the visible selection.
    /// Implementation reads `selection_span()` (the existing FFI sentinel
    /// — empty Vec means no active selection, 5-element Vec carries
    /// `[start_row, start_col, end_row, end_col, is_block]`), runs the
    /// programmatic select, extracts text, and re-establishes the
    /// original via `start_selection` + `update_selection`.
    ///
    /// **M6-5 keybinding source**: the ⌘⇧C key equivalent is sourced
    /// from `KeybindingStore.shared.lookup(.copyBlock)` via `AppMenu`,
    /// not hardcoded here. The selector is reached through the
    /// responder chain regardless of the bound key. Settings →
    /// Keybindings rebinds without touching this file.
    /// Copy-block was a Claude-block-aware variant of Copy. With block
    /// chrome stripped from solidterm, this is now a plain alias to Copy.
    @objc func copyBlock(_ sender: Any?) {
        copy(sender)
    }

    /// Paste from the system pasteboard. Reads the public-utf8 string
    /// type, wraps in bracketed-paste markers if the running app has
    /// enabled DECSET 2004, and feeds the result through the same
    /// `send_input` byte path as IME-committed text — single FFI call,
    /// engine-side parser handles the markers.
    @objc func paste(_ sender: Any?) {
        guard let session = renderer.session else { return }
        let pb = NSPasteboard.general

        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        let payload = Self.formatPastePayload(
            text, bracketedPasteEnabled: session.bracketed_paste_enabled())
        // 4.4 snap-to-bottom on user input — paste behaves like typing.
        session.scroll_to_bottom()
        session.send_input(
            InputEventEncoder.makeKeyInputEvent(
                characters: payload, keycode: 0, modifiers: []))
    }

    /// "Paste (Plain)" — ⌘⇧V. Pastes the pasteboard text verbatim,
    /// **bypassing** bracketed-paste wrapping even when the running
    /// program has enabled DECSET 2004. Workaround for TUIs that do not
    /// honor bracketed-paste (e.g. Ink-based CLIs like Claude Code)
    /// while running under a shell that did set the mode on the
    /// terminal: with stock ⌘V the `\e[200~ ... \e[201~` markers leak
    /// into the TUI's input field as literal text. ⌘⇧V skips the wrap,
    /// matching iTerm2's "Paste Special → Paste Without Markers" and
    /// Terminal.app's "Paste Selection".
    ///
    /// Same scroll-to-bottom + `send_input` plumbing as `paste(_:)` —
    /// only the wrap decision differs.
    @objc func pastePlain(_ sender: Any?) {
        guard let session = renderer.session else { return }
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        let payload = Self.formatPastePayload(text, bracketedPasteEnabled: false)
        session.scroll_to_bottom()
        session.send_input(
            InputEventEncoder.makeKeyInputEvent(
                characters: payload, keycode: 0, modifiers: []))
    }

    /// Pure helper exposed to XCTest. Returns `text` unchanged when
    /// bracketed paste is disabled; wraps in `ESC [200~ ... ESC [201~`
    /// when enabled. Kept `static` + side-effect-free so the test path
    /// doesn't need to stand up a session.
    static func formatPastePayload(_ text: String, bracketedPasteEnabled: Bool) -> String {
        if bracketedPasteEnabled {
            return "\u{1B}[200~" + text + "\u{1B}[201~"
        }
        return text
    }

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
        session.send_input(
            InputEventEncoder.makeKeyInputEvent(
                characters: payload, keycode: 0, modifiers: []))
        return true
    }

    /// Does `url` point at an image file the Kitty Graphics encoder
    /// can handle? `UTType.conforms(to: .image)` covers PNG, JPEG,
    /// HEIC, TIFF, GIF, BMP, plus less-common formats macOS knows
    /// about. Anything else (PDF, text, archives) gets shell-quoted
    /// as a path so the TUI can read or open it via its own tools.
    static func isImageFile(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey])
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
                UInt16(clamping: prev.get(index: 3) ?? 0))
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
        if action == #selector(copyBlock(_:)) {
            return true
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
        // Int → Int32: viewport scroll deltas are bounded by the
        // user's accumulated swipe length; saturating cast is safe.
        let clamped = Int32(clamping: lines)
        session.scroll_lines(clamped)
    }

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
    // and is the spec's pre-authorized architecture per the 4.9 brief.
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
    // per spec/swift-app-modules.md:210 — macOS Dictation fails
    // silently without it. Pinned by `IMETests` regression guard.

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
        // Required minimum per spec/swift-app-modules.md:210:
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
        // (research/04-ffi-and-metal-rendering.md §82, the
        // "Korean preedit lands at screen bottom" bug).
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        // 4.8: derive grid dimensions from the new view size and
        // forward to the renderer (which rebuilds GridPipeline +
        // forwards to the engine via FFI). `cellWidthPt` /
        // `cellHeightPt` return nil before the atlas is built —
        // `windowChanged` runs first on `viewDidMoveToWindow`, so by
        // the time the user can drag-resize the atlas exists.
        // Initial-attach `setFrameSize` calls land before
        // `windowChanged` and skip here (atlas nil).
        propagateGridSizeToRenderer(viewSize: newSize)
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
        // 80 cols` still negotiates 80 cols (not 80 + extra). Q2 from
        // research/19 §"Open questions": cell grid loses space first
        // when the window narrows; gutter stays at 24pt.
        let gridWidth = max(0, viewSize.width - Theme.Gutter.widthPt)
        let cols = max(1, Int((gridWidth / cellWidthPt).rounded(.down)))
        let rows = max(1, Int((viewSize.height / cellHeightPt).rounded(.down)))
        renderer.resizeGrid(cols: cols, rows: rows)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? metalLayer.contentsScale
        metalLayer.contentsScale = scale
        let size = bounds.size
        metalLayer.drawableSize = CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale))
    }


    // MARK: - M6-2 ⌘+hover / ⌘+click file-path open
    // MARK: - M7-1 ⌘+hover / ⌘+click OSC 8 hyperlink open

    /// The path currently underlined by `renderer.linkHover`. Cached
    /// alongside the hover so `mouseDown(.command)` doesn't have to
    /// re-detect.
    private var hoveredPath: URL?

    /// M7-1: the OSC 8 URI currently underlined by `renderer.linkHover`,
    /// when the hovered cell carries a `\e]8;;<URI>\e\\` annotation
    /// rather than a detector-matched filesystem path. Mutually
    /// exclusive with `hoveredPath` — OSC 8 takes priority (shell
    /// explicit assertion beats heuristic detection).
    private var hoveredHyperlink: URL?

    /// NSTrackingArea installed in `updateTrackingAreas`. Re-installed
    /// when the view's bounds change so the tracking rect always
    /// matches the visible viewport. `.activeInKeyWindow` keeps the
    /// underline from leaking when another app is foregrounded.
    private var fileClickTrackingArea: NSTrackingArea?

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
        recomputeFileClickHover(at: event.locationInWindow, modifiers: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearFileClickHover()
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let mouseInWindow = window?.mouseLocationOutsideOfEventStream ?? .zero
        recomputeFileClickHover(at: mouseInWindow, modifiers: event.modifierFlags)
    }

    private func recomputeFileClickHover(at windowPoint: NSPoint, modifiers: NSEvent.ModifierFlags)
    {
        guard modifiers.contains(.command),
            let session = renderer.session,
            let (row, col) = pointToCell(windowPoint)
        else {
            clearFileClickHover()
            return
        }

        // OSC 8 hyperlink is the only supported ⌘-hover surface in
        // solidterm. `uri == ""` is the sentinel for "no link at this cell".
        let hit = session.hyperlink_at(row, col)
        let hyperUri = hit.uri.toString()
        if !hyperUri.isEmpty, let url = URL(string: hyperUri) {
            renderer.linkHover = MetalRenderer.LinkHover(
                row: Int(row),
                startCol: Int(hit.start_col),
                span: Int(hit.span))
            hoveredHyperlink = url
            hoveredPath = nil
            NSCursor.pointingHand.set()
            return
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

    private func launchEditor(forPath url: URL) {
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
