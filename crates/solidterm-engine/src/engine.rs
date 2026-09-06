// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

//! M1 tasks 1.1 through 1.8 —
//! `TerminalEngine` skeleton, `EngineConfig` validation, PTY spawn via
//! `alacritty_terminal::tty::new`, the stable `feed_input` /
//! `poll_output` public API, `resize`, `take_damage`,
//! `viewport_cells`, and `drain_events`. Wraps ~2,000 LOC of
//! production-hardened terminal machinery (alacritty's `Term`,
//! `Pty`, and `vte::ansi::Processor`) behind our own stable interface.
//!
//! Phase 1 sliver after #55: the engine owns `Term<EventProxy>` +
//! `Pty` + a [`PtyReader`] thread + a `vte::ansi::Processor` + a
//! `crossbeam_channel::Receiver<EngineEvent>` for the merged
//! Term-side and PTY-child-lifecycle event stream. M1 Week 1 engine
//! API is feature-complete; FFI integration arrives in the next
//! major dispatch.

use std::collections::HashMap;
use std::io::{self, Write};
use std::ops::Range;
use std::os::fd::{AsFd, AsRawFd};

use alacritty_terminal::event::{OnResize, WindowSize};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::term::{Config as AlacrittyTermConfig, Term, TermDamage};
use alacritty_terminal::tty::{
    self, ChildEvent, EventedPty, EventedReadWrite, Options as TtyOptions, Pty, Shell,
};
use alacritty_terminal::vte::{self, ansi};

/// Kitty keyboard protocol mode flags (task 2.9). Re-export of vte's
/// `KeyboardModes` bitflags so callers don't need to import the vte
/// crate transitively. Each bit corresponds to a Kitty mode per
/// <https://sw.kovidgoyal.net/kitty/keyboard-protocol>:
/// `DISAMBIGUATE_ESC_CODES` (bit 0), `REPORT_EVENT_TYPES` (bit 1),
/// `REPORT_ALTERNATE_KEYS` (bit 2), `REPORT_ALL_KEYS_AS_ESC` (bit 3),
/// `REPORT_ASSOCIATED_TEXT` (bit 4).
///
/// Read via [`TerminalEngine::kitty_keyboard_flags`]. Mutation is
/// shell-driven only — there is no setter on the engine; flags flip
/// when the shell emits `CSI > N u` / `CSI < N u` / `CSI = N u`.
pub use alacritty_terminal::vte::ansi::KeyboardModes as KittyKeyboardFlags;
use crossbeam_channel::{unbounded, Receiver};

use std::collections::VecDeque;
use std::sync::Arc;

use parking_lot::Mutex;

use crate::cells::CellView;
use crate::config::{EngineConfig, EngineConfigError};
use crate::cursor::{CursorReadback, CursorShape};
use crate::damage::DirtyRows;
use crate::events::{EngineEvent, EventProxy, ThemeColors};
use crate::osc::OscPerform;
use crate::pty::PtyReader;

/// Errors that can surface from the engine.
///
/// `Config(_)` is a one-shot construction-time failure (#43); `Spawn(_)`
/// covers PTY fork/exec failures at construction (#44); `Io(_)` covers
/// post-construction stream failures from `feed_input` (#51, master FD
/// revoked etc.). Keeping `Spawn` and `Io` separate so callers can
/// distinguish "couldn't start the shell" from "shell died mid-stream"
/// without inspecting an `io::ErrorKind`.
///
/// Only `Spawn` carries `#[from]` for `io::Error`; `Io` is `#[error(
/// transparent)]` without `#[from]` so the two variants don't conflict.
/// Conversions go through explicit `EngineError::Io(...)` at the call
/// site (currently just `feed_input`).
#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error(transparent)]
    Config(#[from] EngineConfigError),

    #[error("PTY spawn failed: {0}")]
    Spawn(#[from] io::Error),

    #[error(transparent)]
    Io(io::Error),
}

// ── 4.5 selection types ──────────────────────────────────────────────
//
// Public types for the engine selection API. Hoisted to module scope
// so `solidterm-ffi`'s wire shim can re-export them through `lib.rs`
// without crossing alacritty's `SelectionType` directly — same
// precedent as `CursorShape` in `cursor.rs`.

/// Selection mode. Mirrors alacritty's `SelectionType` narrowed to
/// the variants the 4.5 input handler emits: drag (mouse-down +
/// drag), word (double-click → semantic boundary), and line (triple-
/// click → entire logical line). Block-mode (alt-drag) is deferred
/// pending matching input plumb in a follow-up.
///
/// Mapping pinned at the FFI seam in `solidterm-ffi` via the
/// `SELECTION_MODE_*` u8 constants.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum SelectionMode {
    /// Drag selection. Cell-precise; alacritty's `SelectionType::Simple`.
    Simple,
    /// Word selection on double-click. Expands to nearest semantic
    /// boundary on each `update`. alacritty's `SelectionType::Semantic`.
    Word,
    /// Line selection on triple-click. Always covers entire logical
    /// lines. alacritty's `SelectionType::Lines`.
    Line,
}

/// Snapshot of the current selection in **viewport-relative**
/// coordinates. Produced by [`TerminalEngine::selection_span`] for
/// the renderer overlay encode.
///
/// Coordinates: row 0 is the top of the visible viewport;
/// `start_row ≤ end_row`. Both columns are inclusive on each row
/// covered. For multi-row stream selections the renderer interprets
/// the span as:
///
///   - First row: `[start_col, columns)` highlighted.
///   - Middle rows: `[0, columns)` (full width).
///   - Last row: `[0, end_col]`.
///
/// For block selections (`is_block == true`) every row covers
/// `[start_col, end_col]`. As of 4.5 only stream selections are
/// produced (block-mode input is deferred), but the field is plumbed
/// through so the renderer is shape-ready.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct SelectionSpan {
    pub start_row: u16,
    pub start_col: u16,
    pub end_row: u16,
    pub end_col: u16,
    pub is_block: bool,
}

/// `alacritty_terminal`'s `Term::new` is generic over a `Dimensions`
/// adapter that surfaces `screen_lines()` / `columns()` as `usize`.
/// Wrap our `(rows, cols)` u16 pair so callers don't need to know
/// alacritty's internal trait shape.
struct EngineDimensions {
    rows: usize,
    cols: usize,
}

impl Dimensions for EngineDimensions {
    fn total_lines(&self) -> usize {
        // Without scrollback knowledge here, `total_lines` matches the
        // visible viewport. `Term::new` reads `screen_lines()` /
        // `columns()` for grid construction; `total_lines` is only
        // consulted by callers we don't drive in this dispatch.
        self.rows
    }

    fn screen_lines(&self) -> usize {
        self.rows
    }

    fn columns(&self) -> usize {
        self.cols
    }
}

/// The engine wrapper Swift's `TerminalSession` will eventually own.
/// Owns alacritty's `Term`, the spawned `Pty`, and a [`PtyReader`]
/// thread that pumps output bytes into a channel.
///
/// `Debug` is hand-written because `Term`/`Pty`/`PtyReader` are not
/// `Debug`-renderable cleanly — reaching into alacritty's internal
/// grid + child-process state would be noisy and unstable. The summary
/// `screen_lines × columns × child_pid` shape is what callers actually
/// want when printing engine state.
///
/// Field-declaration order matters for Drop: `term` → `parser` →
/// `osc_parser` → `osc_perform` → `pty` → `reader` → `events_tx` →
/// `events_rx`. Rust drops fields in declaration order, so `pty`
/// (which forces EOF on the master FD by closing the slave via
/// SIGHUP) drops before `reader` (which waits for the reader thread
/// to exit). Reordering these would deadlock the reader thread on
/// `read()` against an FD that's still alive in the engine.
///
/// `term` drops first so the `EventProxy` (which holds a sender
/// clone) is released before the `events_tx` we keep for our own
/// child-exit emissions. `events_tx` drops before `events_rx` so the
/// channel cleanly disconnects on teardown. None of those have a
/// Drop-ordering deadlock path because the channel is unbounded —
/// `EventProxy::send_event` never blocks.
///
/// `osc_parser` and `osc_perform` (the §2.1 sibling OSC pre-scanner)
/// hold no OS resources or threads — `vte::Parser` is a stack-state
/// FSM and `OscPerform` owns only a `Sender<EngineEvent>` clone — so
/// their drop order is immaterial. They sit next to `parser` for
/// locality.
pub struct TerminalEngine {
    /// alacritty's grid + cursor + selection + alt-screen + scrollback.
    /// `EventProxy` (from #55) translates alacritty's `Event` enum
    /// into `EngineEvent` and pushes onto `events_rx`'s peer.
    term: Term<EventProxy>,

    /// `vte::ansi::Processor` (re-exported via `alacritty_terminal::vte`)
    /// is the VT/CSI/OSC state machine that turns raw PTY output bytes
    /// into structured `Handler` callbacks. `Term<EventProxy>`
    /// implements `vte::ansi::Handler`, so a single `parser.advance(
    /// &mut term, &bytes)` call drives all grid mutation per the
    /// canonical alacritty pattern (see `event_loop.rs:154` upstream).
    parser: ansi::Processor,

    /// Sibling lower-level `vte::Parser` driven against [`OscPerform`]
    /// (the §2.1 pre-scanner). Runs in parallel with `parser` on every
    /// chunk in [`Self::poll_output`] — sees the raw byte stream and
    /// surfaces OSC sequences that don't bubble up through alacritty's
    /// `vte::ansi::Handler` (notably OSC 133 / 7 / 2026 etc.). See
    /// `crate::osc` module docs for the architectural rationale.
    ///
    /// Per-byte cost: ~50 ns (vte FSM is a tiny table-driven state
    /// machine). At 1 MB/s sustained PTY output that's 0.05 ms/MB
    /// extra — well under any frame budget.
    osc_parser: vte::Parser,

    /// `vte::Perform` impl that observes the OSC sideband. For 2.1 it
    /// holds an extension point + a tracing breadcrumb; specific OSC
    /// arms (133 / 7 / ...) land in tasks 2.2-2.7. Holds a `Sender<
    /// EngineEvent>` cloned from the engine's merged event channel.
    osc_perform: OscPerform,

    /// alacritty's `Pty` — owns the master FD (for read+write), the
    /// child `std::process::Child`, and the SIGCHLD signal handler.
    /// `Pty::Drop` sends SIGHUP to the child and then **blocks** in
    /// `child.wait()` — production teardown therefore goes through
    /// [`TerminalEngine::shutdown_detached`], which moves this drop
    /// onto a detached thread with a SIGKILL escalation. Inline drop
    /// remains for tests only.
    pty: Pty,

    /// Background reader thread that pumps PTY output bytes into a
    /// channel. Drained by `poll_output` and feeds the `parser` field
    /// above.
    reader: PtyReader,

    /// Engine-owned `EngineEvent` sender used by `poll_output` to
    /// emit `ChildExited` when `Pty::next_child_event` reports
    /// `ChildEvent::Exited`. The `EventProxy` held inside `term`
    /// has its own clone of this sender for Term-side events
    /// (Bell / Title / etc.). Both produce into the same receiver.
    events_tx: crossbeam_channel::Sender<EngineEvent>,

    /// Receiver end of the merged event stream. Drained via
    /// [`Self::drain_events`] by external consumers (tests today,
    /// Swift-side `take_frame_delta` at the next FFI atomic).
    events_rx: Receiver<EngineEvent>,

