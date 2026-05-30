//! swift-bridge FFI surface — Stack A, data only.
//!
//! Implements `spec/ffi-boundary.md`. No Metal / `CAMetalLayer` / Obj-C
//! types cross this boundary — Stack A commitment, see
//! `decisions/05-renderer.md`.
//!
//! Minimal "solidterm" surface — basic terminal only (PTY + VT + grid +
//! scrollback + selection + search + OSC routing). Claude / blocks /
//! teams / hooks / auth code has been stripped from the fork.

#![allow(unsafe_code)]
#![allow(clippy::unnecessary_cast, clippy::ptr_as_ptr)]

use bytemuck::{Pod, Zeroable};

// ────────────────────── Discriminator constants ──────────────────────────

/// Stable `u8` discriminator constants for swift-bridge boundary fields
/// that carry tagged-union semantics.
pub mod kinds {
    // ── InputEvent.kind ──
    pub const INPUT_EVENT_KEY: u8 = 0;
    pub const INPUT_EVENT_MOUSE: u8 = 1;
    pub const INPUT_EVENT_FOCUS: u8 = 2;

    // ── KeyEvent.action ──
    pub const KEY_ACTION_PRESS: u8 = 0;
    pub const KEY_ACTION_RELEASE: u8 = 1;
    pub const KEY_ACTION_REPEAT: u8 = 2;

    // ── MouseEvent.action ──
    pub const MOUSE_ACTION_PRESS: u8 = 0;
    pub const MOUSE_ACTION_RELEASE: u8 = 1;
    pub const MOUSE_ACTION_MOVE: u8 = 2;

    // ── CursorState.shape ──
    pub const CURSOR_SHAPE_BLOCK: u8 = 0;
    pub const CURSOR_SHAPE_BEAM: u8 = 1;
    pub const CURSOR_SHAPE_UNDERLINE: u8 = 2;

    // ── InputEvent.modifiers (bit positions, not values) ──
    pub const MODIFIER_BIT_SHIFT: u8 = 0;
    pub const MODIFIER_BIT_CTRL: u8 = 1;
    pub const MODIFIER_BIT_ALT: u8 = 2;
    pub const MODIFIER_BIT_SUPER: u8 = 3;

    // ── Selection mode ──
    pub const SELECTION_MODE_SIMPLE: u8 = 0;
    pub const SELECTION_MODE_WORD: u8 = 1;
    pub const SELECTION_MODE_LINE: u8 = 2;
}

// ───────────────────────── Wire types ────────────────────────────────────

/// On-wire cell-delta record (32 bytes). Field order, sizes, and offsets
/// MUST match `spec/ffi-boundary.md` and the Swift-side decoder.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Pod, Zeroable)]
pub struct CellDeltaWire {
    pub row: u16,
    pub col: u16,
    pub grapheme: [u8; 16],
    pub fg: u32,
    pub bg: u32,
    pub attrs: u16,
    pub width: u8,
    pub reserved: u8,
}

const _: () = {
    assert!(core::mem::size_of::<CellDeltaWire>() == 32);
    assert!(core::mem::align_of::<CellDeltaWire>() == 4);
};

impl CellDeltaWire {
    #[must_use]
    pub fn new(
        row: u16,
        col: u16,
        grapheme: &[u8],
        fg: u32,
        bg: u32,
        attrs: u16,
        width: u8,
    ) -> Self {
        let mut g = [0u8; 16];
        let n = grapheme.len().min(16);
        g[..n].copy_from_slice(&grapheme[..n]);
        Self {
            row,
            col,
            grapheme: g,
            fg,
            bg,
            attrs,
            width,
            reserved: 0,
        }
    }
}

/// Encode a slice of `CellDeltaWire` into the byte payload Swift consumes.
#[must_use]
pub fn encode_cells(cells: &[CellDeltaWire]) -> Vec<u8> {
    bytemuck::cast_slice(cells).to_vec()
}

#[cfg(test)]
fn decode_cells(payload: &[u8]) -> Result<&[CellDeltaWire], bytemuck::PodCastError> {
    bytemuck::try_cast_slice(payload)
}

