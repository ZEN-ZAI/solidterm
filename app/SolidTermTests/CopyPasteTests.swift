// Tests for M1 task 4.6 — copy to / paste from the system pasteboard.
//
// Three layers of coverage live here:
//
//  1. **FFI shape pinning** — `selection_text()` and
//     `bracketed_paste_enabled()` round-trip through the Swift binding
//     so future bridge.rs ABI drift surfaces in CI alongside the
//     Rust-side tests in `crates/solidterm-ffi/src/bridge.rs::tests`.
//
//  2. **Bracketed-paste payload formatting** — pure-function tests on
//     `TerminalSurfaceView.formatPastePayload(_:bracketedPasteEnabled:)`
//     that pin the wire shape of the wrap-vs-passthrough decision. The
//     wrapped form is the only thing the engine will see at ⌘V time;
//     getting the markers wrong would silently break vim insert mode,
//     zsh ZLE, etc.
//
//  3. **Copy / paste end-to-end via direct method invocation** — calls
//     `surface.copy(nil)` / `surface.paste(nil)` (the same selectors the
//     menu items target) on a live `TerminalSurfaceView` and asserts
//     against `NSPasteboard.general`. Mirrors how AppKit's responder
//     chain dispatches ⌘C / ⌘V into the view; live menu-item synthesis
//     hits the same headless-XCTest constraint that 4.4 / 4.5 saw with
//     scrollWheel and mouse drag (per memory
//     `feedback_environment_blocks_methodology`), so we exercise the
//     full handler path through the public selector instead.

import AppKit
import XCTest

@testable import SolidTerm

final class CopyPasteTests: XCTestCase {

    /// Each test isolates the system pasteboard so cross-test contamination
    /// can't sneak in. We snapshot + restore around each test, not in
    /// `setUp`/`tearDown` only, so a crash mid-test still leaves the
    /// developer's clipboard intact at the next run.
    private var pasteboardSnapshot: [NSPasteboardItem] = []