    /// Receiver for OSC 10/11/12 query replies (#71, task 2.5). The
    /// matching `Sender<String>` lives in the [`EventProxy`] inside
    /// `term`; on each `dynamic_color_sequence` callback the proxy
    /// looks up the queried index against the hardcoded Zenzai Dark
    /// palette, runs alacritty's reply formatter, and pushes the
    /// formatted bytes here. [`Self::poll_output`] drains this queue
    /// **after** `parser.advance` returns and writes each reply to the
    /// PTY master FD via `pty.writer()`. Decoupling the channel from
    /// `events_rx` keeps consumer-facing telemetry separate from the
    /// internal write-back path and avoids a re-entrant `pty.writer()`
    /// borrow during parse (the `EventProxy` runs inside the
    /// `&mut self.term` borrow chain inside `parser.advance`).
    pty_responses_rx: Receiver<String>,

    /// Tracks `TermMode::ALT_SCREEN` across `poll_output` calls.
    /// Initial value `false` matches `Term::new`'s primary-screen
    /// default.
    last_alt_screen: bool,

    /// Held event buffer. `poll_output` drains `events_rx` and
    /// re-queues events here for [`Self::drain_events`] to surface to
    /// consumers. The `parking_lot::Mutex` is required because
    /// `drain_events` is `&self` (FFI calls it through an immutable
    /// accessor in the same tick as `poll_output`) — interior
    /// mutability lets us re-emit without forcing every consumer onto
    /// `&mut self`.
    held_events: Mutex<VecDeque<EngineEvent>>,

    /// Absolute anchor point of the in-progress mouse selection, cached
    /// at [`Self::start_selection`]. alacritty's `Selection` keeps the
    /// anchor in a private `region` field with no getter, so we mirror
    /// it here. [`Self::update_selection`] needs it to pick the anchor
    /// *and* drag-end cell sides by drag direction — a right-to-left (or
    /// upward) drag has to flip both sides so the cell under the cursor
    /// and the anchor cell both stay inside the range (see that method).
    /// `None` whenever no selection is active.
    ///
    /// **Staleness caveat.** The point is in alacritty's absolute
    /// `Line` space, which shifts under us whenever the grid rotates
    /// (`Term::scroll_up` on new output). alacritty rotates its own
    /// `Term::selection` to compensate; this shadow copy gets no such
    /// treatment, so it is only a *fallback* — [`Self::update_selection`]
    /// prefers the anchor re-derived from the live selection via
    /// [`Self::selection_anchor_is_start`].
    selection_anchor: Option<Point>,

    /// Which end of the live selection's ordered range is the drag
    /// anchor: `Some(true)` when the anchor is the earlier endpoint in
    /// reading order (the user is dragging forward/down), `Some(false)`
    /// when it is the later one (dragging backward/up). `None` until
    /// the first [`Self::update_selection`] gives the drag a direction.
    ///
    /// Lets [`Self::update_selection`] recover the anchor cell from
    /// `Selection::to_range` — which reads the *rotated* selection —
    /// instead of the stale absolute point cached above.
    selection_anchor_is_start: Option<bool>,

    /// Live fg/bg/cursor for OSC 10/11/12 color-query replies, shared
    /// with the `EventProxy` inside `term`. Updated by the Swift renderer
    /// via [`Self::set_theme_colors`] so a child querying the background
    /// (e.g. Claude Code's `auto` light/dark detection, or vim/delta)
    /// gets the terminal's actual theme, not a hardcoded palette.
    theme_colors: Arc<ThemeColors>,
}

// Manual Debug: omits internal fields deliberately — see the struct
// doc comment for why they don't render usefully.
#[allow(clippy::missing_fields_in_debug)]
impl std::fmt::Debug for TerminalEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TerminalEngine")
            .field("screen_lines", &self.screen_lines())
            .field("columns", &self.columns())
            .field("child_pid", &self.pty.child().id())
            .finish()
    }
}

impl TerminalEngine {
    /// Build a new engine from a validated [`EngineConfig`] and spawn
    /// the configured shell.
    ///
    /// Validation runs first; on `EngineConfigError` no `Term` is
    /// constructed. On success the grid is sized to
    /// `config.rows × config.cols` with `scrollback_lines` of history,
    /// then `alacritty_terminal::tty::new` opens a pseudoterminal and
    /// fork/execs `config.command[0]` with `config.command[1..]` as
    /// argv, in `config.cwd`, with `config.env` extending the inherited
    /// environment.
    ///
    /// Spawn-on-construct (no `.spawn()` split): every method that
    /// will land on the engine surface needs the PTY, so a partial
    /// "constructed but not spawned" state would force `Option`-gating
    /// throughout.
    ///
    /// `config` is by-value by design; `command` / `env` / `cwd` are
    /// moved into the `tty::Options` rather than cloned.
    #[allow(clippy::needless_pass_by_value)]
    pub fn new(config: EngineConfig) -> Result<Self, EngineError> {
        config.validate()?;

        // Alacritty's `Config` is `Default`-derived; we override
        // `scrolling_history` from our config and force-enable
        // `kitty_keyboard` (task 2.9). The rest (cursor style,
        // semantic-escape chars, osc52) keep the alacritty defaults
        // today and surface as engine config in later dispatches.
        //
        // `kitty_keyboard: true` is load-bearing for task 2.9: alacritty
        // gates `set_keyboard_mode` / `push_keyboard_mode` /
        // `pop_keyboard_modes` / `report_keyboard_mode` on this flag
        // (`alacritty_terminal-0.26.0/src/term/mod.rs:1276,1289,1309,1324`),
        // returning early when false. With it true, all four CSI `u`
        // forms (`CSI > N u` push, `CSI < N u` pop, `CSI = N u` set,
        // `CSI ? u` query) flow through and the query reply
        // `CSI ? bits u` is queued via `Event::PtyWrite` → EventProxy
        // → `pty_responses` → `poll_output` → PTY master FD. M2+'s
        // Swift-side input encoding will use
        // `TerminalEngine::kitty_keyboard_flags` to decide how to
        // format keystrokes; engine surface today is observe-only.
        let alacritty_config = AlacrittyTermConfig {
            scrolling_history: config.scrollback_lines as usize,
            kitty_keyboard: true,
            ..AlacrittyTermConfig::default()
        };

        let dimensions = EngineDimensions {
            rows: config.rows as usize,
            cols: config.cols as usize,
        };

        // One unbounded channel; both EventProxy (Term-side events)
        // and the engine's poll_output ChildExit-poll path produce
        // into it. drain_events drains.
        let (events_tx, events_rx) = unbounded::<EngineEvent>();
        // Separate channel for OSC 10/11/12 query replies. The proxy
        // produces formatted reply strings here; poll_output drains
        // and writes them back to the PTY master FD. Kept apart from
        // events_rx because (a) replies are an internal write-back
        // pattern, not consumer-facing telemetry, and (b) consumers
        // shouldn't be able to silently swallow PTY responses by
        // forgetting to drain a single channel.
        let (pty_responses_tx, pty_responses_rx) = unbounded::<String>();
        // Two producers on `pty_responses_tx` today: `EventProxy`
        // (alacritty's color-query / PtyWrite emissions) and
        // `OscPerform` (task 2.9 — `CSI ? 4 m` modifyOtherKeys query
        // reply). Both pre-format the reply bytes; the unbounded
        // channel and the single consumer in `poll_output` keep
        // serialisation order identical to dispatch order.
        // Shared theme-color slot: one clone lives in `EventProxy` (moved
        // into `term`) to answer OSC color queries, the other on the
        // engine so `set_theme_colors` can update it after construction.
        let theme_colors = Arc::new(ThemeColors::new_default());
        let event_proxy = EventProxy::with_theme_colors(
            events_tx.clone(),
            pty_responses_tx.clone(),
            Arc::clone(&theme_colors),
        );

        let term = Term::new(alacritty_config, &dimensions, event_proxy);

        // Translate `EngineConfig` → `tty::Options`. alacritty's `env`
        // is `HashMap<String, String>` — order-preservation in our
        // `Vec<(String, String)>` doesn't matter for env (PATH-style
        // overrides are already resolved at config-build time).
        // command[0] is the program; command[1..] are argv.
        let (program, args) = config
            .command
            .split_first()
            .map(|(head, tail)| (head.clone(), tail.to_vec()))
            .expect("validate() guarantees command is non-empty");

        let env_map: HashMap<String, String> = config.env.into_iter().collect();

        let tty_options = TtyOptions {
            shell: Some(Shell::new(program, args)),
            working_directory: Some(config.cwd),
            drain_on_exit: false,
            env: env_map,
        };

        // alacritty's `WindowSize` carries pixel dimensions used by
        // resize signaling; cell width/height are renderer-side
        // concerns we don't have access to here. Pass the cell counts
        // and zero pixel dimensions — the cell counts (`num_lines` /
        // `num_cols`) are what `openpty`'s ioctl actually consumes.
        let window_size = WindowSize {
            num_lines: config.rows,
            num_cols: config.cols,
            cell_width: 0,
            cell_height: 0,
        };

        // window_id is alacritty's per-window correlation tag; we use
        // 0 since we have one PTY per engine and no multi-window
        // routing at this layer.
        let mut pty = tty::new(&tty_options, window_size, 0)?;

        // Clone the master FD for the reader thread. The reader owns
        // its own `File` view; the engine keeps the original for
        // writes. When `pty` drops, alacritty closes the master, the
        // reader's clone sees EOF, and the reader thread exits.
        //
        // `try_clone` against `EventedReadWrite::reader()`'s `File`.
        let reader_file = pty.reader().try_clone().map_err(EngineError::Spawn)?;

        let reader = PtyReader::spawn(reader_file).map_err(EngineError::Spawn)?;

        tracing::debug!(
            rows = config.rows,
            cols = config.cols,
            scrollback_lines = config.scrollback_lines,
            child_pid = pty.child().id(),
            "TerminalEngine::new — PTY spawned",
        );

        Ok(Self {
            term,
            parser: ansi::Processor::new(),
            osc_parser: vte::Parser::new(),
            osc_perform: OscPerform::new(events_tx.clone(), pty_responses_tx),
            pty,
            reader,
            events_tx,
            events_rx,
            pty_responses_rx,
            last_alt_screen: false,
            held_events: Mutex::new(VecDeque::new()),
            selection_anchor: None,
            selection_anchor_is_start: None,
            theme_colors,
        })
    }

    /// Update the fg/bg/cursor used to answer OSC 10/11/12 color queries
    /// so they reflect the renderer's live theme instead of a hardcoded
    /// palette. Colors are packed sRGB `0x00RRGGBB` (alpha ignored). The
    /// Swift host calls this whenever the resolved theme changes; a child
    /// that subsequently queries (e.g. Claude Code's `auto` light/dark
    /// detection, vim's `background` probe) gets the correct answer.
    /// `&self` — the slot is atomically updated and shared with the
    /// `EventProxy`, so no `&mut` is needed.
    pub fn set_theme_colors(&self, fg: u32, bg: u32, cursor: u32) {
        self.theme_colors.set(fg, bg, cursor);
    }

    /// Visible viewport row count (alacritty's `screen_lines`). Used by
    /// the engine's own consumers and by tests; not on the FFI surface.
    #[must_use]
    pub fn screen_lines(&self) -> usize {
        self.term.screen_lines()
    }

