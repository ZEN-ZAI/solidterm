// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

use super::{
    theme_color_for_index, ClipboardKind, EngineEvent, EventProxy, ThemeColors,
    ZENZAI_DARK_BACKGROUND, ZENZAI_DARK_CURSOR, ZENZAI_DARK_FOREGROUND,
};
use alacritty_terminal::event::{Event as AlacrittyEvent, EventListener};
use alacritty_terminal::term::ClipboardType;
use alacritty_terminal::vte::ansi::NamedColor;
use crossbeam_channel::{unbounded, Receiver};
use std::sync::Arc;

/// Build an `EventProxy` whose PTY-response channel is a throwaway
/// `Receiver` we drop on the floor. Used by every test that doesn't
/// care about OSC 10/11/12 replies. `_pty_rx` is held in a tuple
/// return so it stays alive for the lifetime of the proxy (sender
/// would error on a disconnected receiver).
fn proxy_for_event_tests() -> (EventProxy, Receiver<EngineEvent>, Receiver<String>) {
    let (events_tx, events_rx) = unbounded::<EngineEvent>();
    let (pty_tx, pty_rx) = unbounded::<String>();
    (EventProxy::new(events_tx, pty_tx), events_rx, pty_rx)
}

#[test]
fn clipboard_kind_from_alacritty_type() {
    assert_eq!(
        ClipboardKind::from(ClipboardType::Clipboard),
        ClipboardKind::Clipboard
    );
    assert_eq!(
        ClipboardKind::from(ClipboardType::Selection),
        ClipboardKind::Selection
    );
}

#[test]
fn proxy_forwards_bell() {
    let (proxy, rx, _pty_rx) = proxy_for_event_tests();
    proxy.send_event(AlacrittyEvent::Bell);
    assert_eq!(rx.try_recv().ok(), Some(EngineEvent::Bell));
}

#[test]
fn proxy_forwards_title_changed() {
    let (proxy, rx, _pty_rx) = proxy_for_event_tests();
    proxy.send_event(AlacrittyEvent::Title("solidterm".to_string()));
    assert_eq!(
        rx.try_recv().ok(),
        Some(EngineEvent::TitleChanged("solidterm".to_string()))
    );
}

#[test]
fn proxy_forwards_title_reset() {
    let (proxy, rx, _pty_rx) = proxy_for_event_tests();
    proxy.send_event(AlacrittyEvent::ResetTitle);
    assert_eq!(rx.try_recv().ok(), Some(EngineEvent::TitleReset));
}

#[test]
fn proxy_forwards_clipboard_store() {
    let (proxy, rx, _pty_rx) = proxy_for_event_tests();
    proxy.send_event(AlacrittyEvent::ClipboardStore(
        ClipboardType::Clipboard,
        "hello".to_string(),
    ));
    assert_eq!(
        rx.try_recv().ok(),
        Some(EngineEvent::ClipboardStore {
            kind: ClipboardKind::Clipboard,
            text: "hello".to_string(),
        })
    );
}

#[test]
fn proxy_pty_write_queues_on_pty_responses() {
    // #73: PtyWrite is the alacritty-side hook for `CSI 18 t`
    // (text_area_size_chars) — it routes the formatted reply
    // string through `pty_responses`, NOT the consumer-facing
    // events channel. Pin both halves of that contract.
    let (proxy, events_rx, pty_rx) = proxy_for_event_tests();
    proxy.send_event(AlacrittyEvent::PtyWrite("\x1b[8;24;80t".to_string()));
    assert!(
        events_rx.try_recv().is_err(),
        "PtyWrite must not surface as EngineEvent — replies are internal write-back"
    );
    assert_eq!(
        pty_rx.try_recv().ok(),
        Some("\x1b[8;24;80t".to_string()),
        "PtyWrite payload must land on pty_responses verbatim",
    );
}

#[test]
fn proxy_rewrites_bare_da1_to_advertise_color() {
    // alacritty answers DA1 with the bare VT102 `\x1b[?6c` (no color).
    // EventProxy rewrites it to `\x1b[?62;22c` (VT220 + ANSI color) so
    // probing apps don't treat SolidTerm as a featureless mono terminal.
    let (proxy, _events_rx, pty_rx) = proxy_for_event_tests();
    proxy.send_event(AlacrittyEvent::PtyWrite("\x1b[?6c".to_string()));
    assert_eq!(pty_rx.try_recv().ok(), Some("\x1b[?62;22c".to_string()));
}

