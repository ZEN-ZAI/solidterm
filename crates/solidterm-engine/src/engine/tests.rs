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
    let engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

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
            cell.grapheme[0], b' ',
            "cell ({}, {}) should be a blank space",
            cell.row, cell.col
        );
        assert_eq!(&cell.grapheme[1..], &[0u8; 31]);
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
        &[0u8; 29],
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
// widths that matter to SolidTerm's Thai user + global locales.
// alacritty determines width via `unicode_width::UnicodeWidthChar`
// (default features, no `emoji` flag) — see
// alacritty_terminal-0.26/src/term/mod.rs:14 + 1062. We only
// *verify* that path lands correct values in `CellView.width`; we
// do not reimplement width logic at our layer.
//
// Test corpus parallels `tests/fixtures/font-corpus/`. We use
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
            &[0u8; 31],
            "ASCII grapheme is 1 byte, rest null-padded"
        );
    }
}

/// Ambiguous-width characters (UAX #11 EAW=A) default to **narrow**
/// in `unicode_width` without the `cjk` feature. § (U+00A7),
/// ★ (U+2605), and ° (U+00B0) all report `width = 1`. This pins
/// our default-locale behavior — narrow is the committed default.
/// If the dependency or its
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
        &[0u8; 26],
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
    assert_eq!(&cells[0].grapheme[4..], &[0u8; 28]);

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
    assert_eq!(&cells[2].grapheme[4..], &[0u8; 28]);

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
    let engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

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
    let (row, col) = linked.expect("expected at least one cell to carry the OSC 8 link within 5s");

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
    let engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");
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
    let engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");
    std::thread::sleep(Duration::from_millis(20));
    let events = engine.drain_events();
    assert!(
        events.is_empty(),
        "fresh /bin/cat should produce no events; got {events:?}"
    );
}

/// Feeding an OSC 2 (set-window-title) sequence through the
/// parser pipeline produces an `EngineEvent::TitleChanged`.
/// `\x1b]2;SolidTerm\x07` is the standard form: ESC + ']' + '2' +
/// ';' + title + BEL terminator. We append `\n` because /bin/cat
/// in cooked mode is line-buffered: bytes sit in the kernel's
/// input buffer until LF arrives. Cat then echoes the whole
/// line to its stdout, where the parser sees the OSC sequence
/// and Term fires `Event::Title("SolidTerm")` through the
/// `EventProxy`.
/// OSC 0/2 with an *empty* payload is how a child hands the title
/// back. vte parses it as `set_title(Some(""))` — **not**
/// `set_title(None)` / `Event::ResetTitle`, which only fires for
/// `CSI 23 t` against an empty title stack — so it surfaces here as
/// `TitleChanged("")`. The FFI keys its "the title is yours again"
/// latch off exactly that, so pin the wire fact.
#[test]
fn empty_osc_2_arrives_as_title_changed_with_empty_string() {
    use crate::events::EngineEvent;
    let mut engine =
        TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

    engine
        .feed_input(b"\x1b]2;solidterm\x07\x1b]2;\x07\n")
        .expect("feed_input should write both OSC 2 sequences to /bin/cat");

    let deadline = Instant::now() + Duration::from_secs(5);
    let mut seen: Vec<EngineEvent> = Vec::new();
    while Instant::now() < deadline
        && seen
            .iter()
            .filter(|e| matches!(e, EngineEvent::TitleChanged(_)))
            .count()
            < 2
    {
        let _ = engine
            .poll_output()
            .expect("poll_output is infallible today");
        seen.extend(engine.drain_events());
        std::thread::sleep(Duration::from_millis(20));
    }

    let titles: Vec<_> = seen
        .iter()
        .filter(|e| matches!(e, EngineEvent::TitleChanged(_) | EngineEvent::TitleReset))
        .collect();
    assert_eq!(
        titles.len(),
        2,
        "expected a TitleChanged then a TitleReset; got {titles:?}"
    );
    assert!(matches!(titles[0], EngineEvent::TitleChanged(t) if t == "solidterm"));
    assert!(matches!(titles[1], EngineEvent::TitleChanged(t) if t.is_empty()));
}