    /// Visible viewport column count. See [`Self::screen_lines`].
    #[must_use]
    pub fn columns(&self) -> usize {
        self.term.columns()
    }

    /// Write `bytes` to the PTY master, forwarding them to the child
    /// process's stdin. This is the stable input path: Swift's
    /// `InputEvent` encoder (the Kitty / `modifyOtherKeys` / legacy CSI
    /// dispatcher) produces a byte stream that lands here.
    ///
    /// `write_all` semantics: returns `Ok(())` once every byte has been
    /// written, or `EngineError::Io` on partial-write / FD-revoked /
    /// pipe-broken failures. Short writes are not surfaced as success.
    ///
    /// `&mut self` is required because alacritty's `Pty::writer()`
    /// returns `&mut File`. This is also the right shape semantically:
    /// concurrent writes from different threads to the same PTY would
    /// interleave bytes in undefined order.
    pub fn feed_input(&mut self, bytes: &[u8]) -> Result<(), EngineError> {
        // The PTY master is `O_NONBLOCK` (alacritty forces it at
        // construction — see `tty/unix.rs:293`), so a plain `write_all`
        // aborts on the first `EAGAIN`/`WouldBlock` and silently drops
        // the unwritten tail. To honour the all-or-`Io`-error contract
        // above, loop from the current offset: advance by the bytes the
        // kernel accepted, and on `WouldBlock` back off briefly (1 ms,
        // mirroring `WOULDBLOCK_BACKOFF` in `pty.rs` and the read-loop's
        // EAGAIN cadence) before retrying. `Interrupted` (EINTR) retries
        // immediately. Only a real error is surfaced as `Err`.
        //
        // Retry budget for the blocking input write: ~250 ms of 1 ms sleeps.
        // A `kill -STOP`ped child with a full TTY input buffer returns EAGAIN
        // forever; without a deadline every keystroke would hang the calling
        // (UI) thread indefinitely. On exhaustion the input is dropped with
        // an error — the bridge logs it; this matches what other terminals
        // effectively do to a wedged foreground process.
        const FEED_INPUT_RETRY_BUDGET: usize = 250;

        let mut written = 0usize;
        let mut would_block_count = 0usize;
        let writer = self.pty.writer();
        while written < bytes.len() {
            match writer.write(&bytes[written..]) {
                Ok(0) => {
                    // Zero-length write with bytes remaining means the
                    // FD won't make progress — surface as a write-zero
                    // I/O error rather than spin forever.
                    return Err(EngineError::Io(io::Error::new(
                        io::ErrorKind::WriteZero,
                        "PTY master accepted zero bytes",
                    )));
                }
                Ok(n) => {
                    written += n;
                    // Successful progress resets the backpressure counter
                    // so a brief stall that then clears doesn't prematurely
                    // exhaust the budget on a slow but live child.
                    would_block_count = 0;
                }
                Err(ref err) if err.kind() == io::ErrorKind::Interrupted => {}
                Err(ref err) if err.kind() == io::ErrorKind::WouldBlock => {
                    would_block_count += 1;
                    if would_block_count > FEED_INPUT_RETRY_BUDGET {
                        return Err(EngineError::Io(io::Error::new(
                            io::ErrorKind::TimedOut,
                            "PTY input stalled; dropping write",
                        )));
                    }
                    std::thread::sleep(std::time::Duration::from_millis(1));
                }
                Err(err) => return Err(EngineError::Io(err)),
            }
        }
        Ok(())
    }

    /// Non-blocking PTY write — returns the number of bytes the
    /// kernel accepted before EAGAIN (slave's TTY input buffer
    /// full). Used by the paste/drop chunker so the UI thread can
    /// resubmit the unwritten tail on the next runloop tick instead
    /// of blocking. The master FD is already `O_NONBLOCK` (alacritty
    /// forces it at construction, `tty/unix.rs:293`), so no flag
    /// mutation happens here — important because the reader thread
    /// shares the same file description. Returns 0 on EAGAIN: the
    /// caller treats that as "buffer full, try again next tick".
    //
    // unsafe_code allow: one bare `libc::write` on the PTY master — the
    // SAFETY note at the call site covers the descriptor and the slice.
    #[allow(unsafe_code)]
    pub fn feed_input_nonblocking(&mut self, bytes: &[u8]) -> Result<usize, EngineError> {
        use std::os::fd::AsRawFd;
        if bytes.is_empty() {
            return Ok(0);
        }
        let fd = self.pty.file().as_fd().as_raw_fd();
        // The master is already `O_NONBLOCK` — alacritty forces it at
        // construction (`tty/unix.rs:293`). The reader thread holds a
        // `dup` of this *same* file description, so mutating its status
        // flags here would be a cross-thread hazard; we rely on the
        // documented non-blocking invariant and issue the raw write
        // directly. A short write / `EAGAIN` is returned as the count
        // accepted so far, which `paste_chunk` resubmits next tick.
        // SAFETY: `fd` is a valid open descriptor borrowed from
        // `self.pty.file()` and cannot be closed while `&mut self` is held;
        // `bytes` is a valid slice for `bytes.len()`; casting `*const u8` to
        // `*const libc::c_void` is ABI-correct for write(2).
        let n = unsafe { libc::write(fd, bytes.as_ptr().cast::<libc::c_void>(), bytes.len()) };
        if n >= 0 {
            // Guarded by `n >= 0`, so the sign bit is clear and the cast is
            // exact: on success write(2) returns the accepted byte count.
            #[allow(clippy::cast_sign_loss)]
            return Ok(n as usize);
        }
        let err = std::io::Error::last_os_error();
        match err.raw_os_error() {
            // `EWOULDBLOCK` == `EAGAIN` on macOS, the only platform built for.
            Some(libc::EAGAIN) => Ok(0),
            _ => Err(EngineError::Io(err)),
        }
    }

    /// Drain pending PTY output bytes from the reader thread channel
    /// and feed them through `vte::ansi::Processor` into `Term`.
    /// Returns the total bytes consumed (sum across all chunks drained
    /// in this call); `Ok(0)` means the channel was empty.
    ///
    /// Non-blocking: `try_recv` is used in a tight loop, so callers
    /// can drive this from a tick loop without spawning their own
    /// blocking-IO thread.
    ///
    /// After a successful call, `Term`'s grid + cursor + scrollback
    /// reflect the parsed bytes. Cell-level inspection happens through
    /// alacritty's `Term::grid()` (test-internal today; future
    /// `take_damage` / `viewport_cells` at tasks 1.6 / 1.7 are the
    /// public reads).
    ///
    /// The `Result<usize, EngineError>` shape carries the bytes-
    /// consumed count for FFI consumers (Swift's tick loop) to log
    /// throughput and detect "engine is starved" vs "engine is busy"
    /// without a second roundtrip. `EngineError` is in the signature
    /// for symmetry with `feed_input`; today no I/O happens on the
    /// read side that can fail (the reader thread surfaces errors via
    /// `tracing::debug` and exits its loop), but task 1.8's
    /// `EngineEvent` channel will route child-exit / parser-error
    /// signals through here.
    pub fn poll_output(&mut self) -> Result<usize, EngineError> {
        // Per-call byte budget. A child that outproduces the parser
        // (`cat /dev/urandom`, `yes`) keeps the bounded reader channel
        // full, so without a cap this loop would never see an empty
        // `try_recv` and `poll_output` would not return — freezing the
        // calling display-link tick for the whole flood, and piling
        // unbounded events into `held_events`. Draining at most this
        // many bytes per call leaves the rest in the channel for the
        // next tick; the reader keeps refilling, so sustained
        // throughput stays high while per-frame stall (and per-call
        // event production) is bounded.
        const POLL_OUTPUT_MAX_BYTES: usize = 1 << 20;
        let mut total = 0usize;
        while let Some(chunk) = self.reader.try_recv() {
            // Order: alacritty Processor first (load-bearing grid
            // mutation, the canonical consumer), OSC pre-scanner
            // second. Both see the same bytes; the second pass is
            // observe-only and cannot influence the first. See
            // `crate::osc` for why a sibling parser is the right
            // shape (Term's `vte::ansi::Handler` doesn't surface
            // every OSC we need to route).
            self.parser.advance(&mut self.term, &chunk);
            self.osc_parser.advance(&mut self.osc_perform, &chunk);
            total += chunk.len();
            if total >= POLL_OUTPUT_MAX_BYTES {
                break;
            }
        }

        // Track alt-screen flips for `is_alt_screen` accessor.
        let alt_now = self
            .term
            .mode()
            .contains(alacritty_terminal::term::TermMode::ALT_SCREEN);
        if alt_now != self.last_alt_screen {
            self.last_alt_screen = alt_now;
        }

        // Drain `events_rx` (events fired during `parser.advance`
        // above) into `held_events` for [`Self::drain_events`]
        // consumers.
        {
            let mut held = self.held_events.lock();
            while let Ok(event) = self.events_rx.try_recv() {
                held.push_back(event);
            }
        }

        // Drain OSC 10/11/12 query replies queued by `EventProxy`
        // during the parser run above and write them back to the PTY
        // master so the shell sees the response (#71, task 2.5).
        // Drained here — outside the `parser.advance` borrow chain —
        // because `pty.writer()` would conflict with the `&mut
        // self.term` borrow inside `advance`. Per-call cost: zero
        // syscalls when the queue is empty (the typical case); one
        // `write_all` per query when the shell asked. Replies are
        // small (≤32 bytes) so partial-write is not a practical
        // concern.
        //
        // Errors are logged + dropped, NOT propagated. The realistic
        // failure mode here is "child has already exited so the PTY
        // master returns EIO/BrokenPipe on write" — between the
        // parser dispatching the query and us getting here, the
        // shell could have died (rare in practice; common in our own
        // tests that use a printf-emit-then-exit producer). Treating
        // a dead-child write as fatal would force every consumer of
        // `poll_output` to handle a transient post-exit error path
        // that the consumer can do nothing about. Drop quietly with
        // a tracing breadcrumb instead — `ChildExited` will surface
        // through `drain_events` on the next poll anyway.
        while let Ok(reply) = self.pty_responses_rx.try_recv() {
            // Route through `feed_input`'s EAGAIN/`WouldBlock` backoff
            // loop, NOT a bare `write_all`. The master is `O_NONBLOCK`;
            // a plain `write_all` returns `Err` on a transient
            // `WouldBlock`, and because `try_recv` has already dequeued
            // `reply`, that capability answer (e.g. the DA1 sentinel a
            // child blocks on at startup) would be lost forever. The
            // backoff retries until the tiny reply is fully written, so a
            // transient buffer-full no longer drops it; only a real error
            // (child exited → EIO/BrokenPipe) breaks the drain.
            if let Err(err) = self.feed_input(reply.as_bytes()) {
                tracing::debug!(
                    error = %err,
                    bytes = reply.len(),
                    "poll_output: PTY write-back of OSC reply failed (child likely exited)"
                );
                // Don't try to drain remaining replies if the writer
                // is broken — they'd all hit the same error. Break
                // out and let the next poll_output (or ChildExited)
                // sort it out.
                break;
            }
        }

        // Drive the synchronized-update (`CSI ?2026 h`) 150 ms fallback
        // timeout. If a producer wrote BSU but never sent ESU (e.g. it
        // crashed mid-frame, or buffered output never reached us in
        // time), `vte::ansi::Processor`'s sync buffer would otherwise
        // hold bytes until the 2 MiB cap auto-flush — far too long for
        // an interactive shell. Alacritty's own event loop drives this
        // by waking on `parser.sync_timeout()` and calling `stop_sync`
        // (`alacritty_terminal-0.26.0/src/event_loop.rs:228-249`); we
        // don't use that loop, so we replicate the check here on every
        // poll. Bound: at the renderer's 60-120 Hz tick, the worst-
        // case latency from deadline expiry to flush is one tick (~8-
        // 16 ms), well inside the 150 ms budget.
        //
        // No-op when sync is inactive (`sync_timeout()` returns
        // `None`); branch is cold by construction (`stop_sync` only
        // runs after a missed-ESU producer fault).
        if let Some(deadline) = self.parser.sync_timeout().sync_timeout() {
            if std::time::Instant::now() >= deadline {
                self.parser.stop_sync(&mut self.term);
            }
        }

        // Poll for child-process exit (#55, restoring the #44
        // observability deferral). `next_child_event` returns
        // `Some(ChildEvent::Exited(_))` once SIGCHLD has been
        // observed via alacritty's signal-pipe + `child.try_wait()`.
        // Latency from actual exit → emission is bounded by the
        // consumer's poll_output cadence (60-120Hz for a renderer;
        // ms-level for tests with explicit poll loops).
        if let Some(ChildEvent::Exited(status)) = self.pty.next_child_event() {
            // status: Option<ExitStatus>; convert to Option<i32>.
            let code = status.and_then(|s| s.code());
            if self
                .events_tx
                .send(EngineEvent::ChildExited { status: code })
                .is_err()
            {
                tracing::warn!("poll_output: events channel closed; dropping ChildExited");
            }
        }

        Ok(total)
    }

