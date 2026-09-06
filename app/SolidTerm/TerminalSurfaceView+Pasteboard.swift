// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Copy / paste for `TerminalSurfaceView` (4.6), split out of the
// single-file view along its existing MARK: the ⌘C / ⌘V / paste-plain
// selectors and the chunked bracketed-paste feed.

import AppKit

extension TerminalSurfaceView {
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
    /// UX2: ⌘A — Select the entire visible viewport. Matches Terminal.app's
    /// "viewport-only" interpretation (iTerm2 selects scrollback too;
    /// we keep parity with the stock terminal until users ask for the
    /// broader version). The selection is built by `start_selection`
    /// at (0,0) and `update_selection` at the last cell of the
    /// viewport, then mirrored into `pendingSelection` so `copy(_:)`
    /// can read the text the same way it does for mouse-driven
    /// selections.
    @objc override func selectAll(_ sender: Any?) {
        // A ⌘-shortcut firing mid-composition won't auto-cancel the preedit
        // for a custom NSTextInputClient — drop any orphan so it can't wedge
        // the keyDown gate (see `cancelComposition`).
        cancelComposition()
        guard let session = renderer.session else { return }
        let rows = renderer.viewportRows
        let cols = renderer.viewportCols
        guard rows > 0, cols > 0 else { return }
        let endRow = UInt16(rows - 1)
        let endCol = UInt16(cols - 1)
        session.start_selection(Self.SELECTION_MODE_SIMPLE, 0, 0)
        session.update_selection(endRow, endCol)
        syncPendingSelection(
            from: session,
            fallback: (row: endRow, col: endCol),
            mode: Self.SELECTION_MODE_SIMPLE)
        renderer.markNeedsRedraw()
    }

    @objc func copy(_ sender: Any?) {
        // See `cancelComposition`: AppKit doesn't auto-cancel a custom
        // client's preedit when a ⌘-equivalent fires, so a Thai/CJK
        // composition active at ⌘C time would otherwise leave
        // `compositionState` orphaned and wedge the keyDown gate.
        cancelComposition()
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

    /// Paste from the system pasteboard. Reads the public-utf8 string
    /// type, wraps in bracketed-paste markers if the running app has
    /// enabled DECSET 2004, and feeds the result through the same
    /// `send_input` byte path as IME-committed text — single FFI call,
    /// engine-side parser handles the markers.
    @objc func paste(_ sender: Any?) {
        // See `cancelComposition`: cancel any orphaned preedit a ⌘V fired
        // mid-composition would leave behind on a custom NSTextInputClient.
        cancelComposition()
        guard let session = renderer.session else { return }
        let pb = NSPasteboard.general

        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        let payload = Self.formatPastePayload(
            text, bracketedPasteEnabled: session.bracketed_paste_enabled())
        // 4.4 snap-to-bottom on user input — paste behaves like typing.
        session.scroll_to_bottom()
        Self.feedChunked(payload, into: session)
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
        // See `cancelComposition`: cancel any orphaned preedit a ⌘⇧V fired
        // mid-composition would leave behind on a custom NSTextInputClient.
        cancelComposition()
        guard let session = renderer.session else { return }
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        let payload = Self.formatPastePayload(text, bracketedPasteEnabled: false)
        session.scroll_to_bottom()
        Self.feedChunked(payload, into: session)
    }

    /// Paste/long-input chunker. macOS's PTY input buffer is small —
    /// ~1 KB per direction (`TTYHOG`). A single multi-KB `write_all`
    /// on the master FD blocks the moment the kernel buffer fills.
    /// On the main thread that meant the entire UI froze until the
    /// child drained, which on a slow / paused shell could be tens
    /// of seconds for a long paste.
    ///
    /// Fix: route the payload through the engine's
    /// `paste_chunk` FFI, which sets `O_NONBLOCK` for the duration
    /// of one `write(2)` and returns the byte count the kernel
    /// accepted (0 on EAGAIN). We resubmit whatever wasn't accepted
    /// on the next runloop tick via `DispatchQueue.main.async` so
    /// keystrokes / mouse / display link all interleave between
    /// retries. The first call also runs through `async` so the
    /// `paste(_:)` selector returns immediately and the user sees
    /// the menu close before any byte hits the PTY.
    static func feedChunked(_ payload: String, into session: TerminalSession) {
        let bytes = Array(payload.utf8)
        guard !bytes.isEmpty else { return }
        // Run the first round synchronously — small pastes (a few
        // hundred bytes, the common case) finish before this method
        // returns, which keeps the existing test contract intact
        // (`surface.paste(nil)` followed by a `take_frame_delta`
        // assert sees the bytes immediately) and avoids the visible
        // "paste delay" for keystroke-sized payloads. Only when the
        // kernel returns EAGAIN do we defer the tail to runloop ticks.
        feedPasteTail(bytes: bytes, offset: 0, session: session)
    }

    /// Maximum bytes to attempt per non-blocking `write(2)`. Anything
    /// the kernel can't accept lands in EAGAIN and gets re-queued
    /// for the next tick — so the value only governs throughput
    /// upper bound when the buffer is empty (no syscall-rate cliff
    /// in practice). 4 KB keeps the syscall count modest for a
    /// 200 KB paste (~50 ticks) without making any one slice big
    /// enough to be wasted on an immediate EAGAIN.
    private static let pasteChunkBytes: Int = 4096

    private static func feedPasteTail(
        bytes: [UInt8], offset: Int, session: TerminalSession
    ) {
        var cursor = offset
        // Drain as much as the kernel will accept in this tick.
        // `paste_chunk` returns 0 on EAGAIN — at that point we defer
        // the remainder to the runloop so other main-thread work
        // (keystrokes, draw, mouse) interleaves while the child
        // drains its TTY input buffer.
        while cursor < bytes.count {
            let end = min(cursor + pasteChunkBytes, bytes.count)
            let written = bytes.withUnsafeBufferPointer { buf -> Int in
                let slice = UnsafeBufferPointer(
                    start: buf.baseAddress!.advanced(by: cursor),
                    count: end - cursor)
                return Int(session.paste_chunk(slice))
            }
            if written == 0 {
                // EAGAIN: schedule the rest for the next tick + small
                // delay so the kernel has time to copy bytes out to
                // the child.
                let nextOffset = cursor
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(2)) {
                    feedPasteTail(
                        bytes: bytes, offset: nextOffset, session: session)
                }
                return
            }
            cursor += written
        }
    }