/// Decode the `KEY=VALUE\n`-joined UTF-8 byte payload into owned pairs.
/// Lines without `=` are skipped. Trailing `\n` tolerated. Empty input
/// returns an empty vec.
#[must_use]
pub fn decode_env(payload: &[u8]) -> Vec<(String, String)> {
    let Ok(s) = std::str::from_utf8(payload) else {
        return Vec::new();
    };
    s.split('\n')
        .filter(|line| !line.is_empty())
        .filter_map(|line| line.split_once('='))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

/// On-wire search-match record (8 bytes).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Pod, Zeroable)]
pub struct SearchMatchWire {
    pub line: i32,
    pub col: u16,
    pub len: u16,
}

const _: () = {
    assert!(core::mem::size_of::<SearchMatchWire>() == 8);
    assert!(core::mem::align_of::<SearchMatchWire>() == 4);
};

#[must_use]
pub fn encode_search_matches(matches: &[solidterm_engine::SearchMatch]) -> Vec<u8> {
    let mut out = Vec::with_capacity(matches.len() * core::mem::size_of::<SearchMatchWire>());
    for m in matches {
        let wire = SearchMatchWire {
            line: m.line,
            col: m.col,
            len: m.len,
        };
        out.extend_from_slice(bytemuck::bytes_of(&wire));
    }
    out
}


// ───────────────────────── swift-bridge surface ──────────────────────────

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn ffi_greet(name: &str) -> String;
    }

    // ── Leaf types ───────────────────────────────────────────────────────

    #[swift_bridge(swift_repr = "struct")]
    struct KeyEvent {
        codepoint: u32,
        keycode: u32,
        text: String,
        action: u8,
    }

    #[swift_bridge(swift_repr = "struct")]
    struct MouseEvent {
        col: u16,
        row: u16,
        button: u8,
        action: u8,
    }

    #[swift_bridge(swift_repr = "struct")]
    struct CursorState {
        row: u16,
        col: u16,
        shape: u8,
        blink: bool,
        hidden: bool,
    }

    #[swift_bridge(swift_repr = "struct")]
    struct CellDelta {
        row: u16,
        col: u16,
        grapheme: Vec<u8>,
        fg: u32,
        bg: u32,
        attrs: u16,
        width: u8,
    }

    #[swift_bridge(swift_repr = "struct")]
    struct HyperlinkHit {
        uri: String,
        start_col: u16,
        span: u16,
    }

    // ── Composite types ──────────────────────────────────────────────────

    #[swift_bridge(swift_repr = "struct")]
    struct SessionConfig {
        rows: u16,
        cols: u16,
        pixel_w: u16,
        pixel_h: u16,
        command: String,
        cwd: String,
        env: Vec<u8>,
        // Q2 configurable scrollback. 0 = use engine default
        // (`DEFAULT_SCROLLBACK_LINES`). Capped by the engine at
        // `MAX_SCROLLBACK_LINES`.
        scrollback_lines: u32,
    }

    #[swift_bridge(swift_repr = "struct")]
    struct InputEvent {
        kind: u8,
        key: KeyEvent,
        mouse: MouseEvent,
        modifiers: u8,
    }

    #[swift_bridge(swift_repr = "struct")]
    struct FrameDelta {
        cells: Vec<u8>,
        cursor: CursorState,
        scroll_top: u32,
        scroll_total: u32,
    }

    // ── Session lifecycle ────────────────────────────────────────────────

    extern "Rust" {
        type TerminalSession;

        #[swift_bridge(associated_to = TerminalSession)]
        // Fallible: `nil` on engine/PTY spawn failure (see the impl).
        fn new(config: SessionConfig) -> Option<TerminalSession>;

        fn rows(&self) -> u16;
        fn cols(&self) -> u16;

        fn send_input(self: &mut TerminalSession, event: InputEvent);
        // Non-blocking PTY write — returns bytes accepted before
        // EAGAIN. Swift's paste/drop chunker re-queues the rest.
        fn paste_chunk(self: &mut TerminalSession, bytes: &[u8]) -> u32;
        fn take_frame_delta(self: &mut TerminalSession) -> FrameDelta;
        fn take_full_frame_delta(self: &mut TerminalSession) -> FrameDelta;
        fn cursor_snapshot(self: &TerminalSession) -> CursorState;

        fn scroll_lines(self: &mut TerminalSession, delta: i32);
        fn scroll_to_bottom(self: &mut TerminalSession);
        fn scroll_to_line(self: &mut TerminalSession, line: i32);

        fn search(self: &mut TerminalSession, query: &str, regex_flag: bool) -> Vec<u8>;
        fn last_search_error(self: &TerminalSession) -> String;

        fn is_alt_screen(self: &TerminalSession) -> bool;

        fn start_selection(self: &mut TerminalSession, mode: u8, row: u16, col: u16);
        fn update_selection(self: &mut TerminalSession, row: u16, col: u16);
        fn clear_selection(self: &mut TerminalSession);
        fn selection_span(self: &TerminalSession) -> Vec<u32>;

        fn selection_text(self: &TerminalSession) -> String;
        fn bracketed_paste_enabled(self: &TerminalSession) -> bool;
        // PG1 mouse reporting — bits 0..3 = clicks / drag / motion / sgr.
        fn mouse_mode_bits(self: &TerminalSession) -> u8;

        fn drain_latest_title(self: &mut TerminalSession) -> String;
        fn drain_latest_cwd(self: &mut TerminalSession) -> String;
        fn drain_bell(self: &mut TerminalSession) -> bool;
        fn child_pid(self: &TerminalSession) -> u32;

        fn row_text(self: &TerminalSession, row: u16) -> String;
        fn cell_before_cursor(self: &TerminalSession) -> Vec<u8>;
        fn hyperlink_at(self: &TerminalSession, row: u16, col: u16) -> HyperlinkHit;

        fn resize(self: &mut TerminalSession, rows: u16, cols: u16) -> bool;
    }

    extern "Rust" {
        fn echo_session_config(c: SessionConfig) -> SessionConfig;
        fn echo_input_event(e: InputEvent) -> InputEvent;
        fn echo_frame_delta(f: FrameDelta) -> FrameDelta;
        fn echo_cell_delta(c: CellDelta) -> CellDelta;
    }
}