    /// Grace window between SIGHUP and SIGKILL in
    /// [`Self::shutdown_detached`]. Long enough for an interactive
    /// shell's HUP path (kill jobs, save history — zsh at a prompt
    /// exits in single-digit ms), short enough that a wedged child
    /// never keeps a teardown thread around noticeably.
    const SHUTDOWN_GRACE: std::time::Duration = std::time::Duration::from_millis(500);

    /// Poll cadence of the grace loop in [`Self::shutdown_detached`].
    const SHUTDOWN_POLL: std::time::Duration = std::time::Duration::from_millis(10);

    /// Tear the engine down without ever blocking the calling thread
    /// on child exit. This is the only teardown path the FFI layer
    /// uses; dropping a `TerminalEngine` inline remains correct for
    /// tests but must never happen on the app's main thread.
    ///
    /// Why: alacritty's `Pty::Drop` sends SIGHUP and then calls the
    /// *blocking* `child.wait()`. Dropping inline on the main thread
    /// can deadlock the whole app (observed + sampled 2026-08-22) via
    /// a four-way cycle: the main thread parks in `wait4`; the dying
    /// child parks in `write(2)` because the kernel PTY buffer is
    /// full; the buffer is full because the reader thread is parked in
    /// `send` on the full flood-cap channel (`PTY_CHANNEL_CAP`); and
    /// the only drainer of that channel — `poll_output` on the main
    /// thread's tick — is the thread parked in `wait4`.
    ///
    /// Containment per session: SIGHUP the child immediately, then
    /// ship the whole engine to a detached teardown thread so the
    /// caller returns in microseconds. On that thread, break the cycle
    /// by draining the reader channel during a short grace window —
    /// un-parking a send-blocked reader thread, emptying the kernel
    /// PTY buffer, and letting the child's blocked `write(2)` complete
    /// so it can act on the SIGHUP and exit cleanly. If the grace
    /// expires, escalate to SIGKILL, which cannot be caught. Only then
    /// does the engine drop, so `Pty::Drop`'s `wait()` is prompt and
    /// `PtyReader::Drop`'s channel-disconnect + join always succeeds.
    //
    // unsafe_code allow: three bare `libc::kill` calls — the identical
    // signalling `Pty::Drop` itself performs, minus its blocking wait.
    // No pointers, no FFI types cross here.
    #[allow(unsafe_code)]
    pub fn shutdown_detached(self) {
        /// Owns the engine through the grace dance. Its `Drop` is the
        /// single point that escalates + drops, so every exit path —
        /// grace expiry, early child exit, teardown-thread spawn
        /// failure (the failed `spawn` drops the closure, and with it
        /// this guard, inline) — ends in a prompt, non-blocking reap.
        struct TeardownGuard {
            engine: Option<TerminalEngine>,
            pid: i32,
            exited: bool,
        }
        impl Drop for TeardownGuard {
            fn drop(&mut self) {
                let Some(engine) = self.engine.take() else {
                    return;
                };
                if !self.exited {
                    // `exited` is the only arm in which the child has
                    // been reaped (`next_child_event` → `try_wait`),
                    // so here the pid is still our un-reaped child —
                    // no recycled-pid hazard. SIGKILL cannot be caught
                    // or ignored; a zombie ignores it harmlessly.
                    unsafe { libc::kill(self.pid, libc::SIGKILL) };
                }
                // Now prompt: `Pty::Drop`'s `wait()` reaps a child
                // that is already dead or dying, then
                // `PtyReader::Drop` disconnects the channel (waking a
                // send-parked reader thread) and joins it.
                drop(engine);
            }
        }

        // `child_pid` is a `u32` (std `Child::id`); kernel pids fit
        // i32 — the same cast alacritty's `Pty::Drop` performs.
        #[allow(clippy::cast_possible_wrap)]
        let pid = self.child_pid() as i32;
        // Ask politely first — the same signal `Pty::Drop` would send,
        // decoupled from its blocking wait.
        unsafe { libc::kill(pid, libc::SIGHUP) };

        let mut guard = TeardownGuard {
            engine: Some(self),
            pid,
            exited: false,
        };
        let teardown = move || {
            let deadline = std::time::Instant::now() + Self::SHUTDOWN_GRACE;
            while std::time::Instant::now() < deadline {
                let Some(engine) = guard.engine.as_mut() else {
                    break;
                };
                // Drain so a send-parked reader un-parks and the child
                // can flush its final writes (see method doc).
                while engine.reader.try_recv().is_some() {}
                if let Some(ChildEvent::Exited(_)) = engine.pty.next_child_event() {
                    guard.exited = true;
                    break;
                }
                std::thread::sleep(Self::SHUTDOWN_POLL);
            }
            drop(guard);
        };

        if let Err(err) = std::thread::Builder::new()
            .name("solidterm-pty-teardown".to_string())
            .spawn(teardown)
        {
            // pthread_create failure (RLIMIT_NPROC exhaustion). The
            // failed `spawn` already dropped the closure — and thus
            // the guard — inline above: SIGKILL + prompt reap, no
            // grace. Correct, just not graceful; only record why.
            tracing::warn!(
                ?err,
                "shutdown_detached: teardown thread spawn failed; \
                 fell back to inline SIGKILL teardown"
            );
        }
    }

    /// Drain all `EngineEvent`s that have accumulated since the last
    /// call. Returns an empty `Vec` if no events are pending.
    ///
    /// Two event sources merge into one stream:
    /// 1. `Term`'s [`alacritty_terminal::event::EventListener`]
    ///    (held inside `term` as an [`EventProxy`]) emits Bell,
    ///    Title, Clipboard, etc. as alacritty parses VT/CSI/OSC
    ///    sequences during `poll_output`.
    /// 2. [`Self::poll_output`] polls `Pty::next_child_event` after
    ///    the parser loop and emits `ChildExited` when SIGCHLD has
    ///    been observed.
    ///
    /// Drains via `try_recv` in a loop; non-blocking. The single-
    /// allocation Vec is the canonical FFI-tick consumer pattern
    /// (the renderer's `CAMetalDisplayLink` callback drains once per
    /// frame and iterates).
    ///
    /// `&self` because the receiver's `try_recv` is `&self` — no
    /// mutex needed since the channel itself is `Send + Sync`.
    #[must_use]
    pub fn drain_events(&self) -> Vec<EngineEvent> {
        let mut out = Vec::new();
        // Held buffer first — events surfaced by `poll_output` after
        // routing through the block state machine. Drained in FIFO
        // order so consumers see Term-side events in the same order
        // alacritty emitted them.
        {
            let mut held = self.held_events.lock();
            while let Some(event) = held.pop_front() {
                out.push(event);
            }
        }
        // Channel stragglers — `ChildExited` is sent into `events_tx`
        // after the held-buffer routing in `poll_output`, and
        // consumers calling `drain_events` between two `poll_output`
        // ticks would otherwise miss them. Note: events drained here
        // are NOT routed through the state machine — `ChildExited`
        // isn't block-relevant, and any OSC 133 that landed here
        // bypasses the state machine for one tick (the next
        // `poll_output` will catch it). Acceptable: OSC 133 markers
        // only fire during `parser.advance`, which is inside
        // `poll_output`'s held-buffer routing path. So the only
        // events that reach this fall-through are exactly those
        // emitted *outside* `parser.advance` — i.e. `ChildExited`
        // from the `Pty::next_child_event` poll below.
        while let Ok(event) = self.events_rx.try_recv() {
            out.push(event);
        }
        out
    }

    /// Snapshot the current cursor as a [`CursorReadback`] — viewport
    /// row/col plus shape + blink + visible flags. Computed from
    /// alacritty's `term.grid().cursor.point` (position),
    /// `term.cursor_style()` (shape + blink), and
    /// `term.mode().contains(TermMode::SHOW_CURSOR)` (visibility).
    ///
    /// `&self` because cursor read is non-mutating; callers can
    /// freely interleave with `feed_input` / `poll_output` /
    /// `viewport_cells` without synchronization.
    ///
    /// `point.line` is signed `i32` upstream because alacritty allows
    /// negative indices in vi-mode scroll. M1 doesn't expose vi mode,
    /// so the cast back to u16 is unreachable as a truncation in
    /// practice. The `cast_sign_loss` allow + `cast_possible_truncation`
    /// allow are documented at the cast site.
    #[must_use]
    pub fn cursor(&self) -> CursorReadback {
        let point = self.term.grid().cursor.point;
        let style = self.term.cursor_style();
        // Hide the cursor when the user has scrolled back into history
        // — the cursor is anchored to the live tail, which is no longer
        // visible. Standard terminal behavior (Terminal.app, iTerm2,
        // Ghostty, alacritty's own renderer all do this). Typing snaps
        // the viewport back to the live tail, which restores the cursor.
        let visible = self
            .term
            .mode()
            .contains(alacritty_terminal::term::TermMode::SHOW_CURSOR)
            && self.term.grid().display_offset() == 0;

        // Vi-mode scrollback cursors can have line < 0 upstream, but
        // we don't expose vi mode at M1; line is always in
        // 0..screen_lines for our consumers. The cast preserves that
        // invariant; if it ever fired on a negative line we'd see
        // wrap-around in the rendered cursor position, an obvious
        // visual bug rather than a silent miscompute.
        #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
        let row = point.line.0 as u16;
        #[allow(clippy::cast_possible_truncation)]
        let col = point.column.0 as u16;

        CursorReadback {
            row,
            col,
            shape: CursorShape::from_alacritty(style.shape),
            blink: style.blinking,
            visible,
        }
    }