#[test]
fn proxy_passes_through_non_da1_pty_writes_unchanged() {
    // Only the exact bare-DA1 string is rewritten; every other reply
    // (e.g. the XTWINOPS size report) is forwarded verbatim.
    let (proxy, _events_rx, pty_rx) = proxy_for_event_tests();
    proxy.send_event(AlacrittyEvent::PtyWrite("\x1b[8;24;80t".to_string()));
    assert_eq!(pty_rx.try_recv().ok(), Some("\x1b[8;24;80t".to_string()));
}

#[test]
fn proxy_drops_child_exit_vestigial_variant() {
    // alacritty's Event::ChildExit is defined but never fired
    // from Term::send_event; if it did somehow arrive (via a
    // future upstream change) we'd drop it because ChildExited
    // comes through the Pty::next_child_event path with a more
    // accurate exit status. Use `sh -c true` to construct an
    // ExitStatus portably (avoids hardcoding /bin/true vs
    // /usr/bin/true differences across hosts).
    let (proxy, rx, _pty_rx) = proxy_for_event_tests();
    let exit_status = std::process::Command::new("sh")
        .args(["-c", "true"])
        .status()
        .expect("sh -c true should run");
    proxy.send_event(AlacrittyEvent::ChildExit(exit_status));
    assert!(
        rx.try_recv().is_err(),
        "Event::ChildExit is vestigial upstream; Pty::next_child_event is the canonical source"
    );
}

#[test]
fn proxy_send_after_receiver_dropped_is_silent_warn() {
    let (events_tx, events_rx) = unbounded::<EngineEvent>();
    let (pty_tx, _pty_rx) = unbounded::<String>();
    let proxy = EventProxy::new(events_tx, pty_tx);
    drop(events_rx);
    // Should not panic; just logs a warn and drops.
    proxy.send_event(AlacrittyEvent::Bell);
}

// -----------------------------------------------------------------
// task 2.5 — OSC 10/11/12 (fg/bg/cursor color queries)
//
// The query path runs entirely inside alacritty's stack:
//
//   vte::Parser → vte::ansi::Processor → Term::dynamic_color_sequence
//     → Event::ColorRequest(index, formatter)
//     → EventProxy::send_event → pty_responses queue
//     → poll_output drains and writes to PTY master FD
//
// alacritty's `dynamic_color_sequence` (term/mod.rs:1675-1688) builds
// an `Arc<dyn Fn(Rgb) -> String>` formatter that already encodes the
// OSC prefix and matching terminator (BEL or ST), so EventProxy only
// needs to supply the Rgb. The formatter shape is:
//
//   |color| format!("\x1b]{};rgb:{r:02x}{r:02x}/{g:02x}{g:02x}/{b:02x}{b:02x}{terminator}",
//                   prefix, color.r, color.g, color.b)
//
// For OSC 10 query against fg=#d6d6dd, the reply is
// `\x1b]10;rgb:d6d6/d6d6/dddd\x1b\\` (the doubled hex bytes are the
// standard XParseColor format — a 16-bit channel synthesised by
// duplicating the 8-bit channel byte).
// -----------------------------------------------------------------

/// Direct-call (bypass parser) — `ColorRequest` for index 256
/// (Foreground) builds the formatted reply against
/// `ZENZAI_DARK_FOREGROUND` and pushes it onto the `pty_responses`
/// queue (no `EngineEvent` emitted on the events channel). Pins the
/// Rgb-lookup behaviour without depending on the full Term + parser
/// stack (those are exercised by the `osc_10_*_via_term` tests
/// below).
#[test]
fn proxy_color_request_foreground_pushes_pty_reply() {
    let (proxy, events_rx, pty_rx) = proxy_for_event_tests();
    // Synthesise the formatter alacritty would build for OSC 10 ; ?
    // with an ST terminator. Exact format from `term/mod.rs:1681`.
    let formatter = std::sync::Arc::new(|color: alacritty_terminal::vte::ansi::Rgb| {
        format!(
            "\x1b]10;rgb:{0:02x}{0:02x}/{1:02x}{1:02x}/{2:02x}{2:02x}\x1b\\",
            color.r, color.g, color.b
        )
    });
    proxy.send_event(AlacrittyEvent::ColorRequest(
        NamedColor::Foreground as usize,
        formatter,
    ));
    // No EngineEvent surfaced — replies are internal write-back.
    assert!(
        events_rx.try_recv().is_err(),
        "ColorRequest must not surface as EngineEvent — replies go to pty_responses",
    );
    // PTY response queue carries the formatted reply with the
    // hardcoded foreground (#d6d6dd → rgb:d6d6/d6d6/dddd).
    assert_eq!(
        pty_rx.try_recv().ok(),
        Some("\x1b]10;rgb:d6d6/d6d6/dddd\x1b\\".to_string()),
    );
}