    /// Pure helper for paste chunking — exposed to XCTest. Given a
    /// UTF-8 byte buffer, a start `offset`, and a target chunk size,
    /// returns the end index for a chunk that:
    ///   1. Ends at or before `offset + chunkSize`
    ///   2. Falls on a UTF-8 code-point boundary (so the chunk is
    ///      valid UTF-8 by itself).
    /// Walks backward from the naive boundary while the byte is a
    /// continuation byte (`10xxxxxx`). If the whole window collapses
    /// (pathological payload with a multibyte sequence longer than
    /// `chunkSize`), falls back to the naive boundary — we'd rather
    /// emit one invalid chunk than hang.
    static func pasteChunkEnd(
        bytes: [UInt8], offset: Int, chunkSize: Int
    ) -> Int {
        let naive = min(offset + chunkSize, bytes.count)
        if naive >= bytes.count { return naive }
        var end = naive
        while end > offset && (bytes[end] & 0xC0) == 0x80 {
            end -= 1
        }
        return end == offset ? naive : end
    }

    /// Pure helper exposed to XCTest. Returns `text` unchanged when
    /// bracketed paste is disabled; wraps in `ESC [200~ ... ESC [201~`
    /// when enabled. Kept `static` + side-effect-free so the test path
    /// doesn't need to stand up a session.
    static func formatPastePayload(_ text: String, bracketedPasteEnabled: Bool) -> String {
        if bracketedPasteEnabled {
            // PG2 paste-jail guard: if the clipboard payload contains
            // the bracketed-paste end marker `\e[201~`, the running
            // app would see "paste over" mid-payload and process the
            // tail as regular input — letting an attacker-controlled
            // clipboard execute commands. Strip the embedded marker
            // (matches iTerm2 / Ghostty / Alacritty behaviour). We
            // also strip the start marker for symmetry; without it
            // the leftover end marker has nothing to close anyway.
            // Loop until stable: a single pass is bypassable — a crafted
            // clipboard like `\e[20` + `\e[201~` + `1~` re-splices into a
            // fresh `\e[201~` across the removal boundary, escaping the
            // jail. Each pass strips ≥1 marker so the string strictly
            // shrinks; rescan until none remain, closing the re-splice
            // without over-stripping legitimate ESC bytes.
            var scrubbed = text
            while scrubbed.contains("\u{1B}[200~")
                || scrubbed.contains("\u{1B}[201~")
            {
                scrubbed =
                    scrubbed
                    .replacingOccurrences(of: "\u{1B}[200~", with: "")
                    .replacingOccurrences(of: "\u{1B}[201~", with: "")
            }
            return "\u{1B}[200~" + scrubbed + "\u{1B}[201~"
        }
        return text
    }
}