    /// Returns `true` if the shell has enabled bracketed-paste mode
    /// via `CSI ?2004 h` (DECSET 2004); `false` if disabled (the
    /// default) or after `CSI ?2004 l` (DECRST 2004).
    ///
    /// When enabled, paste handlers (Swift-side, at Cmd-V time) should
    /// wrap pasted content in `\x1b[200~ ... \x1b[201~` so the running
    /// program can distinguish typed input from pasted bytes. Mode
    /// state is maintained by alacritty's `vte::ansi::Handler` impl
    /// on `Term`, flipping `TermMode::BRACKETED_PASTE` from the parser
    /// path — no engine-level work beyond surfacing the bit.
    ///
    /// `&self` because the read is non-mutating; safe to interleave
    /// with `feed_input` / `poll_output` / `viewport_cells`.
    #[must_use]
    pub fn bracketed_paste_enabled(&self) -> bool {
        self.term
            .mode()
            .contains(alacritty_terminal::term::TermMode::BRACKETED_PASTE)
    }

    /// Returns `true` if the shell has enabled focus-event reporting
    /// via `CSI ?1004 h` (DECSET 1004); `false` if disabled (the
    /// default) or after `CSI ?1004 l` (DECRST 1004).
    ///
    /// When enabled, the host (Swift, at `NSWindow` key-status change
    /// time — out of scope for this atomic) is responsible for
    /// writing `\x1b[I` (focus gained) and `\x1b[O` (focus lost) into
    /// the PTY via [`Self::feed_input`]. Like bracketed-paste, the
    /// engine only surfaces the mode bit; emitting the focus bytes is
    /// a host concern. Mode state is maintained by alacritty's
    /// `vte::ansi::Handler` impl on `Term`, flipping
    /// `TermMode::FOCUS_IN_OUT` from the parser path
    /// (`alacritty_terminal-0.26.0/src/term/mod.rs:1969,2028`) — no
    /// engine-level work beyond surfacing the bit.
    ///
    /// `&self` because the read is non-mutating; safe to interleave
    /// with `feed_input` / `poll_output` / `viewport_cells`.
    #[must_use]
    pub fn focus_events_enabled(&self) -> bool {
        self.term
            .mode()
            .contains(alacritty_terminal::term::TermMode::FOCUS_IN_OUT)
    }

    /// Returns `true` when DECCKM (application-cursor-keys mode) is
    /// active — set by `CSI ?1 h`, cleared by `CSI ?1 l`. Full-screen
    /// TUIs (vim, less, htop, fzf) flip this so the host encodes the
    /// arrow / Home / End keys as SS3 (`\eOA`…) instead of the normal
    /// CSI form (`\e[A`…). The host reads this on each keystroke; the
    /// engine only surfaces the bit, mirroring `bracketed_paste_enabled`
    /// / `focus_events_enabled`.
    ///
    /// `&self` is non-mutating; safe to interleave with the cell /
    /// damage / input accessors.
    #[must_use]
    pub fn app_cursor_active(&self) -> bool {
        self.term
            .mode()
            .contains(alacritty_terminal::term::TermMode::APP_CURSOR)
    }

    /// Mouse-reporting mode bits packed into a single u8 for the
    /// Swift host. The host checks these on every mouseDown / mouseUp
    /// / mouseDragged / scrollWheel and, when any bit is set,
    /// encodes the event as an xterm mouse sequence instead of
    /// driving its own selection logic. Lets `vim`, `htop`,
    /// `lazygit`, `tmux` etc. receive raw clicks.
    ///
    /// Bit 0 — `MOUSE_REPORT_CLICK` (DEC 1000): clicks only.
    /// Bit 1 — `MOUSE_DRAG`         (DEC 1002): clicks + button-held drag.
    /// Bit 2 — `MOUSE_MOTION`       (DEC 1003): clicks + all motion.
    /// Bit 3 — `SGR_MOUSE`          (DEC 1006): use SGR-style encoding
    ///                                          (`CSI < Cb;Cx;Cy M/m`).
    #[must_use]
    pub fn mouse_mode_bits(&self) -> u8 {
        let m = self.term.mode();
        let mut bits: u8 = 0;
        if m.contains(alacritty_terminal::term::TermMode::MOUSE_REPORT_CLICK) {
            bits |= 1;
        }
        if m.contains(alacritty_terminal::term::TermMode::MOUSE_DRAG) {
            bits |= 2;
        }
        if m.contains(alacritty_terminal::term::TermMode::MOUSE_MOTION) {
            bits |= 4;
        }
        if m.contains(alacritty_terminal::term::TermMode::SGR_MOUSE) {
            bits |= 8;
        }
        bits
    }

    /// Currently-active Kitty keyboard protocol flags (task 2.9). A
    /// fresh engine returns [`KittyKeyboardFlags::NO_MODE`]; flags flip
    /// as shells push / pop / set them via `CSI > N u` / `CSI < N u` /
    /// `CSI = N u`. The query form `CSI ? u` is replied to internally:
    /// alacritty's `report_keyboard_mode` formats `\x1b[?bits u` and
    /// queues it on `pty_responses` (M1 task 2.5 plumbing); no caller
    /// action required.
    ///
    /// Stack semantics are managed by alacritty: `push` adds to its
    /// internal `keyboard_mode_stack` (capped at 64 entries —
    /// `alacritty_terminal-0.26.0/src/term/mod.rs:KEYBOARD_MODE_STACK_MAX_DEPTH`),
    /// `pop` removes from the top, `set` replaces the top with apply-
    /// behavior modifiers (Replace / Union / Difference). Overflow on
    /// push silently drops the new entry, underflow on pop silently
    /// caps at 0 — both alacritty's policy. We expose the *currently
    /// active* flags only (the set the shell expects the terminal to
    /// honour for the next keystroke); the stack itself is not on the
    /// public surface.
    ///
    /// **M1 vs M2+**: this accessor is the engine-side observable. Swift
    /// reads it on each keystroke (M2+) to decide whether to encode the
    /// key as a `CSI u` sequence with full modifier reporting, fall back
    /// to the legacy modifyOtherKeys path, or emit the bare ASCII byte.
    /// Today there is no Swift-side consumer; the accessor + the
    /// in-engine state plumbing land here so M2 can wire input encoding
    /// without re-touching the engine.
    ///
    /// `&self` is non-mutating; safe to interleave with `feed_input`,
    /// `poll_output`, and the cell/damage accessors.
    #[must_use]
    pub fn kitty_keyboard_flags(&self) -> KittyKeyboardFlags {
        // Alacritty stores active flags as bits in `TermMode` (one
        // bitflag per Kitty mode). We re-read from `mode()` instead
        // of poking at the private `keyboard_mode_stack` so that the
        // accessor reflects the EFFECTIVE mode the parser will apply
        // — matching `report_keyboard_mode`'s view of the world.
        use alacritty_terminal::term::TermMode;
        let m = self.term.mode();
        let mut flags = KittyKeyboardFlags::NO_MODE;
        if m.contains(TermMode::DISAMBIGUATE_ESC_CODES) {
            flags |= KittyKeyboardFlags::DISAMBIGUATE_ESC_CODES;
        }
        if m.contains(TermMode::REPORT_EVENT_TYPES) {
            flags |= KittyKeyboardFlags::REPORT_EVENT_TYPES;
        }
        if m.contains(TermMode::REPORT_ALTERNATE_KEYS) {
            flags |= KittyKeyboardFlags::REPORT_ALTERNATE_KEYS;
        }
        if m.contains(TermMode::REPORT_ALL_KEYS_AS_ESC) {
            flags |= KittyKeyboardFlags::REPORT_ALL_KEYS_AS_ESC;
        }
        if m.contains(TermMode::REPORT_ASSOCIATED_TEXT) {
            flags |= KittyKeyboardFlags::REPORT_ASSOCIATED_TEXT;
        }
        flags
    }

    /// Current `XTerm` `modifyOtherKeys` level (task 2.9). `0` = disabled
    /// (the default and `Reset` form `CSI > 4 ; 0 m`); `1` =
    /// `EnableExceptWellDefined` (`CSI > 4 ; 1 m`); `2` = `EnableAll`
    /// (`CSI > 4 ; 2 m`).
    ///
    /// **Why this lives on `OscPerform`, not `Term`**: alacritty 0.26 does
    /// not implement `Handler::set_modify_other_keys` /
    /// `Handler::report_modify_other_keys` (vte's defaults — both no-op
    /// — apply, see `vte-0.13.1/src/ansi.rs:674,679`). Tracking lives
    /// on the sibling `vte::Perform` (our OSC pre-scanner) which sees
    /// every CSI byte anyway; see `crate::osc` for the architecture
    /// rationale. The `CSI ? 4 m` query reply (`CSI > 4 ; level m`) is
    /// formatted in `OscPerform::handle_modify_other_keys_query` and
    /// queued on the same `pty_responses` channel OSC 10/11/12 / Kitty
    /// keyboard / XTWINOPS replies use; `poll_output` drains and writes.
    ///
    /// **M1 vs M2+**: like `kitty_keyboard_flags`, this is the engine-side
    /// observable. M2+'s Swift-side input encoding will read the level
    /// to decide whether ASCII keys with modifiers should emit a
    /// `CSI 27 ; modifier ; char ~` (xterm-classic) or `CSI char ;
    /// modifier u` (fixterms / Kitty CSI u) sequence — out of scope
    /// here.
    ///
    /// `&self` is non-mutating; safe to interleave with `feed_input`,
    /// `poll_output`, and the cell/damage accessors.
    #[must_use]
    pub fn modify_other_keys_level(&self) -> u8 {
        self.osc_perform.modify_other_keys_level()
    }

    /// Returns `true` while the parser is inside a synchronized-output
    /// window opened by `CSI ?2026 h` (BSU) and not yet closed by
    /// `CSI ?2026 l` (ESU) or the 150 ms vte fallback timeout.
    ///
    /// Spec: <https://gist.github.com/christianparpart/d8a62cc1ab659194337d73e399004036>.
    /// While active, alacritty's `vte::ansi::Processor` buffers the
    /// post-BSU byte stream into an internal scratch (up to 2 MiB)
    /// instead of feeding it to `Term`, so the grid + cursor + damage
    /// regions stay frozen at the pre-BSU snapshot. ESU (or timeout
    /// expiry, or the 2 MiB cap) flushes the buffer through the parser
    /// in one shot, producing a single coherent damage batch.
    ///
    /// Note that — unlike `BRACKETED_PASTE` — alacritty's `Term` does
    /// **not** track this as a `TermMode` bit. The flag lives entirely
    /// inside `vte::ansi::Processor`'s `sync_state`; `Term::set_private_
    /// mode(SyncUpdate)` is a no-op (`alacritty_terminal-0.26.0/src/
    /// term/mod.rs:1992`) because the parser uses the bit internally
    /// to redirect bytes before they reach `Term`. So we read the
    /// state from `parser.sync_timeout().pending_timeout()`, which
    /// covers BSU-set ⇒ ESU-or-timeout-clear, exactly the window we
    /// want to expose.
    ///
    /// Useful for FFI consumers (the Swift renderer can opt to skip a
    /// frame's damage drain while sync is active) and for tests that
    /// want to assert mid-BSU state. `&self` is non-mutating; safe to
    /// interleave with `feed_input` / `poll_output` / `viewport_cells`.
    #[must_use]
    pub fn synchronized_output_active(&self) -> bool {
        use alacritty_terminal::vte::ansi::Timeout;
        self.parser.sync_timeout().pending_timeout()
    }