// ───────────────────────── TerminalSession wrapper ─────────────────────

pub struct TerminalSession {
    inner: solidterm_engine::TerminalEngine,
    pending_title: Option<String>,
    pending_cwd: Option<String>,
    /// I1 bell: latched on every `EngineEvent::Bell` seen by
    /// `drain_pending_events`; cleared by `drain_bell()`. We only need
    /// to know "did at least one bell happen since the last drain" —
    /// rapid-fire `\a\a\a` collapses to one visible flash, matching
    /// what iTerm2 / Terminal.app do.
    pending_bell: bool,
    last_search_error: Option<String>,
}

impl TerminalSession {
    /// Construct a session, spawning the PTY and terminal engine.
    ///
    /// `TerminalEngine::new` is genuinely fallible (openpty / FD
    /// exhaustion / bad geometry). Rather than panic — which would
    /// unwind across the swift-bridge `extern "C"` boundary into Swift
    /// (unsupported, and an abort under `panic = "abort"`) — a spawn
    /// failure is surfaced to Swift as a `nil` `TerminalSession?`. The
    /// Swift host already stores `session` as optional and guards every
    /// use, so a failed spawn degrades gracefully instead of crashing.
    /// `panic = "abort"` (workspace Cargo.toml) remains as a backstop
    /// for any *other* unexpected panic reaching the FFI surface.
    #[must_use]
    pub fn new(config: ffi::SessionConfig) -> Option<TerminalSession> {
        let engine_config = config_to_engine_config(config);
        let inner = match solidterm_engine::TerminalEngine::new(engine_config) {
            Ok(inner) => inner,
            Err(err) => {
                tracing::error!(
                    ?err,
                    "TerminalSession::new: engine construction failed \
                     (geometry / PTY spawn); returning nil to Swift",
                );
                return None;
            }
        };
        Some(TerminalSession {
            inner,
            pending_title: None,
            pending_cwd: None,
            pending_bell: false,
            last_search_error: None,
        })
    }

    fn drain_pending_events(&mut self) {
        for ev in self.inner.drain_events() {
            match ev {
                solidterm_engine::events::EngineEvent::TitleChanged(s) => {
                    self.pending_title = Some(s);
                }
                solidterm_engine::events::EngineEvent::CwdChanged(s) => {
                    self.pending_cwd = Some(s);
                }
                solidterm_engine::events::EngineEvent::Bell => {
                    self.pending_bell = true;
                }
                _ => {}
            }
        }
    }