/// `set_theme_colors` makes the OSC reply reflect the live theme, not
/// the hardcoded Zenzai Dark default. Set bg=#445566 and confirm the
/// OSC 11 reply carries it (`rgb:4444/5555/6666`).
#[test]
fn proxy_color_request_reflects_set_theme_colors() {
    let (events_tx, _events_rx) = unbounded::<EngineEvent>();
    let (pty_tx, pty_rx) = unbounded::<String>();
    let theme = Arc::new(ThemeColors::new_default());
    theme.set(0x11_22_33, 0x44_55_66, 0x77_88_99); // fg, bg, cursor (sRGB)
    let proxy = EventProxy::with_theme_colors(events_tx, pty_tx, Arc::clone(&theme));
    let formatter = Arc::new(|color: alacritty_terminal::vte::ansi::Rgb| {
        format!(
            "\x1b]11;rgb:{0:02x}{0:02x}/{1:02x}{1:02x}/{2:02x}{2:02x}\x1b\\",
            color.r, color.g, color.b
        )
    });
    proxy.send_event(AlacrittyEvent::ColorRequest(
        NamedColor::Background as usize,
        formatter,
    ));
    assert_eq!(
        pty_rx.try_recv().ok(),
        Some("\x1b]11;rgb:4444/5555/6666\x1b\\".to_string()),
        "OSC 11 reply must reflect the set background (#445566)",
    );
}

/// Index outside the M1 palette (256/257/258) — silently dropped.
/// Indices for the 16-color ANSI palette (0..16) and 256-color
/// extension (16..256) aren't themed at M1, so no reply is queued.
/// Future themability widens this; pin the current behaviour.
#[test]
fn proxy_color_request_unsupported_index_drops_silently() {
    let (proxy, events_rx, pty_rx) = proxy_for_event_tests();
    let formatter = std::sync::Arc::new(|_: alacritty_terminal::vte::ansi::Rgb| String::new());
    proxy.send_event(AlacrittyEvent::ColorRequest(0, formatter)); // ANSI black
    assert!(events_rx.try_recv().is_err());
    assert!(
        pty_rx.try_recv().is_err(),
        "OSC 4 query for ANSI palette must not produce a reply at M1",
    );
}

/// `theme_color_for_index` returns the right Rgb for each of the
/// three named indices. Belt-and-suspenders against an off-by-one
/// in the `NamedColor` discriminant constants.
#[test]
fn theme_color_lookup_matches_named_indices() {
    assert_eq!(
        theme_color_for_index(NamedColor::Foreground as usize),
        Some(ZENZAI_DARK_FOREGROUND),
    );
    assert_eq!(
        theme_color_for_index(NamedColor::Background as usize),
        Some(ZENZAI_DARK_BACKGROUND),
    );
    assert_eq!(
        theme_color_for_index(NamedColor::Cursor as usize),
        Some(ZENZAI_DARK_CURSOR),
    );
    // Bright/Dim variants and ANSI palette indices are intentionally
    // unhandled at M1 — defer to ThemeManager.
    assert!(theme_color_for_index(0).is_none());
    assert!(theme_color_for_index(255).is_none());
    assert!(theme_color_for_index(NamedColor::DimForeground as usize).is_none());
}

// -----------------------------------------------------------------
// task 2.6 — OSC 52 (clipboard write) end-to-end
//
// The OSC 52 path runs entirely inside alacritty's stack:
//
//   vte::Parser → vte::ansi::Processor → Term::clipboard_store
//     → EventProxy::send_event → EngineEvent::ClipboardStore
//
// alacritty already (a) parses `OSC 52 ; <selection> ; <data> ST`,
// (b) base64-decodes + UTF-8-validates `data`, (c) gates on the
// `Osc52` config (default `OnlyCopy` allows store, denies load), and
// (d) routes through `Event::ClipboardStore(ClipboardType, String)`.
// Our `EventProxy::send_event` impl above translates that to
// `EngineEvent::ClipboardStore { kind, text }`.
//
// Sources (alacritty_terminal 0.26.0 / vte 0.15.0):
//   - vte/ansi.rs:1483-1492 — OSC 52 dispatch (b"52" arm).
//   - alacritty_terminal/term/mod.rs:1705-1722 — clipboard_store
//     (selection match, base64 decode, UTF-8 validate, send_event).
//   - alacritty_terminal/term/mod.rs:1726-1747 — clipboard_load
//     (gated to Osc52::OnlyPaste|CopyPaste; denied under our default).
//
// These tests therefore serve two purposes:
//   1. Pin the upstream behaviour our renderer relies on (so a
//      future alacritty bump that breaks OSC 52 fails CI here).
//   2. Document the proxy translation for reviewers — `text` is
//      the **decoded** UTF-8 string, not raw base64.
//
// Tests run a real `Term<EventProxy>` + `ansi::Processor` (no PTY
// spawn — fast + deterministic) per the alacritty-internal pattern.
// -----------------------------------------------------------------

