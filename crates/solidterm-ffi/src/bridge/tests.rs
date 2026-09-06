// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

use super::ffi::{
    CellDelta, CursorState, FrameDelta, HyperlinkHit, InputEvent, KeyEvent, MouseEvent,
    SessionConfig,
};
use super::{decode_cells, decode_env, encode_cells, kinds, CellDeltaWire, SearchMatchWire};

/// A `/bin/cat` session: bytes written with `send_input` come back
/// on the read path, so escape sequences reach the parser exactly as
/// a real child would emit them.
fn cat_session() -> super::TerminalSession {
    let config = SessionConfig {
        rows: 24,
        cols: 80,
        pixel_w: 0,
        pixel_h: 0,
        command: "/bin/cat".to_string(),
        cwd: "/tmp".to_string(),
        env: b"TERM=xterm-256color\n".to_vec(),
        scrollback_lines: 0,
    };
    super::TerminalSession::new(config).expect("/bin/cat spawn ok")
}

fn feed(session: &mut super::TerminalSession, payload: &str) {
    session.send_input(InputEvent {
        kind: kinds::INPUT_EVENT_KEY,
        key: KeyEvent {
            codepoint: 0,
            keycode: 0,
            text: payload.to_string(),
            action: 0,
        },
        mouse: MouseEvent {
            col: 0,
            row: 0,
            button: 0,
            action: 0,
        },
        modifiers: 0,
    });
}

/// `\e]2;<text>\a` claims the title; `\e]2;\a` hands it back. The
/// empty payload arrives from vte as `TitleChanged("")`, which is
/// the Swift boundary's "nothing happened" sentinel — the host can
/// only tell the two apart because we latch it as a reset here.
#[test]
fn empty_osc_2_latches_a_title_reset_not_an_empty_title() {
    use std::time::{Duration, Instant};
    let mut session = cat_session();

    feed(&mut session, "\x1b]2;solidterm\x07\n");
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut title = String::new();
    while Instant::now() < deadline && title.is_empty() {
        let _ = session.take_frame_delta();
        title = session.drain_latest_title();
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(title, "solidterm");
    assert!(
        !session.drain_title_reset(),
        "claiming a title is not handing it back"
    );

    feed(&mut session, "\x1b]2;\x07\n");
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut reset = false;
    while Instant::now() < deadline && !reset {
        let _ = session.take_frame_delta();
        reset = session.drain_title_reset();
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(reset, "empty OSC 2 must surface as a title reset");
    assert!(
        session.drain_latest_title().is_empty(),
        "the reset must not also land as a title"
    );
}

fn sample_cell(row: u16, col: u16, ch: u8) -> CellDeltaWire {
    let mut g = [0u8; 32];
    g[0] = ch;
    CellDeltaWire {
        row,
        col,
        grapheme: g,
        fg: 0xFFFF_FFFF,
        bg: 0x0000_0000,
        attrs: 0,
        width: 1,
        reserved: 0,
    }
}

#[test]
fn cell_delta_wire_size_and_align_pinned() {
    assert_eq!(core::mem::size_of::<CellDeltaWire>(), 48);
    assert_eq!(core::mem::align_of::<CellDeltaWire>(), 4);
}

#[test]
fn encode_then_decode_cells_round_trip() {
    let cells = vec![sample_cell(0, 0, b'a'), sample_cell(0, 1, b'b')];
    let payload = encode_cells(&cells);
    assert_eq!(payload.len(), cells.len() * 48);
    let back = decode_cells(&payload).expect("aligned");
    assert_eq!(back, cells.as_slice());
}

#[test]
fn decode_env_parses_kv_lines() {
    let payload = b"TERM=xterm-256color\nLANG=en_US.UTF-8\n".to_vec();
    let pairs = decode_env(&payload);
    assert_eq!(pairs.len(), 2);
    assert_eq!(pairs[0], ("TERM".to_string(), "xterm-256color".to_string()));
    assert_eq!(pairs[1], ("LANG".to_string(), "en_US.UTF-8".to_string()));
}

#[test]
fn decode_env_skips_malformed_lines() {
    let payload = b"GOOD=value\nNO_EQUALS_HERE\nALSO_GOOD=yes\n".to_vec();
    let pairs = decode_env(&payload);
    assert_eq!(pairs.len(), 2);
}

#[test]
fn decode_env_empty_returns_empty() {
    assert!(decode_env(&[]).is_empty());
}

#[test]
fn search_match_wire_size_pinned() {
    assert_eq!(core::mem::size_of::<SearchMatchWire>(), 8);
}

#[test]
fn kinds_constants_distinct() {
    assert_ne!(kinds::INPUT_EVENT_KEY, kinds::INPUT_EVENT_MOUSE);
    assert_ne!(kinds::CURSOR_SHAPE_BLOCK, kinds::CURSOR_SHAPE_BEAM);
    assert_ne!(kinds::SELECTION_MODE_SIMPLE, kinds::SELECTION_MODE_WORD);
}

fn sample_session_config() -> SessionConfig {
    SessionConfig {
        rows: 24,
        cols: 80,
        pixel_w: 800,
        pixel_h: 600,
        command: "/bin/zsh".to_string(),
        cwd: "/tmp".to_string(),
        env: b"TERM=xterm-256color\n".to_vec(),
        scrollback_lines: 0,
    }
}

#[test]
fn echo_session_config_round_trips() {
    let c = sample_session_config();
    let out = super::echo_session_config(c);
    assert_eq!(out.rows, 24);
    assert_eq!(out.cols, 80);
    assert_eq!(out.command, "/bin/zsh");
}

#[test]
fn echo_input_event_round_trips() {
    let e = InputEvent {
        kind: kinds::INPUT_EVENT_KEY,
        key: KeyEvent {
            codepoint: 0x61,
            keycode: 0,
            text: "a".to_string(),
            action: kinds::KEY_ACTION_PRESS,
        },
        mouse: MouseEvent {
            col: 0,
            row: 0,
            button: 0,
            action: kinds::MOUSE_ACTION_PRESS,
        },
        modifiers: 0,
    };
    let out = super::echo_input_event(e);
    assert_eq!(out.kind, kinds::INPUT_EVENT_KEY);
    assert_eq!(out.key.text, "a");
}

#[test]
fn echo_frame_delta_round_trips() {
    let f = FrameDelta {
        cells: vec![],
        cursor: CursorState {
            row: 0,
            col: 0,
            shape: kinds::CURSOR_SHAPE_BLOCK,
            blink: true,
            hidden: false,
        },
        scroll_top: 0,
        scroll_total: 0,
    };
    let out = super::echo_frame_delta(f);
    assert_eq!(out.scroll_top, 0);
}

#[test]
fn echo_cell_delta_round_trips() {
    let c = CellDelta {
        row: 1,
        col: 2,
        grapheme: b"x".to_vec(),
        fg: 0,
        bg: 0,
        attrs: 0,
        width: 1,
    };
    let out = super::echo_cell_delta(c);
    assert_eq!(out.row, 1);
    assert_eq!(out.col, 2);
}

#[test]
fn hyperlink_hit_default_empty() {
    let h = HyperlinkHit {
        uri: String::new(),
        start_col: 0,
        span: 0,
    };
    assert!(h.uri.is_empty());
}

#[test]
fn ffi_greet_concatenates() {
    let out = super::ffi_greet("world");
    assert_eq!(out, "hello world, from rust");
}