    #[must_use]
    #[allow(clippy::cast_possible_truncation)]
    pub fn rows(&self) -> u16 {
        self.inner.screen_lines() as u16
    }

    #[must_use]
    #[allow(clippy::cast_possible_truncation)]
    pub fn cols(&self) -> u16 {
        self.inner.columns() as u16
    }

    /// Non-blocking PTY write. Returns the number of bytes the
    /// kernel accepted before EAGAIN. Caller retries the remainder
    /// next runloop tick.
    pub fn paste_chunk(&mut self, bytes: &[u8]) -> u32 {
        match self.inner.feed_input_nonblocking(bytes) {
            Ok(n) => u32::try_from(n).unwrap_or(0),
            Err(err) => {
                tracing::warn!(?err, "paste_chunk: nonblocking write failed");
                0
            }
        }
    }

    #[allow(clippy::needless_pass_by_value)]
    pub fn send_input(&mut self, event: ffi::InputEvent) {
        match event.kind {
            kinds::INPUT_EVENT_KEY => {
                if let Err(err) = self.inner.feed_input(event.key.text.as_bytes()) {
                    tracing::warn!(?err, "send_input: PTY write failed; child may have exited");
                }
            }
            kinds::INPUT_EVENT_MOUSE => {
                tracing::debug!(kind = event.kind, "send_input: mouse event, no-op stub");
            }
            kinds::INPUT_EVENT_FOCUS => {
                tracing::debug!(kind = event.kind, "send_input: focus event, no-op stub");
            }
            other => {
                tracing::warn!(kind = other, "send_input: unknown InputEvent.kind, ignored");
            }
        }
    }

    pub fn scroll_lines(&mut self, delta: i32) {
        self.inner.scroll_lines(delta);
    }

    pub fn scroll_to_bottom(&mut self) {
        self.inner.scroll_to_bottom();
    }

    pub fn scroll_to_line(&mut self, line: i32) {
        self.inner.scroll_to_line(line);
    }

    #[must_use]
    pub fn search(&mut self, query: &str, regex_flag: bool) -> Vec<u8> {
        match self.inner.search(query, regex_flag) {
            Ok(matches) => {
                self.last_search_error = None;
                encode_search_matches(&matches)
            }
            Err(e) => {
                self.last_search_error = Some(e.to_string());
                Vec::new()
            }
        }
    }

    #[must_use]
    pub fn last_search_error(&self) -> String {
        self.last_search_error.clone().unwrap_or_default()
    }

    #[must_use]
    pub fn is_alt_screen(&self) -> bool {
        self.inner.is_alt_screen()
    }

    pub fn start_selection(&mut self, mode: u8, row: u16, col: u16) {
        let engine_mode = match mode {
            kinds::SELECTION_MODE_SIMPLE => solidterm_engine::SelectionMode::Simple,
            kinds::SELECTION_MODE_WORD => solidterm_engine::SelectionMode::Word,
            kinds::SELECTION_MODE_LINE => solidterm_engine::SelectionMode::Line,
            other => {
                tracing::warn!(
                    mode = other,
                    "start_selection: unknown SELECTION_MODE_*, defaulting to Simple"
                );
                solidterm_engine::SelectionMode::Simple
            }
        };
        self.inner.start_selection(engine_mode, row, col);
    }

    pub fn update_selection(&mut self, row: u16, col: u16) {
        self.inner.update_selection(row, col);
    }

    pub fn clear_selection(&mut self) {
        self.inner.clear_selection();
    }

    #[must_use]
    pub fn selection_span(&self) -> Vec<u32> {
        let Some(span) = self.inner.selection_span() else {
            return Vec::new();
        };
        vec![
            u32::from(span.start_row),
            u32::from(span.start_col),
            u32::from(span.end_row),
            u32::from(span.end_col),
            u32::from(span.is_block),
        ]
    }

    #[must_use]
    pub fn selection_text(&self) -> String {
        self.inner.selection_text().unwrap_or_default()
    }

    #[must_use]
    pub fn bracketed_paste_enabled(&self) -> bool {
        self.inner.bracketed_paste_enabled()
    }

    /// PG1: bits 0..3 = clicks(1) / drag(2) / motion(4) / sgr(8).
    pub fn mouse_mode_bits(&self) -> u8 {
        self.inner.mouse_mode_bits()
    }