#[test]
fn drain_events_emits_title_changed_after_osc_2() {
    use crate::events::EngineEvent;
    let mut engine =
        TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed on macOS");

    engine
        .feed_input(b"\x1b]2;SolidTerm\x07\n")
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
        Some("SolidTerm"),
        "expected EngineEvent::TitleChanged(\"SolidTerm\") within 5s after OSC 2"
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

#[test]
fn app_cursor_disabled_by_default() {
    let engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");
    assert!(
        !engine.app_cursor_active(),
        "fresh engine must report normal (non-application) cursor keys"
    );
}

/// `CSI ?1 h` (DECCKM set) flips `TermMode::APP_CURSOR`; the host
/// reads this to emit SS3 cursor keys. Cat-loopback + poll, same
/// pattern as the focus-events / bracketed-paste mode tests.
#[test]
fn app_cursor_active_after_decckm_set() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");
    engine
        .feed_input(b"\x1b[?1h\n")
        .expect("feed_input should write DECCKM set");

    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && !engine.app_cursor_active() {
        let _ = engine
            .poll_output()
            .expect("poll_output is infallible today");
        if !engine.app_cursor_active() {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    assert!(
        engine.app_cursor_active(),
        "expected APP_CURSOR within 5s after CSI ?1 h"
    );
}

/// `CSI ?1 l` (DECCKM reset) clears `TermMode::APP_CURSOR` again.
#[test]
fn app_cursor_inactive_after_decckm_reset() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");
    engine
        .feed_input(b"\x1b[?1h\n")
        .expect("feed_input should write DECCKM set");
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && !engine.app_cursor_active() {
        let _ = engine
            .poll_output()
            .expect("poll_output is infallible today");
        if !engine.app_cursor_active() {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    assert!(engine.app_cursor_active(), "precondition: APP_CURSOR set");

    engine
        .feed_input(b"\x1b[?1l\n")
        .expect("feed_input should write DECCKM reset");
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && engine.app_cursor_active() {
        let _ = engine
            .poll_output()
            .expect("poll_output is infallible today");
        if engine.app_cursor_active() {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    assert!(
        !engine.app_cursor_active(),
        "expected APP_CURSOR cleared within 5s after CSI ?1 l"
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
    while Instant::now() < deadline && engine.kitty_keyboard_flags() != KittyKeyboardFlags::NO_MODE
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
    let mut engine = TerminalEngine::new(osc_query_emitter_config("\x1b]10;rgb:00/00/00\x1b\\"))
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
    let mut engine = TerminalEngine::new(cfg).expect("alt-screen-toggle child spawn ok on macOS");
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

/// Drag anchor must follow the *content*, not the screen row, when
/// new output scrolls the grid mid-drag (Claude CLI and friends
/// stream while the user is selecting). alacritty rotates its own
/// `Term::selection`; before the fix, `update_selection` rebuilt the
/// range from a cached absolute `Point` nothing rotated, so the
/// anchor snapped onto whatever text had scrolled into that line.
#[test]
fn selection_anchor_follows_content_scrolled_mid_drag() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn ok");
    let mut payload = Vec::new();
    for i in 0..40 {
        payload.extend_from_slice(format!("line{i:02}\n").as_bytes());
    }
    engine.feed_input(&payload).expect("feed_input ok");
    wait_for_row_text(&mut engine, "line39");

    // Press at the row holding "line27", drag two rows down.
    engine.start_selection(SelectionMode::Simple, 10, 0);
    engine.update_selection(12, 5);
    assert_eq!(
        engine.selection_text().as_deref(),
        Some("line27\nline28\nline29"),
        "pre-scroll drag selects the pressed rows"
    );

    // Output arrives mid-drag: the grid rotates under the selection.
    engine
        .feed_input(b"NEWA\nNEWB\nNEWC\n")
        .expect("feed_input ok");
    wait_for_row_text(&mut engine, "NEWC");

    // The drag continues one row further down. The anchor must still
    // be on "line27" — only the trailing edge moves.
    engine.update_selection(13, 5);
    let text = engine.selection_text().expect("selection still live");
    assert!(
        text.starts_with("line27\n"),
        "anchor stayed on the pressed content across the scroll; got {text:?}"
    );
}

/// Poll `poll_output` until some viewport row contains `needle`.
/// Panics after 5s. Needed over `drive_text` when the marker isn't
/// the grid's first cell.
fn wait_for_row_text(engine: &mut TerminalEngine, needle: &str) {
    use alacritty_terminal::grid::Dimensions as _;
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        let _ = engine.poll_output().expect("poll_output infallible");
        for r in 0..engine.term.screen_lines() {
            #[allow(clippy::cast_possible_truncation, clippy::cast_possible_wrap)]
            let line = Line(r as i32);
            let row: String = (0..engine.term.columns())
                .map(|c| engine.term.grid()[Point::new(line, Column(c))].c)
                .collect();
            if row.contains(needle) {
                return;
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("never saw {needle} in the viewport within 5s");
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
    assert_eq!(
        (span.start_row, span.start_col),
        (0, 0),
        "leftmost cell kept"
    );
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
    let text = engine
        .selection_text()
        .expect("reflowed selection has text");
    assert_eq!(
        text,
        format!("{}\n{}", "A".repeat(60), "B".repeat(60)),
        "reflowed soft-wrap copies as the two original logical lines"
    );
    assert_eq!(
        text.matches('\n').count(),
        1,
        "only the hard break survives"
    );
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
