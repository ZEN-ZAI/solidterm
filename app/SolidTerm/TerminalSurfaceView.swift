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
//
// The view is split along its MARKs across sibling files: selection and
// keyDown routing in TerminalSurfaceView+Selection.swift, copy / paste in
// +Pasteboard.swift, Finder drops in +DragDrop.swift, the NSTextInputClient
// methods and the composition state in +TextInputClient.swift, ⌘-hover /
// ⌘-click link opening in +Links.swift. What stays here: the class
// declaration with its conformances, every stored property, init / deinit,
// the input-source observers, the restored-command pre-fill and the scroll
// keycodes.

import AppKit
import Carbon.HIToolbox
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

    let renderer: MetalRenderer

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

    var compositionState: PreeditState?

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

    /// Cached ID of the currently-selected keyboard input source, polled
    /// synchronously at the top of every `keyDown`. macOS's
    /// `keyboardSelectionDidChangeNotification` is dispatched on the
    /// main queue *after* the OS has already routed the next keystroke
    /// through the new IME — so for a few frames after ⌃Space / globe,
    /// `compositionState` from the outgoing IME is stale but the
    /// observer hasn't run yet. We compare on each keystroke and run
    /// the reset path synchronously when the ID changes, eliminating
    /// the post-switch input lag entirely (the notification-driven
    /// path stays as a backstop for switches that don't coincide with
    /// a keystroke).
    var lastInputSourceID: String?

    /// Cached backing-scale factor, compared in
    /// `viewDidChangeBackingProperties`. A window moving to a display with
    /// a different scale factor (Retina 2× → external 1×), or a scaled-
    /// resolution change, alters the backing scale WITHOUT changing the
    /// view's point size — so no resize fires and the glyph atlas +
    /// `cellSizePx` (baked from the scale at `reloadFont`/`windowChanged`
    /// time) would stay stale, rendering text ~2× too large / blurry.
    /// Seeded on the first callback (`windowChanged` builds the initial
    /// atlas); a later change triggers an atlas rebuild.
    var lastBackingScale: CGFloat = 0

    /// Observers for the host window's key-status changes, used to drive
    /// focus-event reporting (DECSET 1004): a TUI that enabled it expects
    /// `\e[I` when the terminal gains focus and `\e[O` when it loses it
    /// (vim `FocusGained`/`FocusLost`, tmux focus events, neovim
    /// autoread). Re-bound to the current window in `viewDidMoveToWindow`
    /// and torn down in `deinit`. Empty when the view has no window.
    var windowFocusObservers: [NSObjectProtocol] = []

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
    /// observer AND synchronously from `keyDown` when the cached
    /// input-source ID has rotated since the last keystroke.
    func handleInputSourceChange() {
        // Idempotence / re-entrancy guard — fixes a 100%-CPU main-thread
        // hang. The `discardMarkedText()` below drives TSM/IMK
        // (MyActivateTSMDocument → IMKInputSessionActivate), which re-posts
        // `keyboardSelectionDidChangeNotification`. This observer runs on
        // `.main`, so the re-post is re-scheduled as a fresh main-queue block
        // rather than recursing — an unbounded loop that wedges the run loop
        // (observed in the wild: a ~38h pegged-CPU hang). The re-post carries
        // the SAME input source (activation doesn't rotate the selection), so
        // bail when the ID hasn't actually changed. A genuine switch has
        // `currentID != lastInputSourceID` and still reaches
        // `discardMarkedText()` exactly once; this also dedups the synchronous
        // keyDown path (see `:507`) against this notification backstop when a
        // single switch happens to coincide with a keystroke.
        let currentID = Self.currentInputSourceID()
        guard currentID != lastInputSourceID else { return }

        if compositionState != nil {
            compositionState = nil
            renderer.invalidateCompositionRender()
        }
        // Tell AppKit's IME machinery to drop any in-flight marked
        // text it's holding for the outgoing input source. Without
        // this, the next keyDown still routes through the old
        // context's residual state for a few hundred ms.
        inputContext?.discardMarkedText()
        // Refresh the input-context binding so the next handleEvent
        // dispatch uses the new input source's plugin without waiting
        // for AppKit's lazy re-bind.
        inputContext?.invalidateCharacterCoordinates()
        // Force `hasMarkedText` to flip back to false next read so
        // the keyDown gate stops suppressing direct send.
        insertTextFiredThisKeyDown = false
        lastInputSourceID = currentID
    }

    /// Tear down any in-flight preedit WITHOUT committing it. Mirrors the
    /// `compositionState = nil` + `invalidateCompositionRender()` pair the
    /// lifecycle methods (`unmarkText`, the empty-`setMarkedText` branch,
    /// `handleInputSourceChange`) already run, factored out so the new
    /// control-key intercept and the ⌘-shortcut actions (`copy`/`paste`/
    /// `pastePlain`/`selectAll`) share one correct cancel path.
    ///
    /// Why this exists (the bug it fixes): this view is a CUSTOM
    /// `NSTextInputClient`. When a ⌘-key equivalent (Copy/Paste/Select
    /// All) fires while a Thai/CJK composition is active, AppKit does
    /// NOT auto-commit or cancel the preedit for a custom client the way
    /// it would for an `NSTextView`. So none of insertText / unmarkText /
    /// setMarkedText("") runs, and `compositionState` is left orphaned
    /// non-nil. From then on `hasMarkedText()` stays true forever and the
    /// `keyDown` direct-send gate (`!insertTextFiredThisKeyDown &&
    /// !hasMarkedText()`) blocks EVERY raw key — including Ctrl-C (SIGINT)
    /// — so the user can't interrupt a foreground TUI. Callers invoke this
    /// to drop the orphan before it wedges the gate.
    ///
    /// Also tells AppKit's IME machinery to discard its own marked-text
    /// bookkeeping (`discardMarkedText`), so the input context and our
    /// Swift-side state stay in agreement; otherwise the IME could re-emit
    /// the stale preedit on the next handleEvent.
    func cancelComposition() {
        guard compositionState != nil else { return }
        compositionState = nil
        renderer.invalidateCompositionRender()
        inputContext?.discardMarkedText()
    }

    /// True when `event` is a Control-modified key that a terminal must
    /// treat as a raw C0 control byte (Ctrl-A..Z, Ctrl-[ \ ] ^ _,
    /// Ctrl-Space) rather than as IME composition input. Such keystrokes
    /// are NEVER preedit: every terminal forwards them verbatim. The
    /// decision rides on `NSEvent.characters` already being the C0 byte
    /// macOS produced (Ctrl-C → "\u{03}", Ctrl-[ → "\u{1B}", …) so the
    /// intercept's bytes match the normal encoder path exactly — we only
    /// change WHEN they're sent, never WHAT.
    ///
    /// Strictly scoped to Control-WITHOUT-Command so app shortcuts
    /// (⌘C copy, ⌃⌘F full-screen, …) are never swallowed. Control+Option
    /// combos are deliberately excluded too: those carry their own
    /// terminal semantics (some readline bindings, Option-as-Meta with a
    /// control) and the existing encode path / Option-as-Meta block must
    /// keep handling them. Shift is allowed (Ctrl-Shift-key still resolves
    /// to a control byte where one exists; otherwise `characters` is empty
    /// and we return false).
    ///
    /// Internal (not `private`) so the unit-test target can pin the exact
    /// scope of the bypass (Ctrl-C in, ⌘C / Ctrl+Option / plain keys out)
    /// without the headless-fragile live `keyDown` + input-context path.
    static func isControlByteKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.control),
            !mods.contains(.command),
            !mods.contains(.option)
        else { return false }
        // `characters` is the modifier-resolved text: for a key that maps
        // to a C0 control code under Control, macOS already returns that
        // single 0x00..0x1F (or 0x7F for some layouts) byte here. A
        // Control-modified key that does NOT produce a control byte (e.g.
        // Ctrl-9, which has no C0 mapping) yields a normal/empty
        // `characters`; we leave those on the regular path.
        guard let chars = event.characters, chars.unicodeScalars.count == 1,
            let scalar = chars.unicodeScalars.first
        else { return false }
        return scalar.value <= 0x1F || scalar.value == 0x7F
    }

    /// Current selected keyboard input source ID via Carbon TIS.
    /// Cheap (a `CFRetain` + dictionary lookup); safe to poll on every
    /// keystroke. Returns nil if TIS is unavailable, which collapses
    /// the keyDown change-check to a no-op so we don't reset state
    /// based on transient failures.
    static func currentInputSourceID() -> String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        else { return nil }
        guard let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
        else { return nil }
        let cf = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        return cf as String
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalSurfaceView is AppKit-only; storyboards are not supported")
    }

    deinit {
        // `DispatchSourceTimer` instances must be cancelled before their
        // last strong reference drops; releasing an un-cancelled source
        // is undefined per Apple's GCD docs and has caused hangs in the
        // wild. Both timers below outlive the view by a few ms when the
        // window closes mid-drag / mid-resize, so the deinit guard is
        // load-bearing — not cosmetic.
        autoScrollTimer?.cancel()
        autoScrollTimer = nil
        pendingResizeTimer?.cancel()
        pendingResizeTimer = nil
        for obs in windowFocusObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        windowFocusObservers.removeAll()
        if let obs = inputSourceObserver {
            NotificationCenter.default.removeObserver(obs)
            inputSourceObserver = nil
        }
    }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// Test seam: lets `LatencyMeasurementTests` (commit 2) reach the
    /// renderer without exposing it on the wider public surface.
    var rendererForTesting: MetalRenderer { renderer }

    /// Test seam: when non-nil, receives the exact payload
    /// `performDragOperation` hands to the session, alongside the real
    /// PTY write rather than instead of it. Nil in production, so the
    /// drop path is byte-for-byte what it was; `DragDropTests` sets it
    /// to assert the composed string without waiting on a shell echo.
    /// Declared here rather than beside the drop handler because a
    /// stored property cannot live in the extension ticket 13 moves
    /// that section into.
    var dropPayloadSink: ((String) -> Void)?

    /// Used by `TerminalWindowController` to plumb the source window's
    /// cwd into the renderer's pending-session slot. Called before
    /// `windowChanged` fires (which spawns the PTY); the renderer
    /// consumes it once in `makeDefaultSession` and clears the slot.
    func setInitialCwd(_ cwd: String) {
        renderer.pendingInitialCwd = cwd
    }

    // MARK: - Restored-command pre-fill

    /// The command this window was running before it was restored, waiting
    /// to be typed onto the fresh prompt. Cleared once fed, once the user
    /// types, or once we give up waiting for the shell.
    private var pendingPrefillCommand: String?
    private var prefillWaitTicks = 0

    /// Interval between "is the shell up yet?" checks.
    private static let prefillPollInterval: DispatchTimeInterval = .milliseconds(250)
    /// Give up after ~5s. A shell that hasn't spawned by then is not going
    /// to accept a pre-fill sensibly.
    private static let prefillMaxWaitTicks = 20
    /// Extra settle time after the session exists, so zsh has drawn its
    /// prompt and zle owns the line. Feeding earlier puts the text in front
    /// of the prompt, where it looks like output instead of input.
    private static let prefillSettleDelay: DispatchTimeInterval = .milliseconds(400)

    /// Queue a restored command to appear at the prompt. Never executes it:
    /// the payload is sanitised (no newline can survive
    /// `SessionJournal.sanitizeCommand`) and fed without a trailing return,
    /// so the user still has to press Enter.
    func setPendingPrefill(_ command: String) {
        let clean = SessionJournal.sanitizeCommand(command)
        guard !clean.isEmpty else { return }
        pendingPrefillCommand = clean
        prefillWaitTicks = 0
        schedulePrefill()
    }

    /// Drop a queued pre-fill because the user started typing. Whatever
    /// they are doing now outranks a command from the previous run.
    func cancelPendingPrefill() {
        pendingPrefillCommand = nil
    }

    private func schedulePrefill() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.prefillPollInterval) {
            [weak self] in
            guard let self, self.pendingPrefillCommand != nil else { return }
            guard self.renderer.session != nil else {
                self.prefillWaitTicks += 1
                if self.prefillWaitTicks < Self.prefillMaxWaitTicks {
                    self.schedulePrefill()
                } else {
                    self.pendingPrefillCommand = nil
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.prefillSettleDelay) {
                [weak self] in
                guard let self,
                    let command = self.pendingPrefillCommand,
                    let session = self.renderer.session
                else { return }
                self.pendingPrefillCommand = nil
                session.scroll_to_bottom()
                // Deliberately NOT wrapped in bracketed paste: at this point
                // the shell has only just come up and may not have enabled
                // DECSET 2004 yet, and the payload has no control bytes to
                // protect anyway.
                Self.feedChunked(command, into: session)
            }
        }
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
    var insertTextFiredThisKeyDown = false

    // MARK: 4.4 scroll wiring — keyCodes + trackpad accumulator
    //
    // PgUp / PgDn keyCodes are stable across keyboard layouts (Carbon
    // virtual keycodes from `HIToolbox/Events.h` — `kVK_PageUp = 0x74`,
    // `kVK_PageDown = 0x79`). We could match on
    // `charactersIgnoringModifiers == NSPageUpFunctionKey`, but the
    // Carbon constants are cheaper and more idiomatic for terminal
    // input handling. They also stay correct when an IME or keyboard
    // remapper rewrites the produced characters.
    static let kVKPageUp: UInt16 = 0x74
    static let kVKPageDown: UInt16 = 0x79
    static let kVKDelete: UInt16 = 0x33  // ⌫ backspace

    /// Pixel-precision trackpad accumulator. NSEvent.scrollingDeltaY
    /// arrives in points, often as fractional values (Magic Trackpad
    /// reports sub-cell precision); we accumulate and flush at line
    /// boundaries so a slow drag still produces predictable scroll
    /// stepping.
    var accumulatedScrollPt: CGFloat = 0

    // MARK: stored properties for the split-out extension files
    //
    // Swift extensions cannot declare stored instance properties, so these
    // stayed behind, grouped by the file each was hoisted out of and kept in
    // their original order with their original doc comments.

    // TerminalSurfaceView+Selection.swift

    /// Last cell the shift+arrow handler extended a selection to.
    /// Tracked so successive arrow keystrokes keep extending the
    /// existing selection rather than re-anchoring on each press —
    /// mirrors iTerm2 / Terminal.app keyboard-selection UX.
    /// Reset to nil whenever the mouse / clearSelection retires the
    /// selection.
    var keyboardSelectionEnd: (row: UInt16, col: UInt16)? = nil

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
    ///  - Programmatic selection paths (e.g. `selectAll`) write to it
    ///    after running their own `start_selection` + `update_selection`.
    struct PendingSelection {
        var start: (row: UInt16, col: UInt16)
        var end: (row: UInt16, col: UInt16)
        var mode: UInt8
    }
    var pendingSelection: PendingSelection?

    /// I4: in-flight repeating timer for drag-select auto-scroll.
    /// Nil when the drag is inside the viewport. Fires every 30 ms on
    /// the main queue; killed in `mouseUp` and when the drag returns
    /// inside the viewport.
    var autoScrollTimer: DispatchSourceTimer?

    var autoScrollDirection: Int32 = 0
    /// UX7: tracks the cadence the in-flight `autoScrollTimer` was
    /// scheduled with (in milliseconds) so we can detect when the
    /// user drags farther out and needs the faster tier.
    var autoScrollIntervalMs: Int? = nil

    /// I4: last pointer position seen by `mouseDragged`, in window
    /// coordinates. Read by `autoScrollTick`, which fires on a timer
    /// with no NSEvent of its own. Cleared on `mouseUp`.
    var lastDragPointInWindow: NSPoint?

    /// Who owns the in-flight mouse gesture.
    ///
    /// Decided once, at `mouseDown`, and held for the whole press →
    /// drag → release. `mouseDown` and `mouseUp` used to re-test the
    /// modifier flags on each event while `mouseDragged` only tested
    /// `MouseReporting.modeActive`, so the ⌥/⌘ override documented on
    /// `mouseDown` half-worked over a TUI holding the mouse: the press
    /// started a selection, every drag went to the TUI instead of
    /// extending it, and the release auto-copied the 1-cell anchor.
    /// Latching the owner also stops a modifier pressed or released
    /// mid-drag from handing the rest of the gesture to the other side.
    enum MouseGestureOwner {
        /// Our own selection machinery (the default, and what a
        /// modifier-held press over a mouse-capturing TUI selects).
        case selection
        /// Forwarded to the child as xterm mouse sequences.
        case mouseReporting
        /// Spent on the press itself — ⌘-click opening a hyperlink or
        /// a file path. Drag and release do nothing.
        case consumed
    }
    var mouseGestureOwner: MouseGestureOwner = .selection

    /// I2: mouse-down origin in view-space points, captured at the top
    /// of `mouseDown` so `mouseUp` can compute drag distance for the
    /// auto-copy gate.
    var mouseDownLocationInView: CGPoint?

    // TerminalSurfaceView+TextInputClient.swift

    /// P2 resize debounce: pending timer + the size it will apply on
    /// fire. Last-write-wins — subsequent `setFrameSize` calls during
    /// the debounce window replace `pendingResizeSize` and reset the
    /// timer. The timer fires on main queue at ~50 ms cadence; with
    /// a fast trackpad pinch the user sees one resize at gesture-end
    /// instead of 30.
    var pendingResizeTimer: DispatchSourceTimer?
    var pendingResizeSize: NSSize?

    // TerminalSurfaceView+Links.swift

    /// The path currently underlined by `renderer.linkHover`. Cached
    /// alongside the hover so `mouseDown(.command)` doesn't have to
    /// re-detect.
    var hoveredPath: URL?

    /// M7-1: the OSC 8 URI currently underlined by `renderer.linkHover`,
    /// when the hovered cell carries a `\e]8;;<URI>\e\\` annotation
    /// rather than a detector-matched filesystem path. Mutually
    /// exclusive with `hoveredPath` — OSC 8 takes priority (shell
    /// explicit assertion beats heuristic detection).
    var hoveredHyperlink: URL?

    /// NSTrackingArea installed in `updateTrackingAreas`. Re-installed
    /// when the view's bounds change so the tracking rect always
    /// matches the visible viewport. `.activeInKeyWindow` keeps the
    /// underline from leaking when another app is foregrounded.
    var fileClickTrackingArea: NSTrackingArea?
}