use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::{Config as AlacrittyTermConfig, Term};
use alacritty_terminal::vte::ansi;

/// Minimal `Dimensions` for a non-PTY `Term` constructed inside
/// these tests. Mirrors the `EngineDimensions` in `engine.rs`; kept
/// local to the test module so we don't widen the engine's surface.
struct TestDimensions {
    rows: usize,
    cols: usize,
}

impl Dimensions for TestDimensions {
    fn total_lines(&self) -> usize {
        self.rows
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

/// Drive `bytes` through `vte::ansi::Processor` against a fresh
/// `Term<EventProxy>` and return the events drained from the proxy
/// channel. This is the same code path `TerminalEngine::poll_output`
/// runs (`engine.rs:373`), minus the PTY reader thread.
fn drive_through_term(bytes: &[u8]) -> Vec<EngineEvent> {
    let (events, _replies) = drive_through_term_full(bytes);
    events
}

/// Same as [`drive_through_term`] but also returns the queue of
/// PTY-write-back replies (OSC 10/11/12 query answers). Used by
/// task 2.5's tests to verify the reply payload without mocking
/// a PTY.
fn drive_through_term_full(bytes: &[u8]) -> (Vec<EngineEvent>, Vec<String>) {
    let (events_tx, events_rx) = unbounded::<EngineEvent>();
    let (pty_tx, pty_rx) = unbounded::<String>();
    let proxy = EventProxy::new(events_tx, pty_tx);
    let dims = TestDimensions { rows: 24, cols: 80 };
    let mut term = Term::new(AlacrittyTermConfig::default(), &dims, proxy);
    // Explicit type annotation — `Processor`'s `Timeout` type
    // parameter has a default (`StdSyncHandler`) that the inference
    // engine doesn't pick automatically across crate boundaries.
    // `engine.rs:134` uses the same shape (typed field).
    let mut parser: ansi::Processor = ansi::Processor::new();
    parser.advance(&mut term, bytes);
    let mut events = Vec::new();
    while let Ok(event) = events_rx.try_recv() {
        events.push(event);
    }
    let mut replies = Vec::new();
    while let Ok(reply) = pty_rx.try_recv() {
        replies.push(reply);
    }
    (events, replies)
}

/// OSC 52 ; c ; <base64> — the canonical clipboard-write form.
/// Base64 of "Hello" is `SGVsbG8=`. Expect `ClipboardStore` with
/// `kind: Clipboard` and the **decoded** text.
#[test]
fn osc_52_c_with_base64_emits_clipboard_store() {
    let events = drive_through_term(b"\x1b]52;c;SGVsbG8=\x1b\\");
    assert_eq!(
        events,
        vec![EngineEvent::ClipboardStore {
            kind: ClipboardKind::Clipboard,
            text: "Hello".to_string(),
        }],
    );
}

/// BEL terminator (`\x07`) is interchangeable with ST (`\x1b\\`)
/// for OSC sequences. `vte::Parser` collapses both into the same
/// `osc_dispatch`; pin that down for OSC 52 too.
#[test]
fn osc_52_c_bel_terminated_also_works() {
    let events = drive_through_term(b"\x1b]52;c;d29ybGQ=\x07");
    assert_eq!(
        events,
        vec![EngineEvent::ClipboardStore {
            kind: ClipboardKind::Clipboard,
            text: "world".to_string(),
        }],
    );
}

/// OSC 52 ; p ; <base64> — X11 PRIMARY selection. macOS has no
/// PRIMARY equivalent; alacritty still surfaces it as
/// `ClipboardType::Selection` and the renderer is responsible for
/// ignoring it. Pin the kind translation here.
#[test]
fn osc_52_p_emits_selection_kind() {
    let events = drive_through_term(b"\x1b]52;p;Zm9v\x1b\\");
    assert_eq!(
        events,
        vec![EngineEvent::ClipboardStore {
            kind: ClipboardKind::Selection,
            text: "foo".to_string(),
        }],
    );
}

/// OSC 52 ; s ; <base64> — `s` (alias for select-text) also maps
/// to `Selection` per `term/mod.rs:1713`.
#[test]
fn osc_52_s_emits_selection_kind() {
    let events = drive_through_term(b"\x1b]52;s;YmFy\x1b\\");
    assert_eq!(
        events,
        vec![EngineEvent::ClipboardStore {
            kind: ClipboardKind::Selection,
            text: "bar".to_string(),
        }],
    );
}

/// OSC 52 ; c ; ? — clipboard *read* request. Under our default
/// `Osc52::OnlyCopy` config (set in `engine.rs:220`, inheriting
/// alacritty's Default), reads are denied and no event fires.
/// Read-path support is deferred to M2+ for security reasons
/// (terminal apps reading clipboard = exfiltration vector; needs
/// explicit user-consent UX).
#[test]
fn osc_52_query_form_does_not_emit_under_default_config() {
    let events = drive_through_term(b"\x1b]52;c;?\x1b\\");
    assert!(
        events.is_empty(),
        "OSC 52 ; c ; ? must not emit under default Osc52::OnlyCopy",
    );
}

/// OSC 52 ; c ; <invalid-base64> — alacritty's base64 decoder
/// returns `Err`; `clipboard_store` early-returns without firing
/// an event (`term/mod.rs:1717`). Exfil-resistant: malformed input
/// is silently dropped rather than panicking or emitting a
/// half-decoded payload.
#[test]
fn osc_52_invalid_base64_does_not_emit() {
    // `not-base64!!!` decodes-fails (! is outside the base64
    // alphabet). The arm must drop, no panic, no event.
    let events = drive_through_term(b"\x1b]52;c;not-base64!!!\x1b\\");
    assert!(events.is_empty(), "invalid base64 must be silently dropped",);
}

/// OSC 52 ; c ; <base64-of-invalid-utf8> — base64 decodes to bytes
/// that aren't valid UTF-8; alacritty's `String::from_utf8` returns
/// `Err` and the event is dropped (`term/mod.rs:1718`). Pins the
/// "no malformed text emit" guarantee.
#[test]
fn osc_52_invalid_utf8_payload_does_not_emit() {
    // Lone continuation byte 0x80 is not valid UTF-8. Base64-encoded
    // `[0x80]` is `gA==`.
    let events = drive_through_term(b"\x1b]52;c;gA==\x1b\\");
    assert!(
        events.is_empty(),
        "non-UTF-8 decoded payload must not emit (silent drop)",
    );
}

/// OSC 52 with an unrecognised selection byte (e.g. `q`, `0`-`7`,
/// or any letter outside `c`/`p`/`s`) — alacritty's match arm
/// early-returns (`term/mod.rs:1714`). No event fires. Multi-char
/// selection like `cs` collapses to its first byte (`c`) per vte's
/// `params[1].first().unwrap_or(&b'c')` (`vte/ansi.rs:1488`); the
/// "unrecognised" case here picks a byte that's neither.
#[test]
fn osc_52_unrecognised_selection_does_not_emit() {
    let events = drive_through_term(b"\x1b]52;q;SGVsbG8=\x1b\\");
    assert!(
        events.is_empty(),
        "OSC 52 with unrecognised selection byte must not emit",
    );
}

/// OSC 52 with empty selection (`OSC 52 ; ; <base64>`) — vte's
/// dispatch defaults to `b'c'` when `params[1].first()` is `None`
/// (`vte/ansi.rs:1488`). So this is treated as an OSC 52 ; c ; ...
/// write. Pins that fallback so a future vte change doesn't
/// silently break "missing-selection" shells.
#[test]
fn osc_52_empty_selection_defaults_to_clipboard() {
    let events = drive_through_term(b"\x1b]52;;SGVsbG8=\x1b\\");
    assert_eq!(
        events,
        vec![EngineEvent::ClipboardStore {
            kind: ClipboardKind::Clipboard,
            text: "Hello".to_string(),
        }],
    );
}

/// OSC 52 with too few parameters (`OSC 52` alone, or just
/// `OSC 52 ; c`) — vte's `params.len() < 3` guard returns via
/// `unhandled` (`vte/ansi.rs:1484`). No event, no panic.
#[test]
fn osc_52_truncated_params_does_not_emit() {
    // No selection, no data.
    let events = drive_through_term(b"\x1b]52\x1b\\");
    assert!(events.is_empty(), "OSC 52 with no params must not emit");

    // Selection but no data.
    let events = drive_through_term(b"\x1b]52;c\x1b\\");
    assert!(
        events.is_empty(),
        "OSC 52 with selection but no data must not emit",
    );
}

/// OSC 52 ; c ; <empty-base64> — empty base64 is valid and decodes
/// to an empty byte string, which is valid UTF-8 (the empty
/// string). alacritty fires `ClipboardStore` with `text: ""`. Pins
/// this edge case so a renderer-side "non-empty payload" assertion
/// can be added later without surprise.
#[test]
fn osc_52_empty_base64_emits_empty_text() {
    let events = drive_through_term(b"\x1b]52;c;\x1b\\");
    assert_eq!(
        events,
        vec![EngineEvent::ClipboardStore {
            kind: ClipboardKind::Clipboard,
            text: String::new(),
        }],
    );
}

/// OSC 52 with a decoded payload that exceeds `OSC52_MAX_DECODED_BYTES`
/// is dropped at the `EventProxy` cap check. "QUFB" is base64 for "AAA"
/// (3 bytes); repeating it `(cap / 3) + 1` times decodes to more than
/// cap bytes. The engine must not emit a `ClipboardStore` event.
#[test]
fn osc_52_write_over_cap_is_dropped() {
    use super::OSC52_MAX_DECODED_BYTES;
    // (cap / 3) + 1 repetitions decodes to cap + 1 bytes — just over the limit.
    let payload = "QUFB".repeat((OSC52_MAX_DECODED_BYTES / 3) + 1);
    let seq = format!("\x1b]52;c;{payload}\x1b\\");
    let events = drive_through_term(seq.as_bytes());
    assert!(
        events.is_empty(),
        "OSC 52 payload exceeding OSC52_MAX_DECODED_BYTES must be dropped; got {events:?}",
    );
}

/// OSC 52 with a decoded payload well under the cap passes through
/// unchanged. "QUFB" decodes to "AAA" (3 bytes).
#[test]
fn osc_52_write_under_cap_passes() {
    let events = drive_through_term(b"\x1b]52;c;QUFB\x1b\\");
    assert_eq!(
        events,
        vec![EngineEvent::ClipboardStore {
            kind: ClipboardKind::Clipboard,
            text: "AAA".to_string(),
        }],
        "OSC 52 payload under cap must emit exactly one ClipboardStore event",
    );
}

// -----------------------------------------------------------------
// task 2.5 — OSC 10/11/12 end-to-end through Term + Processor
//
// Drive each query through the full alacritty stack and assert the
// formatted reply lands on `pty_responses`. The reply uses the
// XParseColor `rgb:RRRR/GGGG/BBBB` format alacritty's formatter at
// term/mod.rs:1681 builds (16-bit channels synthesised by repeating
// each 8-bit byte — see vte/ansi.rs comments for why).
// -----------------------------------------------------------------

/// OSC 10 ; ? ST — query the foreground color. Reply carries
/// `rgb:d6d6/d6d6/dddd` for `#d6d6dd` and the same ST terminator
/// the shell sent.
#[test]
fn osc_10_query_replies_with_foreground() {
    let (events, replies) = drive_through_term_full(b"\x1b]10;?\x1b\\");
    assert!(events.is_empty(), "OSC 10 query must not surface as event");
    assert_eq!(
        replies,
        vec!["\x1b]10;rgb:d6d6/d6d6/dddd\x1b\\".to_string()]
    );
}

/// OSC 11 ; ? ST — query the background color. Reply carries
/// `rgb:0c0c/0d0d/1010` for `#0c0d10`.
#[test]
fn osc_11_query_replies_with_background() {
    let (events, replies) = drive_through_term_full(b"\x1b]11;?\x1b\\");
    assert!(events.is_empty());
    assert_eq!(
        replies,
        vec!["\x1b]11;rgb:0c0c/0d0d/1010\x1b\\".to_string()]
    );
}

/// OSC 12 ; ? ST — query the cursor color. Reply carries
/// `rgb:7a7a/a2a2/f7f7` for `#7aa2f7`.
#[test]
fn osc_12_query_replies_with_cursor() {
    let (events, replies) = drive_through_term_full(b"\x1b]12;?\x1b\\");
    assert!(events.is_empty());
    assert_eq!(
        replies,
        vec!["\x1b]12;rgb:7a7a/a2a2/f7f7\x1b\\".to_string()]
    );
}

/// BEL terminator (`\x07`) — alacritty's formatter takes the
/// terminator the shell used and echoes it back; vte's parser
/// surfaces both `\x1b\\` and `\x07` as the same OSC dispatch. Pin
/// the BEL-roundtrip path for OSC 10 (the others share the formatter
/// shape).
#[test]
fn osc_10_query_bel_terminated_reply_uses_bel() {
    let (_events, replies) = drive_through_term_full(b"\x1b]10;?\x07");
    assert_eq!(replies, vec!["\x1b]10;rgb:d6d6/d6d6/dddd\x07".to_string()]);
}

/// OSC 10 set form (`OSC 10 ; rgb:RR/GG/BB ST`) — alacritty parses
/// the rgb body and calls `Handler::set_color` on Term, which
/// updates Term's internal palette (no event, no PTY reply). M1
/// doesn't react to set requests beyond letting alacritty mutate
/// its palette; the renderer keeps painting against its own
/// hardcoded ThemeManager-replacement constants. The test pins
/// "no panic, no surprise event, no PTY reply" — the contract is
/// "set form is silently absorbed by alacritty".
#[test]
fn osc_10_set_form_does_not_emit_or_reply() {
    let (events, replies) = drive_through_term_full(b"\x1b]10;rgb:00/00/00\x1b\\");
    assert!(events.is_empty(), "OSC 10 set must not surface as event");
    assert!(
        replies.is_empty(),
        "OSC 10 set must not produce a PTY reply"
    );
}

/// OSC 11 set form, same contract as OSC 10 set.
#[test]
fn osc_11_set_form_does_not_emit_or_reply() {
    let (events, replies) = drive_through_term_full(b"\x1b]11;rgb:ff/ff/ff\x1b\\");
    assert!(events.is_empty());
    assert!(replies.is_empty());
}

/// OSC 12 set form, same contract.
#[test]
fn osc_12_set_form_does_not_emit_or_reply() {
    let (events, replies) = drive_through_term_full(b"\x1b]12;#7aa2f7\x1b\\");
    assert!(events.is_empty());
    assert!(replies.is_empty());
}

/// Multiple queries chained in one chunk (`OSC 10 ; ? ; ?`) —
/// alacritty's `OSC 10|11|12` arm at vte/ansi.rs:1422 iterates
/// `params[1..]` and **increments** the dynamic color code on each
/// iteration (vte/ansi.rs:1447). So `OSC 10 ; ? ; ? ; ?` is a
/// chained query for fg → bg → cursor in one OSC. Each iteration
/// invokes `dynamic_color_sequence` separately, so `EventProxy`
/// queues one reply per `?`. Pin the per-index advancement to
/// catch upstream behaviour changes.
#[test]
fn osc_10_chained_query_advances_index_per_question_mark() {
    let (_events, replies) = drive_through_term_full(b"\x1b]10;?;?;?\x1b\\");
    assert_eq!(
        replies,
        vec![
            "\x1b]10;rgb:d6d6/d6d6/dddd\x1b\\".to_string(),
            "\x1b]11;rgb:0c0c/0d0d/1010\x1b\\".to_string(),
            "\x1b]12;rgb:7a7a/a2a2/f7f7\x1b\\".to_string(),
        ],
        "chained `;?` parameters should advance fg → bg → cursor per upstream loop",
    );
}

// -----------------------------------------------------------------
// task 2.10 — XTWINOPS title operations & rows-cols query (#73)
//
// Of the four CSI t variants vte/alacritty handles
// (vte-0.15.0/src/ansi.rs:1739-1745):
//   - 14 t (text_area_size_pixels) — needs cell pixel dims; deferred
//     (the renderer side owns those values).
//   - 18 t (text_area_size_chars) — formats `\x1b[8;rows;cols t`
//     directly via `Event::PtyWrite`, exercised below.
//   - 22 t (push_title) — alacritty stores `term.title.clone()` on
//     an internal stack capped at TITLE_STACK_MAX_DEPTH = 4096
//     (alacritty_terminal-0.26.0/src/term/mod.rs:42). No event is
//     fired; verified indirectly by the pop-restores-prior-title
//     test below.
//   - 23 t (pop_title) — alacritty calls `set_title(popped)` which
//     fires `Event::Title` (or `Event::ResetTitle` if the popped
//     value was None). That's what surfaces as `EngineEvent::Title
//     Changed` / `TitleReset` to consumers — we just verify the
//     existing translation still holds across a push/pop cycle.
//
// CSI 0 t and 2 t (title queries) are intentionally NOT supported
// by vte (the `_ => unhandled!()` arm at vte/ansi.rs:1744). xterm-
// hardened terminal emulators omit title query support — replying
// with arbitrary user-controlled title text is a CVE class
// (e.g. CVE-2003-0063). We inherit that posture by not adding our
// own dispatch; if a future spec requires it, we'd have to handle
// it outside the alacritty stack.
// -----------------------------------------------------------------

/// `CSI 18 t` produces `\x1b[8;<rows>;<cols> t` on the PTY-response
/// queue via the `PtyWrite` arm. `TestDimensions` is 24×80, so the
/// expected reply is `\x1b[8;24;80t`. Pins both:
///   1. alacritty/vte still dispatches `('t', []) => 18 =>
///      text_area_size_chars` (catches an upstream regression).
///   2. Our `PtyWrite` translation routes the bytes verbatim through
///      `pty_responses` (catches a regression in `EventProxy`).
#[test]
fn xtwinops_18t_emits_rows_cols_reply() {
    let (events, replies) = drive_through_term_full(b"\x1b[18t");
    assert!(
        events.is_empty(),
        "CSI 18 t must not surface a consumer-facing event; got {events:?}",
    );
    assert_eq!(
        replies,
        vec!["\x1b[8;24;80t".to_string()],
        "CSI 18 t reply payload (rows;cols) must match the test dimensions",
    );
}

/// `CSI 14 t` (`text_area_size_pixels`) is the deferred sibling —
/// alacritty fires `Event::TextAreaSizeRequest(formatter)` which
/// the proxy currently drops with a tracing breadcrumb. Pin the
/// drop so an accidental "wire it up" change has to surface here
/// (it would need cell pixel dims that don't live on the engine).
#[test]
fn xtwinops_14t_pixel_query_drops_until_renderer_wired() {
    let (events, replies) = drive_through_term_full(b"\x1b[14t");
    assert!(
        events.is_empty(),
        "CSI 14 t must not surface a consumer-facing event today",
    );
    assert!(
        replies.is_empty(),
        "CSI 14 t reply path is deferred (needs cell pixel dims from renderer)",
    );
}

/// `CSI 22 t` (`push_title`) does not fire any alacritty event —
/// title state is mutated only on `set_title` / `pop_title` /
/// `reset_title`. Pin the silent-stack-push contract: feeding
/// `OSC 0 ; A ST` then `CSI 22 t` produces exactly one
/// `TitleChanged("A")`, with no extra event for the push.
#[test]
fn xtwinops_22t_push_title_emits_no_event() {
    let (events, replies) = drive_through_term_full(b"\x1b]0;A\x1b\\\x1b[22t");
    assert_eq!(
        events,
        vec![EngineEvent::TitleChanged("A".to_string())],
        "push_title must be silent — only the prior set_title fires an event",
    );
    assert!(
        replies.is_empty(),
        "push_title is purely state-mutating; no PTY reply",
    );
}

/// `CSI 23 t` (`pop_title`) restores the most recent pushed title
/// via `set_title(popped)`, which fires `Event::Title(prev)` or
/// `Event::ResetTitle` if the popped value was `None`. Round-trip:
///
/// 1. `OSC 0 ; A ST` -> `TitleChanged("A")`
/// 2. `CSI 22 t` -> silent push of "A"
/// 3. `OSC 0 ; B ST` -> `TitleChanged("B")`
/// 4. `CSI 23 t` -> `set_title(Some("A"))` -> `TitleChanged("A")`
///
/// Confirms the title stack semantics our consumers (block
/// tracking, window-chrome label) rely on.
#[test]
fn xtwinops_23t_pop_title_restores_prior_title() {
    let (events, replies) =
        drive_through_term_full(b"\x1b]0;A\x1b\\\x1b[22t\x1b]0;B\x1b\\\x1b[23t");
    assert_eq!(
        events,
        vec![
            EngineEvent::TitleChanged("A".to_string()),
            EngineEvent::TitleChanged("B".to_string()),
            EngineEvent::TitleChanged("A".to_string()),
        ],
        "expected push/pop cycle to restore the pushed title via set_title",
    );
    assert!(replies.is_empty());
}

/// `CSI 23 t` against an empty title stack is a no-op —
/// `pop_title` early-returns when `title_stack.pop()` yields `None`
/// (`alacritty_terminal-0.26.0/src/term/mod.rs:2252`). No event, no
/// reply, no panic. Defensive against a host that emits `23 t`
/// without a matching prior `22 t`.
#[test]
fn xtwinops_23t_pop_on_empty_stack_is_noop() {
    let (events, replies) = drive_through_term_full(b"\x1b[23t");
    assert!(
        events.is_empty(),
        "pop_title on empty stack must not fire any event; got {events:?}",
    );
    assert!(replies.is_empty());
}