    pub fn drain_latest_title(&mut self) -> String {
        self.drain_pending_events();
        self.pending_title.take().unwrap_or_default()
    }

    pub fn drain_latest_cwd(&mut self) -> String {
        self.drain_pending_events();
        self.pending_cwd.take().unwrap_or_default()
    }

    /// I1: returns true once per bell event observed since the last
    /// call. Consumed once-per-frame by the Swift renderer so a
    /// single flash overlay fires per audible/visual bell.
    pub fn drain_bell(&mut self) -> bool {
        self.drain_pending_events();
        let bell = self.pending_bell;
        self.pending_bell = false;
        bell
    }

    /// Shell child PID. Used by the Swift host to query the child's
    /// live cwd via `proc_pidinfo` when OSC 7 isn't wired up — this is
    /// the fallback path for `⌘N` / `⌘T` cwd inheritance and matches
    /// what Terminal.app does when shell integration is absent.
    #[must_use]
    pub fn child_pid(&self) -> u32 {
        self.inner.child_pid()
    }

    #[must_use]
    pub fn cell_before_cursor(&self) -> Vec<u8> {
        let cursor = self.inner.cursor();
        if cursor.col == 0 {
            return Vec::new();
        }
        let target_col = cursor.col - 1;
        let cells = self
            .inner
            .viewport_cells(cursor.row..cursor.row.saturating_add(1));
        for cell in &cells {
            if cell.col == target_col {
                let len = cell.grapheme.iter().position(|&b| b == 0).unwrap_or(16);
                return cell.grapheme[..len].to_vec();
            }
        }
        Vec::new()
    }

    #[must_use]
    pub fn row_text(&self, row: u16) -> String {
        let cells = self.inner.viewport_cells(row..row.saturating_add(1));
        let mut out = String::with_capacity(cells.len());
        for cell in &cells {
            let len = cell.grapheme.iter().position(|&b| b == 0).unwrap_or(16);
            if let Ok(s) = std::str::from_utf8(&cell.grapheme[..len]) {
                out.push_str(s);
            }
        }
        out.trim_end().to_string()
    }

    #[must_use]
    pub fn hyperlink_at(&self, row: u16, col: u16) -> ffi::HyperlinkHit {
        let Some(uri) = self.inner.hyperlink_at(row, col) else {
            return ffi::HyperlinkHit {
                uri: String::new(),
                start_col: 0,
                span: 0,
            };
        };
        let (start_col, span) = self.inner.hyperlink_span(row, col).unwrap_or((col, 1));
        ffi::HyperlinkHit {
            uri,
            start_col,
            span,
        }
    }

    pub fn resize(&mut self, rows: u16, cols: u16) -> bool {
        self.inner.resize(rows, cols).is_ok()
    }

    pub fn take_frame_delta(&mut self) -> ffi::FrameDelta {
        if let Err(err) = self.inner.poll_output() {
            tracing::warn!(?err, "take_frame_delta: poll_output failed");
        }
        let cursor = cursor_to_ffi(self.inner.cursor());
        let damage = self.inner.take_damage();
        let cells = encode_damaged_rows(&self.inner, &damage);
        ffi::FrameDelta {
            cells,
            cursor,
            scroll_top: self.inner.scroll_top(),
            scroll_total: self.inner.scroll_total(),
        }
    }

    pub fn take_full_frame_delta(&mut self) -> ffi::FrameDelta {
        if let Err(err) = self.inner.poll_output() {
            tracing::warn!(?err, "take_full_frame_delta: poll_output failed");
        }
        let cursor = cursor_to_ffi(self.inner.cursor());
        let cells = encode_damaged_rows(&self.inner, &solidterm_engine::DirtyRows::Full);
        ffi::FrameDelta {
            cells,
            cursor,
            scroll_top: self.inner.scroll_top(),
            scroll_total: self.inner.scroll_total(),
        }
    }

    pub fn cursor_snapshot(&self) -> ffi::CursorState {
        cursor_to_ffi(self.inner.cursor())
    }
}

fn cell_view_to_wire(view: &solidterm_engine::CellView) -> CellDeltaWire {
    CellDeltaWire {
        row: view.row,
        col: view.col,
        grapheme: view.grapheme,
        fg: view.fg,
        bg: view.bg,
        attrs: view.attrs,
        width: view.width,
        reserved: 0,
    }
}