    /// Number of rows the viewport is scrolled up from the live tail.
    /// 0 means "at the bottom" (live viewport); positive values mean
    /// the user has scrolled up by that many rows into scrollback.
    /// Derived from alacritty's `Grid::display_offset()`.
    #[must_use]
    pub fn scroll_top(&self) -> u32 {
        u32::try_from(self.term.grid().display_offset()).unwrap_or(u32::MAX)
    }

    /// Number of scrollback rows currently retained. Derived as
    /// `total_lines - screen_lines` per alacritty's `Dimensions`
    /// trait — the storage size minus the visible viewport.
    /// Capped to u32 (real scrollback is u32-bounded by
    /// `EngineConfig`'s `scrollback_lines: u32`).
    #[must_use]
    pub fn scroll_total(&self) -> u32 {
        let grid = self.term.grid();
        let total = grid.total_lines();
        let visible = grid.screen_lines();
        u32::try_from(total.saturating_sub(visible)).unwrap_or(u32::MAX)
    }

    /// Scroll the display by `delta` rows. Positive = scroll back into
    /// scrollback history (toward older content); negative = scroll
    /// forward toward the live tail. Bounds-clamped by alacritty's
    /// `Grid::scroll_display` (`grid/mod.rs:163-173` upstream): the
    /// resulting `display_offset` is clamped to `[0, history_size()]`
    /// for `Scroll::Delta`, so callers can pass arbitrarily large
    /// deltas without worrying about over-scroll.
    ///
    /// Sign convention matches alacritty: positive moves the viewport
    /// up into history, mirroring `Term::scroll_to_point`'s usage at
    /// `term/mod.rs:893,896`. Task 4.4 wires trackpad `scrollingDeltaY`
    /// (positive when content moves down under fingers, i.e. user
    /// wants to see older content) directly to `delta` — same sign.
    ///
    /// `&mut self` is required because `Term::scroll_display` mutates
    /// `display_offset`, sends `Event::MouseCursorDirty` through the
    /// `EventListener`, and may clamp the vi-mode cursor; safe to
    /// interleave with `feed_input` / `poll_output` / `take_damage`.
    pub fn scroll_lines(&mut self, delta: i32) {
        use alacritty_terminal::grid::Scroll;
        self.term.scroll_display(Scroll::Delta(delta));
    }

    /// Reset the display to the live tail (`scroll_top == 0`). Called
    /// when the user types or when new PTY output arrives mid-
    /// scrollback — matches iTerm2 / Terminal.app "snap to bottom on
    /// activity" UX. Implemented via alacritty's `Scroll::Bottom`,
    /// which sets `display_offset = 0` directly (`grid/mod.rs:171`).
    ///
    /// Idempotent at `display_offset == 0`: the upstream match arm
    /// unconditionally writes 0, so calling on the live tail is a
    /// trivial assignment + one `MouseCursorDirty` event.
    pub fn scroll_to_bottom(&mut self) {
        use alacritty_terminal::grid::Scroll;
        self.term.scroll_display(Scroll::Bottom);
    }

    /// M7-2: scroll the viewport so the requested absolute `line` is
    /// visible. Used by the ⌘F find panel's jump-to-match handler.
    /// Negative `line` = scrollback row; non-negative = viewport row
    /// (`0..screen_lines`). Bounds-clamped — out-of-range lines snap
    /// to the live tail or the topmost scrollback row.
    pub fn scroll_to_line(&mut self, line: i32) {
        use alacritty_terminal::grid::Scroll;
        let grid = self.term.grid();
        // alacritty's screen / history fits comfortably in i32 for any
        // realistic terminal config (cap'd by EngineConfig). Clamp the
        // cast so a 32-bit pathological config can't wrap.
        let screen = i32::try_from(grid.screen_lines()).unwrap_or(i32::MAX);
        let history = i32::try_from(grid.history_size()).unwrap_or(i32::MAX);
        // Target: place `line` ~ 1/3 from the top of the viewport for
        // context. `display_offset` is non-negative (0 = live tail,
        // history_size() = topmost); viewport spans alacritty lines
        // `[-display_offset, screen - display_offset)`.
        let third = screen / 3;
        let desired = (-line + third).clamp(0, history);
        let current = i32::try_from(grid.display_offset()).unwrap_or(i32::MAX);
        let delta = desired - current;
        self.term.scroll_display(Scroll::Delta(delta));
    }

    /// M7-2: search the full grid (scrollback history + viewport) for
    /// `query`. `regex_flag` toggles regex vs. case-insensitive plain
    /// substring. Returns matches in reading order (oldest first).
    /// Surfaces malformed-regex errors so the search panel can render a
    /// "syntax error" chip.
    pub fn search(
        &self,
        query: &str,
        regex_flag: bool,
    ) -> Result<Vec<crate::search::SearchMatch>, crate::search::SearchError> {
        crate::search::search(self.term.grid(), query, regex_flag)
    }

    /// Whether the terminal is currently in alt-screen mode (DECSET
    /// 1049 / 47 / 1047 — vim, less, man, htop, etc.). Read from
    /// `Term::mode()` directly so it tracks the parser's view of the
    /// world without needing a sibling cache.
    ///
    /// Task 4.4 uses this to gate scrollback paging on `PgUp` / `PgDn`:
    /// alt-screen apps generally manage their own paging keys (less's
    /// `b` / `f`, vim's `Ctrl-B` / `Ctrl-F`), so we forward the
    /// keystrokes through to the PTY when alt-screen is active and
    /// only steal them for scrollback navigation on the primary
    /// screen. Matches iTerm2 / Terminal.app behavior.
    ///
    /// `&self` is non-mutating; safe to interleave with the rest of
    /// the read-side accessor surface.
    #[must_use]
    pub fn is_alt_screen(&self) -> bool {
        use alacritty_terminal::term::TermMode;
        self.term.mode().contains(TermMode::ALT_SCREEN)
    }

    // ── 4.5 selection API ────────────────────────────────────────────
    //
    // Thin wrapper over alacritty's `Selection` — start, update, query,
    // clear. The (row, col) inputs are **viewport-relative** so callers
    // (Swift's mouse-down handler) don't need to know about
    // `display_offset`. We translate to alacritty's absolute `Point`
    // (Line counts up from the top of the viewport, with negative
    // values for scrolled-back rows) inside each method.
    //
    // Block-mode selection (alt-drag) is intentionally excluded from
    // [`SelectionMode`] for 4.5 — paired with the alt-drag input plumb
    // it lands as a single follow-up. The on-wire `is_block` field on
    // [`SelectionSpan`] still propagates whatever alacritty produces
    // (always `false` for the modes we support today).

    // Selection mode + span types for this API live at module scope
    // below (re-exported through `lib.rs` per the precedent set by
    // `CursorShape`). `SelectionMode::{Simple,Word,Line}` mirrors
    // alacritty's `SelectionType` narrowed to the variants 4.5
    // supports; the FFI seam in `solidterm-ffi` pins the cross-language
    // tag via `kinds::SELECTION_MODE_*`.

    /// Start a new selection at the given viewport-relative cell.
    ///
    /// Replaces any prior selection. The anchor cell is cached in
    /// [`Self::selection_anchor`] so [`Self::update_selection`] can pick
    /// drag-direction-aware cell sides; the side passed here only matters
    /// for the anchor-only state (a `Simple` selection with no drag is
    /// empty regardless), so `Side::Left` is fine until the first update.
    ///
    /// `row` is clamped to `[0, screen_lines)` and `col` to `[0,
    /// columns)`. Out-of-range inputs become a 0-cell selection at the
    /// nearest in-range cell; this keeps the FFI surface infallible
    /// and matches the rest of the engine's "silently clamp" stance
    /// for renderer-driven coordinates.
    pub fn start_selection(&mut self, mode: SelectionMode, row: u16, col: u16) {
        let point = self.viewport_point(row, col);
        let ty = match mode {
            SelectionMode::Simple => SelectionType::Simple,
            SelectionMode::Word => SelectionType::Semantic,
            SelectionMode::Line => SelectionType::Lines,
        };
        self.selection_anchor = Some(point);
        self.selection_anchor_is_start = None;
        self.term.selection = Some(Selection::new(ty, point, Side::Left));
    }

    /// Extend the in-progress selection to a new viewport-relative
    /// cell. No-op if there's no active selection.
    ///
    /// For `Word` (Semantic) and `Line` modes alacritty re-evaluates
    /// the boundary on each `to_range`, so dragging past additional
    /// words / lines keeps expanding outward — matches iTerm2 / Terminal
    /// behaviour. For `Simple` the range is updated cell-precise.
    ///
    /// **Drag-direction-aware sides.** alacritty's `range_simple` drops
    /// the boundary cell on the side flagged "away from the selection
    /// body" (`start` cell when its side is `Right`, `end` cell when its
    /// side is `Left`). With fixed sides (anchor `Left`, drag-end
    /// `Right`) a left-to-right drag includes both ends, but a
    /// right-to-left drag — where `to_range` swaps the ordered endpoints
    /// — inverts them, dropping *both* the cell under the cursor and the
    /// anchor cell. That's the "can't select the first character / must
    /// overshoot" bug. We fix it by choosing sides from the drag
    /// direction so the leftmost (in reading order) endpoint is always
    /// `Left` and the rightmost always `Right`, keeping both cells in:
    /// dragging at/after the anchor → anchor `Left`, end `Right`;
    /// dragging before it → anchor `Right`, end `Left`. The anchor side
    /// lives in the private `region`, so we rebuild the selection through
    /// the public API rather than mutate it in place.
    ///
    /// **Anchor follows content, not the screen.** New output arriving
    /// mid-drag rotates the grid (`Term::scroll_up`), which shifts every
    /// absolute `Line` — alacritty rotates its own `Term::selection` to
    /// keep it on the same cells, but our cached [`Self::selection_anchor`]
    /// is a plain `Point` nothing rotates. Rebuilding from that stale
    /// cache re-anchored the drag onto whatever text had since scrolled
    /// into the old line, so the selection jumped away from the cell the
    /// user pressed on. We therefore re-derive the anchor from the *live*
    /// (already-rotated) selection — `to_range()`'s start or end
    /// depending on [`Self::selection_anchor_is_start`] — and only fall
    /// back to the cached point before the drag has a direction (the
    /// first update after `start_selection`, where the anchor-only
    /// selection is empty and `to_range` yields `None`).
    pub fn update_selection(&mut self, row: u16, col: u16) {
        // Compute the point first so the immutable `&self.term` read
        // inside `viewport_point` doesn't overlap the subsequent
        // `&mut self.term.selection` borrow on the assignment.
        let point = self.viewport_point(row, col);
        let Some(ty) = self.term.selection.as_ref().map(|s| s.ty) else {
            return;
        };
        let Some(anchor) = self.live_selection_anchor().or(self.selection_anchor) else {
            return;
        };
        // Point ordering is (line, then column): `point < anchor` means
        // the cursor is before the anchor in reading order (left on the
        // same row, or any earlier row).
        let (anchor_side, end_side) = if point < anchor {
            (Side::Right, Side::Left)
        } else {
            (Side::Left, Side::Right)
        };
        let mut selection = Selection::new(ty, anchor, anchor_side);
        selection.update(point, end_side);
        self.term.selection = Some(selection);
        // Refresh the fallback with the anchor we actually used, and
        // record which end of the ordered range it now sits on so the
        // next update can re-derive it after a rotation.
        self.selection_anchor = Some(anchor);
        self.selection_anchor_is_start = Some(point >= anchor);
    }