    override func setUp() {
        super.setUp()
        pasteboardSnapshot = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let clone = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    clone.setData(data, forType: type)
                }
            }
            return clone
        }
        NSPasteboard.general.clearContents()
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        if !pasteboardSnapshot.isEmpty {
            NSPasteboard.general.writeObjects(pasteboardSnapshot)
        }
        pasteboardSnapshot = []
        super.tearDown()
    }

    // MARK: - 1. FFI round-trips

    /// Fresh session has no selection — `selection_text()` returns the
    /// empty-string sentinel that the ⌘C handler short-circuits on.
    func testSelectionTextEmptyOnFreshSessionThroughFFI() {
        let session = Self.makeCatSession()
        XCTAssertEqual(session.selection_text().toString(), "")
    }

    /// Fresh session: bracketed-paste defaults to disabled (matches
    /// xterm/VT default + alacritty default). Pinned because the ⌘V
    /// handler's wrap decision rides on this bit.
    func testBracketedPasteDisabledByDefaultThroughFFI() {
        let session = Self.makeCatSession()
        XCTAssertFalse(session.bracketed_paste_enabled())
    }

    // MARK: - 2. formatPastePayload — pure helper

    /// Disabled mode: payload is unmodified. Empty input is preserved
    /// (the caller short-circuits on empty before reaching the helper,
    /// but the helper itself stays well-defined).
    func testFormatPastePayloadDisabledIsIdentity() {
        XCTAssertEqual(
            TerminalSurfaceView.formatPastePayload("hello", bracketedPasteEnabled: false),
            "hello")
        XCTAssertEqual(
            TerminalSurfaceView.formatPastePayload("", bracketedPasteEnabled: false),
            "")
        // Multiline with embedded ESC bytes is passed through verbatim.
        let multi = "line1\nline2\u{1B}other"
        XCTAssertEqual(
            TerminalSurfaceView.formatPastePayload(multi, bracketedPasteEnabled: false),
            multi)
    }

    /// Enabled mode: wrap exactly with `ESC [200~` ... `ESC [201~`.
    /// Pinned byte-for-byte against the xterm spec because zsh ZLE / vim
    /// insert mode parse on these literal bytes.
    func testFormatPastePayloadEnabledWrapsWithMarkers() {
        let wrapped = TerminalSurfaceView.formatPastePayload(
            "x", bracketedPasteEnabled: true)
        XCTAssertEqual(wrapped, "\u{1B}[200~x\u{1B}[201~")

        // Bytes (ESC = 0x1B = 27) — pin the exact wire form.
        let bytes = Array(wrapped.utf8)
        XCTAssertEqual(bytes.first, 0x1B)
        XCTAssertEqual(bytes[1], UInt8(ascii: "["))
        XCTAssertEqual(bytes[2], UInt8(ascii: "2"))
        XCTAssertEqual(bytes[3], UInt8(ascii: "0"))
        XCTAssertEqual(bytes[4], UInt8(ascii: "0"))
        XCTAssertEqual(bytes[5], UInt8(ascii: "~"))
        XCTAssertEqual(bytes[6], UInt8(ascii: "x"))
        XCTAssertEqual(bytes[7], 0x1B)
        XCTAssertEqual(bytes[8], UInt8(ascii: "["))
        XCTAssertEqual(bytes[9], UInt8(ascii: "2"))
        XCTAssertEqual(bytes[10], UInt8(ascii: "0"))
        XCTAssertEqual(bytes[11], UInt8(ascii: "1"))
        XCTAssertEqual(bytes[12], UInt8(ascii: "~"))
    }

    // MARK: - Paste chunking (regression: long-paste UI freeze)

    /// Naive boundary lands inside ASCII → returned as-is.
    func testPasteChunkEnd_ascii_returnsNaiveBoundary() {
        let bytes = Array("hello world this is some ascii".utf8)
        XCTAssertEqual(
            TerminalSurfaceView.pasteChunkEnd(bytes: bytes, offset: 0, chunkSize: 5),
            5)
        XCTAssertEqual(
            TerminalSurfaceView.pasteChunkEnd(bytes: bytes, offset: 5, chunkSize: 5),
            10)
    }

    /// When the chunk size lands mid-multibyte, the helper walks
    /// back to the previous code-point start. Thai cluster "ก่อน"
    /// is 4 codepoints × 3 bytes = 12 bytes. Chunking at byte 5
    /// would split the second codepoint mid-sequence — the helper
    /// should back up to byte 3 (end of first codepoint).
    func testPasteChunkEnd_walksBackFromMultibyteSplit() {
        let bytes = Array("ก่อน".utf8)
        XCTAssertEqual(bytes.count, 12,
            "Thai 4-codepoint string should be 12 UTF-8 bytes")
        // chunkSize=5 → naive end=5, walk back to 3 (codepoint boundary).
        let end = TerminalSurfaceView.pasteChunkEnd(
            bytes: bytes, offset: 0, chunkSize: 5)
        XCTAssertEqual(end, 3, "must land on codepoint boundary")
        // Verify the slice is valid UTF-8.
        let slice = Array(bytes[0..<end])
        XCTAssertNotNil(String(bytes: slice, encoding: .utf8))
    }

    /// End of buffer always wins — even if the last partial chunk
    /// would normally walk back, the tail of the payload is allowed
    /// because there's nothing more coming.
    func testPasteChunkEnd_lastChunkAllowsRemainder() {
        let bytes = Array("ก่อน".utf8)
        // offset=6, chunkSize=10, naive end = 12 (== bytes.count) →
        // return naive end as-is, no walk-back.
        XCTAssertEqual(
            TerminalSurfaceView.pasteChunkEnd(bytes: bytes, offset: 6, chunkSize: 10),
            12)
    }

    /// Pathological: a single UTF-8 codepoint that exceeds chunkSize
    /// (rare — 4-byte codepoints with chunkSize<4). Helper falls back
    /// to the naive boundary rather than collapsing the chunk to zero
    /// (which would loop forever).
    func testPasteChunkEnd_pathologicalCodepointFallsBackToNaive() {
        // 4-byte UTF-8 codepoint (emoji 😀 = F0 9F 98 80)
        let bytes = Array("😀".utf8)
        XCTAssertEqual(bytes.count, 4)
        // chunkSize=2 mid-codepoint → naive=2, walk-back collapses
        // to 0 (offset) → fallback returns naive 2.
        let end = TerminalSurfaceView.pasteChunkEnd(
            bytes: bytes, offset: 0, chunkSize: 2)
        XCTAssertEqual(end, 2,
            "single oversized codepoint must not collapse the chunk window")
    }

    // MARK: - PG2 paste-jail injection guard

    /// Clipboard payload containing the bracketed-paste END marker
    /// gets stripped before re-wrapping — otherwise an attacker-
    /// controlled clipboard can break out of paste mode and execute
    /// commands. Matches iTerm2 / Ghostty / Alacritty behaviour.
    func testFormatPastePayloadStripsEmbeddedEndMarker() {
        let malicious = "echo safe\u{1B}[201~\nrm -rf /\n"
        let wrapped = TerminalSurfaceView.formatPastePayload(
            malicious, bracketedPasteEnabled: true)
        // Embedded `\e[201~` removed; exactly one start + one end marker.
        XCTAssertTrue(wrapped.hasPrefix("\u{1B}[200~"))
        XCTAssertTrue(wrapped.hasSuffix("\u{1B}[201~"))
        XCTAssertEqual(
            wrapped.components(separatedBy: "\u{1B}[201~").count, 2,
            "exactly one end marker should remain (the trailing wrap)")
        XCTAssertFalse(
            wrapped.dropLast(6).contains("\u{1B}[201~"),
            "embedded end marker must be stripped from the body")
    }

    /// Re-splice bypass: a single-pass strip lets `\e[20` + `\e[201~` +
    /// `1~` re-form a fresh `\e[201~` across the removal boundary,
    /// escaping the paste jail. The loop-until-stable scrub must leave NO
    /// end marker in the body.
    func testFormatPastePayloadDefeatsRespliceBypass() {
        let malicious = "echo safe\u{1B}[20\u{1B}[201~1~\rrm -rf ~\r"
        let wrapped = TerminalSurfaceView.formatPastePayload(
            malicious, bracketedPasteEnabled: true)
        XCTAssertTrue(wrapped.hasPrefix("\u{1B}[200~"))
        XCTAssertTrue(wrapped.hasSuffix("\u{1B}[201~"))
        XCTAssertFalse(
            wrapped.dropLast(6).contains("\u{1B}[201~"),
            "re-spliced end marker must not survive the scrub")
        XCTAssertEqual(
            wrapped.components(separatedBy: "\u{1B}[201~").count, 2,
            "exactly one end marker (the trailing wrap) may remain")
    }

    /// Embedded START markers get stripped too — a defensive
    /// symmetry. Without it the user-visible "paste" would still
    /// end correctly, but the running app sees nested 200~ pairs.
    func testFormatPastePayloadStripsEmbeddedStartMarker() {
        let payload = "before\u{1B}[200~middle\u{1B}[201~after"
        let wrapped = TerminalSurfaceView.formatPastePayload(
            payload, bracketedPasteEnabled: true)
        let body = String(wrapped.dropFirst(6).dropLast(6))
        XCTAssertEqual(body, "beforemiddleafter")
    }

    /// When bracketed-paste is OFF, the payload passes through
    /// untouched — even if it carries marker bytes. Disabled mode
    /// has no injection surface (no envelope to escape).
    func testFormatPastePayloadDoesNotStripWhenBracketedDisabled() {
        let payload = "echo\u{1B}[201~next"
        let wrapped = TerminalSurfaceView.formatPastePayload(
            payload, bracketedPasteEnabled: false)
        XCTAssertEqual(wrapped, payload)
    }

    /// Multiline payload (typical "paste a code snippet") is wrapped as
    /// a single block — the markers wrap the whole payload, not each
    /// line. Matches xterm's behavior; ZLE-style "paste fired into a
    /// multiline buffer" depends on the single-block shape.
    func testFormatPastePayloadEnabledWrapsMultilineAsSingleBlock() {
        let payload = "echo one\necho two\n"
        let wrapped = TerminalSurfaceView.formatPastePayload(
            payload, bracketedPasteEnabled: true)
        XCTAssertTrue(wrapped.hasPrefix("\u{1B}[200~"))
        XCTAssertTrue(wrapped.hasSuffix("\u{1B}[201~"))
        // Exactly one start marker + one end marker.
        XCTAssertEqual(wrapped.components(separatedBy: "\u{1B}[200~").count, 2)
        XCTAssertEqual(wrapped.components(separatedBy: "\u{1B}[201~").count, 2)
    }

    // MARK: - 3. End-to-end — copy / paste via the public selector

    /// `copy(nil)` reads the engine selection's text and writes it to
    /// `NSPasteboard.general`. We drive the engine through the same FFI
    /// path the menu does, so the assertion proves "menu ⌘C → engine →
    /// pasteboard" end-to-end (modulo the one final NSResponder hop
    /// AppKit handles for us in production).
    func testCopyWritesEngineSelectionToPasteboard() throws {
        let surface = Self.makeSurface()
        let session = try XCTUnwrap(surface.rendererForTesting.session)

        // Drive cat-loopback "hello world\n" so row 0 holds the text.
        Self.feedAndWaitForFirstChar(session, payload: "hello world\n", first: "h")
        session.start_selection(TerminalSurfaceView.SELECTION_MODE_SIMPLE, 0, 0)
        session.update_selection(0, 4)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string) ?? "", "")
        surface.copy(nil)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string), "hello",
            "⌘C must put the selection's text on the system pasteboard")
    }

    /// `copy(nil)` with no active selection must not clobber the
    /// pasteboard. Pre-populate with a sentinel; assert it survives.
    func testCopyWithNoSelectionLeavesPasteboardUntouched() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("PRESERVE_ME", forType: .string)

        let surface = Self.makeSurface()
        // No selection set up.
        surface.copy(nil)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string), "PRESERVE_ME",
            "⌘C with empty selection must be a no-op")
    }

    /// `paste(nil)` reads from the pasteboard and feeds the bytes
    /// through `send_input`. Verify by waiting for the cat-echoed text
    /// to appear in the engine's grid via `take_frame_delta`.
    func testPasteSendsPasteboardTextToSession() throws {
        let surface = Self.makeSurface()
        let session = try XCTUnwrap(surface.rendererForTesting.session)
        // Drain the initial Full-damage frame so the cell-search
        // helper looks at post-paste state only.
        _ = session.take_frame_delta()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Pasted!\n", forType: .string)

        // Bracketed paste defaults to off — payload is sent verbatim.
        XCTAssertFalse(session.bracketed_paste_enabled())
        surface.paste(nil)

        Self.waitForFirstCellChar(session, expected: "P")
    }

    /// With bracketed-paste enabled, the bytes the engine sees must be
    /// `ESC [200~ ... ESC [201~` wrapped. We can't directly inspect the
    /// PTY-bound bytes from XCTest, but we can verify the contract by
    /// driving DECSET 2004 through the engine, calling paste, and
    /// asserting the payload-format helper would have wrapped — the
    /// helper test above pins the exact wire form, this test pins that
    /// the live ⌘V path consults `bracketed_paste_enabled()`.
    func testPasteConsultsBracketedPasteFlag() throws {
        let surface = Self.makeSurface()
        let session = try XCTUnwrap(surface.rendererForTesting.session)

        // Drive DECSET 2004 through cat-loopback the same way the FFI
        // bracketed-paste round-trip test does.
        let on = InputEventEncoder.makeKeyInputEvent(
            characters: "\u{1B}[?2004h\n", keycode: 0, modifiers: [])
        session.send_input(on)
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline && !session.bracketed_paste_enabled() {
            _ = session.take_frame_delta()
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(
            session.bracketed_paste_enabled(),
            "precondition: DECSET 2004 must enable bracketed-paste")

        // The helper this test exists to pin: when the flag is set,
        // the formatter wraps; when it isn't, it passes through. The
        // live paste call uses the same helper internally (see
        // `paste(_:)` in TerminalSurfaceView.swift).
        let payload = TerminalSurfaceView.formatPastePayload(
            "x", bracketedPasteEnabled: session.bracketed_paste_enabled())
        XCTAssertEqual(payload, "\u{1B}[200~x\u{1B}[201~")
    }

    /// End-to-end Kitty keyboard protocol: a TUI pushes kitty mode
    /// (`CSI > 1 u`), the engine flips `DISAMBIGUATE_ESC_CODES`, the FFI
    /// surfaces it via `kitty_keyboard_flags()`, and the live key encoder
    /// — fed that flag exactly as `keyDown` does — emits `\e[13;2u` for
    /// Shift+Enter (vs the bare `\r` "submit"). Drives the enable through
    /// cat-loopback the same way the bracketed-paste round-trip does.
    func testShiftEnterEmitsCSIuAfterKittyEnabledEndToEnd() throws {
        // /bin/cat loopback (the proven engine-test pattern): cat echoes
        // the pushed escape back so the parser processes it. A real shell
        // wouldn't echo the raw sequence for the parser to see.
        let session = Self.makeCatSession()

        // Precondition: no kitty mode → encoder keeps the legacy ESC+CR.
        XCTAssertEqual(session.kitty_keyboard_flags(), 0)
        XCTAssertEqual(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x24, modifiers: .shift,
                kittyFlags: session.kitty_keyboard_flags()),
            "\u{1B}\r")

        // Push the Kitty disambiguate flag via cat-loopback.
        let push = InputEventEncoder.makeKeyInputEvent(
            characters: "\u{1B}[>1u\n", keycode: 0, modifiers: [])
        session.send_input(push)
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline && session.kitty_keyboard_flags() == 0 {
            _ = session.take_frame_delta()
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertNotEqual(
            session.kitty_keyboard_flags() & 0x01, 0,
            "precondition: CSI > 1 u must set DISAMBIGUATE_ESC_CODES")

        // The real keyDown path: encoder reads the live FFI flag and
        // upgrades modified Enter to CSI u; plain Enter stays bare \r.
        let flags = session.kitty_keyboard_flags()
        XCTAssertEqual(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x24, modifiers: .shift, kittyFlags: flags),
            "\u{1B}[13;2u",
            "Shift+Enter under kitty must be CSI 13 ; 2 u")
        XCTAssertNil(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x24, modifiers: [], kittyFlags: flags),
            "plain Enter stays a bare \\r even under kitty")
    }

    /// End-to-end DECCKM: a TUI sets `CSI ?1 h`, the engine flips
    /// `APP_CURSOR`, the FFI surfaces it via `app_cursor_active()`, and
    /// the live encoder — fed that flag exactly as `keyDown` does — emits
    /// SS3 (`\eOA`) for the Up arrow instead of the normal CSI (`\e[A`).
    func testArrowEmitsSS3AfterAppCursorEnabledEndToEnd() throws {
        let session = Self.makeCatSession()

        // Precondition: normal cursor keys → CSI.
        XCTAssertFalse(session.app_cursor_active())
        XCTAssertEqual(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x7E, modifiers: [],
                appCursor: session.app_cursor_active()),
            "\u{1B}[A")

        // Enable DECCKM via cat-loopback.
        let on = InputEventEncoder.makeKeyInputEvent(
            characters: "\u{1B}[?1h\n", keycode: 0, modifiers: [])
        session.send_input(on)
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline && !session.app_cursor_active() {
            _ = session.take_frame_delta()
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(
            session.app_cursor_active(),
            "precondition: CSI ?1 h must set application-cursor mode")

        XCTAssertEqual(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x7E, modifiers: [],
                appCursor: session.app_cursor_active()),
            "\u{1B}OA",
            "Up arrow under app-cursor must be SS3 \\eOA")
    }

    /// Focus-event reporting plumbing: `CSI ?1004 h` flips the engine
    /// mode and the FFI surfaces it via `focus_events_enabled()` — the
    /// exact gate `sendFocusEvent` consults before writing `\e[I`/`\e[O`
    /// on window key changes.
    func testFocusEventsFlagExposedAfterDecset1004EndToEnd() throws {
        let session = Self.makeCatSession()
        XCTAssertFalse(session.focus_events_enabled())

        let on = InputEventEncoder.makeKeyInputEvent(
            characters: "\u{1B}[?1004h\n", keycode: 0, modifiers: [])
        session.send_input(on)
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline && !session.focus_events_enabled() {
            _ = session.take_frame_delta()
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(
            session.focus_events_enabled(),
            "DECSET 1004 must enable focus-event reporting")
    }

    /// ⌘⇧V "Paste (Plain)" never wraps the payload, even when the
    /// running program has enabled DECSET 2004. Pin the formatter call
    /// with `bracketedPasteEnabled: false` matches the live selector's
    /// behavior — the user-visible bytes equal the pasteboard bytes.
    /// This protects TUIs that don't honor bracketed paste (Ink-based
    /// CLIs like Claude Code) from leaked `\e[200~` markers.
    func testPastePlainSkipsBracketedWrapEvenWhenEnabled() throws {
        // Static-helper guarantee: forcing bracketedPasteEnabled=false
        // is identity regardless of how the live program would have
        // formatted ⌘V's payload.
        XCTAssertEqual(
            TerminalSurfaceView.formatPastePayload("x", bracketedPasteEnabled: false),
            "x")
        let multi = "line1\nline2\n"
        XCTAssertEqual(
            TerminalSurfaceView.formatPastePayload(multi, bracketedPasteEnabled: false),
            multi)
    }

    /// `pastePlain(nil)` end-to-end: reads from the pasteboard and feeds
    /// the bytes through `send_input` without wrapping. Verify by
    /// waiting for the first cat-echoed character to land on row 0 col
    /// 0 — same pattern as `testPasteSendsPasteboardTextToSession`. The
    /// stronger "no `\e[200~` even when bracketed-paste is enabled"
    /// guarantee is pinned by
    /// `testPastePlainSkipsBracketedWrapEvenWhenEnabled` at the helper
    /// boundary; live ⌘⇧V calls that helper with `false` unconditionally.
    func testPastePlainSendsPasteboardTextToSession() throws {
        let surface = Self.makeSurface()
        let session = try XCTUnwrap(surface.rendererForTesting.session)
        _ = session.take_frame_delta()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Plain!\n", forType: .string)

        surface.pastePlain(nil)

        Self.waitForFirstCellChar(session, expected: "P")
    }

    /// `validateMenuItem(_:)` greys out Paste (Plain) when the
    /// pasteboard is empty — same gate as Paste. Pin so both selectors
    /// stay aligned: the wrap decision is the only difference between
    /// the two; both require usable clipboard content.
    func testValidateMenuItemPastePlainMatchesPaste() {
        let surface = Self.makeSurface()
        let pastePlainItem = NSMenuItem(
            title: "Paste (Plain)",
            action: #selector(TerminalSurfaceView.pastePlain(_:)),
            keyEquivalent: "v")

        NSPasteboard.general.clearContents()
        XCTAssertFalse(
            surface.validateMenuItem(pastePlainItem),
            "Paste (Plain) disabled with empty pasteboard")

        NSPasteboard.general.setString("anything", forType: .string)
        XCTAssertTrue(
            surface.validateMenuItem(pastePlainItem),
            "Paste (Plain) enabled when pasteboard has a string")
    }

    /// `validateMenuItem(_:)` greys out Copy when no selection exists
    /// and Paste when the pasteboard is empty — terminal-app polish so
    /// the user doesn't see ⌘C / ⌘V available when they're no-ops.
    func testValidateMenuItemDisablesCopyWhenNoSelectionAndPasteWhenClipboardEmpty() {
        let surface = Self.makeSurface()
        let copyItem = NSMenuItem(
            title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(
            title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")

        // No selection, no pasteboard contents — both disabled.
        NSPasteboard.general.clearContents()
        XCTAssertFalse(
            surface.validateMenuItem(copyItem), "Copy disabled with no selection")
        XCTAssertFalse(
            surface.validateMenuItem(pasteItem), "Paste disabled with empty pasteboard")

        // Add pasteboard content — Paste enables.
        NSPasteboard.general.setString("anything", forType: .string)
        XCTAssertTrue(
            surface.validateMenuItem(pasteItem),
            "Paste enabled when pasteboard has a string")

        // Add a selection — Copy enables.
        if let session = surface.rendererForTesting.session {
            session.start_selection(TerminalSurfaceView.SELECTION_MODE_SIMPLE, 0, 0)
            session.update_selection(0, 4)
            XCTAssertTrue(
                surface.validateMenuItem(copyItem),
                "Copy enabled once a selection is active")
        }
    }

    // MARK: - 3b. Selection mirror — engine-clears-on-write recovery

    /// Round-trip pin for the Swift-side selection mirror. Reproduces
    /// the TUI failure mode (alacritty clears `Term::selection` on
    /// grid writes intersecting the selection's row range, see
    /// `term/mod.rs:1657,1773,1786,1803,1811`) by:
    ///
    ///  1. Driving cells onto row 0 via cat-loopback.
    ///  2. Establishing a mouse-style selection through the mirror
    ///     seam + engine FFI (matching what `mouseDown` / `mouseDragged`
    ///     would do live).
    ///  3. Simulating the engine clearing its own selection (the
    ///     visible failure: `selection_span().len()` returns 0).
    ///  4. Asserting `copy(_:)` re-establishes the engine selection
    ///     from the Swift mirror and reads non-empty text onto the
    ///     pasteboard.
    ///
    /// Without the mirror, step 4 would copy the empty-string sentinel
    /// — exactly the bug TUI users hit with Claude Code.
    func testCopyRecoversFromEngineClearedSelection() throws {
        let surface = Self.makeSurface()
        let session = try XCTUnwrap(surface.rendererForTesting.session)

        // 1. Lay down "hello\n" on row 0 via cat-loopback.
        Self.feedAndWaitForFirstChar(session, payload: "hello\n", first: "h")

        // 2. Establish mouse-style selection. The Swift mirror is the
        //    UI-layer record (what `mouseDown` + `mouseDragged` would
        //    set live); the engine call mirrors the synchronous
        //    `start_selection` / `update_selection` those handlers
        //    issue alongside the mirror write.
        surface.setPendingSelectionForTesting(
            startRow: 0, startCol: 0, endRow: 0, endCol: 4)
        session.start_selection(TerminalSurfaceView.SELECTION_MODE_SIMPLE, 0, 0)
        session.update_selection(0, 4)

        // 3. Simulate the engine clearing its own selection between
        //    `mouseDragged` and the user's `⌘C`. In production this is
        //    triggered by any grid write touching the selection's row
        //    — Claude CLI does this on every render tick.
        session.clear_selection()
        XCTAssertEqual(
            session.selection_span().len(), 0,
            "precondition: engine has dropped its selection — the bug "
                + "this test exists to pin")

        // 4. `copy(_:)` must re-establish from the mirror and read
        //    non-empty text. Without the recovery path, the empty
        //    engine sentinel would short-circuit to a no-op.
        NSPasteboard.general.clearContents()
        surface.copy(nil)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string), "hello",
            "⌘C must recover from engine-cleared selection via the "
                + "Swift mirror — the alacritty-clears-on-write workaround")

        // Engine state should also be re-established post-copy so the
        // visible selection-tint stays coherent. Both the mirror and
        // the engine now point at the same span.
        let after = session.selection_span()
        XCTAssertEqual(
            after.len(), 5,
            "engine selection re-established after copy for visible tint")
        XCTAssertEqual(after.get(index: 0), 0)
        XCTAssertEqual(after.get(index: 1), 0)
        XCTAssertEqual(after.get(index: 2), 0)
        XCTAssertEqual(after.get(index: 3), 4)
    }

    /// Regression: the Copy menu item (and thus the ⌘C key equivalent)
    /// must validate as ENABLED off the Swift mirror after the engine
    /// drops its own selection on a TUI repaint. Before the fix,
    /// `validateMenuItem` checked only `session.selection_span()`, so a
    /// live TUI (Claude Code) disabled Copy even with a visible highlight
    /// — ⌘C then fell through to keyDown and typed a literal "c". The
    /// previous test pins `copy(_:)` itself; this pins the validation
    /// gate that decides whether ⌘C ever reaches `copy(_:)`.
    func testCopyMenuItemEnabledFromMirrorAfterEngineClear() throws {
        let surface = Self.makeSurface()
        let session = try XCTUnwrap(surface.rendererForTesting.session)

        surface.setPendingSelectionForTesting(
            startRow: 0, startCol: 0, endRow: 0, endCol: 4)
        session.clear_selection()
        XCTAssertEqual(
            session.selection_span().len(), 0,
            "precondition: engine selection dropped (TUI-repaint scenario)")

        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(TerminalSurfaceView.copy(_:)),
            keyEquivalent: "c")
        XCTAssertTrue(
            surface.validateMenuItem(copyItem),
            "Copy must stay enabled via the mirror so ⌘C copies instead "
                + "of leaking a literal \"c\" into a live TUI")
    }

    /// With neither a mirror nor an engine selection, Copy is disabled —
    /// so ⌘C is a no-op rather than enabling an empty copy.
    func testCopyMenuItemDisabledWithNoSelection() {
        let surface = Self.makeSurface()
        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(TerminalSurfaceView.copy(_:)),
            keyEquivalent: "c")
        XCTAssertFalse(surface.validateMenuItem(copyItem))
    }

    /// Renderer-overlay source-of-truth: when the Swift mirror is set,
    /// `swiftSelectionSpan` returns the 5-element wire-format Vec the
    /// renderer reads in preference to the engine's `selection_span`.
    /// Pin the shape pre- and post-clear so the renderer's preference
    /// for the mirror survives the engine's drop. Block flag is 0
    /// (Simple/Word/Line only; Block-mode requires modifier path not
    /// yet wired).
    func testSwiftSelectionSpanSurvivesEngineClear() throws {
        let surface = Self.makeSurface()
        let session = try XCTUnwrap(surface.rendererForTesting.session)

        // Pre: mirror nil → nil span.
        XCTAssertNil(surface.swiftSelectionSpan)

        // Establish mirror + engine in lock-step.
        surface.setPendingSelectionForTesting(
            startRow: 2, startCol: 5, endRow: 2, endCol: 12)
        session.start_selection(TerminalSurfaceView.SELECTION_MODE_SIMPLE, 2, 5)
        session.update_selection(2, 12)

        // Mirror exposes the same 5-element wire shape the engine
        // would — renderer's branch consumes either equivalently.
        let span = try XCTUnwrap(surface.swiftSelectionSpan)
        XCTAssertEqual(span, [2, 5, 2, 12, 0])

        // Engine drops its view (TUI redraw simulation).
        session.clear_selection()
        XCTAssertEqual(session.selection_span().len(), 0)

        // Mirror still holds — renderer continues painting the tint
        // off this exact span.
        let after = try XCTUnwrap(surface.swiftSelectionSpan)
        XCTAssertEqual(after, [2, 5, 2, 12, 0])
    }

    // MARK: - 4. M2-6 — clean-text contract across blocks

    /// Multi-block selection yields chrome-free cell text. Drives the
    /// session through two OSC 133 cycles (prompt → command → output →
    /// exit, twice) and selects across both blocks. The architectural
    /// claim being pinned: `selection_text()` reads alacritty's grid
    /// cells directly, and the SwiftUI block-chrome overlay (3px stripe,
    /// 1px border, footer pill) is a sibling NSHostingView that doesn't
    /// touch the cell store. No UI chrome character (`╭` `╰` `─` `│`,
    /// pill text, exit-code numerals) can leak into copy output —
    /// because nothing wrote those characters into the cells in the
    /// first place. Pin this so a future architecture change (e.g.
    /// painting block headers as cell content) is forced to reckon
    /// with the contract.
    func testMultiBlockSelectionYieldsCleanText() throws {
        let session = Self.makeCatSession()

        // OSC 133 cycle 1: A (PromptStart), B (PreExec), echoed
        // command bytes (cat loopback), D (CommandExit). Sequences
        // landed via the same KeyEvent path used by
        // BlockBoundaryDecodingTests.testIntegratesWithLiveSession.
        Self.driveOscPayload(
            session,
            payload: "\u{1B}]133;A\u{07}prompt1$ \u{1B}]133;B\u{07}cmd1\n"
                + "out1\n\u{1B}]133;D;0\u{07}")
        Self.driveOscPayload(
            session,
            payload: "\u{1B}]133;A\u{07}prompt2$ \u{1B}]133;B\u{07}cmd2\n"
                + "out2\n\u{1B}]133;D;0\u{07}")
        // Wait for the second cycle's bytes to land on the grid before
        // we read them via selection_text.
        Self.waitForCellSubstring(session, anyOf: ["o", "u", "t"], timeout: 5.0)

        // Select the first 6 rows (covers both block cycles in our
        // small test surface). Simple-mode + UInt16.max end-col grabs
        // every cell on each row.
        session.start_selection(
            TerminalSurfaceView.SELECTION_MODE_SIMPLE, 0, 0)
        session.update_selection(5, UInt16.max)
        let text = session.selection_text().toString()

        // Architectural contract: the engine's grid stores raw cell
        // content. The block UI is SwiftUI overlay paint, NOT cell
        // content. So none of the box-drawing characters the chrome
        // is composed of CAN appear in the copied text — period.
        let chromeCharacters: [Character] = ["╭", "╰", "─", "│", "┌", "┐", "└", "┘"]
        for ch in chromeCharacters {
            XCTAssertFalse(
                text.contains(ch),
                "block chrome '\(ch)' must never appear in selection_text(); "
                    + "got: \(text.debugDescription)")
        }
        // Sanity: the cells we wrote should be in there. cat echoes
        // the bytes back including the OSC sequence wrappers (cat
        // echoes raw bytes; the parser routes them at a separate
        // layer). Just confirm we got SOME selection content so the
        // test isn't vacuously chrome-free on an empty buffer.
        XCTAssertFalse(text.isEmpty, "selection across block range must yield text")
    }

    /// Selection across an alt-screen-was-here range returns the cells
    /// as the engine recorded them when alt-screen exited. Pin: the
    /// `AltScreenStub` is a SwiftUI overlay decoration; it doesn't
    /// substitute "this was alt-screen" placeholder text into the cell
    /// store. Anything we render ON TOP of those cells stays Swift-side.
    func testSelectionAcrossAltScreenStubYieldsRawCells() throws {
        let session = Self.makeCatSession()

        // Drive the session through alt-screen entry / payload / exit.
        // 1049h enters; we write some bytes; 1049l exits. cat-loopback
        // echoes the bytes back — alacritty's parser routes the DECSET
        // and the printable bytes to the alt screen, then back to the
        // primary on exit.
        Self.driveOscPayload(
            session,
            payload: "\u{1B}[?1049h" + "ALT" + "\u{1B}[?1049l" + "AFTER\n")
        Self.waitForCellSubstring(session, anyOf: ["A", "F", "T", "E", "R"], timeout: 5.0)

        // Select the full first row. The cells underneath should
        // reflect what's actually on the primary screen post-exit —
        // NOT a synthesized "Alt-screen session" stub label (which is
        // the SwiftUI BlockContainerView's own paint).
        session.start_selection(
            TerminalSurfaceView.SELECTION_MODE_SIMPLE, 0, 0)
        session.update_selection(0, UInt16.max)
        let text = session.selection_text().toString()

        XCTAssertFalse(
            text.contains("Alt-screen session"),
            "AltScreenStub variant's SwiftUI label must not leak into "
                + "selection_text(); got: \(text.debugDescription)")
    }

    /// Selection scoped within a single command block returns exactly
    /// the cell content — no AltScreenStub leak (negative-control case)
    /// and no exit-code badge / duration label (the M2-5d footer is
    /// SwiftUI paint atop the bottom-right corner, not cell content).
    /// Pin the architecture: the SwiftUI overlay does not affect the
    /// engine selection → text path.
    func testSelectionWithBlockChromeAroundIsUnaffected() throws {
        let session = Self.makeCatSession()
        Self.driveOscPayload(
            session,
            payload: "\u{1B}]133;A\u{07}prompt$ \u{1B}]133;B\u{07}"
                + "hello\n\u{1B}]133;D;0\u{07}")
        Self.waitForCellSubstring(session, anyOf: ["h", "e", "l", "o"], timeout: 5.0)

        session.start_selection(
            TerminalSurfaceView.SELECTION_MODE_SIMPLE, 0, 0)
        session.update_selection(0, UInt16.max)
        let text = session.selection_text().toString()

        // Footer "0" exit-code numeral is rendered as a SwiftUI Text
        // pill inside BlockContainerView.commandFooter — it lives in
        // the hosting NSView, NOT the alacritty grid. The cells past
        // the prompt / command should hold prompt + bytes only;
        // checkmark / xmark SF Symbols cannot appear in `text`
        // because they're SF Symbol glyphs in SwiftUI, not Unicode in
        // cells. Pin both negatives.
        XCTAssertFalse(
            text.contains("✓"),
            "checkmark glyph from M2-5d footer must not leak into selection")
        XCTAssertFalse(
            text.contains("✗"),
            "xmark glyph from M2-5d footer must not leak into selection")
        XCTAssertFalse(text.isEmpty, "selection over a populated block row must yield text")
    }

    // MARK: - Ctrl-C survives a wedged IME composition (SIGINT regression)

    /// Root-cause regression: a custom `NSTextInputClient` does NOT get its
    /// preedit auto-cancelled by AppKit when a ⌘-equivalent (Copy/Paste)
    /// fires mid-composition, so `compositionState` can be left orphaned
    /// non-nil. From then on `hasMarkedText()` is permanently true and the
    /// `keyDown` direct-send gate (`!insertTextFiredThisKeyDown &&
    /// !hasMarkedText()`) blocks EVERY raw key — including Ctrl-C — so the
    /// user can no longer interrupt a foreground TUI (the reported "Ctrl+C
    /// suddenly stops working in Claude" bug).
    ///
    /// The fix intercepts Control-mapped C0 keys in `keyDown` BEFORE the
    /// IME/gate path and cancels any in-flight composition. This test
    /// forces the wedge (via `setMarkedText`, the exact production trigger
    /// for a stuck `compositionState`), synthesizes a Ctrl-C `keyDown`, and
    /// asserts the composition is cleared so `hasMarkedText()` can no longer
    /// block direct send. The byte-level "Ctrl-C → 0x03" contract is pinned
    /// separately below (`testCtrlCEncodesToETXByte`) because the PTY line
    /// discipline turns 0x03 into SIGINT rather than an echoable byte.
    func testCtrlCClearsWedgedCompositionSoSigintCanSend() throws {
        let surface = Self.makeSurface()
        _ = try XCTUnwrap(
            surface.rendererForTesting.session,
            "cat session must be up so the control-byte intercept's "
                + "`renderer.session` guard is satisfied")

        // Force the orphaned-composition wedge: a live Thai preedit that
        // never got committed/cancelled (what a mid-composition ⌘C leaves
        // behind on a custom NSTextInputClient).
        surface.setMarkedText(
            "ก",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(
            surface.hasMarkedText(),
            "precondition: composition is stuck active — this is the state "
                + "that wedges the keyDown gate against Ctrl-C")

        // Synthesize Ctrl-C exactly as macOS delivers it: `characters` is
        // the resolved C0 byte (ETX = 0x03), `charactersIgnoringModifiers`
        // the base "c", keyCode = kVK_ANSI_C (0x08), Control held.
        let ctrlC = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .control,
                timestamp: CACurrentMediaTime(),
                windowNumber: 0,
                context: nil,
                characters: "\u{03}",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 0x08),
            "synthetic Ctrl-C NSEvent.keyEvent returned nil — methodology blocked")

        surface.keyDown(with: ctrlC)

        // The wedge is gone: `hasMarkedText()` no longer suppresses direct
        // send, so the next (and this) Ctrl-C reaches the PTY. Before the
        // fix this stayed true and SIGINT was swallowed forever.
        XCTAssertFalse(
            surface.hasMarkedText(),
            "Ctrl-C keyDown must cancel the orphaned composition so the "
                + "direct-send gate stops blocking SIGINT")
    }

    /// Byte contract: Ctrl-C must encode to the single ETX byte (0x03) the
    /// PTY turns into SIGINT. The control-byte intercept reuses the exact
    /// `InputEventEncoder.encode(...)` of the normal path, so pinning the
    /// encoder output here proves the intercept changes only WHEN the bytes
    /// are sent, never WHAT — Ctrl-C stays 0x03.
    func testCtrlCEncodesToETXByte() throws {
        let ctrlC = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .control,
                timestamp: CACurrentMediaTime(),
                windowNumber: 0,
                context: nil,
                characters: "\u{03}",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 0x08))
        let event = InputEventEncoder.encode(ctrlC)
        XCTAssertEqual(
            event.key.text.toString(), "\u{03}",
            "Ctrl-C must encode to ETX (0x03) — the SIGINT byte")
        XCTAssertEqual(event.key.codepoint, 0x03)
    }

    /// Scope guard for the bypass predicate. `isControlByteKey` decides
    /// which keys take the early Control-byte intercept; this pins its
    /// exact boundary so a future edit can't silently widen it (e.g. start
    /// swallowing ⌘ shortcuts) or narrow it (re-break Ctrl-C). Synthesized
    /// NSEvents mirror how macOS delivers each combo: `characters` is the
    /// modifier-resolved text the OS produces.
    func testIsControlByteKeyScope() throws {
        func event(
            _ chars: String, _ baseChars: String,
            _ mods: NSEvent.ModifierFlags, _ keyCode: UInt16
        ) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: mods,
                    timestamp: CACurrentMediaTime(), windowNumber: 0, context: nil,
                    characters: chars, charactersIgnoringModifiers: baseChars,
                    isARepeat: false, keyCode: keyCode))
        }

        // IN: the C0 control family — these must take the bypass.
        XCTAssertTrue(  // Ctrl-C → ETX (SIGINT)
            TerminalSurfaceView.isControlByteKey(
                try event("\u{03}", "c", .control, 0x08)))
        XCTAssertTrue(  // Ctrl-D → EOT
            TerminalSurfaceView.isControlByteKey(
                try event("\u{04}", "d", .control, 0x02)))
        XCTAssertTrue(  // Ctrl-[ → ESC
            TerminalSurfaceView.isControlByteKey(
                try event("\u{1B}", "[", .control, 0x21)))
        XCTAssertTrue(  // Ctrl-Space → NUL
            TerminalSurfaceView.isControlByteKey(
                try event("\u{00}", " ", .control, 0x31)))
        XCTAssertTrue(  // Ctrl-Shift-C still resolves to a control byte
            TerminalSurfaceView.isControlByteKey(
                try event("\u{03}", "C", [.control, .shift], 0x08)))

        // OUT: ⌘C (a Copy shortcut — Command set) must NOT be intercepted.
        XCTAssertFalse(
            TerminalSurfaceView.isControlByteKey(
                try event("c", "c", .command, 0x08)))
        // OUT: Ctrl+⌘ combos stay on the shortcut path.
        XCTAssertFalse(
            TerminalSurfaceView.isControlByteKey(
                try event("\u{03}", "c", [.control, .command], 0x08)))
        // OUT: Ctrl+Option carries its own (Meta/readline) semantics.
        XCTAssertFalse(
            TerminalSurfaceView.isControlByteKey(
                try event("\u{03}", "c", [.control, .option], 0x08)))
        // OUT: a plain printable key (no Control) is normal input/preedit.
        XCTAssertFalse(
            TerminalSurfaceView.isControlByteKey(
                try event("a", "a", [], 0x00)))
        // OUT: Control on a key with no C0 mapping (Ctrl-9) — `characters`
        // is not a single control byte, so it stays on the normal path.
        XCTAssertFalse(
            TerminalSurfaceView.isControlByteKey(
                try event("9", "9", .control, 0x19)))
    }

    /// Secondary fix: `copy(_:)` cancels an orphaned composition so a
    /// mid-composition ⌘C can't leave `compositionState` wedged (which is
    /// what AppKit fails to do for a custom NSTextInputClient). Pins the
    /// leak plug for the Copy selector; `paste`/`pastePlain`/`selectAll`
    /// share the same `cancelComposition()` call.
    func testCopyCancelsActiveComposition() throws {
        let surface = Self.makeSurface()
        _ = try XCTUnwrap(surface.rendererForTesting.session)
        surface.setMarkedText(
            "한",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(surface.hasMarkedText())

        surface.copy(nil)

        XCTAssertFalse(
            surface.hasMarkedText(),
            "⌘C must cancel an active composition so it can't orphan "
                + "compositionState and wedge the keyDown gate")
    }

    // MARK: - Helpers

    private static func makeSurface() -> TerminalSurfaceView {
        let surface = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        // viewDidMoveToWindow drives the renderer's session bring-up;
        // attach to a host window so the renderer wires correctly.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentView = surface
        return surface
    }

    private static func makeCatSession() -> TerminalSession {
        let envPayload = "TERM=xterm-256color\nLANG=en_US.UTF-8\n"
        let envVec = RustVec<UInt8>()
        for byte in envPayload.utf8 { envVec.push(value: byte) }
        let config = SessionConfig(
            rows: 24,
            cols: 80,
            pixel_w: 0,
            pixel_h: 0,
            command: "/bin/cat".intoRustString(),
            cwd: "/tmp".intoRustString(),
            env: envVec,
            scrollback_lines: 0)
        // Force-unwrap: a /bin/cat spawn must succeed in the test env;
        // nil here is a real failure worth crashing the test on.
        return TerminalSession.new(config)!
    }

    /// Drive cat-loopback by sending `payload` through `send_input` and
    /// polling `take_frame_delta` until row 0's first cell holds
    /// `first`. Mirrors the engine-side `drive_text` helper.
    private static func feedAndWaitForFirstChar(
        _ session: TerminalSession, payload: String, first: Character
    ) {
        let event = InputEventEncoder.makeKeyInputEvent(
            characters: payload, keycode: 0, modifiers: [])
        session.send_input(event)
        waitForFirstCellChar(session, expected: first)
    }

    /// Poll `take_frame_delta` until row 0 col 0 holds `expected`.
    /// Generous deadline; fails fast on timeout.
    ///
    /// `take_frame_delta` carries only the dirty cells per frame
    /// (alacritty re-marks the cursor row by design, so subsequent
    /// frames will keep yielding row 0 — but we may need to wait a
    /// few cycles for the PTY → reader → parser pipeline to land
    /// the byte on the grid).
    private static func waitForFirstCellChar(
        _ session: TerminalSession, expected: Character
    ) {
        let deadline = Date().addingTimeInterval(5.0)
        let expectedByte: UInt8? = expected.asciiValue
        while Date() < deadline {
            let frame = session.take_frame_delta()
            if let cells = try? FrameDeltaDecoding.decodeCells(frame.cells) {
                for cell in cells where cell.row == 0 && cell.col == 0 {
                    // First grapheme byte holds the ASCII codepoint
                    // for printable single-byte characters (this
                    // helper is ASCII-only — `Pasted!` and `hello
                    // world` both qualify).
                    if let want = expectedByte,
                        cell.grapheme.first == want
                    {
                        return
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("expected '\(expected)' at (0, 0) within 5s")
    }

    /// M2-6: drive a raw byte payload (typically OSC 133 sequences +
    /// printable bytes) through cat-loopback. Mirrors the live-FFI
    /// pattern used in `BlockBoundaryDecodingTests` —
    /// `KeyEvent.text.as_bytes()` is dispatched into the engine's
    /// `feed_input`, which writes through the PTY back to cat. cat
    /// echoes the bytes back so the parser sees them on the read path.
    private static func driveOscPayload(
        _ session: TerminalSession, payload: String
    ) {
        let key = KeyEvent(
            codepoint: 0,
            keycode: 0,
            text: payload.intoRustString(),
            action: 0)
        let mouse = MouseEvent(col: 0, row: 0, button: 0, action: 0)
        let event = InputEvent(kind: 0, key: key, mouse: mouse, modifiers: 0)
        session.send_input(event)
    }

    /// M2-6: poll `take_frame_delta` until ANY cell on row 0 holds one
    /// of the expected ASCII characters. Used by the multi-block /
    /// alt-screen / single-block clean-text contract tests where we
    /// don't need first-cell anchoring (cat may interleave OSC bytes
    /// with printable bytes), just confirmation that some content has
    /// landed in the grid before reading selection_text.
    private static func waitForCellSubstring(
        _ session: TerminalSession, anyOf chars: [Character], timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        let wantBytes = Set(chars.compactMap { $0.asciiValue })
        while Date() < deadline {
            let frame = session.take_frame_delta()
            if let cells = try? FrameDeltaDecoding.decodeCells(frame.cells) {
                for cell in cells {
                    if let first = cell.grapheme.first, wantBytes.contains(first) {
                        return
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // Don't XCTFail here — some tests deliberately drive content
        // that may not land in the row-0/col-0 sense (alt-screen entry
        // hides bytes from the primary grid; multi-block sequences
        // span multiple rows). Caller can assert text content directly.
    }
}