fn encode_damaged_rows(
    engine: &solidterm_engine::TerminalEngine,
    damage: &solidterm_engine::DirtyRows,
) -> Vec<u8> {
    use solidterm_engine::DirtyRows;
    match damage {
        DirtyRows::Full => {
            #[allow(clippy::cast_possible_truncation)]
            let rows = engine.screen_lines() as u16;
            let views = engine.viewport_cells(0..rows);
            let wire: Vec<CellDeltaWire> = views.iter().map(cell_view_to_wire).collect();
            encode_cells(&wire)
        }
        DirtyRows::Partial(rows) => {
            if rows.is_empty() {
                return Vec::new();
            }
            let mut wire: Vec<CellDeltaWire> = Vec::new();
            for &row in rows {
                let views = engine.viewport_cells(row..row.saturating_add(1));
                wire.extend(views.iter().map(cell_view_to_wire));
            }
            encode_cells(&wire)
        }
    }
}

fn cursor_to_ffi(c: solidterm_engine::CursorReadback) -> ffi::CursorState {
    use solidterm_engine::CursorShape;
    let (shape, hidden) = match c.shape {
        CursorShape::Block => (kinds::CURSOR_SHAPE_BLOCK, !c.visible),
        CursorShape::Beam => (kinds::CURSOR_SHAPE_BEAM, !c.visible),
        CursorShape::Underline => (kinds::CURSOR_SHAPE_UNDERLINE, !c.visible),
        CursorShape::Hidden => (kinds::CURSOR_SHAPE_BLOCK, true),
    };
    ffi::CursorState {
        row: c.row,
        col: c.col,
        shape,
        blink: c.blink,
        hidden,
    }
}

#[allow(clippy::needless_pass_by_value)]
fn config_to_engine_config(config: ffi::SessionConfig) -> solidterm_engine::EngineConfig {
    let env: Vec<(String, String)> = decode_env(&config.env);
    let command: Vec<String> = if config.command.is_empty() {
        vec!["/bin/zsh".to_string()]
    } else {
        config
            .command
            .split_whitespace()
            .map(str::to_string)
            .collect()
    };
    let cwd = if config.cwd.is_empty() {
        std::path::PathBuf::from("/")
    } else {
        std::path::PathBuf::from(&config.cwd)
    };
    let scrollback = if config.scrollback_lines == 0 {
        solidterm_engine::DEFAULT_SCROLLBACK_LINES
    } else {
        config.scrollback_lines
    };
    solidterm_engine::EngineConfig {
        rows: config.rows,
        cols: config.cols,
        env,
        command,
        cwd,
        scrollback_lines: scrollback,
    }
}

#[must_use]
pub fn ffi_greet(name: &str) -> String {
    format!("hello {name}, from rust")
}

#[must_use]
pub fn echo_session_config(c: ffi::SessionConfig) -> ffi::SessionConfig {
    c
}

#[must_use]
pub fn echo_input_event(e: ffi::InputEvent) -> ffi::InputEvent {
    e
}

#[must_use]
pub fn echo_frame_delta(f: ffi::FrameDelta) -> ffi::FrameDelta {
    f
}

#[must_use]
pub fn echo_cell_delta(c: ffi::CellDelta) -> ffi::CellDelta {
    c
}

#[cfg(test)]
mod tests {
    use super::ffi::{
        CellDelta, CursorState, FrameDelta, HyperlinkHit, InputEvent, KeyEvent, MouseEvent,
        SessionConfig,
    };
    use super::{decode_cells, decode_env, encode_cells, kinds, CellDeltaWire, SearchMatchWire};

    fn sample_cell(row: u16, col: u16, ch: u8) -> CellDeltaWire {
        let mut g = [0u8; 16];
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
        assert_eq!(core::mem::size_of::<CellDeltaWire>(), 32);
        assert_eq!(core::mem::align_of::<CellDeltaWire>(), 4);
    }

    #[test]
    fn encode_then_decode_cells_round_trip() {
        let cells = vec![sample_cell(0, 0, b'a'), sample_cell(0, 1, b'b')];
        let payload = encode_cells(&cells);
        assert_eq!(payload.len(), cells.len() * 32);
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
}