    /// The drag anchor as it stands in the *live* selection, i.e. after
    /// any grid rotation alacritty applied to `Term::selection`.
    ///
    /// `None` before the drag has a direction, or when the selection is
    /// empty / fully scrolled out of the buffer (`to_range` yields
    /// `None`) — callers fall back to [`Self::selection_anchor`].
    ///
    /// For `Word` / `Line` selections `to_range` reports the *expanded*
    /// boundary rather than the pressed cell; re-anchoring there is
    /// stable because the boundary cell still lies inside the same word
    /// / line, so the next expansion reproduces the same range.
    fn live_selection_anchor(&self) -> Option<Point> {
        let anchor_is_start = self.selection_anchor_is_start?;
        let range = self.term.selection.as_ref()?.to_range(&self.term)?;
        Some(if anchor_is_start {
            range.start
        } else {
            range.end
        })
    }

    /// Clear any active selection. Idempotent.
    ///
    /// Called by the Swift handler on outside-click / new mouse-down
    /// in non-extending mode. The renderer's overlay encode reads
    /// [`Self::selection_span`]; once it returns `None`, the next
    /// frame paints without the selection tint.
    pub fn clear_selection(&mut self) {
        self.term.selection = None;
        self.selection_anchor = None;
        self.selection_anchor_is_start = None;
    }

    /// Snapshot the current selection's viewport-space span, if any.
    ///
    /// Returns `None` when:
    /// - No selection is active (`Term::selection.is_none()`).
    /// - The selection is empty (`Simple` zero-width with side-collapse).
    /// - The selection scrolled entirely off the top of the viewport
    ///   (alacritty's `to_range` returns `None` when `end.line <
    ///   topmost_line`).
    /// - The selection scrolled entirely past the bottom of the viewport
    ///   (every selected row maps below the last visible row). alacritty
    ///   only nils the off-the-top case; this symmetric guard is on us,
    ///   so a selection parked in not-yet-revealed scrollback below the
    ///   fold leaves no tint behind.
    ///
    /// Coordinates are **viewport-relative**: row 0 is the top of the
    /// visible viewport at the current `display_offset`. A *partially*
    /// visible selection is clamped to the viewport: rows still in
    /// scrollback above the top snap to row 0, rows past the bottom snap
    /// to `screen_lines - 1`. (A *fully* off-screen selection returns
    /// `None` per the bullet above — without that, both endpoints would
    /// clamp to the same edge row and paint a bogus one-row highlight.)
    ///
    /// `start_row` ≤ `end_row`. When `start_row == end_row`, `start_col
    /// ≤ end_col`. Both columns are inclusive — the renderer is
    /// expected to highlight cells `[start_col..=end_col]` on the
    /// terminal row.
    ///
    /// `is_block` reflects alacritty's `SelectionRange.is_block`. With
    /// the `SelectionMode::Simple/Word/Line` API only, this is always
    /// `false`; the field is plumbed through anyway so 4.5's renderer
    /// can choose between stream- and block-mode encoding without an
    /// API addition when block-mode lands.
    #[must_use]
    pub fn selection_span(&self) -> Option<SelectionSpan> {
        let selection = self.term.selection.as_ref()?;
        let range = selection.to_range(&self.term)?;

        // Translate alacritty's absolute Point (Line counts negative
        // for scrollback) into viewport-relative coordinates. Clamp
        // `start` upward (anything above the viewport snaps to row 0)
        // and `end` downward (anything below snaps to the last visible
        // row) so partially-off-screen selections produce a partial
        // viewport span the renderer can highlight without further
        // clipping.
        //
        // `display_offset` is `usize` upstream; the i32 cast is
        // bounded by `EngineConfig::validate`'s scrollback cap (u32,
        // sub-i32::MAX) — same precedent as `scroll_top()`'s cast at
        // line 754 above.
        #[allow(clippy::cast_possible_truncation, clippy::cast_possible_wrap)]
        let display_offset = self.term.grid().display_offset() as i32;
        // `screen_lines()` is bounded by the u16 we passed to
        // `Term::new`; the cast back is unreachable as a truncation.
        #[allow(clippy::cast_possible_truncation)]
        let max_row = self.term.screen_lines().saturating_sub(1) as u16;

        // Bail when the whole selection sits outside the viewport so a
        // scrolled-away selection paints nothing (rather than collapsing
        // both clamped endpoints onto one edge row). `range.start` is the
        // topmost row, `range.end` the bottommost. Fully below the bottom:
        // even the top endpoint maps past `max_row`. Fully above the top:
        // even the bottom endpoint maps above row 0 (alacritty's `to_range`
        // usually nils this already; kept as a symmetric guard).
        let top_vp = range.start.line.0.saturating_add(display_offset);
        let bottom_vp = range.end.line.0.saturating_add(display_offset);
        if top_vp > i32::from(max_row) || bottom_vp < 0 {
            return None;
        }

        // Convert absolute line → viewport-relative (positive down).
        // alacritty's `point_to_viewport` returns None for points below
        // the viewport bottom; we want to clamp instead.
        let to_viewport_row = |line: Line| -> u16 {
            let v = line.0.saturating_add(display_offset);
            if v < 0 {
                0
            } else if v > i32::from(max_row) {
                max_row
            } else {
                #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
                let r = v as u16;
                r
            }
        };

        let start_row = to_viewport_row(range.start.line);
        let end_row = to_viewport_row(range.end.line);
        // Column casts are unreachable as truncations: alacritty's
        // grid columns are bounded by the same u16 we passed at
        // `Term::new`. EngineConfig::validate caps cols at u16.
        #[allow(clippy::cast_possible_truncation)]
        let start_col = range.start.column.0 as u16;
        #[allow(clippy::cast_possible_truncation)]
        let end_col = range.end.column.0 as u16;

        Some(SelectionSpan {
            start_row,
            start_col,
            end_row,
            end_col,
            is_block: range.is_block,
        })
    }

    /// Snapshot the current selection's text content as a `String`,
    /// formatted by alacritty's [`Term::selection_to_string`].
    ///
    /// Returns `None` when no selection is active or when the selection
    /// resolves to an empty range (the same conditions under which
    /// [`Self::selection_span`] returns `None`). Multi-row stream
    /// selections are joined with `\n` between rows; trailing whitespace
    /// is stripped per row by alacritty's stringifier — this matches
    /// what users expect to land on the system pasteboard for ⌘C.
    ///
    /// Used by the Swift-side ⌘C handler in M1 task 4.6: read the
    /// string, write to `NSPasteboard.general`, no further translation
    /// needed (terminals copy plain text — rich/HTML copy is M5+ scope).
    /// Block-mode selections (`SelectionRange.is_block == true`) are
    /// handled by alacritty internally, joining each row's substring
    /// with `\n`; today's input surface only emits stream selections
    /// (`Simple` / `Word` / `Line`) so the block path is reserved for
    /// when alt-drag input lands.
    ///
    /// `&self` because the read is non-mutating; safe to interleave
    /// with `feed_input` / `poll_output` / `viewport_cells` /
    /// `selection_span`.
    #[must_use]
    pub fn selection_text(&self) -> Option<String> {
        self.term.selection_to_string()
    }

    /// Convert a viewport-relative `(row, col)` into alacritty's
    /// absolute `Point` (Line counts negative for scrollback). Clamps
    /// to grid bounds so callers can pass arbitrary user-input coords.
    ///
    /// Cast notes — `screen_lines()` and `display_offset()` are
    /// `usize` in alacritty but bounded by our config's u16 row cap +
    /// u32 scrollback cap, so the i32 narrowing here matches the
    /// precedent set by `scroll_top()` (line 754) and the row casts in
    /// `take_damage()`.
    #[allow(clippy::cast_possible_truncation, clippy::cast_possible_wrap)]
    fn viewport_point(&self, row: u16, col: u16) -> Point {
        let cols = self.term.columns();
        let lines = self.term.screen_lines();
        let display_offset = self.term.grid().display_offset() as i32;
        let row_clamped = (row as usize).min(lines.saturating_sub(1)) as i32;
        let col_clamped = (col as usize).min(cols.saturating_sub(1));
        // Viewport row → absolute Line: subtract display_offset so a
        // viewport-row-0 click on a scrolled-up viewport addresses the
        // correct (negative) absolute line.
        let line = Line(row_clamped - display_offset);
        Point::new(line, Column(col_clamped))
    }

    /// Propagate a new viewport size to both the underlying PTY (so
    /// the child process receives `SIGWINCH` and re-renders at the
    /// new dimensions) and `Term` (so the grid + cursor + scrollback
    /// reflect the new shape).
    ///
    /// Validates `rows > 0 && cols > 0` first; the same invariant
    /// from #43 / `EngineConfig::validate` applies here. Surfaces as
    /// `EngineError::Config(EngineConfigError::InvalidGeometry { rows,
    /// cols })`.
    ///
    /// PTY first, then `Term` — so a hypothetical pre-condition
    /// failure on the PTY side leaves `Term` untouched and the engine
    /// in a consistent old-dimensions state. Cell pixel dimensions
    /// (`cell_width` / `cell_height` on `WindowSize`) stay 0 here:
    /// real metrics flow back at task 1.7+ when atlas cell size
    /// propagates from Swift. Programs that care about pixel-precise
    /// sizing (Sixel, kitty +icat) are out of scope at M1.
    ///
    /// Idempotent for unchanged dimensions: alacritty's `Term::resize`
    /// has its own no-op early-return when both dimensions match
    /// (`term/mod.rs:662-665` upstream); the PTY ioctl is also a
    /// trivial no-op when the kernel already holds the same
    /// `winsize`. This makes "Swift sends a resize on every drag
    /// tick" a cheap call pattern.
    ///
    /// **Caveat — kernel-side ioctl failure is not surfaced**:
    /// alacritty's `Pty::on_resize` (`tty/unix.rs:417` upstream)
    /// aborts the process via the `die!` macro if `TIOCSWINSZ`
    /// fails. Our `Result<(), EngineError>` is therefore honest
    /// about validation failures (`Err(EngineError::Config(_))`) but
    /// cannot surface kernel-side ioctl failures — alacritty kills
    /// the process first. The `Result` shape is preserved for
    /// surface symmetry with `feed_input` / `poll_output` and
    /// future-proofs against an upstream non-aborting ioctl path.
    pub fn resize(&mut self, rows: u16, cols: u16) -> Result<(), EngineError> {
        if rows == 0 || cols == 0 {
            return Err(EngineError::Config(EngineConfigError::InvalidGeometry {
                rows,
                cols,
            }));
        }

        self.pty.on_resize(WindowSize {
            num_lines: rows,
            num_cols: cols,
            cell_width: 0,
            cell_height: 0,
        });

        self.term.resize(EngineDimensions {
            rows: rows as usize,
            cols: cols as usize,
        });

        tracing::debug!(rows, cols, "TerminalEngine::resize");

        Ok(())
    }

