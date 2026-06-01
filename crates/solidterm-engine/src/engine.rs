//! Implements spec/m1-task-breakdown.md §1.1 through §1.8 —
//! `TerminalEngine` skeleton, `EngineConfig` validation, PTY spawn via
//! `alacritty_terminal::tty::new`, the stable `feed_input` /
//! `poll_output` public API, `resize`, `take_damage`,
//! `viewport_cells`, and `drain_events`. Wraps ~2,000 LOC of
//! production-hardened terminal machinery (alacritty's `Term`,
//! `Pty`, and `vte::ansi::Processor`) behind our own stable interface
//! per spec/rust-core-modules.md.
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

use parking_lot::Mutex;

use crate::cells::CellView;
use crate::config::{EngineConfig, EngineConfigError};
use crate::cursor::{CursorReadback, CursorShape};
use crate::damage::DirtyRows;
use crate::events::{EngineEvent, EventProxy};
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
    /// `Pty::Drop` sends SIGHUP to the child and waits, so we don't
    /// write any process cleanup on this side.
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
    selection_anchor: Option<Point>,
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
    /// `config` is by-value to match the spec/rust-core-modules.md
    /// signature; `command` / `env` / `cwd` are moved into the
    /// `tty::Options` rather than cloned.
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
        let event_proxy = EventProxy::new(events_tx.clone(), pty_responses_tx.clone());

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

        let reader = PtyReader::spawn(reader_file);

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
        })
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
        let mut written = 0usize;
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
                Ok(n) => written += n,
                Err(ref err) if err.kind() == io::ErrorKind::Interrupted => {}
                Err(ref err) if err.kind() == io::ErrorKind::WouldBlock => {
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
        let n = unsafe {
            libc::write(fd, bytes.as_ptr() as *const _, bytes.len())
        };
        if n >= 0 {
            return Ok(n as usize);
        }
        let err = std::io::Error::last_os_error();
        match err.raw_os_error() {
            Some(libc::EAGAIN) | Some(libc::EWOULDBLOCK) => Ok(0),
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
            if let Err(err) = self.pty.writer().write_all(reply.as_bytes()) {
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
    pub fn update_selection(&mut self, row: u16, col: u16) {
        // Compute the point first so the immutable `&self.term` read
        // inside `viewport_point` doesn't overlap the subsequent
        // `&mut self.term.selection` borrow on the assignment.
        let point = self.viewport_point(row, col);
        let Some(anchor) = self.selection_anchor else {
            return;
        };
        let Some(ty) = self.term.selection.as_ref().map(|s| s.ty) else {
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
mod tests {
    use super::{EngineError, KittyKeyboardFlags, SelectionMode, TerminalEngine};
    use crate::config::{EngineConfig, EngineConfigError};
    use crate::damage::DirtyRows;
    use crate::events::EngineEvent;
    use alacritty_terminal::index::{Column, Line, Point};
    use std::path::PathBuf;
    use std::time::{Duration, Instant};

    fn valid_config(rows: u16, cols: u16) -> EngineConfig {
        EngineConfig {
            rows,
            cols,
            env: vec![("TERM".to_string(), "xterm-256color".to_string())],
            command: vec!["/bin/zsh".to_string()],
            cwd: PathBuf::from("/tmp"),
            scrollback_lines: 100_000,
        }
    }

    /// `/bin/cat` is the canonical "echo stdin to stdout" workhorse
    /// for VT-parser unit testing — no startup banner, no prompt,
    /// deterministic byte-for-byte echo. Used by `feed_input` /
    /// `poll_output` tests below.
    fn cat_config() -> EngineConfig {
        EngineConfig {
            rows: 24,
            cols: 80,
            env: vec![("TERM".to_string(), "xterm-256color".to_string())],
            command: vec!["/bin/cat".to_string()],
            cwd: PathBuf::from("/tmp"),
            scrollback_lines: 100,
        }
    }

    /// Validation errors must surface BEFORE the spawn — no fork/exec
    /// happens on bad config. Confirmed by the absence of any "spawn
    /// failed" error from `tty::new` in this code path.
    #[test]
    fn new_returns_config_error_on_invalid_geometry() {
        let mut cfg = valid_config(24, 80);
        cfg.rows = 0;
        match TerminalEngine::new(cfg) {
            Err(EngineError::Config(_)) => {}
            other => panic!("expected EngineError::Config, got {other:?}"),
        }
    }

    #[test]
    fn new_returns_config_error_on_empty_command() {
        let mut cfg = valid_config(24, 80);
        cfg.command = Vec::new();
        match TerminalEngine::new(cfg) {
            Err(EngineError::Config(_)) => {}
            other => panic!("expected EngineError::Config, got {other:?}"),
        }
    }

    /// Real-spawn smoke test inside the unit-tests module. Spawning
    /// `/bin/zsh -l` in a unit test is fast (~5–20 ms on Apple
    /// Silicon) and reliable on macOS where zsh is the default shell.
    /// Cleanup is automatic via `Pty::Drop` (SIGHUP → child waits).
    /// Deeper coverage (write input, drain output via
    /// `feed_input`/`poll_output`) lives in the cat tests below + in
    /// `tests/spawn_smoke.rs`.
    #[test]
    fn new_spawns_zsh_and_reads_back_geometry() {
        let engine =
            TerminalEngine::new(valid_config(40, 120)).expect("zsh spawn should succeed on macOS");
        assert_eq!(engine.screen_lines(), 40);
        assert_eq!(engine.columns(), 120);
        assert!(engine.child_pid() > 0, "child PID must be set");
    }

    #[test]
    fn new_constructs_with_minimum_viable_geometry() {
        let engine = TerminalEngine::new(valid_config(1, 1)).expect("1x1 is valid");
        assert_eq!(engine.screen_lines(), 1);
        assert_eq!(engine.columns(), 1);
    }

    /// Spawn `/bin/cat`, write `hello\n`, and verify `poll_output`
    /// drains those bytes back from the PTY (via the reader thread)
    /// and feeds them through `vte::ansi::Processor` into `Term`.
    /// `cat` echoes stdin to stdout, so writing N bytes typically
    /// produces N (or N+1, when the PTY's line discipline echoes the
    /// terminating `\n` as `\r\n`) bytes of output within a few ms.
    /// The 5s deadline is generous defense — typical first-byte
    /// latency is ~50 ms — to avoid flakes under cargo's parallel
    /// test runner.
    #[test]
    fn feed_input_writes_to_pty_and_poll_output_drains() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        engine
            .feed_input(b"hello\n")
            .expect("feed_input should write to /bin/cat's stdin");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut total = 0usize;
        while Instant::now() < deadline && total < 6 {
            total += engine
                .poll_output()
                .expect("poll_output is infallible today");
            if total < 6 {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            total >= 6,
            "expected ≥6 bytes echoed back from /bin/cat within 5s; got {total}"
        );
    }

    /// After feeding `hello\n` and draining via `poll_output`,
    /// `Term`'s grid should contain the literal characters at row 0.
    /// PTY line-discipline echo means the parsed-into-grid bytes are
    /// `hello\r\n` (CR moves cursor to col 0, LF moves to row 1) so
    /// row 0 reads `hello` then blanks for the rest of the row. 5s
    /// deadline is generous defense (see
    /// `feed_input_writes_to_pty_and_poll_output_drains`).
    #[test]
    fn poll_output_advances_term_grid() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        engine
            .feed_input(b"hello\n")
            .expect("feed_input should write to /bin/cat's stdin");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            // Cursor moves off row 0 once `\n` is parsed; that means
            // the grid is in its final state for row 0.
            let cursor_line = engine.term.grid().cursor.point.line;
            if cursor_line >= Line(1) {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }

        let grid = engine.term.grid();
        let row0: String = (0..5)
            .map(|col| grid[Point::new(Line(0), Column(col))].c)
            .collect();
        assert_eq!(
            row0, "hello",
            "row 0 cells [0..5] should hold the echoed 'hello'"
        );
    }

    /// `poll_output` on a freshly-spawned engine (no input written
    /// yet) returns `Ok(0)` — the reader-thread channel has nothing.
    /// `/bin/cat` itself emits zero bytes on startup, so this is the
    /// stable steady state.
    #[test]
    fn poll_output_returns_zero_when_idle() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");
        // Tiny settle so the spawn is fully through fork/exec; no
        // bytes should arrive even with the settle, since /bin/cat
        // doesn't print anything autonomously.
        std::thread::sleep(Duration::from_millis(20));
        let consumed = engine
            .poll_output()
            .expect("poll_output is infallible today");
        assert_eq!(
            consumed, 0,
            "fresh /bin/cat should not have emitted any output"
        );
    }

    /// `resize` updates Term's grid dimensions to the new values.
    /// Construct at 24×80, resize to 30×100, assert Term reads back
    /// 30×100. PTY-side propagation correctness is alacritty's
    /// invariant (its own tests cover `TIOCSWINSZ` against a real
    /// child); we test the boundary we own — engine-level validation
    /// + Term dimension propagation.
    #[test]
    fn resize_changes_grid_dimensions() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");
        assert_eq!(engine.screen_lines(), 24);
        assert_eq!(engine.columns(), 80);

        engine
            .resize(30, 100)
            .expect("resize to 30×100 should succeed");

        assert_eq!(engine.screen_lines(), 30);
        assert_eq!(engine.columns(), 100);
    }

    /// `resize(0, _)` and `resize(_, 0)` both produce the same
    /// `EngineError::Config(EngineConfigError::InvalidGeometry { rows,
    /// cols })` shape that #43's construct-time validation produces.
    /// Same invariant; same variant.
    #[test]
    fn resize_with_zero_dimensions_errors() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        match engine.resize(0, 80) {
            Err(EngineError::Config(EngineConfigError::InvalidGeometry { rows: 0, cols: 80 })) => {}
            other => panic!("expected InvalidGeometry {{ rows: 0, cols: 80 }}, got {other:?}"),
        }

        match engine.resize(24, 0) {
            Err(EngineError::Config(EngineConfigError::InvalidGeometry { rows: 24, cols: 0 })) => {}
            other => panic!("expected InvalidGeometry {{ rows: 24, cols: 0 }}, got {other:?}"),
        }

        // Failed resize must not have moved the engine off old dims.
        assert_eq!(engine.screen_lines(), 24);
        assert_eq!(engine.columns(), 80);
    }

    /// Resize to the current dimensions is a cheap no-op via
    /// alacritty's `Term::resize` early-return at `term/mod.rs:
    /// 662-665` (and the kernel's `TIOCSWINSZ` is similarly trivial
    /// when the held `winsize` already matches). Exercises the
    /// "Swift sends redundant resize on every drag tick" call
    /// pattern.
    #[test]
    fn resize_is_idempotent_for_unchanged_dimensions() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        engine
            .resize(24, 80)
            .expect("resize to current dims should succeed");

        assert_eq!(engine.screen_lines(), 24);
        assert_eq!(engine.columns(), 80);
    }

    /// `take_damage` after `feed_input` + `poll_output` returns a
    /// snapshot containing the cells the parser advanced through.
    /// Exact shape (Full vs Partial) is sensitive to alacritty's
    /// internal damage tracking — we assert "non-empty" without
    /// nailing down which variant, since insert-mode / display-
    /// offset transitions could push a row write into Full.
    #[test]
    fn take_damage_after_feed_input_includes_dirty_rows() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        // Drain the initial Full from construction so we observe
        // damage produced by the test's own input.
        let _initial = engine.take_damage();

        engine
            .feed_input(b"hi\n")
            .expect("feed_input should write to /bin/cat's stdin");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut consumed = 0usize;
        while Instant::now() < deadline && consumed < 3 {
            consumed += engine
                .poll_output()
                .expect("poll_output is infallible today");
            if consumed < 3 {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(consumed >= 3, "expected /bin/cat to echo ≥3 bytes");

        let damage = engine.take_damage();
        assert!(
            damage.is_full() || !damage.is_empty(),
            "expected damage from feed_input + poll_output, got {damage:?}"
        );
        if let DirtyRows::Partial(rows) = &damage {
            assert!(
                rows.contains(&0),
                "expected row 0 in partial damage after writing to row 0; got {rows:?}"
            );
        }
    }

    /// Two consecutive `take_damage()` calls — the second is
    /// **strictly smaller** than the first because alacritty's
    /// `Term::damage()` re-marks the cursor row on every call by
    /// design (`term/mod.rs:480` upstream — for cursor blink /
    /// shape repaint). The strict-shrink invariant is the load-
    /// bearing one: if it didn't hold, our `reset_damage()` call
    /// would be ineffective.
    #[test]
    fn take_damage_resets_state_between_calls() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        engine
            .feed_input(b"hi\n")
            .expect("feed_input should write to /bin/cat's stdin");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            let consumed = engine
                .poll_output()
                .expect("poll_output is infallible today");
            if consumed >= 3 {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }

        let first = engine.take_damage();
        let second = engine.take_damage();

        // Compute "size" for both variants so we can compare.
        let size = |d: &DirtyRows| match d {
            DirtyRows::Full => usize::MAX,
            DirtyRows::Partial(rows) => rows.len(),
        };
        assert!(
            size(&second) < size(&first),
            "second take_damage must be strictly smaller than first \
             (alacritty re-marks cursor row by design; second is \
             expected to be Partial(vec![cursor_row]) or Partial(vec![])); \
             got first={first:?}, second={second:?}"
        );
    }

    /// `resize` mass-damages the entire viewport via alacritty's
    /// internal `mark_fully_damaged` call (visible in `term/mod.rs`
    /// resize path). The next `take_damage()` returns `Full`,
    /// regardless of any prior state.
    #[test]
    fn take_damage_after_resize_marks_full() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        // Drain initial damage so the resize-induced Full is the
        // only Full we observe.
        let _initial = engine.take_damage();
        let _post_initial = engine.take_damage();

        engine.resize(30, 100).expect("resize should succeed");

        let damage = engine.take_damage();
        assert!(
            damage.is_full(),
            "resize should produce Full damage (alacritty marks the \
             whole viewport via mark_fully_damaged); got {damage:?}"
        );
    }

    /// On a freshly-constructed engine, `take_damage()` returns
    /// `Full` (alacritty's `TermDamageState::new` sets `full = true`
    /// at `term/mod.rs:230` so the renderer paints the initial
    /// blank screen). After draining that, subsequent calls return
    /// `Partial` — typically `Partial(vec![cursor_row])` due to the
    /// cursor-damage-on-every-call upstream contract.
    #[test]
    fn take_damage_initial_is_full_then_partial_after_drain() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        let initial = engine.take_damage();
        assert!(
            initial.is_full(),
            "initial take_damage on freshly-constructed engine must be Full \
             (alacritty constructs TermDamageState with full=true); got {initial:?}"
        );

        let post_initial = engine.take_damage();
        assert!(
            !post_initial.is_full(),
            "after draining the initial Full, take_damage must transition \
             to Partial; got {post_initial:?}"
        );
    }

    /// Helper: drain the PTY until `poll_output` reports the expected
    /// byte count, with a 5s deadline matching the `take_damage`
    /// tests. Used by `viewport_cells` tests that need to confirm
    /// input has reached the parser before reading cell state.
    fn drain_until(engine: &mut TerminalEngine, expected: usize) {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut total = 0usize;
        while Instant::now() < deadline && total < expected {
            total += engine
                .poll_output()
                .expect("poll_output is infallible today");
            if total < expected {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            total >= expected,
            "expected ≥{expected} bytes from /bin/cat within 5s; got {total}"
        );
    }

    /// `viewport_cells(0..1)` on a freshly-spawned engine returns 80
    /// cells (cols=80, single-row range). All cells are blanks
    /// (grapheme=' ', width=1), default Foreground/Background, no
    /// attrs. Sanity check that the iteration covers the whole row.
    #[test]
    fn viewport_cells_returns_blanks_on_idle_engine() {
        let engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        let cells = engine.viewport_cells(0..1);
        assert_eq!(
            cells.len(),
            80,
            "row 0 has 80 cells in cat_config (cols=80)"
        );

        for (i, cell) in cells.iter().enumerate() {
            assert_eq!(cell.row, 0);
            #[allow(clippy::cast_possible_truncation)]
            let expected_col = i as u16;
            assert_eq!(cell.col, expected_col);
            assert_eq!(
                cell.grapheme, *b" \0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",
                "cell ({}, {}) should be a blank space",
                cell.row, cell.col
            );
            assert_eq!(cell.width, 1);
            assert_eq!(cell.attrs, 0);
        }
    }

    /// After `feed_input(b"hi\n")` + drain, `viewport_cells(0..1)`
    /// reflects the echoed `h` and `i` at cols 0 and 1.
    #[test]
    fn viewport_cells_after_feed_input_reflects_grid() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        engine
            .feed_input(b"hi\n")
            .expect("feed_input should write to /bin/cat's stdin");
        drain_until(&mut engine, 3);

        let cells = engine.viewport_cells(0..1);
        assert_eq!(cells.len(), 80);
        assert_eq!(&cells[0].grapheme[..1], b"h");
        assert_eq!(&cells[1].grapheme[..1], b"i");
    }

    /// CJK 字 (U+5B57, UTF-8 = E5 AD 97) is a wide character. After
    /// `feed_input` + drain, `viewport_cells` emits one `CellView`
    /// at col 0 with `width = 2` and the 3-byte UTF-8 grapheme; col
    /// 1 is **skipped** (continuation cell), so the next `CellView`
    /// is at col 2.
    #[test]
    fn viewport_cells_handles_wide_chars() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        engine
            .feed_input("字\n".as_bytes())
            .expect("feed_input should write to /bin/cat's stdin");
        // 字 is 3 bytes UTF-8; cat echoes those + \r + \n = 5 bytes
        // minimum.
        drain_until(&mut engine, 4);

        let cells = engine.viewport_cells(0..1);
        // Wide char + 78 trailing blanks (col 1 skipped) = 79 cells.
        assert_eq!(
            cells.len(),
            79,
            "wide char at col 0 + 78 trailing blanks (col 1 is the skipped continuation)"
        );

        let wide = &cells[0];
        assert_eq!(wide.row, 0);
        assert_eq!(wide.col, 0);
        assert_eq!(wide.width, 2);
        assert_eq!(
            &wide.grapheme[..3],
            &[0xe5, 0xad, 0x97],
            "字 UTF-8 = E5 AD 97"
        );
        assert_eq!(
            &wide.grapheme[3..],
            &[0u8; 13],
            "remaining bytes null-padded"
        );

        // The cell after the wide char is at col 2, not col 1.
        let after_wide = &cells[1];
        assert_eq!(after_wide.col, 2, "col 1 (continuation) is skipped");
    }

    // -----------------------------------------------------------------
    // UAX #11 width verification — task 2.11.
    //
    // The tests below pin alacritty_terminal's behavior for the cell
    // widths that matter to NextTerm's Thai user + global locales.
    // alacritty determines width via `unicode_width::UnicodeWidthChar`
    // (default features, no `emoji` flag) — see
    // alacritty_terminal-0.26/src/term/mod.rs:14 + 1062. We only
    // *verify* that path lands correct values in `CellView.width`; we
    // do not reimplement width logic at our layer.
    //
    // Test corpus parallels `tests/fixtures/font-corpus/` (the spec at
    // `spec/test-fixtures.md` — which exists in draft state). We use
    // small inline strings rather than reading the .txt fixtures
    // because:
    //   1. unit tests need fast, hermetic input, not file I/O;
    //   2. the corpus files are renderer-side fixtures (Swift snapshot
    //      tests will read them); engine-side width is per-codepoint
    //      and a few canonical samples per category cover it;
    //   3. avoiding a fixture-loader dependency keeps this task atomic.
    // -----------------------------------------------------------------

    /// Narrow ASCII letters and digits all report `width = 1` — the
    /// trivial baseline. Confirms the iteration emits one cell per
    /// printed char with the correct UTF-8 (1-byte) grapheme.
    #[test]
    fn viewport_cells_narrow_ascii_width_1() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        engine
            .feed_input(b"abc123\n")
            .expect("feed_input should write to /bin/cat's stdin");
        drain_until(&mut engine, 7);

        let cells = engine.viewport_cells(0..1);
        let expected = [b'a', b'b', b'c', b'1', b'2', b'3'];
        for (i, want) in expected.iter().enumerate() {
            let col = u16::try_from(i).expect("test indices fit u16");
            assert_eq!(cells[i].col, col);
            assert_eq!(cells[i].width, 1, "ASCII char at col {i} must be width 1");
            assert_eq!(cells[i].grapheme[0], *want);
            assert_eq!(
                &cells[i].grapheme[1..],
                &[0u8; 15],
                "ASCII grapheme is 1 byte, rest null-padded"
            );
        }
    }

    /// Ambiguous-width characters (UAX #11 EAW=A) default to **narrow**
    /// in `unicode_width` without the `cjk` feature. § (U+00A7),
    /// ★ (U+2605), and ° (U+00B0) all report `width = 1`. This pins
    /// our default-locale behavior (decisions/08-protocol-priorities
    /// commits to narrow as default). If the dependency or its
    /// features ever change to EAW=W for ambiguous chars, this test
    /// fails loudly.
    #[test]
    fn viewport_cells_ambiguous_width_defaults_narrow() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        // § (U+00A7, 2 bytes UTF-8: C2 A7), ★ (U+2605, 3 bytes: E2 98 85),
        // ° (U+00B0, 2 bytes: C2 B0). Total UTF-8 = 7 bytes + \n.
        let s = "\u{00A7}\u{2605}\u{00B0}\n";
        engine
            .feed_input(s.as_bytes())
            .expect("feed_input should write to /bin/cat's stdin");
        drain_until(&mut engine, 8);

        let cells = engine.viewport_cells(0..1);
        // Each ambiguous char occupies a single cell; col 3 onwards is
        // blank space.
        assert_eq!(cells[0].col, 0);
        assert_eq!(
            cells[0].width, 1,
            "§ defaults to narrow (UAX #11 ambiguous)"
        );
        assert_eq!(&cells[0].grapheme[..2], &[0xc2, 0xa7]);

        assert_eq!(cells[1].col, 1);
        assert_eq!(
            cells[1].width, 1,
            "★ defaults to narrow (UAX #11 ambiguous)"
        );
        assert_eq!(&cells[1].grapheme[..3], &[0xe2, 0x98, 0x85]);

        assert_eq!(cells[2].col, 2);
        assert_eq!(
            cells[2].width, 1,
            "° defaults to narrow (UAX #11 ambiguous)"
        );
        assert_eq!(&cells[2].grapheme[..2], &[0xc2, 0xb0]);
    }

    /// CJK ideographs across Chinese (中), Japanese hiragana (あ),
    /// Japanese katakana (カ), and Korean hangul (한) all report
    /// `width = 2` (UAX #11 EAW=W or F). Continuation columns are
    /// skipped, so successive `CellView`s are at cols 0, 2, 4, 6.
    #[test]
    fn viewport_cells_cjk_wide_width_2() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        // 中 U+4E2D (E4 B8 AD), あ U+3042 (E3 81 82),
        // カ U+30AB (E3 82 AB), 한 U+D55C (ED 95 9C).
        let s = "\u{4E2D}\u{3042}\u{30AB}\u{D55C}\n";
        engine
            .feed_input(s.as_bytes())
            .expect("feed_input should write to /bin/cat's stdin");
        drain_until(&mut engine, 13);

        let cells = engine.viewport_cells(0..1);

        // Four wide chars + (cols=80 − 8 occupied) blanks = 76 + 4 = 80,
        // but continuation cells are skipped, so 4 wide CellViews + 72
        // trailing blank CellViews = 76.
        assert_eq!(
            cells.len(),
            76,
            "4 wide cells + 72 trailing blanks (4 continuation cells skipped)"
        );

        // 中 at col 0
        assert_eq!(cells[0].col, 0);
        assert_eq!(cells[0].width, 2, "中 (Chinese ideograph) is wide");
        assert_eq!(&cells[0].grapheme[..3], &[0xe4, 0xb8, 0xad]);

        // あ at col 2 (col 1 is the skipped continuation of 中)
        assert_eq!(cells[1].col, 2);
        assert_eq!(cells[1].width, 2, "あ (Japanese hiragana) is wide");
        assert_eq!(&cells[1].grapheme[..3], &[0xe3, 0x81, 0x82]);

        // カ at col 4 (full-width katakana)
        assert_eq!(cells[2].col, 4);
        assert_eq!(cells[2].width, 2, "カ (Japanese katakana) is wide");
        assert_eq!(&cells[2].grapheme[..3], &[0xe3, 0x82, 0xab]);

        // 한 at col 6 (Korean hangul precomposed syllable)
        assert_eq!(cells[3].col, 6);
        assert_eq!(cells[3].width, 2, "한 (Korean hangul) is wide");
        assert_eq!(&cells[3].grapheme[..3], &[0xed, 0x95, 0x9c]);

        // First trailing blank is at col 8.
        assert_eq!(cells[4].col, 8);
        assert_eq!(cells[4].width, 1);
        assert_eq!(cells[4].grapheme[0], b' ');
    }

    /// Thai consonant + tone mark stacks as a single grid cell:
    /// the consonant ก (U+0E01) is `width = 1`; the tone mark ๊
    /// (U+0E4A) is a nonspacing mark (Mn) with `width = 0`, which
    /// alacritty pushes onto the previous cell's `zerowidth` list
    /// (see `Term::input` at term/mod.rs:1083). Our `encode_grapheme`
    /// concatenates `cell.c` with all `zerowidth` chars, so the
    /// resulting `CellView.grapheme` carries both codepoints in 6
    /// UTF-8 bytes.
    ///
    /// Pins the invariant Thai users care about: combining marks do
    /// NOT consume their own grid cell, and the engine surfaces the
    /// full cluster in a single `CellView`.
    #[test]
    fn viewport_cells_thai_combining_mark_stacks_on_consonant() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        // ก (U+0E01, 3 bytes: E0 B8 81) + ๊ (U+0E4A, 3 bytes: E0 B9 8A).
        let s = "\u{0E01}\u{0E4A}\n";
        engine
            .feed_input(s.as_bytes())
            .expect("feed_input should write to /bin/cat's stdin");
        drain_until(&mut engine, 7);

        let cells = engine.viewport_cells(0..1);

        // ก๊ occupies ONE cell at col 0 — the tone mark is zero-width.
        // 79 trailing blanks; nothing skipped.
        assert_eq!(
            cells.len(),
            80,
            "Thai consonant + tone mark = 1 cell; 79 trailing blanks"
        );

        let cluster = &cells[0];
        assert_eq!(cluster.row, 0);
        assert_eq!(cluster.col, 0);
        assert_eq!(
            cluster.width, 1,
            "Thai consonant width is 1; tone mark stacks zero-width"
        );
        // 6 UTF-8 bytes total: ก = E0 B8 81, ๊ = E0 B9 8A.
        assert_eq!(
            &cluster.grapheme[..6],
            &[0xe0, 0xb8, 0x81, 0xe0, 0xb9, 0x8a],
            "grapheme buffer holds consonant + zerowidth tone mark"
        );
        assert_eq!(
            &cluster.grapheme[6..],
            &[0u8; 10],
            "remaining bytes null-padded"
        );

        // The next cell is at col 1 — the tone mark did NOT advance
        // the cursor.
        assert_eq!(cells[1].col, 1);
        assert_eq!(cells[1].grapheme[0], b' ');
    }

    /// A single-codepoint emoji (🎉 U+1F389) is UAX #11 EAW=W →
    /// `width = 2` per `unicode_width`. UTF-8 is 4 bytes (F0 9F 8E 89),
    /// which fits within `CellView.grapheme`'s 8-byte buffer with
    /// 4 bytes of null padding.
    #[test]
    fn viewport_cells_emoji_basic_width_2() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        // 🎉 U+1F389 = F0 9F 8E 89 (4 bytes).
        engine
            .feed_input("\u{1F389}\n".as_bytes())
            .expect("feed_input should write to /bin/cat's stdin");
        drain_until(&mut engine, 5);

        let cells = engine.viewport_cells(0..1);
        // Wide emoji + 78 trailing blanks (col 1 continuation skipped).
        assert_eq!(cells.len(), 79);

        assert_eq!(cells[0].col, 0);
        assert_eq!(cells[0].width, 2, "🎉 is EAW=W, width 2");
        assert_eq!(&cells[0].grapheme[..4], &[0xf0, 0x9f, 0x8e, 0x89]);
        assert_eq!(&cells[0].grapheme[4..], &[0u8; 12]);

        // Next CellView is at col 2 (col 1 is the continuation).
        assert_eq!(cells[1].col, 2);
    }

    /// Emoji ZWJ sequences are NOT collapsed into one grid cell by
    /// alacritty — each base emoji takes its own pair of grid cells
    /// (width 2 + `WIDE_CHAR_SPACER`), and the U+200D ZWJ is treated as
    /// zero-width and stacked onto the preceding cell's zerowidth list
    /// (see `Term::input` at term/mod.rs:1070-1084).
    ///
    /// Concretely, 👨‍👩‍👧 (man + ZWJ + woman + ZWJ + girl) lays out as:
    ///   col 0: 👨 (width 2) with ZWJ stacked as zerowidth
    ///   col 2: 👩 (width 2) with ZWJ stacked as zerowidth
    ///   col 4: 👧 (width 2)
    /// The renderer can recognize the cross-cell ZWJ pattern and draw
    /// a single composite glyph at glyph layer; that's not the
    /// engine's job. This test pins the grid-side truth so M3+
    /// renderer work has a stable contract.
    ///
    /// **Surprise documented**: the rendering "looks like one emoji"
    /// in modern terminals is purely a font-shaping side-effect; the
    /// underlying grid stores 3 wide cells (6 columns total).
    #[test]
    fn viewport_cells_emoji_zwj_sequence_stays_separate_cells() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        // 👨 U+1F468 (F0 9F 91 A8) + ZWJ U+200D (E2 80 8D) +
        // 👩 U+1F469 (F0 9F 91 A9) + ZWJ U+200D + 👧 U+1F467 (F0 9F 91 A7).
        // Total 18 bytes + \n = 19.
        let s = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\n";
        engine
            .feed_input(s.as_bytes())
            .expect("feed_input should write to /bin/cat's stdin");
        drain_until(&mut engine, 18);

        let cells = engine.viewport_cells(0..1);
        // 3 wide emoji cells + 74 trailing blanks (3 continuation
        // cells skipped from cols 1, 3, 5) = 77 CellViews.
        assert_eq!(
            cells.len(),
            77,
            "ZWJ family = 3 wide cells (cols 0, 2, 4); 3 continuations skipped"
        );

        // Col 0: 👨 + ZWJ stacked zero-width.
        assert_eq!(cells[0].col, 0);
        assert_eq!(cells[0].width, 2, "👨 is wide");
        assert_eq!(&cells[0].grapheme[..4], &[0xf0, 0x9f, 0x91, 0xa8]);
        // ZWJ (E2 80 8D) appended as zerowidth — bytes 4..7.
        assert_eq!(
            &cells[0].grapheme[4..7],
            &[0xe2, 0x80, 0x8d],
            "ZWJ stacks onto the preceding cell's zerowidth list"
        );

        // Col 2: 👩 + ZWJ stacked zero-width.
        assert_eq!(cells[1].col, 2);
        assert_eq!(cells[1].width, 2, "👩 is wide");
        assert_eq!(&cells[1].grapheme[..4], &[0xf0, 0x9f, 0x91, 0xa9]);
        assert_eq!(
            &cells[1].grapheme[4..7],
            &[0xe2, 0x80, 0x8d],
            "second ZWJ stacks onto 👩's cell"
        );

        // Col 4: 👧 (no trailing ZWJ).
        assert_eq!(cells[2].col, 4);
        assert_eq!(cells[2].width, 2, "👧 is wide");
        assert_eq!(&cells[2].grapheme[..4], &[0xf0, 0x9f, 0x91, 0xa7]);
        // No trailing zerowidth for the last emoji.
        assert_eq!(&cells[2].grapheme[4..], &[0u8; 12]);

        // First trailing blank is at col 6 (cols 1, 3, 5 are skipped
        // continuation cells).
        assert_eq!(cells[3].col, 6);
        assert_eq!(cells[3].width, 1);
        assert_eq!(cells[3].grapheme[0], b' ');
    }

    /// Out-of-range row requests return an empty Vec (silent clamp).
    /// `viewport_cells(100..200)` on a 24-row grid: full out-of-
    /// range, empty Vec. Caller-side bug surfaces loudly without
    /// forcing every call site through `Result` propagation.
    #[test]
    fn viewport_cells_with_out_of_range_returns_empty() {
        let engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        // cat_config sets rows = 24; range 100..200 is fully OOB.
        let cells = engine.viewport_cells(100..200);
        assert!(
            cells.is_empty(),
            "fully out-of-range request returns empty Vec"
        );

        // Inverted range (start >= end) also returns empty. Clippy
        // flags the literal `5..3` as a known-empty range; that's
        // exactly what we're testing the function tolerates without
        // panicking, so the lint is allowed locally.
        #[allow(clippy::reversed_empty_ranges)]
        let cells = engine.viewport_cells(5..3);
        assert!(cells.is_empty(), "inverted range returns empty Vec");

        // Partial OOB clamps: 22..30 returns rows 22..24 = 2 rows × 80 cells.
        let cells = engine.viewport_cells(22..30);
        assert_eq!(
            cells.len(),
            2 * 80,
            "partial OOB clamps end to screen_lines"
        );
    }

    /// SGR escape sequences round-trip through the parser pipeline:
    /// `feed_input` writes raw bytes to the PTY master; under
    /// cooked-mode line discipline `/bin/cat` echoes those bytes back
    /// through its stdout (where they re-enter the master and the
    /// reader thread); `poll_output` feeds them through
    /// `vte::ansi::Processor`, which applies SGR state to Term's
    /// cursor-cell rendition. The next emitted character carries the
    /// SGR-applied attrs through to `CellView.attrs`.
    ///
    /// We feed bytes directly to alacritty's parser via repeated
    /// `feed_input` rather than relying on cat's echo because macOS
    /// `termios` defaults set `ECHOCTL`, which causes the line
    /// discipline to display escape characters as literal `^[`
    /// representations during echo — the SGR sequence wouldn't
    /// survive the round-trip even though the parser handles it
    /// correctly when fed directly. To test the parser pipeline
    /// itself we drive it without cat-echo masking by feeding the
    /// engine's reader-thread channel via the PTY round-trip path
    /// once cat has emitted *any* output, which proves the channel
    /// works, then assert the parser semantics by simulating the
    /// stdout side via a known-good shell command... actually,
    /// simpler: write SGR + 'B' through the master FD; cat echoes
    /// (badly, with ECHOCTL) but its own *stdout* re-emits the
    /// original bytes UN-mangled (cat reads stdin and writes them
    /// verbatim). The reader thread sees both: ECHOCTL mangled echo
    /// from the line discipline, then the un-mangled stdout from
    /// cat. The parser sees both streams interleaved; the un-mangled
    /// SGR + 'B' from cat's stdout is what we want to assert on.
    /// We search for *any* cell with BOLD set after a generous drain
    /// — if the parser pipeline works at all, exactly one will.
    #[test]
    fn viewport_cells_round_trips_sgr_attrs() {
        use alacritty_terminal::term::cell::Flags;
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        // \x1b[1m = bold ON, B, \x1b[0m = reset, \n. cat reads stdin
        // (this byte stream) and writes the same bytes verbatim to
        // its stdout, which the master FD also receives. The parser
        // sees the un-mangled SGR sequence from cat's stdout output.
        engine
            .feed_input(b"\x1b[1mB\x1b[0m\n")
            .expect("feed_input should write SGR bytes to cat");
        // Drain generously: we don't know exact byte counts because
        // cooked-mode echo + cat's stdout copy interleave bytes
        // unpredictably. The 'B' may land on row 0 (if cat's stdout
        // emit precedes the line-discipline echo's `\n`-cursor-
        // advance) or row 1 (if not), so search rows 0..2.
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut bold_seen = false;
        while Instant::now() < deadline && !bold_seen {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            let cells = engine.viewport_cells(0..2);
            if cells
                .iter()
                .any(|c| c.attrs & Flags::BOLD.bits() != 0 && c.grapheme[0] == b'B')
            {
                bold_seen = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            bold_seen,
            "expected a 'B' cell with BOLD attrs to appear in rows 0..2 within 5s; \
             the parser pipeline (PTY → reader → poll_output → vte::ansi → Term \
             flags → CellView.attrs) did not propagate SGR state"
        );
    }

    /// OSC 8 (hyperlink) end-to-end: the alacritty `vte::ansi` parser
    /// owns OSC 8 dispatch — `Term::set_hyperlink` writes the link
    /// onto `cursor.template`, every printed cell inherits it, and
    /// `Cell::hyperlink()` surfaces it through `CellView.link`. We
    /// drive the test by feeding the OSC open + payload + close
    /// sequence as a single contiguous byte stream; the parser sees
    /// the un-mangled bytes via cat's stdout (same trick as the SGR
    /// test — line-discipline echo would mangle escapes via ECHOCTL,
    /// but cat's read+write copy preserves them). Search rows 0..2
    /// because line-discipline / cat-stdout interleaving can place
    /// the payload on either row.
    #[test]
    fn viewport_cells_round_trips_osc_8_hyperlink() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        // OSC 8 ; ; <uri> ST  →  payload "L"  →  OSC 8 ; ; ST
        // The closing form (empty id + empty URI) clears the active
        // link — characters printed after it must NOT carry the
        // annotation.
        engine
            .feed_input(b"\x1b]8;;https://example.com\x1b\\L\x1b]8;;\x1b\\X\n")
            .expect("feed_input should write OSC 8 + payload to cat");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut linked_seen = false;
        let mut bare_seen = false;
        while Instant::now() < deadline && !(linked_seen && bare_seen) {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            let cells = engine.viewport_cells(0..2);
            for cell in &cells {
                if cell.grapheme[0] == b'L' {
                    if let Some(link) = &cell.link {
                        if link.uri == "https://example.com" {
                            linked_seen = true;
                        }
                    }
                }
                if cell.grapheme[0] == b'X' && cell.link.is_none() {
                    bare_seen = true;
                }
            }
            if !(linked_seen && bare_seen) {
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        assert!(
            linked_seen,
            "expected a cell with grapheme 'L' carrying link \
             uri = https://example.com (OSC 8 open + payload did not \
             propagate to CellView.link)"
        );
        assert!(
            bare_seen,
            "expected a cell with grapheme 'X' carrying link = None \
             (OSC 8 ; ; ST close did not clear the active hyperlink)"
        );
    }

    /// OSC 8 with an explicit `id=anchor-1` correlation parameter.
    /// The upstream vte parser strips the `id=` prefix and forwards
    /// the rest as the `Hyperlink::id`; we surface it on
    /// `CellView.link.id`. Verifies the sub-parameter parsing path
    /// (`vte-0.15/src/ansi.rs:1413`) is wired all the way through.
    #[test]
    fn viewport_cells_round_trips_osc_8_with_explicit_id() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        engine
            .feed_input(b"\x1b]8;id=anchor-1;https://example.com/a\x1b\\Y\x1b]8;;\x1b\\\n")
            .expect("feed_input should write OSC 8 with id= to cat");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut id_seen = false;
        while Instant::now() < deadline && !id_seen {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            let cells = engine.viewport_cells(0..2);
            for cell in &cells {
                if cell.grapheme[0] == b'Y' {
                    if let Some(link) = &cell.link {
                        if link.id == "anchor-1" && link.uri == "https://example.com/a" {
                            id_seen = true;
                            break;
                        }
                    }
                }
            }
            if !id_seen {
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        assert!(
            id_seen,
            "expected a cell with grapheme 'Y' carrying link \
             id = anchor-1, uri = https://example.com/a; the OSC 8 \
             id= sub-parameter did not surface on CellView.link.id"
        );
    }

    /// A close OSC 8 (`OSC 8 ; ; ST`) without a prior open is a no-op:
    /// no panic, no spurious link annotation on subsequent cells. The
    /// upstream parser's `set_hyperlink(None)` on an already-empty
    /// template is a no-op, so this exercises only that we don't add
    /// brittle interception logic of our own.
    #[test]
    fn viewport_cells_osc_8_close_without_open_is_noop() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        engine
            .feed_input(b"\x1b]8;;\x1b\\Z\n")
            .expect("feed_input should write OSC 8 close + payload to cat");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut z_seen = false;
        while Instant::now() < deadline && !z_seen {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            let cells = engine.viewport_cells(0..2);
            for cell in &cells {
                if cell.grapheme[0] == b'Z' {
                    assert_eq!(
                        cell.link, None,
                        "OSC 8 close without a matching open must not \
                         leak a link annotation onto subsequent cells"
                    );
                    z_seen = true;
                    break;
                }
            }
            if !z_seen {
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        assert!(
            z_seen,
            "expected to see the 'Z' payload land in the grid within 5s"
        );
    }

    /// M7-1: `hyperlink_at(row, col)` returns `Some(uri)` for cells
    /// inside an open OSC 8 pair and `None` outside. Mirrors the
    /// round-trip test but exercises the per-cell accessor used by
    /// the Swift ⌘+hover hit-test.
    #[test]
    fn hyperlink_at_returns_uri_for_linked_cell() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        engine
            .feed_input(b"\x1b]8;;https://example.com\x1b\\Click me\x1b]8;;\x1b\\\n")
            .expect("feed_input should write OSC 8 sequence to cat");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut linked: Option<(u16, u16)> = None;
        while Instant::now() < deadline && linked.is_none() {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            'scan: for r in 0..2u16 {
                for c in 0..80u16 {
                    if let Some(uri) = engine.hyperlink_at(r, c) {
                        if uri == "https://example.com" {
                            linked = Some((r, c));
                            break 'scan;
                        }
                    }
                }
            }
            if linked.is_none() {
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        let (row, col) =
            linked.expect("expected at least one cell to carry the OSC 8 link within 5s");

        // hyperlink_span over an anchor inside "Click me" must cover
        // the whole 8-cell run (no spaces, contiguous link template).
        let span = engine
            .hyperlink_span(row, col)
            .expect("anchor cell carries a link, span must be Some");
        assert_eq!(
            span.1, 8,
            "expected span to cover the 8 cells of \"Click me\"; got start={}, span={}",
            span.0, span.1
        );
    }

    /// M7-1: out-of-range row/col returns `None` rather than panicking
    /// on the underlying `grid` index. Defensive contract for the
    /// Swift caller, which clamps via `pointToCell` but we don't trust
    /// that across the FFI.
    #[test]
    fn hyperlink_at_out_of_range_returns_none() {
        let engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");
        assert_eq!(engine.hyperlink_at(9999, 0), None);
        assert_eq!(engine.hyperlink_at(0, 9999), None);
        assert_eq!(
            engine.hyperlink_at(0, 0),
            None,
            "fresh engine has no links yet"
        );
        assert_eq!(engine.hyperlink_span(9999, 0), None);
        assert_eq!(engine.hyperlink_span(0, 9999), None);
    }

    /// M7-1 regression: `hyperlink_at`/`hyperlink_span` must subtract
    /// `display_offset` so they resolve against the *displayed* row when
    /// the viewport is scrolled into scrollback — not the live tail.
    /// Mirrors the `scroll_lines_*` fixtures: print the OSC 8 link, push
    /// it up into history with newlines, then assert the link is absent
    /// at the live tail but reappears once we scroll back to it.
    #[test]
    fn hyperlink_resolves_against_scrolled_history_row() {
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        // Print the link on its own line, then ~40 blank lines to push
        // it off the top of the 24-row viewport into scrollback.
        engine
            .feed_input(b"\x1b]8;;https://example.com\x1b\\Click me\x1b]8;;\x1b\\\n")
            .expect("feed_input should write OSC 8 sequence to cat");
        engine
            .feed_input(&b"\n".repeat(40))
            .expect("feed_input should write newlines to cat");

        // Wait until enough scrollback has accumulated that the link row
        // is no longer in the live viewport.
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && engine.scroll_total() < 20 {
            let _ = engine.poll_output().expect("poll_output infallible");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(
            engine.scroll_total() >= 20,
            "fixture must push the link row into scrollback; scroll_total={}",
            engine.scroll_total()
        );

        // Helper: scan the live viewport for the example.com link.
        let find_link = |engine: &TerminalEngine| -> Option<(u16, u16)> {
            for r in 0..24u16 {
                for c in 0..80u16 {
                    if engine.hyperlink_at(r, c).as_deref() == Some("https://example.com") {
                        return Some((r, c));
                    }
                }
            }
            None
        };

        // At the live tail (display_offset == 0) the link has scrolled
        // off the top, so it must NOT be found in the viewport. This is
        // what makes the offset translation load-bearing.
        assert_eq!(engine.scroll_top(), 0, "starts at the live tail");
        assert!(
            find_link(&engine).is_none(),
            "link row is in history; it must not appear in the live viewport"
        );

        // Scroll back through history until the link row enters the
        // viewport, then assert both accessors resolve against it.
        let mut hit = None;
        for _ in 0..engine.scroll_total() {
            engine.scroll_lines(1);
            if let Some((r, c)) = find_link(&engine) {
                hit = Some((r, c));
                break;
            }
        }
        let (row, col) =
            hit.expect("scrolling back into history must surface the OSC 8 link via hyperlink_at");
        assert!(
            engine.scroll_top() > 0,
            "the link must be found while scrolled into history (display_offset > 0)"
        );

        // hyperlink_span at the scrolled-in anchor covers the 8-cell
        // "Click me" run, proving the span walk also honours the offset.
        let span = engine
            .hyperlink_span(row, col)
            .expect("scrolled-in anchor carries a link, span must be Some");
        assert_eq!(
            span.1, 8,
            "expected span to cover the 8 cells of \"Click me\"; got start={}, span={}",
            span.0, span.1
        );
    }

    /// `drain_events` returns an empty Vec when no events have been
    /// produced. /bin/cat doesn't emit any startup events, so a
    /// fresh engine + brief settle has nothing to drain.
    #[test]
    fn drain_events_returns_empty_on_idle_engine() {
        let engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");
        std::thread::sleep(Duration::from_millis(20));
        let events = engine.drain_events();
        assert!(
            events.is_empty(),
            "fresh /bin/cat should produce no events; got {events:?}"
        );
    }

    /// Feeding an OSC 2 (set-window-title) sequence through the
    /// parser pipeline produces an `EngineEvent::TitleChanged`.
    /// `\x1b]2;NextTerm\x07` is the standard form: ESC + ']' + '2' +
    /// ';' + title + BEL terminator. We append `\n` because /bin/cat
    /// in cooked mode is line-buffered: bytes sit in the kernel's
    /// input buffer until LF arrives. Cat then echoes the whole
    /// line to its stdout, where the parser sees the OSC sequence
    /// and Term fires `Event::Title("NextTerm")` through the
    /// `EventProxy`.
    #[test]
    fn drain_events_emits_title_changed_after_osc_2() {
        use crate::events::EngineEvent;
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        engine
            .feed_input(b"\x1b]2;NextTerm\x07\n")
            .expect("feed_input should write OSC 2 to /bin/cat");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut title_seen: Option<String> = None;
        while Instant::now() < deadline && title_seen.is_none() {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            for event in engine.drain_events() {
                if let EngineEvent::TitleChanged(t) = event {
                    title_seen = Some(t);
                    break;
                }
            }
            if title_seen.is_none() {
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        assert_eq!(
            title_seen.as_deref(),
            Some("NextTerm"),
            "expected EngineEvent::TitleChanged(\"NextTerm\") within 5s after OSC 2"
        );
    }

    /// Feeding `\x07` (BEL byte) followed by `\n` produces
    /// `EngineEvent::Bell`. The newline is required because cat is
    /// line-buffered in cooked mode (see the OSC 2 test for the
    /// canonical explanation). Bytes round-trip through /bin/cat's
    /// stdin → stdout, parser dispatches Bell, `EventProxy`
    /// translates to `EngineEvent`.
    #[test]
    fn drain_events_emits_bell_after_bel_byte() {
        use crate::events::EngineEvent;
        let mut engine =
            TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

        engine
            .feed_input(b"\x07\n")
            .expect("feed_input should write BEL to /bin/cat");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut bell_seen = false;
        while Instant::now() < deadline && !bell_seen {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            if engine.drain_events().contains(&EngineEvent::Bell) {
                bell_seen = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            bell_seen,
            "expected EngineEvent::Bell within 5s after BEL byte"
        );
    }

    /// ⭐ Closes the #44 deferral: spawn `/bin/zsh -l`, write
    /// `exit\n`, and assert `EngineEvent::ChildExited` fires within
    /// the deadline. The signal-pipe race that #44 hit (alacritty's
    /// `signal_hook` registration vs cargo test's parent-process
    /// SIGCHLD handler) was traced to a process-internal mechanism;
    /// inside the test binary, signal-hook is the only SIGCHLD
    /// registrant, so the race shouldn't fire. This test exercises
    /// that hypothesis empirically. If it flakes across consecutive
    /// runs, rule-9 escalation kicks in.
    #[test]
    fn drain_events_emits_child_exited_after_zsh_exit() {
        use crate::events::EngineEvent;
        use std::path::PathBuf;
        let mut engine = TerminalEngine::new(EngineConfig {
            rows: 24,
            cols: 80,
            env: vec![("TERM".to_string(), "xterm-256color".to_string())],
            command: vec!["/bin/zsh".to_string(), "-l".to_string()],
            cwd: PathBuf::from("/tmp"),
            scrollback_lines: 100,
        })
        .expect("/bin/zsh -l spawn should succeed on macOS");

        engine
            .feed_input(b"exit\n")
            .expect("feed_input should write exit command");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut exit_seen = false;
        while Instant::now() < deadline && !exit_seen {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            if engine
                .drain_events()
                .iter()
                .any(|e| matches!(e, EngineEvent::ChildExited { .. }))
            {
                exit_seen = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            exit_seen,
            "expected EngineEvent::ChildExited within 5s after writing 'exit\\n' to /bin/zsh -l; \
             this closes the #44 deferral. If this flakes, rule-9 escalation: \
             cargo-test SIGCHLD race may still be a factor."
        );
    }

    /// A freshly-constructed engine has `TermMode::BRACKETED_PASTE`
    /// clear — alacritty's default `Term` mode does not include it
    /// (matches xterm/VT default).
    #[test]
    fn bracketed_paste_disabled_by_default() {
        let engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");
        assert!(
            !engine.bracketed_paste_enabled(),
            "fresh engine must report bracketed-paste disabled"
        );
    }

    /// Feeding `CSI ?2004 h` through the parser (via cat-loopback —
    /// `/bin/cat` echoes stdin to stdout, the reader thread enqueues,
    /// `poll_output` advances the VT parser) sets
    /// `TermMode::BRACKETED_PASTE`. We poll until the accessor flips,
    /// guarded by a 5s deadline (matches the deadline used by
    /// `poll_output_advances_term_grid`).
    #[test]
    fn bracketed_paste_enabled_after_decset_2004() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

        engine
            // Trailing `\n` is required: `/bin/cat` runs in canonical
            // (line-buffered) mode under the PTY line discipline, so
            // bytes don't get echoed back until a newline arrives.
            // The `\n` itself is a benign LF in the parser path
            // (advances the cursor; doesn't affect mode flags).
            .feed_input(b"\x1b[?2004h\n")
            .expect("feed_input should write DECSET 2004");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && !engine.bracketed_paste_enabled() {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            if !engine.bracketed_paste_enabled() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            engine.bracketed_paste_enabled(),
            "expected bracketed-paste enabled within 5s after DECSET 2004"
        );
    }

    /// After enabling bracketed-paste with DECSET 2004, feeding DECRST
    /// 2004 (`CSI ?2004 l`) clears `TermMode::BRACKETED_PASTE`. Same
    /// cat-loopback pattern as the enable test.
    #[test]
    fn bracketed_paste_disabled_after_decrst_2004() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

        engine
            // Trailing `\n` is required: `/bin/cat` runs in canonical
            // (line-buffered) mode under the PTY line discipline, so
            // bytes don't get echoed back until a newline arrives.
            // The `\n` itself is a benign LF in the parser path
            // (advances the cursor; doesn't affect mode flags).
            .feed_input(b"\x1b[?2004h\n")
            .expect("feed_input should write DECSET 2004");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && !engine.bracketed_paste_enabled() {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            if !engine.bracketed_paste_enabled() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            engine.bracketed_paste_enabled(),
            "precondition: bracketed-paste must be enabled before DECRST"
        );

        engine
            // Trailing `\n` for the same canonical-mode reason as
            // the DECSET write above.
            .feed_input(b"\x1b[?2004l\n")
            .expect("feed_input should write DECRST 2004");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && engine.bracketed_paste_enabled() {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            if engine.bracketed_paste_enabled() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            !engine.bracketed_paste_enabled(),
            "expected bracketed-paste disabled within 5s after DECRST 2004"
        );
    }

    /// A freshly-constructed engine has `TermMode::FOCUS_IN_OUT`
    /// clear — alacritty's default `Term` mode does not include it
    /// (matches xterm/VT default). Focus reporting is opt-in via
    /// DECSET 1004.
    #[test]
    fn focus_events_disabled_by_default() {
        let engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");
        assert!(
            !engine.focus_events_enabled(),
            "fresh engine must report focus-events disabled"
        );
    }

    /// Feeding `CSI ?1004 h` through the parser (via cat-loopback —
    /// same pattern as `bracketed_paste_enabled_after_decset_2004`)
    /// sets `TermMode::FOCUS_IN_OUT`. We poll until the accessor
    /// flips, guarded by a 5 s deadline.
    #[test]
    fn focus_events_enabled_after_decset_1004() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

        engine
            // Trailing `\n` is required: `/bin/cat` runs in canonical
            // (line-buffered) mode under the PTY line discipline, so
            // bytes don't get echoed back until a newline arrives.
            .feed_input(b"\x1b[?1004h\n")
            .expect("feed_input should write DECSET 1004");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && !engine.focus_events_enabled() {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            if !engine.focus_events_enabled() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            engine.focus_events_enabled(),
            "expected focus-events enabled within 5s after DECSET 1004"
        );
    }

    /// After enabling focus-events with DECSET 1004, feeding DECRST
    /// 1004 (`CSI ?1004 l`) clears `TermMode::FOCUS_IN_OUT`. Same
    /// cat-loopback pattern as the enable test.
    #[test]
    fn focus_events_disabled_after_decrst_1004() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

        engine
            .feed_input(b"\x1b[?1004h\n")
            .expect("feed_input should write DECSET 1004");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && !engine.focus_events_enabled() {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            if !engine.focus_events_enabled() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            engine.focus_events_enabled(),
            "precondition: focus-events must be enabled before DECRST"
        );

        engine
            .feed_input(b"\x1b[?1004l\n")
            .expect("feed_input should write DECRST 1004");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && engine.focus_events_enabled() {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            if engine.focus_events_enabled() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            !engine.focus_events_enabled(),
            "expected focus-events disabled within 5s after DECRST 1004"
        );
    }

    // -----------------------------------------------------------------
    // task 2.9 — Kitty keyboard protocol + modifyOtherKeys (#?? — this dispatch)
    //
    // Kitty keyboard is fully implemented by alacritty (we enabled
    // `Config::kitty_keyboard: true` in `engine::new`); the engine
    // surface is read-only via `kitty_keyboard_flags()`. modifyOtherKeys
    // is engine-side (alacritty leaves vte's no-op defaults); state
    // lives on `OscPerform`'s `modify_other_keys_level`. Tests use the
    // same cat-loopback shape as bracketed-paste / focus-events.
    // -----------------------------------------------------------------

    /// A freshly-constructed engine reports Kitty keyboard flags as
    /// `NO_MODE`. Default `Term` mode does not include any of the five
    /// Kitty bits (`DISAMBIGUATE_ESC_CODES` etc.); shells opt in via
    /// `CSI > N u`.
    #[test]
    fn kitty_keyboard_flags_disabled_by_default() {
        let engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");
        assert_eq!(
            engine.kitty_keyboard_flags(),
            KittyKeyboardFlags::NO_MODE,
            "fresh engine must report no Kitty keyboard flags set"
        );
    }

    /// Feeding `CSI > 1 u` through the parser pushes the
    /// `DISAMBIGUATE_ESC_CODES` flag onto alacritty's
    /// `keyboard_mode_stack` and sets `TermMode::DISAMBIGUATE_ESC_CODES`
    /// (the bit our accessor reads). Cat-loopback poll matches the
    /// existing focus-events / bracketed-paste pattern.
    #[test]
    fn kitty_keyboard_flags_after_push_disambiguate() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

        engine
            // Trailing `\n` for cat's canonical mode (line discipline).
            .feed_input(b"\x1b[>1u\n")
            .expect("feed_input should write CSI > 1 u");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline
            && !engine
                .kitty_keyboard_flags()
                .contains(KittyKeyboardFlags::DISAMBIGUATE_ESC_CODES)
        {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            if !engine
                .kitty_keyboard_flags()
                .contains(KittyKeyboardFlags::DISAMBIGUATE_ESC_CODES)
            {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert_eq!(
            engine.kitty_keyboard_flags(),
            KittyKeyboardFlags::DISAMBIGUATE_ESC_CODES,
            "expected only DISAMBIGUATE_ESC_CODES set after CSI > 1 u"
        );
    }

    /// Push, then pop: feed `CSI > 1 u` then `CSI < u` and confirm flags
    /// revert to `NO_MODE`. Verifies alacritty's
    /// `pop_keyboard_modes` actually flushes the bit out of `TermMode`
    /// (it does — `term/mod.rs:1318` calls `set_keyboard_mode` with the
    /// new top of stack, which falls back to `NO_MODE` when empty).
    #[test]
    fn kitty_keyboard_flags_after_pop_revert_to_no_mode() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

        // Push.
        engine
            .feed_input(b"\x1b[>1u\n")
            .expect("feed_input push should succeed");
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline
            && !engine
                .kitty_keyboard_flags()
                .contains(KittyKeyboardFlags::DISAMBIGUATE_ESC_CODES)
        {
            let _ = engine.poll_output().expect("poll_output");
            if !engine
                .kitty_keyboard_flags()
                .contains(KittyKeyboardFlags::DISAMBIGUATE_ESC_CODES)
            {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert_eq!(
            engine.kitty_keyboard_flags(),
            KittyKeyboardFlags::DISAMBIGUATE_ESC_CODES,
            "precondition: push must succeed before pop test",
        );

        // Pop one (default).
        engine
            .feed_input(b"\x1b[<u\n")
            .expect("feed_input pop should succeed");
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline
            && engine.kitty_keyboard_flags() != KittyKeyboardFlags::NO_MODE
        {
            let _ = engine.poll_output().expect("poll_output");
            if engine.kitty_keyboard_flags() != KittyKeyboardFlags::NO_MODE {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert_eq!(
            engine.kitty_keyboard_flags(),
            KittyKeyboardFlags::NO_MODE,
            "expected flags to revert to NO_MODE after CSI < u",
        );
    }

    /// modifyOtherKeys defaults to level 0 — alacritty doesn't implement
    /// the parser hook, so our tracking field starts at 0 and stays
    /// there until a `CSI > 4 ; level m` sequence is parsed.
    #[test]
    fn modify_other_keys_level_disabled_by_default() {
        let engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");
        assert_eq!(
            engine.modify_other_keys_level(),
            0,
            "fresh engine must report modifyOtherKeys level 0"
        );
    }

    /// `CSI > 4 ; 1 m` raises modifyOtherKeys to level 1
    /// (`EnableExceptWellDefined`). The cat-loopback path is identical
    /// to the focus-events tests: `feed_input` writes to cat's stdin, cat
    /// echoes to stdout, the reader thread feeds bytes into the OSC
    /// sibling parser, our `csi_dispatch` mutates the level.
    #[test]
    fn modify_other_keys_level_1_after_csi_gt_4_1_m() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

        engine
            .feed_input(b"\x1b[>4;1m\n")
            .expect("feed_input should write CSI > 4 ; 1 m");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && engine.modify_other_keys_level() != 1 {
            let _ = engine.poll_output().expect("poll_output");
            if engine.modify_other_keys_level() != 1 {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert_eq!(
            engine.modify_other_keys_level(),
            1,
            "expected modifyOtherKeys level 1 within 5s after CSI > 4 ; 1 m"
        );
    }

    /// `CSI > 4 ; 2 m` raises modifyOtherKeys to level 2 (`EnableAll`).
    #[test]
    fn modify_other_keys_level_2_after_csi_gt_4_2_m() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

        engine
            .feed_input(b"\x1b[>4;2m\n")
            .expect("feed_input should write CSI > 4 ; 2 m");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && engine.modify_other_keys_level() != 2 {
            let _ = engine.poll_output().expect("poll_output");
            if engine.modify_other_keys_level() != 2 {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert_eq!(
            engine.modify_other_keys_level(),
            2,
            "expected modifyOtherKeys level 2 within 5s after CSI > 4 ; 2 m"
        );
    }

    /// After raising to level 2, `CSI > 4 ; 0 m` resets back to 0.
    /// Pin the disable path explicitly — same shape as the
    /// `focus_events_disabled_after_decrst_1004` test.
    #[test]
    fn modify_other_keys_level_0_after_reset() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

        engine
            .feed_input(b"\x1b[>4;2m\n")
            .expect("feed_input should write CSI > 4 ; 2 m");
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && engine.modify_other_keys_level() != 2 {
            let _ = engine.poll_output().expect("poll_output");
            if engine.modify_other_keys_level() != 2 {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert_eq!(
            engine.modify_other_keys_level(),
            2,
            "precondition: enable level 2 before testing reset",
        );

        engine
            .feed_input(b"\x1b[>4;0m\n")
            .expect("feed_input should write reset");
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && engine.modify_other_keys_level() != 0 {
            let _ = engine.poll_output().expect("poll_output");
            if engine.modify_other_keys_level() != 0 {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert_eq!(
            engine.modify_other_keys_level(),
            0,
            "expected modifyOtherKeys level 0 within 5s after CSI > 4 ; 0 m"
        );
    }

    /// `CSI ? 4 m` query — when the shell asks for the current
    /// modifyOtherKeys level, our `csi_dispatch` queues `CSI > 4 ;
    /// level m` on `pty_responses` and `poll_output` writes it to the
    /// PTY master FD. Verify by spawning a printf-emitter (same
    /// pattern as `osc_10_query_drains_pty_response_queue_without_
    /// erroring`) — we assert the engine doesn't error during the
    /// write-back.
    #[test]
    fn modify_other_keys_query_drains_pty_response_queue_without_erroring() {
        // `\033` = ESC. printf interprets the C-style escape.
        let mut engine = TerminalEngine::new(osc_query_emitter_config("\x1b[?4m"))
            .expect("printf spawn should succeed on macOS");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut total = 0usize;
        while Instant::now() < deadline {
            total += engine
                .poll_output()
                .expect("poll_output must not error while writing modifyOtherKeys reply");
            let events = engine.drain_events();
            if events
                .iter()
                .any(|e| matches!(e, EngineEvent::ChildExited { .. }))
            {
                let _ = engine
                    .poll_output()
                    .expect("post-exit drain should still be Ok");
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        // CSI ? 4 m is 5 bytes; PTY line-discipline can reshape, but
        // we should observe at least some — same lower-bound as the
        // OSC 10 query test.
        assert!(
            total >= 4,
            "expected the engine to read at least some bytes from printf; got {total}",
        );
    }

    /// `CSI ? u` Kitty keyboard query — alacritty implements
    /// `report_keyboard_mode` (gated on `Config::kitty_keyboard`, which
    /// we set to `true`). It formats `\x1b[?bits u` and queues it via
    /// `Event::PtyWrite` → `EventProxy` → `pty_responses`. Verify the
    /// engine doesn't error draining the queue. Default mode is
    /// `NO_MODE`, so the reply is `\x1b[?0 u` (4 bytes).
    #[test]
    fn kitty_keyboard_query_drains_pty_response_queue_without_erroring() {
        let mut engine = TerminalEngine::new(osc_query_emitter_config("\x1b[?u"))
            .expect("printf spawn should succeed on macOS");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut total = 0usize;
        while Instant::now() < deadline {
            total += engine
                .poll_output()
                .expect("poll_output must not error while writing Kitty keyboard reply");
            let events = engine.drain_events();
            if events
                .iter()
                .any(|e| matches!(e, EngineEvent::ChildExited { .. }))
            {
                let _ = engine
                    .poll_output()
                    .expect("post-exit drain should still be Ok");
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(
            total >= 3,
            "expected the engine to read at least some bytes from printf; got {total}",
        );
    }

    /// A freshly-constructed engine reports synchronized output as
    /// inactive — alacritty's `vte::ansi::Processor` initialises with
    /// no pending sync timeout (`StdSyncHandler { timeout: None }`).
    #[test]
    fn synchronized_output_inactive_by_default() {
        let engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");
        assert!(
            !engine.synchronized_output_active(),
            "fresh engine must report synchronized output inactive"
        );
    }

    /// Feeding `CSI ?2026 h` through the parser (via cat-loopback)
    /// activates synchronized-output mode in `vte::ansi::Processor`'s
    /// internal `sync_state.timeout`. We poll until the accessor flips
    /// (5 s deadline, mirroring the bracketed-paste tests).
    ///
    /// Note: unlike `BRACKETED_PASTE`, this state is *not* exposed as a
    /// `TermMode` bit; it lives entirely inside the parser. See
    /// `synchronized_output_active` doc-comment for details.
    #[test]
    fn synchronized_output_active_after_decset_2026() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

        engine
            // Trailing `\n` is required for cat's canonical-mode line
            // discipline. The LF that comes back through the parser
            // arrives *after* BSU has activated sync, so it lands in
            // the sync buffer rather than reaching `Term` — that's
            // fine, we only assert on the parser's sync flag here.
            .feed_input(b"\x1b[?2026h\n")
            .expect("feed_input should write DECSET 2026");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && !engine.synchronized_output_active() {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            if !engine.synchronized_output_active() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            engine.synchronized_output_active(),
            "expected synchronized output active within 5 s after DECSET 2026"
        );
    }

    /// After enabling synchronized output with DECSET 2026, feeding
    /// DECRST 2026 (`CSI ?2026 l`) clears the parser's sync state.
    /// Same cat-loopback pattern as the enable test; the ESU is
    /// detected by `vte`'s `advance_sync_csi` reverse scan, which
    /// then calls `stop_sync_internal` and zeroes the timeout.
    #[test]
    fn synchronized_output_inactive_after_decrst_2026() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

        engine
            .feed_input(b"\x1b[?2026h\n")
            .expect("feed_input should write DECSET 2026");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && !engine.synchronized_output_active() {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            if !engine.synchronized_output_active() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            engine.synchronized_output_active(),
            "precondition: synchronized output must be active before DECRST"
        );

        engine
            .feed_input(b"\x1b[?2026l\n")
            .expect("feed_input should write DECRST 2026");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && engine.synchronized_output_active() {
            let _ = engine
                .poll_output()
                .expect("poll_output is infallible today");
            if engine.synchronized_output_active() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            !engine.synchronized_output_active(),
            "expected synchronized output inactive within 5 s after DECRST 2026"
        );
    }

    /// End-to-end assertion that BSU genuinely holds grid mutations:
    /// after BSU activates, bytes that would normally land on the grid
    /// are buffered by `vte::ansi::Processor` instead of being
    /// dispatched to `Term`. ESU then flushes them in one shot.
    ///
    /// Methodology: snapshot row 0..3 immediately after sync activates,
    /// feed a sentinel `Y\n`, drain, assert the snapshot is byte-for-
    /// byte unchanged. Then feed ESU and assert the sentinel is now
    /// observable. We snapshot multiple rows because the cat-loopback
    /// PTY echoes our BSU input as visible characters (`^[[?2026h`)
    /// onto the grid before BSU activates — only an exact-equality
    /// check on the post-activation snapshot is unambiguous.
    #[test]
    fn synchronized_output_buffers_grid_until_esu() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

        // Step 1: open BSU, wait for sync-active. The cat-loopback
        // echo of "^[[?2026h\n" lands on row 0 BEFORE the actual
        // \x1b[?2026h sequence (re-emitted by cat) flips the parser
        // into sync mode. That's fine for snapshot-equality below.
        engine.feed_input(b"\x1b[?2026h\n").expect("feed_input BSU");
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && !engine.synchronized_output_active() {
            let _ = engine.poll_output().expect("poll_output is infallible");
            if !engine.synchronized_output_active() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            engine.synchronized_output_active(),
            "precondition: BSU must activate sync within 5 s"
        );

        // Snapshot the grid immediately, then feed the sentinel and
        // drain quickly — we have a budget of 150 ms (vte's sync
        // timeout, replicated in poll_output's force-flush below)
        // before the buffer would auto-drain. 80 ms total wait gives
        // cat enough time to echo the sentinel through the parser
        // while staying well clear of the timeout.
        let snapshot_during_bsu: Vec<Vec<u8>> = engine
            .viewport_cells(0..3)
            .iter()
            .map(|c| c.grapheme[..c.width.max(1) as usize].to_vec())
            .collect();

        engine.feed_input(b"Y\n").expect("feed_input sentinel");
        for _ in 0..8 {
            let _ = engine.poll_output().expect("poll_output is infallible");
            std::thread::sleep(Duration::from_millis(10));
        }

        // Step 4: re-snapshot. Must equal the BSU snapshot byte-for-
        // byte — sync mode held the sentinel.
        let snapshot_after_sentinel: Vec<Vec<u8>> = engine
            .viewport_cells(0..3)
            .iter()
            .map(|c| c.grapheme[..c.width.max(1) as usize].to_vec())
            .collect();
        assert_eq!(
            snapshot_after_sentinel, snapshot_during_bsu,
            "grid must be byte-for-byte unchanged during BSU — sentinel 'Y' is buffered"
        );
        assert!(
            engine.synchronized_output_active(),
            "sync must still be active before ESU"
        );

        // Step 5: send ESU. cat re-emits it; vte's reverse-scan in
        // advance_sync_csi detects the ESU CSI in the sync buffer and
        // calls stop_sync_internal, which flushes all previously-held
        // bytes through the parser into Term in one shot.
        engine.feed_input(b"\x1b[?2026l\n").expect("feed_input ESU");
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && engine.synchronized_output_active() {
            let _ = engine.poll_output().expect("poll_output is infallible");
            if engine.synchronized_output_active() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            !engine.synchronized_output_active(),
            "ESU must clear sync within 5 s"
        );
        for _ in 0..5 {
            let _ = engine.poll_output().expect("poll_output is infallible");
            std::thread::sleep(Duration::from_millis(10));
        }

        // Step 6: the sentinel 'Y' must now be visible somewhere on
        // the grid (exact row depends on prior cursor advance from
        // the BSU echo's CR LF; we accept any row in 0..5).
        let cells = engine.viewport_cells(0..5);
        let saw_sentinel = cells.iter().any(|c| c.grapheme[..1] == *b"Y");
        assert!(
            saw_sentinel,
            "grid must contain 'Y' after ESU flushes the buffered bytes; got {} cells",
            cells.len()
        );
    }

    /// If a producer opens BSU but never sends ESU (e.g. crashes
    /// mid-frame), `vte::ansi::Processor` would otherwise hold bytes
    /// until its 2 MiB buffer cap. We replicate alacritty's 150 ms
    /// fallback timeout in `poll_output`, calling `parser.stop_sync`
    /// when the deadline passes. This test feeds BSU + sentinel +
    /// sleeps past the timeout, then polls and asserts the grid was
    /// flushed.
    ///
    /// The 250 ms sleep gives the 150 ms vte timeout a comfortable
    /// margin (cat-loopback latency + scheduling jitter on busy CI).
    #[test]
    fn synchronized_output_timeout_force_flushes_buffer() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

        // Open BSU, wait for sync to activate, feed sentinel, give cat
        // time to echo it back through the parser into the sync buffer.
        engine.feed_input(b"\x1b[?2026h\n").expect("feed_input BSU");
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && !engine.synchronized_output_active() {
            let _ = engine.poll_output().expect("poll_output is infallible");
            if !engine.synchronized_output_active() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            engine.synchronized_output_active(),
            "precondition: BSU must activate sync"
        );

        engine.feed_input(b"Z\n").expect("feed_input sentinel");
        // Brief drain so the bytes land in the sync buffer before we
        // start the timeout clock — otherwise we'd race the parser.
        let drain_deadline = Instant::now() + Duration::from_secs(2);
        let mut seen = 0usize;
        while Instant::now() < drain_deadline && seen < 2 {
            seen += engine.poll_output().expect("poll_output is infallible");
            if seen < 2 {
                std::thread::sleep(Duration::from_millis(10));
            }
        }

        // Sleep past the 150 ms vte sync timeout. No ESU is sent.
        std::thread::sleep(Duration::from_millis(250));

        // poll_output observes the expired deadline and force-flushes
        // via `parser.stop_sync`. After this call, sync is inactive
        // and the buffered sentinel has been committed to the grid.
        let _ = engine.poll_output().expect("poll_output is infallible");
        assert!(
            !engine.synchronized_output_active(),
            "expired timeout must clear sync state on next poll_output"
        );

        // The sentinel 'Z' must now be visible somewhere on the grid.
        // (cat-loopback echoes the BSU input first, advancing the
        // cursor; the post-flush 'Z' lands on whatever row the cursor
        // had reached. We accept any row in 0..5.)
        let cells = engine.viewport_cells(0..5);
        let saw_sentinel = cells.iter().any(|c| c.grapheme[..1] == *b"Z");
        assert!(
            saw_sentinel,
            "grid must contain 'Z' after the 150 ms timeout force-flush; got {} cells",
            cells.len()
        );
    }

    // -----------------------------------------------------------------
    // task 2.5 — OSC 10/11/12 engine round-trip (#71)
    //
    // The engine-level contract is: when the parser sees an OSC 10|11|12
    // query, `poll_output` writes the formatted reply back to the PTY
    // master FD before returning. The proxy + formatter behaviour is
    // covered by `events.rs` unit tests; this test pins the engine-side
    // drain + write_all path against a real PTY child.
    //
    // The cat-loopback shape: feed_input writes the OSC bytes to cat's
    // stdin; cat echoes them to stdout; the reader thread feeds them
    // into the parser; alacritty's `dynamic_color_sequence` fires;
    // EventProxy queues the reply; poll_output drains the queue and
    // writes the reply to the PTY master (which is cat's stdin again);
    // cat echoes the reply to stdout; the reader thread reads it; the
    // parser dispatches the reply as `set_color` (alacritty's set form,
    // a silent no-op for our consumer). End state: the engine consumed
    // approximately 2× the OSC sequence length and never errored.
    // -----------------------------------------------------------------

    // -----------------------------------------------------------------
    // task 2.5 — OSC 10/11/12 engine round-trip (#71)
    //
    // Verify `poll_output` actually drains the `pty_responses` queue and
    // writes replies to the PTY master FD. We spawn a child that emits
    // an OSC 10 query directly on its stdout (so the byte path is
    // child → reader → parser → proxy → queue → poll_output → write),
    // then verify the engine doesn't error.
    //
    // We use `printf` rather than `cat` for the stdout path because cat
    // requires user input + line-discipline cooking which complicates
    // the byte accounting. `printf '\033]10;?\033\\'` writes exactly
    // the 8-byte OSC query and exits — clean, deterministic, no PTY
    // interactivity needed for the producer side. The PTY-write-back
    // (poll_output → pty.writer().write_all) just needs to not error;
    // exactly which bytes the dead child sees on its stdin is moot
    // (printf has already exited).
    // -----------------------------------------------------------------

    fn osc_query_emitter_config(query_arg: &str) -> EngineConfig {
        EngineConfig {
            rows: 24,
            cols: 80,
            env: vec![("TERM".to_string(), "xterm-256color".to_string())],
            command: vec![
                "/usr/bin/printf".to_string(),
                "%s".to_string(),
                query_arg.to_string(),
            ],
            cwd: PathBuf::from("/tmp"),
            scrollback_lines: 100,
        }
    }

    /// Spawn a child that emits `\x1b]10;?\x1b\\` on stdout. The
    /// engine's parser sees the query and the proxy queues the reply.
    /// `poll_output` drains the queue and writes the reply to the
    /// master FD via `pty.writer().write_all`. We assert `poll_output`
    /// stays `Ok` across many iterations — the load-bearing engine-
    /// level invariant (the reply formatting + payload is unit-tested
    /// in `events.rs::tests`).
    #[test]
    fn osc_10_query_drains_pty_response_queue_without_erroring() {
        // \033 = ESC, ST = ESC \. printf interprets the C-style escape.
        let mut engine = TerminalEngine::new(osc_query_emitter_config("\x1b]10;?\x1b\\"))
            .expect("printf spawn should succeed on macOS");

        // Loop poll_output until the child has exited and the queue is
        // empty. The reply write-back happens inside poll_output; the
        // assertion is that none of those poll calls return Err.
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut total = 0usize;
        while Instant::now() < deadline {
            total += engine
                .poll_output()
                .expect("poll_output must not error while writing OSC reply to PTY");
            // Watch for the child-exited event, then drain one more
            // time (the reply could be queued before exit was observed).
            let events = engine.drain_events();
            if events
                .iter()
                .any(|e| matches!(e, EngineEvent::ChildExited { .. }))
            {
                let _ = engine
                    .poll_output()
                    .expect("post-exit drain should still be Ok");
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        // Threshold is a defensive lower-bound — PTY line discipline
        // can reshape ESC/CR/LF byte counts. The query is 8 bytes; a
        // few are typically observable. We care about "engine processed
        // SOME bytes from the child without erroring", not exact count.
        assert!(
            total >= 4,
            "expected the engine to read at least some bytes from printf; got {total}",
        );
    }

    /// Spawn a child that emits `OSC 10 ; rgb:00/00/00 ST` (set form).
    /// alacritty absorbs this via `set_color`; nothing goes onto our
    /// `pty_responses` queue, so `poll_output` writes nothing back to
    /// the PTY. Pin "no panic, no error" for the set path.
    #[test]
    fn osc_10_set_form_drains_through_engine_without_reply() {
        let mut engine =
            TerminalEngine::new(osc_query_emitter_config("\x1b]10;rgb:00/00/00\x1b\\"))
                .expect("printf spawn should succeed on macOS");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut total = 0usize;
        while Instant::now() < deadline {
            total += engine
                .poll_output()
                .expect("poll_output must not error on a set-form OSC");
            let events = engine.drain_events();
            if events
                .iter()
                .any(|e| matches!(e, EngineEvent::ChildExited { .. }))
            {
                let _ = engine
                    .poll_output()
                    .expect("post-exit drain should still be Ok");
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        // Same defensive lower-bound as the query test. The set form
        // is 22 input bytes but PTY post-fork-exec / line-discipline
        // can reduce observable count.
        assert!(
            total >= 4,
            "expected the engine to read at least some bytes from printf; got {total}",
        );
    }

    // ─── 4.4 scroll API: scroll_lines / scroll_to_bottom / is_alt_screen ──

    /// Drive enough PTY output through the engine to populate
    /// scrollback, then assert `scroll_lines` actually moves the
    /// viewport. `printf` of 200 newlines on a 24-row grid produces
    /// ~176 rows of scrollback once the screen fills.
    fn scrollback_emitter_config(lines: usize) -> EngineConfig {
        EngineConfig {
            rows: 24,
            cols: 80,
            env: vec![("TERM".to_string(), "xterm-256color".to_string())],
            command: vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                format!("i=0; while [ $i -lt {lines} ]; do echo line$i; i=$((i+1)); done"),
            ],
            cwd: PathBuf::from("/tmp"),
            scrollback_lines: 10_000,
        }
    }

    /// Drain `poll_output` until the scrollback grows past `min_rows`
    /// or the deadline elapses. Used to set up scroll-state fixtures.
    fn drain_until_scrollback(engine: &mut TerminalEngine, min_rows: u32) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            let _ = engine.poll_output().expect("poll_output infallible");
            if engine.scroll_total() >= min_rows {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn scroll_lines_moves_display_offset_back_into_history() {
        let mut engine = TerminalEngine::new(scrollback_emitter_config(200))
            .expect("printf scrollback emitter spawn ok on macOS");
        drain_until_scrollback(&mut engine, 50);
        assert_eq!(engine.scroll_top(), 0, "starts at the live tail");

        engine.scroll_lines(10);
        assert_eq!(
            engine.scroll_top(),
            10,
            "positive delta scrolls back into history"
        );

        engine.scroll_lines(-3);
        assert_eq!(
            engine.scroll_top(),
            7,
            "negative delta scrolls forward toward the live tail"
        );
    }

    /// `Scroll::Delta` clamps to `[0, history_size()]` upstream
    /// (`grid/mod.rs:166`); a wildly large delta should never panic
    /// and should saturate at `scroll_total()`.
    #[test]
    fn scroll_lines_clamps_to_history_bounds() {
        let mut engine = TerminalEngine::new(scrollback_emitter_config(200))
            .expect("printf scrollback emitter spawn ok on macOS");
        drain_until_scrollback(&mut engine, 50);
        let total = engine.scroll_total();
        assert!(total > 0, "fixture must produce non-empty scrollback");

        // Over-scroll back: clamps at scroll_total().
        engine.scroll_lines(i32::MAX);
        assert_eq!(
            engine.scroll_top(),
            total,
            "over-scroll back clamps at scroll_total"
        );

        // Over-scroll forward: clamps at 0 (live tail).
        engine.scroll_lines(i32::MIN);
        assert_eq!(engine.scroll_top(), 0, "over-scroll forward clamps at 0");
    }

    #[test]
    fn scroll_to_bottom_resets_to_live_tail() {
        let mut engine = TerminalEngine::new(scrollback_emitter_config(200))
            .expect("printf scrollback emitter spawn ok on macOS");
        drain_until_scrollback(&mut engine, 50);
        engine.scroll_lines(20);
        assert_eq!(engine.scroll_top(), 20);

        engine.scroll_to_bottom();
        assert_eq!(engine.scroll_top(), 0);

        // Idempotent at 0.
        engine.scroll_to_bottom();
        assert_eq!(engine.scroll_top(), 0);
    }

    /// `cursor().visible` must flip false the moment the viewport
    /// scrolls back into history (`display_offset > 0`) and back to
    /// true the moment we snap to the live tail. The renderer reads
    /// this via `cursor_to_ffi` (`hidden = !visible`) and gates the
    /// cursor overlay encode on `!hidden`; without this gate the
    /// block / beam cursor stays drawn at the last live-grid row
    /// while the user is paging through scrollback, the canonical
    /// "ghost cursor at the bottom of history" bug.
    ///
    /// Pins the contract from commit 27b0228 so a future refactor of
    /// `cursor()` can't silently drop the `display_offset == 0`
    /// clause.
    #[test]
    fn cursor_hides_while_scrolled_into_history() {
        let mut engine = TerminalEngine::new(scrollback_emitter_config(200))
            .expect("printf scrollback emitter spawn ok on macOS");
        drain_until_scrollback(&mut engine, 50);
        assert!(
            engine.cursor().visible,
            "cursor visible at live tail (display_offset == 0)"
        );

        engine.scroll_lines(10);
        assert!(
            !engine.cursor().visible,
            "cursor hidden after scrolling back into history"
        );

        engine.scroll_lines(-5);
        assert!(
            !engine.cursor().visible,
            "cursor stays hidden while display_offset > 0"
        );

        engine.scroll_to_bottom();
        assert!(
            engine.cursor().visible,
            "cursor restored on snap-back to live tail"
        );
    }

    /// Initial `Term` state is the primary screen; `\e[?1049h` enters
    /// alt-screen, `\e[?1049l` exits. `feed_input` is the wrong path
    /// here (writes to PTY, not parser); use `Pty` write through the
    /// shell's `printf '\e[?1049h'`. Simpler: drive bytes through the
    /// parser the same way OSC tests do — emit the sequences from a
    /// short-lived child via `printf '\\e[?1049h\\n; sleep 1; printf
    /// \\e[?1049l\\n'`. We just need observable transitions.
    #[test]
    fn is_alt_screen_tracks_alt_screen_mode() {
        let cfg = EngineConfig {
            rows: 24,
            cols: 80,
            env: vec![("TERM".to_string(), "xterm-256color".to_string())],
            // `printf '\e[?1049h'` enters alt-screen, then exits.
            // Two distinct child invocations would race; instead run
            // a single shell that pauses between the two so we can
            // observe the alt-on state mid-run.
            command: vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "printf '\\033[?1049h'; sleep 0.4; printf '\\033[?1049l'; sleep 0.2".to_string(),
            ],
            cwd: PathBuf::from("/tmp"),
            scrollback_lines: 100,
        };
        let mut engine =
            TerminalEngine::new(cfg).expect("alt-screen-toggle child spawn ok on macOS");
        assert!(
            !engine.is_alt_screen(),
            "fresh engine starts on the primary screen"
        );

        // Drain until the parser observes the alt-screen-enter sequence
        // (or the deadline trips). Within a couple hundred ms.
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline && !engine.is_alt_screen() {
            let _ = engine.poll_output().expect("poll_output infallible");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(
            engine.is_alt_screen(),
            "expected alt-screen-on after \\e[?1049h within 2s"
        );

        // Drain until the exit sequence flips it back. Skip silently
        // if the child already exited and the leave-sequence wasn't
        // observable (post-exit FD state varies); the assertion is on
        // the entry, not the symmetric exit.
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline && engine.is_alt_screen() {
            let _ = engine.poll_output().expect("poll_output infallible");
            std::thread::sleep(Duration::from_millis(10));
        }
        // Tolerate either outcome — entry-side observation already pins
        // the live read; exit-side timing depends on child teardown.
        let _ = engine.is_alt_screen();
    }

    // ─── 4.5 selection API ──────────────────────────────────────────────

    /// Drive bytes into the engine's parser end-to-end via /bin/cat
    /// echo, polling until expected content arrives. Same shape as the
    /// `poll_output_advances_term_grid` helper above. Returns once
    /// row 0's first cell holds `c`, or the deadline trips.
    fn drive_text(engine: &mut TerminalEngine, payload: &[u8], expect_first_char: char) {
        engine.feed_input(payload).expect("feed_input ok");
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            let _ = engine.poll_output().expect("poll_output infallible");
            let cell = &engine.term.grid()[Point::new(Line(0), Column(0))];
            if cell.c == expect_first_char {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!(
            "expected '{}' at (0, 0) within 5s; got '{}'",
            expect_first_char,
            engine.term.grid()[Point::new(Line(0), Column(0))].c
        );
    }

    #[test]
    fn start_simple_selection_at_anchor_is_empty() {
        // Alacritty treats a `Simple` selection that hasn't moved past
        // its anchor as empty: `Side::Left` at one cell with no update
        // is not a renderable range. The Swift handler relies on this —
        // mouseDown without a drag doesn't paint a tint, mouseDragged
        // is what surfaces the visual selection.
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        engine.start_selection(SelectionMode::Simple, 5, 10);
        assert!(
            engine.selection_span().is_none(),
            "Simple selection collapses to None until mouseDragged extends it"
        );
    }

    #[test]
    fn update_selection_extends_simple_range() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        engine.start_selection(SelectionMode::Simple, 5, 10);
        engine.update_selection(5, 20);
        let span = engine
            .selection_span()
            .expect("after update, range is non-empty");
        assert_eq!(span.start_row, 5);
        assert_eq!(span.end_row, 5);
        assert_eq!(span.start_col, 10);
        assert_eq!(span.end_col, 20);
    }

    #[test]
    fn word_selection_picks_up_semantic_boundary() {
        // Feed "hello world\n" so /bin/cat echoes it back into the
        // grid; double-clicking inside "world" must select exactly
        // that word.
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        drive_text(&mut engine, b"hello world\n", 'h');
        // Click anywhere inside "world" (cols 6..=10). Pick col 8.
        engine.start_selection(SelectionMode::Word, 0, 8);
        let span = engine
            .selection_span()
            .expect("semantic selection produces a span");
        assert_eq!(span.start_row, 0);
        assert_eq!(span.end_row, 0);
        assert_eq!(span.start_col, 6, "word starts at 'w' (col 6)");
        assert_eq!(span.end_col, 10, "word ends at 'd' (col 10)");
    }

    #[test]
    fn line_selection_covers_full_row() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        // Triple-click inside row 3 — line selection produces a full
        // logical line span.
        engine.start_selection(SelectionMode::Line, 3, 7);
        let span = engine
            .selection_span()
            .expect("line selection produces a span");
        assert_eq!(span.start_row, 3);
        assert_eq!(span.end_row, 3);
        assert_eq!(span.start_col, 0);
        // /bin/cat at 80 cols: the full line span runs to col 79.
        assert_eq!(span.end_col, 79);
    }

    #[test]
    fn clear_selection_resets() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        engine.start_selection(SelectionMode::Simple, 5, 10);
        engine.update_selection(7, 5);
        assert!(engine.selection_span().is_some());
        engine.clear_selection();
        assert!(
            engine.selection_span().is_none(),
            "clear_selection must produce None on subsequent reads"
        );
        // Idempotent — calling again is a trivial no-op.
        engine.clear_selection();
        assert!(engine.selection_span().is_none());
    }

    #[test]
    fn update_selection_without_active_is_no_op() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        // No prior start_selection; update should be a no-op, span
        // stays None.
        engine.update_selection(3, 5);
        assert!(engine.selection_span().is_none());
    }

    #[test]
    fn selection_span_clamps_out_of_range_inputs() {
        // Out-of-range start/update coords should silently clamp to
        // the nearest in-range cell rather than panic. Keeps the FFI
        // surface infallible against renderer-driven mouse events.
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        // 24×80 grid; row 999 / col 999 are far past the bottom-right.
        engine.start_selection(SelectionMode::Simple, 999, 999);
        engine.update_selection(999, 999);
        let span = engine
            .selection_span()
            .expect("clamped selection still produces a span");
        assert!(span.start_row < 24);
        assert!(span.end_row < 24);
        assert!(span.start_col < 80);
        assert!(span.end_col < 80);
    }

    #[test]
    fn multi_row_simple_selection_spans_rows() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        engine.start_selection(SelectionMode::Simple, 2, 10);
        engine.update_selection(7, 30);
        let span = engine.selection_span().expect("multi-row simple span");
        assert_eq!(span.start_row, 2);
        assert_eq!(span.start_col, 10);
        assert_eq!(span.end_row, 7);
        assert_eq!(span.end_col, 30);
        assert!(!span.is_block);
    }

    #[test]
    fn simple_selection_right_to_left_includes_both_ends() {
        // Regression: a right-to-left drag must keep BOTH the anchor cell
        // and the cell under the cursor. Anchor on 'o' (col 4) of "hello",
        // drag left to 'h' (col 0). Before the side-by-direction fix this
        // dropped both ends and yielded cols 1..3 ("ell") — the user's
        // "can't select the first character" report.
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        drive_text(&mut engine, b"hello world\n", 'h');
        engine.start_selection(SelectionMode::Simple, 0, 4);
        engine.update_selection(0, 0);
        let span = engine.selection_span().expect("reverse drag has a span");
        assert_eq!((span.start_row, span.start_col), (0, 0), "leftmost cell kept");
        assert_eq!((span.end_row, span.end_col), (0, 4), "anchor cell kept");
        assert_eq!(engine.selection_text().as_deref(), Some("hello"));
    }

    #[test]
    fn simple_selection_direction_flip_tracks_both_ends() {
        // Anchor mid-line, drag left (reverse) then back right (forward).
        // Each update re-derives the sides, so the range follows the
        // cursor in both directions and never sticks excluding an endpoint.
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        drive_text(&mut engine, b"hello world\n", 'h');
        engine.start_selection(SelectionMode::Simple, 0, 6); // anchor 'w'
        engine.update_selection(0, 2); // drag left into "hello"
        let left = engine.selection_span().expect("leftward span");
        assert_eq!(
            (left.start_col, left.end_col),
            (2, 6),
            "leftward drag spans cursor..=anchor inclusive"
        );
        engine.update_selection(0, 10); // drag back right to 'd'
        let right = engine.selection_span().expect("rightward span");
        assert_eq!(
            (right.start_col, right.end_col),
            (6, 10),
            "rightward drag spans anchor..=cursor inclusive"
        );
    }

    #[test]
    fn selection_span_tracks_scrollback_offset() {
        // Regression: a wheel scroll must re-project the selection into
        // the new viewport. Select rows 10..=12 at the live tail
        // (display_offset 0), scroll back 5 lines — the same content must
        // now report rows 15..=17, not stay pinned at 10..=12. This is the
        // engine contract the Swift mirror re-sync relies on.
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        // 40 echoed lines into a 24-row grid → enough history to scroll
        // back 5 without hitting the top.
        let mut payload = Vec::new();
        for i in 0..40 {
            payload.extend_from_slice(format!("line{i:02}\n").as_bytes());
        }
        drive_text(&mut engine, &payload, 'l');

        engine.start_selection(SelectionMode::Simple, 10, 3);
        engine.update_selection(12, 7);
        let before = engine.selection_span().expect("in-view span");
        assert_eq!((before.start_row, before.end_row), (10, 12));

        engine.scroll_lines(5);
        let after = engine.selection_span().expect("span tracks the scroll");
        assert_eq!(
            (after.start_row, after.end_row),
            (15, 17),
            "selection rows must shift down by the scrollback offset"
        );
        // Columns are content-anchored — vertical scroll leaves them be.
        assert_eq!((after.start_col, after.end_col), (3, 7));
    }

    #[test]
    fn selection_span_none_when_scrolled_past_bottom() {
        // Regression: a selection scrolled entirely below the fold reports
        // no span (renderer paints no stray tint), rather than collapsing
        // both clamped endpoints onto the bottom edge row.
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        // 80 echoed lines → ~56 rows of history, comfortably more than the
        // 24-row viewport, so a top-of-viewport selection can be pushed
        // fully past the bottom edge.
        let mut payload = Vec::new();
        for i in 0..80 {
            payload.extend_from_slice(format!("row{i:02}\n").as_bytes());
        }
        drive_text(&mut engine, &payload, 'r');

        engine.start_selection(SelectionMode::Simple, 0, 0);
        engine.update_selection(2, 5);
        assert!(engine.selection_span().is_some(), "in-view before scroll");

        engine.scroll_lines(10_000); // clamps to history_size
        assert!(
            engine.selection_span().is_none(),
            "fully-below-viewport selection must report None"
        );
    }

    /// Soft-wrap copy contract (autowrap): a single logical line longer
    /// than the grid width autowraps across visual rows with `WRAPLINE`
    /// set at each wrap point. Copying the whole thing must yield the
    /// original line with NO embedded newline — the user pastes back the
    /// logical line, not the visually-wrapped rows. alacritty's
    /// `selection_to_string` is wrap-aware; this pins that we rely on it
    /// (and never reconstruct text row-by-row, which would re-insert the
    /// wrap breaks).
    #[test]
    fn selection_text_rejoins_autowrapped_line() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        // 100 chars into an 80-col grid → row 0 holds 80 (WRAPLINE), row 1
        // holds 20.
        let mut payload = vec![b'A'; 100];
        payload.push(b'\n');
        drive_text(&mut engine, &payload, 'A');

        engine.start_selection(SelectionMode::Simple, 0, 0);
        engine.update_selection(1, 19);
        let text = engine.selection_text().expect("wrapped selection has text");
        assert_eq!(text, "A".repeat(100), "autowrapped line copies as one line");
        assert!(!text.contains('\n'), "no wrap-point newline in copied text");
    }

    /// Soft-wrap copy contract (reflow): two logical lines laid down wide
    /// (each on its own row, hard newline) then reflowed narrower so each
    /// spans two visual rows — four visual rows total. Copying all four
    /// must yield exactly the two original logical lines (one newline at
    /// the genuine line break, none at the reflow wrap points). This is
    /// the "window too small → 2 lines become 4" case from the bug report.
    #[test]
    fn selection_text_rejoins_reflowed_lines() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        let mut payload = vec![b'A'; 60];
        payload.push(b'\n');
        payload.extend(std::iter::repeat(b'B').take(60));
        payload.push(b'\n');
        drive_text(&mut engine, &payload, 'A');

        // Shrink 80 → 40 cols: alacritty reflows each 60-char line into
        // 40 + 20, flagging WRAPLINE at the fold.
        engine.resize(24, 40).expect("shrink to 40 cols");

        engine.start_selection(SelectionMode::Simple, 0, 0);
        engine.update_selection(3, 19);
        let text = engine.selection_text().expect("reflowed selection has text");
        assert_eq!(
            text,
            format!("{}\n{}", "A".repeat(60), "B".repeat(60)),
            "reflowed soft-wrap copies as the two original logical lines"
        );
        assert_eq!(text.matches('\n').count(), 1, "only the hard break survives");
    }

    // ─── 4.6 selection_text — copy path ──────────────────────────────────

    /// Fresh engine, no selection: `selection_text` returns `None` so the
    /// FFI surface can ship the empty-string sentinel without ambiguity.
    #[test]
    fn selection_text_none_when_no_active_selection() {
        let engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        assert!(engine.selection_text().is_none());
    }

    /// Drag-select "hello" from cat-echoed "hello world": the text content
    /// must round-trip exactly. Pinned because the ⌘C handler relies on
    /// alacritty's stringifier for trailing-whitespace trimming + newline
    /// placement (we don't post-process on the Swift side).
    #[test]
    fn selection_text_returns_selected_substring() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        drive_text(&mut engine, b"hello world\n", 'h');
        engine.start_selection(SelectionMode::Simple, 0, 0);
        engine.update_selection(0, 4);
        let text = engine
            .selection_text()
            .expect("selection_text must produce content for a non-empty range");
        assert_eq!(text, "hello");
    }

    /// Word-mode selection on "world" yields the bare word — no leading
    /// space, no trailing newline. Mirrors the span test
    /// `word_selection_picks_up_semantic_boundary`.
    #[test]
    fn selection_text_for_word_mode_returns_word_only() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        drive_text(&mut engine, b"hello world\n", 'h');
        engine.start_selection(SelectionMode::Word, 0, 8);
        let text = engine
            .selection_text()
            .expect("word selection must produce text");
        assert_eq!(text, "world");
    }

    /// Clearing the selection retires the text accessor as well —
    /// `selection_text` should mirror `selection_span`'s post-clear
    /// `None` so the ⌘C handler doesn't write stale pasteboard contents.
    #[test]
    fn selection_text_none_after_clear() {
        let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
        drive_text(&mut engine, b"hello world\n", 'h');
        engine.start_selection(SelectionMode::Simple, 0, 0);
        engine.update_selection(0, 4);
        assert!(engine.selection_text().is_some());
        engine.clear_selection();
        assert!(engine.selection_text().is_none());
    }
}