    /// Snapshot the set of viewport rows damaged since the previous
    /// `take_damage()` call, then reset alacritty's internal damage
    /// tracking. Renderers (eventually Swift via 1.7+'s FFI bridge)
    /// pull this once per frame to know what needs repainting.
    ///
    /// Two-call dance over alacritty's API: `Term::damage()` returns
    /// either `TermDamage::Full` or `TermDamage::Partial(iter)`,
    /// where `iter` borrows `self.term`. We collect the iterator
    /// eagerly into our owned `Vec<u16>` so the borrow ends before we
    /// invoke `Term::reset_damage()` — alacritty does *not* auto-
    /// reset on read (`term/mod.rs:454-456` upstream documents the
    /// caller-must-reset contract).
    ///
    /// Damage state must be drained periodically; alacritty
    /// accumulates per-line bounds across calls and unbounded growth
    /// (e.g. tests that call `feed_input` 1000× without ever calling
    /// `take_damage`) would expand the per-line bounds across the
    /// whole viewport, eventually surfacing as `TermDamage::Full` for
    /// every read. Callers should plan for one `take_damage()` per
    /// frame.
    ///
    /// Returned indices are **viewport-relative** (range
    /// `0..screen_lines`); scrollback rows that scrolled off-screen
    /// are filtered out by alacritty's iterator
    /// (`term/mod.rs:194-199`). Cursor row is re-marked on every
    /// `damage()` call by design (`term/mod.rs:480` upstream — for
    /// blink / shape repaint), so a `Partial(vec![])` only occurs in
    /// extreme edge cases; the typical post-clear state is
    /// `Partial(vec![cursor_row])`.
    ///
    /// `Vec<u16>` cap matches `EngineConfig::validate`'s u16 row
    /// count guarantee (no real terminal hits 65535 rows); the
    /// `bounds.line as u16` cast below is unreachable as a truncation
    /// in practice.
    pub fn take_damage(&mut self) -> DirtyRows {
        let result = match self.term.damage() {
            TermDamage::Full => DirtyRows::Full,
            TermDamage::Partial(iter) => {
                // Iterator borrows `self.term`; collect eagerly so
                // the borrow ends before we call `reset_damage()`.
                //
                // `bounds.line as u16` truncation is unreachable in
                // practice: `EngineConfig::validate` caps rows at
                // u16, and alacritty's row indices are bounded by
                // the same `screen_lines` we passed to `Term::new`.
                // No real terminal hits 65535 rows.
                #[allow(clippy::cast_possible_truncation)]
                let mut rows: Vec<u16> = iter.map(|bounds| bounds.line as u16).collect();
                // Alacritty's per-line storage is row-indexed so the
                // iterator should already be sorted; defensive sort
                // + dedup handles the cursor-damage write at upstream
                // line 480 potentially adding a row that's also in
                // the per-line storage, plus any future upstream
                // ordering-behavior changes.
                rows.sort_unstable();
                rows.dedup();
                DirtyRows::Partial(rows)
            }
        };
        self.term.reset_damage();
        result
    }

    /// Snapshot the cells in the requested viewport row range as a
    /// flat row-major `Vec<CellView>`. Pairs with [`Self::take_damage`]
    /// — `take_damage` says *which* rows changed, `viewport_cells`
    /// returns the actual cell contents for the renderer to repaint.
    ///
    /// Read-only via `&self`: no Term state mutation, so callers can
    /// interleave `viewport_cells` with `feed_input` / `poll_output`
    /// without synchronization. The borrow on `Term` lasts only for
    /// the iteration.
    ///
    /// **Range handling**: silently clamped to
    /// `0..self.screen_lines()`. Out-of-range or inverted ranges
    /// return an empty `Vec`. Out-of-bounds is a caller-side bug, not
    /// a recoverable runtime failure — empty Vec surfaces it loudly
    /// in tests + early integration without forcing every caller
    /// through `Result` propagation.
    ///
    /// **Wide chars**: alacritty stores wide characters as a primary
    /// cell with `Flags::WIDE_CHAR` plus a continuation cell with
    /// `Flags::WIDE_CHAR_SPACER`. We emit only the primary, with
    /// `width = 2`. Callers walk the output and use `width` to
    /// advance; col gaps in the output are unambiguous because
    /// `(row, col)` are explicit on every `CellView`.
    /// `LEADING_WIDE_CHAR_SPACER` (the wrap-line case) is also
    /// skipped — only the primary wide cell at column 0 of the next
    /// line carries the actual character.
    ///
    /// **Output ordering**: row-major (rows ascending, columns
    /// ascending within a row), with continuation cells skipped.
    /// `Vec` capacity is preallocated to `(end - start) * cols` to
    /// avoid reallocations during the inner loop; the actual length
    /// is smaller when wide chars are present.
    ///
    /// Refs: alacritty `term/cell.rs:134` (Cell), `term/cell.rs:15`
    /// (Flags), `term/mod.rs:645` (`Term::grid`), `grid/mod.rs:469`
    /// (`Index<Point>` for Grid).
    #[must_use]
    pub fn viewport_cells(&self, range: Range<u16>) -> Vec<CellView> {
        // `EngineConfig::validate` ensures `screen_lines` fits u16
        // (matches the rows: u16 input); the cast back is unreachable
        // as a truncation in practice.
        #[allow(clippy::cast_possible_truncation)]
        let max_row = self.term.screen_lines() as u16;
        let start = range.start.min(max_row);
        let end = range.end.min(max_row);
        if start >= end {
            return Vec::new();
        }

        let cols = self.term.columns();
        let grid = self.term.grid();
        // `Line(r)` indexes the LIVE viewport — it does NOT incorporate
        // `display_offset`. When the user has scrolled back, alacritty's
        // `display_iter()` starts at `Line(-display_offset - 1)` to walk
        // history; we mirror that by subtracting `display_offset` from
        // each visible row so r=0 (top of viewport) maps into history
        // when `display_offset > 0`. Without this offset, scroll_lines
        // mutates display_offset but the rendered cells stay pinned to
        // the live tail (the scroll-doesn't-work bug).
        // `display_offset` is `usize` upstream; the cast is bounded
        // by `EngineConfig::validate`'s scrollback cap (u32 sub-i32::MAX).
        // Same precedent as the `selection_span` cast at ~line 1600.
        #[allow(clippy::cast_possible_truncation, clippy::cast_possible_wrap)]
        let display_offset = grid.display_offset() as i32;
        let mut out = Vec::with_capacity((end - start) as usize * cols);

        for r in start..end {
            let line = Line(i32::from(r) - display_offset);
            for c in 0..cols {
                let cell = &grid[Point::new(line, Column(c))];
                #[allow(clippy::cast_possible_truncation)]
                let col_u16 = c as u16;
                if let Some(view) = CellView::from_alacritty_cell(r, col_u16, cell) {
                    out.push(view);
                }
            }
        }
        out
    }

    /// M7-1: read the OSC 8 hyperlink URI for the cell at viewport
    /// `(row, col)`. Returns `None` when the row/col is out of range
    /// or the cell has no link annotation.
    ///
    /// Per-call lookup (no per-frame propagation) — keeps `CellDeltaWire`
    /// at 24 bytes/cell. Swift queries this on ⌘+hover hit-testing only,
    /// so the per-cell `Cell::hyperlink()` `Arc` clone is paid at most
    /// once per pointer move.
    #[must_use]
    pub fn hyperlink_at(&self, row: u16, col: u16) -> Option<String> {
        #[allow(clippy::cast_possible_truncation)]
        let max_row = self.term.screen_lines() as u16;
        if row >= max_row {
            return None;
        }
        let cols = self.term.columns();
        if (col as usize) >= cols {
            return None;
        }
        // Translate the viewport row into a grid `Line` by subtracting
        // `display_offset`, matching `viewport_cells`/`viewport_point`.
        // Without this, a ⌘+hover while scrolled into scrollback reads
        // the live-tail row instead of the displayed one.
        #[allow(clippy::cast_possible_truncation, clippy::cast_possible_wrap)]
        let display_offset = self.term.grid().display_offset() as i32;
        let line = Line(i32::from(row) - display_offset);
        let cell = &self.term.grid()[Point::new(line, Column(col as usize))];
        cell.hyperlink().map(|h| h.uri().to_owned())
    }

    /// M7-1: find the contiguous column span on `row` whose cells
    /// share the OSC 8 hyperlink at `(row, anchor_col)`. Returns
    /// `(start_col, span)` for the underline overlay; `None` if the
    /// anchor cell has no link or row/col is out of range.
    ///
    /// Span is computed on the alacritty `Hyperlink` identity (the
    /// upstream `Arc<HyperlinkInner>` — `==` walks `id == id && uri ==
    /// uri`). Adjacent cells of the same link cluster contiguously
    /// because alacritty's `cursor.template.hyperlink` is set on
    /// `OSC 8` open and stamped onto every printed cell until the
    /// closing `\e]8;;\e\\` clears it.
    #[must_use]
    pub fn hyperlink_span(&self, row: u16, anchor_col: u16) -> Option<(u16, u16)> {
        #[allow(clippy::cast_possible_truncation)]
        let max_row = self.term.screen_lines() as u16;
        if row >= max_row {
            return None;
        }
        let cols = self.term.columns();
        if (anchor_col as usize) >= cols {
            return None;
        }
        // Translate the viewport row into a grid `Line` by subtracting
        // `display_offset`, matching `viewport_cells`/`hyperlink_at`, so
        // the span resolves against the displayed row when scrolled into
        // scrollback rather than the live tail.
        #[allow(clippy::cast_possible_truncation, clippy::cast_possible_wrap)]
        let display_offset = self.term.grid().display_offset() as i32;
        let line = Line(i32::from(row) - display_offset);
        let grid = self.term.grid();
        let anchor_link = grid[Point::new(line, Column(anchor_col as usize))].hyperlink()?;

        // Walk left.
        let mut start = anchor_col as usize;
        while start > 0 {
            let prev = &grid[Point::new(line, Column(start - 1))];
            match prev.hyperlink() {
                Some(h) if h == anchor_link => start -= 1,
                _ => break,
            }
        }
        // Walk right.
        let mut end = anchor_col as usize + 1;
        while end < cols {
            let next = &grid[Point::new(line, Column(end))];
            match next.hyperlink() {
                Some(h) if h == anchor_link => end += 1,
                _ => break,
            }
        }
        #[allow(clippy::cast_possible_truncation)]
        let start_u16 = start as u16;
        #[allow(clippy::cast_possible_truncation)]
        let span_u16 = (end - start) as u16;
        Some((start_u16, span_u16))
    }

    /// Internal accessor for the child process's PID. **Not the
    /// stable public API**; the integration test uses it for
    /// diagnostic logging on test failure. Child-exit observability
    /// is now surfaced via [`EngineEvent::ChildExited`] on the
    /// `drain_events` channel (#55), not via this PID accessor.
    #[must_use]
    pub fn child_pid(&self) -> u32 {
        self.pty.child().id()
    }

    /// Internal accessor exposing the master PTY's raw file
    /// descriptor for callers that need to drive their own poll
    /// loop. **Not the stable public API.**
    #[must_use]
    pub fn master_fd(&self) -> i32 {
        self.pty.file().as_fd().as_raw_fd()
    }
}

#[cfg(test)]
mod tests;
