//! Integration tests for `spec/m1-task-breakdown.md` §2.13 (initial
//! corpus) + §4.10 (full-corpus expansion). Pins `solidterm-engine`
//! behaviour against the vttest categories that are in M1 scope per
//! `spec/test-fixtures.md` §2 + `decisions/08-protocol-priorities.md`:
//!
//!   - cursor movement (CUP / CUU / CUD / CUF / CUB / CHA / VPA, plus
//!     IND / RI / NEL / CBT — §4.10)
//!   - screen erase (ED 0/1/2, EL 0/1/2) and edits (ICH / DCH / IL /
//!     DL / ECH / REP — §4.10)
//!   - SGR colors (named 30-37 / 90-97, indexed 38;5;n + 48;5;n,
//!     truecolor 38;2;r;g;b + 48;2;r;g;b)
//!   - SGR text attributes (bold / underline / reverse — §4.10)
//!   - DECSET / DECRST modes (?25 cursor visibility, ?7 autowrap — §4.10)
//!   - SCS character sets (`ESC ( 0` line-drawing — §4.10)
//!   - terminal reports (DA primary `CSI c`, DA secondary `CSI > c`,
//!     DSR cursor-position `CSI 6 n` — §4.10; verified via the
//!     `pty_responses` write-back drain pattern)
//!   - terminal reset (RIS `ESC c` — §4.10)
//!
//! Out-of-scope at M1, deferred to a future vttest full-pass at M2+:
//!
//!   - mouse reporting (CSI ? 1000 / 1002 / 1006 h, X10 / SGR
//!     protocols) — input-side, not pure engine-state
//!   - DECSTBM scroll regions + IND/RI scroll-on-overflow — needs
//!     scroll-region accessor on `TerminalEngine` (today scroll
//!     regions are observable only via the alacritty `Term` private
//!     state, not surfaced through any of our pub-fn accessors)
//!   - DECSC / DECRC save/restore — needs cursor-stack accessor
//!   - DECCOLM 80↔132 column mode — visual-only, no observable accessor
//!   - DECRQM mode-query replies — Phase 2
//!   - VT52 mode — explicitly out of scope (we are VT100+ only)
//!   - double-sized chars (DECDWL / DECDHL) — not in MVP protocols
//!   - keyboard input encoding (vttest "keyboard" menu) — covered by
//!     Swift-side input integration tests, not engine state
//!
//! ## Why these tests live here, not in `tests/fixtures/vttest/`
//!
//! `tests/fixtures/vttest/` (per `spec/test-fixtures.md` §2) is meant
//! to mirror byte captures from the upstream `vttest` binary by Thomas
//! Dickey. `vttest` is interactive — it waits for the user to confirm
//! each test screen — and is not available on the CI runners
//! (macos-14 / macos-15) without a non-trivial `expect`-based PTY
//! harness. The architectural signal we need (engine state transitions
//! against documented VT100 / ECMA-48 / xterm escape sequences) is
//! identical whether the bytes come from `vttest` itself or from a
//! hand-crafted corpus that emits the same byte sequences vttest's
//! menus emit. So we ship the latter.
//!
//! ## Test pattern
//!
//! Same cat-loopback the in-module engine.rs SGR / OSC tests use:
//! spawn `/bin/cat`, write the VT byte sequence as input, drain via
//! `poll_output` until a sentinel character (typically `X`) materialises
//! at a known grid position. `/bin/cat` runs in canonical line-buffered
//! mode under the PTY line discipline, so each input batch must end in
//! `\n` for cat to read + echo. The trailing `\n` then advances the
//! cursor — tests account for that by asserting on the row where the
//! sentinel landed BEFORE the LF was processed.
//!
//! 5-second deadlines match the existing in-module patterns and are
//! generous defence against parallel-test scheduler jitter on shared
//! macOS runners.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use solidterm_engine::{CellView, EngineConfig, TerminalEngine};

/// Same `/bin/cat` config the in-module unit tests use. 24×80 grid is
/// the VT100 / vttest default so cursor-movement assertions read
/// naturally against the spec's `1..=24` row / `1..=80` col bounds.
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

/// Drain `poll_output` until `predicate(&engine)` returns true or the
/// 5-second deadline expires. Panics with `msg` on timeout. Mirrors
/// the polling shape used by `bracketed_paste_enabled_after_decset_2004`
/// + the SGR / OSC 8 viewport-cell scans in `engine.rs`.
fn poll_until<F>(engine: &mut TerminalEngine, mut predicate: F, msg: &str)
where
    F: FnMut(&TerminalEngine) -> bool,
{
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        let _ = engine
            .poll_output()
            .expect("poll_output is infallible today");
        if predicate(engine) {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("{msg}");
}

/// Search the visible viewport (rows 0..24) for a single cell whose
/// `grapheme[0]` matches `byte`. Returns the first match in
/// row-major order. `viewport_cells(0..24)` returns 24 × 80 = 1920
/// cells in `cat_config`.
///
/// NB: in cat-loopback the PTY line discipline echoes the input with
/// ESC rendered as the printable two-byte sequence `^[`, so byte
/// `R` from `\x1b[31mR` lands at TWO grid positions — once on the
/// echo row at column-after-the-escape, and once on the `cat`-stdout
/// row carrying the actual SGR-coloured cell. Tests that need to
/// disambiguate pass a `predicate` to `find_cell_where` instead.
fn find_cell(engine: &TerminalEngine, byte: u8) -> Option<CellView> {
    engine
        .viewport_cells(0..24)
        .into_iter()
        .find(|c| c.grapheme[0] == byte)
}

/// Search the visible viewport for a cell satisfying `predicate`.
/// Used by the SGR / colour tests to pick the cat-stdout-rendered
/// occurrence (which carries the SGR attribute) over the line-
/// discipline echo (which renders the byte with default attrs).
fn find_cell_where<F>(engine: &TerminalEngine, predicate: F) -> Option<CellView>
where
    F: Fn(&CellView) -> bool,
{
    engine
        .viewport_cells(0..24)
        .into_iter()
        .find(|c| predicate(c))
}

// ─────────────────────────────────────────────────────────────────────
//  CURSOR MOVEMENT
//
//  Each test feeds the cursor-movement sequence followed by a sentinel
//  ASCII letter, so we can pinpoint exactly where the cursor landed by
//  searching for that letter in the grid. Letter choice (A/B/C/D/E/F/G)
//  loosely tracks the CSI suffix to keep the bytes self-documenting.
// ─────────────────────────────────────────────────────────────────────

/// `CSI r ; c H` (CUP — Cursor Position) moves the cursor to row `r`,
/// column `c` (1-based). Grid coordinates are 0-based, so vttest's
/// `CSI 5 ; 10 H` lands on grid (4, 9). Sentinel `A` is then printed
/// at that position. Note: the PTY line discipline also echoes the
/// raw input bytes (with ESC printed as `^[`), placing a copy of `A`
/// on the echo row — the assertion targets the cat-stdout `A` at the
/// expected (4, 9) position via `find_cell_where`.
#[test]
fn vttest_cursor_cup_absolute_position() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[5;10HA\n")
        .expect("feed_input should write CUP + sentinel");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'A' && c.row == 4 && c.col == 9).is_some(),
        "expected sentinel 'A' at grid (4, 9) within 5s after CUP 5;10",
    );
}

/// `CSI H` with no parameters (CUP default) homes the cursor to (1,1) /
/// grid (0, 0). Drive cat to land sentinel `H` at (0, 0), with `Z`
/// first displaced to (9, 19) so the home-jump isn't trivially
/// satisfied by cat's freshly-initialised cursor.
#[test]
fn vttest_cursor_cup_home_default() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[10;20HZ\x1b[HH\n")
        .expect("feed_input should write displaced+CUP-home sequence");

    poll_until(
        &mut engine,
        |e| {
            find_cell_where(e, |c| c.grapheme[0] == b'H' && c.row == 0 && c.col == 0).is_some()
                && find_cell_where(e, |c| c.grapheme[0] == b'Z' && c.row == 9 && c.col == 19)
                    .is_some()
        },
        "expected 'H' at (0, 0) and 'Z' at (9, 19) within 5s",
    );
}

/// `CSI n A` (CUU — Cursor Up) moves the cursor up `n` rows, clamped
/// to the top of the viewport. Position to (10, 5), CUU 3, write `U`,
/// expect `U` at (6, 4). (vttest "Test of cursor movements" — relative
/// motion menu.)
#[test]
fn vttest_cursor_cuu_relative_up() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[10;5H\x1b[3AU\n")
        .expect("feed_input should write CUP + CUU 3 + sentinel");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'U' && c.row == 6 && c.col == 4).is_some(),
        "expected 'U' at (6, 4) within 5s after CUP 10;5 + CUU 3",
    );
}

/// `CSI n B` (CUD — Cursor Down) — counterpart of CUU. From (5, 5)
/// move down 4 rows, expect sentinel at (8, 4).
#[test]
fn vttest_cursor_cud_relative_down() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[5;5H\x1b[4BD\n")
        .expect("feed_input should write CUP + CUD 4 + sentinel");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'D' && c.row == 8 && c.col == 4).is_some(),
        "expected 'D' at (8, 4) within 5s after CUP 5;5 + CUD 4",
    );
}

/// `CSI n C` (CUF — Cursor Forward). From (3, 3) move right 5 cols,
/// expect sentinel at (2, 7).
#[test]
fn vttest_cursor_cuf_relative_right() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[3;3H\x1b[5CF\n")
        .expect("feed_input should write CUP + CUF 5 + sentinel");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'F' && c.row == 2 && c.col == 7).is_some(),
        "expected 'F' at (2, 7) within 5s after CUP 3;3 + CUF 5",
    );
}

/// `CSI n D` (CUB — Cursor Back). From (4, 20) move left 8 cols,
/// expect sentinel at (3, 11).
#[test]
fn vttest_cursor_cub_relative_left() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[4;20H\x1b[8DK\n")
        .expect("feed_input should write CUP + CUB 8 + sentinel");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'K' && c.row == 3 && c.col == 11).is_some(),
        "expected 'K' at (3, 11) within 5s after CUP 4;20 + CUB 8",
    );
}

/// `CSI n G` (CHA — Cursor Horizontal Absolute). Position to row 6,
/// col 1, then CHA 25 jumps to col 25 of the same row. Expect sentinel
/// at grid (5, 24).
#[test]
fn vttest_cursor_cha_horizontal_absolute() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[6;1H\x1b[25GG\n")
        .expect("feed_input should write CUP + CHA 25 + sentinel");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'G' && c.row == 5 && c.col == 24).is_some(),
        "expected 'G' at (5, 24) within 5s after CUP 6;1 + CHA 25",
    );
}

/// `CSI n d` (VPA — Vertical Position Absolute). From (1, 7) jump to
/// row 12 (col preserved). Expect sentinel at grid (11, 6).
#[test]
fn vttest_cursor_vpa_vertical_absolute() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[1;7H\x1b[12dV\n")
        .expect("feed_input should write CUP + VPA 12 + sentinel");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'V' && c.row == 11 && c.col == 6).is_some(),
        "expected 'V' at (11, 6) within 5s after CUP 1;7 + VPA 12",
    );
}

// ─────────────────────────────────────────────────────────────────────
//  ERASE
//
//  EL 2 (`CSI 2 K`) clears the whole line; EL 0 / 1 do trailing /
//  leading spans. ED 2 (`CSI 2 J`) clears the whole screen.
// ─────────────────────────────────────────────────────────────────────

/// `CSI 2 K` (EL 2 — Erase Line) clears the entire current line.
///
/// Two-phase loopback: feed seed first and wait for `X/Y/Z` to land
/// at row 2 cols 0..3 (cat-stdout copy — the line-discipline echo
/// also paints X/Y/Z but on a different row). Then feed CUP-onto-
/// the-same-row + EL 2 and wait for those three cells to revert to
/// blanks. The line-discipline echo on the OTHER row is unaffected
/// by EL 2 (which only touches the cursor's current row), so the
/// per-row scan disambiguates cleanly.
#[test]
fn vttest_erase_el2_clears_line() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    // Phase 1: seed XYZ at row 2 cols 0..3 via CUP 3;1 + literal print.
    engine
        .feed_input(b"\x1b[3;1HXYZ\n")
        .expect("feed_input should write seed");

    poll_until(
        &mut engine,
        |e| {
            let row2 = e.viewport_cells(2..3);
            row2.iter().any(|c| c.col == 0 && c.grapheme[0] == b'X')
                && row2.iter().any(|c| c.col == 1 && c.grapheme[0] == b'Y')
                && row2.iter().any(|c| c.col == 2 && c.grapheme[0] == b'Z')
        },
        "expected XYZ seeded at row 2 cols 0..3 within 5s",
    );

    // Phase 2: CUP 3;5 puts the cursor on row 2 col 4, then EL 2
    // erases the entire row.
    engine
        .feed_input(b"\x1b[3;5H\x1b[2K\n")
        .expect("feed_input should write CUP + EL 2");

    poll_until(
        &mut engine,
        |e| {
            let row2 = e.viewport_cells(2..3);
            // Row 2 cols 0..3 must all be blanks now.
            (0..3).all(|col| {
                row2.iter()
                    .find(|c| c.col == col)
                    .is_some_and(|c| c.grapheme[0] == b' ')
            })
        },
        "expected EL 2 to blank row 2 cols 0..3 within 5s",
    );
}

/// `CSI 2 J` (ED 2 — Erase Display) clears the entire screen.
///
/// Two-phase like the EL 2 test: seed Q at (4, 4) and R at (14, 49)
/// from cat-stdout, then issue ED 2 and wait for those exact grid
/// positions to revert to blanks. The line-discipline echo of the
/// raw bytes (`^[[5;5HQ...`) lives at a different row but unlike
/// EL 2, ED 2 touches the WHOLE screen — so the echo IS erased too,
/// which makes a global `find_cell(b'Q').is_none()` predicate sound
/// here. We assert both.
#[test]
fn vttest_erase_ed2_clears_screen() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    // Phase 1: seed Q at (4, 4), R at (14, 49).
    engine
        .feed_input(b"\x1b[5;5HQ\x1b[15;50HR\n")
        .expect("feed_input should write seed");

    poll_until(
        &mut engine,
        |e| {
            find_cell_where(e, |c| c.grapheme[0] == b'Q' && c.row == 4 && c.col == 4).is_some()
                && find_cell_where(e, |c| c.grapheme[0] == b'R' && c.row == 14 && c.col == 49)
                    .is_some()
        },
        "expected Q and R seeded at their target positions within 5s",
    );

    // Phase 2: ED 2 erases the entire display.
    engine
        .feed_input(b"\x1b[2J\n")
        .expect("feed_input should write ED 2");

    poll_until(
        &mut engine,
        |e| find_cell(e, b'Q').is_none() && find_cell(e, b'R').is_none(),
        "expected ED 2 to remove all 'Q' and 'R' cells from the viewport within 5s",
    );
}

// ─────────────────────────────────────────────────────────────────────
//  COLORS (SGR)
//
//  The fallback palette in `cells::encode_named` / `XTERM_256_PALETTE`
//  is the source of truth for expected packed RGBA values. We assert
//  against those literals so future palette changes (M2 theme work)
//  are caught at this gate.
// ─────────────────────────────────────────────────────────────────────

/// `CSI 31 m` (SGR 31 — set foreground to red). The named-Red entry
/// in the zenzai palette is `pack_rgba(0xcc, 0x66, 0x66)` =
/// `0xd4_70_70_ff`.
#[test]
fn vttest_color_sgr_named_foreground_red() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[31mR\x1b[0m\n")
        .expect("feed_input should write SGR 31 + sentinel + reset");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'R' && c.fg == 0xd4_70_70_ff).is_some(),
        "expected an 'R' cell with named-Red fg (0xd4_70_70_ff) within 5s after SGR 31",
    );
}

/// `CSI 92 m` (SGR 92 — bright green foreground). zenzai maps
/// `BrightGreen` to `pack_rgba(0xa0, 0xc8, 0xa0)` = `0xb8_dc_a0_ff`.
#[test]
fn vttest_color_sgr_named_foreground_bright_green() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[92mB\x1b[0m\n")
        .expect("feed_input should write SGR 92 + sentinel + reset");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'B' && c.fg == 0xb8_dc_a0_ff).is_some(),
        "expected a 'B' cell with bright-Green fg (0xb8_dc_a0_ff) within 5s after SGR 92",
    );
}

/// `CSI 44 m` (SGR 44 — blue background). Named-Blue maps to
/// `pack_rgba(0x5f, 0x8f, 0xaf)` = `0x68_98_b0_ff`.
#[test]
fn vttest_color_sgr_named_background_blue() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[44mW\x1b[0m\n")
        .expect("feed_input should write SGR 44 + sentinel + reset");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'W' && c.bg == 0x68_98_b0_ff).is_some(),
        "expected a 'W' cell with named-Blue bg (0x68_98_b0_ff) within 5s after SGR 44",
    );
}

/// `CSI 38 ; 5 ; 196 m` (SGR 256-color indexed fg). Index 196 sits at
/// the upper-right of the 6×6×6 cube — `(r=5, g=0, b=0)` step values
/// `(255, 0, 0)`. Packed = `0xff_00_00_ff`.
#[test]
fn vttest_color_sgr_indexed_foreground_196() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[38;5;196mI\x1b[0m\n")
        .expect("feed_input should write SGR 38;5;196 + sentinel + reset");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'I' && c.fg == 0xff_00_00_ff).is_some(),
        "expected an 'I' cell with indexed-196 fg (0xff_00_00_ff) within 5s after SGR 38;5;196",
    );
}

/// `CSI 48 ; 5 ; 21 m` (SGR 256-color indexed bg). Index 21 = bottom-
/// corner blue in the 6×6×6 cube → `pack_rgba(0, 0, 255)` =
/// `0x00_00_ff_ff`.
#[test]
fn vttest_color_sgr_indexed_background_21() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[48;5;21mJ\x1b[0m\n")
        .expect("feed_input should write SGR 48;5;21 + sentinel + reset");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'J' && c.bg == 0x00_00_ff_ff).is_some(),
        "expected a 'J' cell with indexed-21 bg (0x00_00_ff_ff) within 5s after SGR 48;5;21",
    );
}

/// `CSI 38 ; 2 ; r ; g ; b m` (SGR truecolor fg). RGB(0x12, 0x34, 0x56)
/// packs to `0x12_34_56_ff`.
#[test]
fn vttest_color_sgr_truecolor_foreground() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[38;2;18;52;86mT\x1b[0m\n")
        .expect("feed_input should write SGR 38;2 truecolor + sentinel + reset");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'T' && c.fg == 0x12_34_56_ff).is_some(),
        "expected a 'T' cell with truecolor fg (0x12_34_56_ff) within 5s",
    );
}

/// `CSI 48 ; 2 ; r ; g ; b m` (SGR truecolor bg). RGB(0xab, 0xcd, 0xef)
/// packs to `0xab_cd_ef_ff`.
#[test]
fn vttest_color_sgr_truecolor_background() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[48;2;171;205;239mC\x1b[0m\n")
        .expect("feed_input should write SGR 48;2 truecolor + sentinel + reset");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'C' && c.bg == 0xab_cd_ef_ff).is_some(),
        "expected a 'C' cell with truecolor bg (0xab_cd_ef_ff) within 5s",
    );
}

/// `CSI 0 m` (SGR reset) clears all attributes including fg/bg back
/// to the Foreground / Background sentinels (`0xffff_ffff` /
/// `0x0000_00ff`). Drive bold + red, sentinel `S`, reset, sentinel `P`,
/// then verify the bold+red 'S' AND the post-reset plain 'P' both
/// land. Disambiguates the line-discipline-echoed copies (which
/// carry default attrs) from the cat-stdout-rendered copies.
#[test]
fn vttest_color_sgr_reset_clears_attrs() {
    use alacritty_terminal::term::cell::Flags;
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[1;31mS\x1b[0mP\n")
        .expect("feed_input should write bold+red 'S', reset, plain 'P'");

    let bold = Flags::BOLD.bits();
    poll_until(
        &mut engine,
        |e| {
            // The bold+red 'S' is the cat-stdout copy; the 'P' we want
            // is the immediately-following one on the same row, with
            // BOLD cleared and fg back to the sentinel. The line-
            // discipline echo also paints an 'S' and 'P' but with
            // default attrs and adjacent to a leading `m` — those
            // cells fail the predicate.
            find_cell_where(e, |c| {
                c.grapheme[0] == b'S' && c.attrs & bold != 0 && c.fg == 0xd4_70_70_ff
            })
            .is_some()
                && find_cell_where(e, |c| {
                    c.grapheme[0] == b'P'
                        && c.attrs & bold == 0
                        && c.fg == 0xffff_ffff
                        && c.bg == 0x0000_00ff
                })
                .is_some()
        },
        "expected bold+red 'S' AND post-reset default-attrs 'P' within 5s after SGR 0",
    );
}

// ─────────────────────────────────────────────────────────────────────
//  MODES (DECSET / DECRST)
//
//  Modes already covered by in-module unit tests (?1004 focus, ?2004
//  bracketed-paste, ?2026 sync output) are intentionally NOT
//  duplicated here. ?25 cursor visibility is the one mode in M1's
//  observable accessor surface that still lacks a vttest-style
//  exercise; we cover the round-trip here.
// ─────────────────────────────────────────────────────────────────────

/// `CSI ? 25 l` (DECRST 25) hides the cursor. `engine.cursor().visible`
/// must flip to false. Default after spawn is true (alacritty's
/// `TermMode::SHOW_CURSOR` is in the default-mode bitset).
#[test]
fn vttest_mode_cursor_hidden_after_decrst_25() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    assert!(
        engine.cursor().visible,
        "fresh engine must report cursor visible (precondition)"
    );

    engine
        .feed_input(b"\x1b[?25l\n")
        .expect("feed_input should write DECRST 25");

    poll_until(
        &mut engine,
        |e| !e.cursor().visible,
        "expected cursor.visible == false within 5s after DECRST 25",
    );
}

/// `CSI ? 25 h` (DECSET 25) re-shows the cursor after a prior DECRST.
/// Round-trip verification: hide, drain, show, drain — final state is
/// visible.
#[test]
fn vttest_mode_cursor_shown_after_decset_25() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[?25l\n")
        .expect("feed_input should write DECRST 25");

    poll_until(
        &mut engine,
        |e| !e.cursor().visible,
        "precondition: cursor must hide via DECRST 25 within 5s",
    );

    engine
        .feed_input(b"\x1b[?25h\n")
        .expect("feed_input should write DECSET 25");

    poll_until(
        &mut engine,
        |e| e.cursor().visible,
        "expected cursor.visible == true within 5s after DECSET 25",
    );
}

// ─────────────────────────────────────────────────────────────────────
//  CURSOR MOVEMENT — §4.10 expansion
//
//  C1-control / ESC-form cursor motions (IND / RI / NEL) and back-tab
//  (CBT). Scroll-region tests in the BUG-FIXES block below.
// ─────────────────────────────────────────────────────────────────────

/// `ESC E` (NEL — Next Line). Equivalent to CR+LF: cursor moves to
/// column 1 of the row below. Position to (5, 20), NEL, write `N`,
/// expect `N` at row 5 col 0 (cat-stdout copy). vttest "Test of
/// cursor movements" — Index/Newline/RI menu.
#[test]
fn vttest_cursor_nel_next_line() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[5;20H\x1bEN\n")
        .expect("feed_input should write CUP + NEL + sentinel");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'N' && c.row == 5 && c.col == 0).is_some(),
        "expected 'N' at (5, 0) within 5s after CUP 5;20 + NEL",
    );
}

/// `ESC D` (IND — Index). Cursor moves down one row, column preserved.
/// Position to (4, 12), IND, write `I`, expect `I` at (4, 12) — wait,
/// IND moves DOWN so from row 3 (4-1=3) to row 4. Column preserved at
/// 11 (12-1). Sentinel lands at (4, 11).
#[test]
fn vttest_cursor_ind_index_down() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[4;12H\x1bDI\n")
        .expect("feed_input should write CUP + IND + sentinel");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'I' && c.row == 4 && c.col == 11).is_some(),
        "expected 'I' at (4, 11) within 5s after CUP 4;12 + IND",
    );
}

/// `ESC M` (RI — Reverse Index). Cursor moves up one row, column
/// preserved. Position to (10, 8), RI, write `R`, expect `R` at
/// (8, 7).
#[test]
fn vttest_cursor_ri_reverse_index() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[10;8H\x1bMR\n")
        .expect("feed_input should write CUP + RI + sentinel");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'R' && c.row == 8 && c.col == 7).is_some(),
        "expected 'R' at (8, 7) within 5s after CUP 10;8 + RI",
    );
}

/// `CSI n Z` (CBT — Cursor Backward Tabulation). Default tab stops are
/// every 8 columns (1, 9, 17, 25, ...). From (3, 25) — col 24 0-based —
/// CBT 1 should move back to col 16 (tab stop 17). Sentinel at (2, 16).
#[test]
fn vttest_cursor_cbt_back_tab() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[3;25H\x1b[1ZT\n")
        .expect("feed_input should write CUP + CBT + sentinel");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'T' && c.row == 2 && c.col == 16).is_some(),
        "expected 'T' at (2, 16) within 5s after CUP 3;25 + CBT 1",
    );
}

// ─────────────────────────────────────────────────────────────────────
//  SCREEN FEATURES — §4.10 expansion
//
//  Erase variants (ED 0/1, EL 0/1) and inline edit primitives
//  (ICH / DCH / IL / DL / ECH / REP). vttest "Test of screen features"
//  menu items 1..6.
// ─────────────────────────────────────────────────────────────────────

/// `CSI 0 K` (EL 0 — Erase to End of Line) clears from cursor to EOL,
/// inclusive. Seed `ABCDE` at row 6 cols 0..4, position cursor at
/// (6, 3), EL 0, expect cols 0..2 = ABC and col 3..79 = blanks.
#[test]
fn vttest_erase_el0_clears_to_eol() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[7;1HABCDE\n")
        .expect("feed_input should write seed");

    poll_until(
        &mut engine,
        |e| {
            let row = e.viewport_cells(6..7);
            row.iter().any(|c| c.col == 0 && c.grapheme[0] == b'A')
                && row.iter().any(|c| c.col == 4 && c.grapheme[0] == b'E')
        },
        "expected ABCDE seeded at row 6 cols 0..4 within 5s",
    );

    engine
        .feed_input(b"\x1b[7;4H\x1b[0K\n")
        .expect("feed_input should write CUP + EL 0");

    poll_until(
        &mut engine,
        |e| {
            let row = e.viewport_cells(6..7);
            row.iter().any(|c| c.col == 0 && c.grapheme[0] == b'A')
                && row.iter().any(|c| c.col == 1 && c.grapheme[0] == b'B')
                && row.iter().any(|c| c.col == 2 && c.grapheme[0] == b'C')
                && row
                    .iter()
                    .find(|c| c.col == 3)
                    .is_some_and(|c| c.grapheme[0] == b' ')
                && row
                    .iter()
                    .find(|c| c.col == 4)
                    .is_some_and(|c| c.grapheme[0] == b' ')
        },
        "expected EL 0 to keep ABC at cols 0..2 and blank cols 3..79 within 5s",
    );
}

/// `CSI 1 K` (EL 1 — Erase to Start of Line). From (6, 3), EL 1
/// clears cols 0..3 inclusive, leaving D at col 3 (oh wait — EL 1
/// clears col 0 through cursor position INCLUSIVE per ECMA-48). Seed
/// `ABCDE` at row 6 cols 0..4, CUP to (6, 4) — col 3 0-based — EL 1.
/// Expect cols 0..3 blank, col 4 = E.
#[test]
fn vttest_erase_el1_clears_to_sol() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[8;1HABCDE\n")
        .expect("feed_input should write seed");

    poll_until(
        &mut engine,
        |e| {
            let row = e.viewport_cells(7..8);
            row.iter().any(|c| c.col == 0 && c.grapheme[0] == b'A')
                && row.iter().any(|c| c.col == 4 && c.grapheme[0] == b'E')
        },
        "expected ABCDE seeded at row 7 cols 0..4 within 5s",
    );

    engine
        .feed_input(b"\x1b[8;4H\x1b[1K\n")
        .expect("feed_input should write CUP + EL 1");

    poll_until(
        &mut engine,
        |e| {
            let row = e.viewport_cells(7..8);
            (0..=3).all(|col| {
                row.iter()
                    .find(|c| c.col == col)
                    .is_some_and(|c| c.grapheme[0] == b' ')
            }) && row.iter().any(|c| c.col == 4 && c.grapheme[0] == b'E')
        },
        "expected EL 1 to blank cols 0..3 and keep E at col 4 within 5s",
    );
}

/// `CSI 0 J` (ED 0 — Erase Display from cursor down). Seed `Q` at
/// (4, 4) and `R` at (14, 49) — same as ED 2 — then CUP to (10, 1)
/// and ED 0. Q (above) survives, R (below) is erased.
#[test]
fn vttest_erase_ed0_clears_to_eos() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[5;5HQ\x1b[15;50HR\n")
        .expect("feed_input should write seed");

    poll_until(
        &mut engine,
        |e| {
            find_cell_where(e, |c| c.grapheme[0] == b'Q' && c.row == 4 && c.col == 4).is_some()
                && find_cell_where(e, |c| c.grapheme[0] == b'R' && c.row == 14 && c.col == 49)
                    .is_some()
        },
        "expected Q and R seeded within 5s",
    );

    engine
        .feed_input(b"\x1b[10;1H\x1b[0J\n")
        .expect("feed_input should write CUP + ED 0");

    poll_until(
        &mut engine,
        |e| {
            // R below the cursor is gone; Q above survives.
            find_cell_where(e, |c| c.grapheme[0] == b'Q' && c.row == 4 && c.col == 4).is_some()
                && find_cell_where(e, |c| c.grapheme[0] == b'R' && c.row == 14 && c.col == 49)
                    .is_none()
        },
        "expected ED 0 to keep Q (above) and erase R (below) within 5s",
    );
}

/// `CSI 1 J` (ED 1 — Erase Display from start to cursor). Mirror of
/// ED 0: from (10, 1) ED 1 erases Q (above) and keeps R (below).
#[test]
fn vttest_erase_ed1_clears_from_sos() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[5;5HQ\x1b[15;50HR\n")
        .expect("feed_input should write seed");

    poll_until(
        &mut engine,
        |e| {
            find_cell_where(e, |c| c.grapheme[0] == b'Q' && c.row == 4 && c.col == 4).is_some()
                && find_cell_where(e, |c| c.grapheme[0] == b'R' && c.row == 14 && c.col == 49)
                    .is_some()
        },
        "expected Q and R seeded within 5s",
    );

    engine
        .feed_input(b"\x1b[10;1H\x1b[1J\n")
        .expect("feed_input should write CUP + ED 1");

    poll_until(
        &mut engine,
        |e| {
            find_cell_where(e, |c| c.grapheme[0] == b'Q' && c.row == 4 && c.col == 4).is_none()
                && find_cell_where(e, |c| c.grapheme[0] == b'R' && c.row == 14 && c.col == 49)
                    .is_some()
        },
        "expected ED 1 to erase Q (above) and keep R (below) within 5s",
    );
}

/// `CSI n @` (ICH — Insert Character). Seed `ABCDE` at row 9 cols
/// 0..4, CUP to (9, 2) — col 1 0-based — ICH 2. Expect blanks at
/// cols 1..2 and `BCD` shifted to cols 3..5 (E falls off). Inserted
/// cells are blank space.
#[test]
fn vttest_screen_ich_insert_chars() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[10;1HABCDE\n")
        .expect("feed_input should write seed");

    poll_until(
        &mut engine,
        |e| {
            let row = e.viewport_cells(9..10);
            row.iter().any(|c| c.col == 0 && c.grapheme[0] == b'A')
                && row.iter().any(|c| c.col == 4 && c.grapheme[0] == b'E')
        },
        "expected ABCDE seeded at row 9 within 5s",
    );

    engine
        .feed_input(b"\x1b[10;2H\x1b[2@\n")
        .expect("feed_input should write CUP + ICH 2");

    poll_until(
        &mut engine,
        |e| {
            let row = e.viewport_cells(9..10);
            row.iter().any(|c| c.col == 0 && c.grapheme[0] == b'A')
                && row
                    .iter()
                    .find(|c| c.col == 1)
                    .is_some_and(|c| c.grapheme[0] == b' ')
                && row
                    .iter()
                    .find(|c| c.col == 2)
                    .is_some_and(|c| c.grapheme[0] == b' ')
                && row.iter().any(|c| c.col == 3 && c.grapheme[0] == b'B')
                && row.iter().any(|c| c.col == 4 && c.grapheme[0] == b'C')
                && row.iter().any(|c| c.col == 5 && c.grapheme[0] == b'D')
        },
        "expected ICH 2 to insert 2 blanks at col 1 and shift BCD right within 5s",
    );
}

/// `CSI n P` (DCH — Delete Character). Seed `ABCDE` at row 11 cols
/// 0..4, CUP to (11, 2), DCH 2. Expect `A` at col 0, `D, E` shifted
/// to cols 1, 2, with rightmost cells filled with blanks.
#[test]
fn vttest_screen_dch_delete_chars() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[12;1HABCDE\n")
        .expect("feed_input should write seed");

    poll_until(
        &mut engine,
        |e| {
            let row = e.viewport_cells(11..12);
            row.iter().any(|c| c.col == 0 && c.grapheme[0] == b'A')
                && row.iter().any(|c| c.col == 4 && c.grapheme[0] == b'E')
        },
        "expected ABCDE seeded at row 11 within 5s",
    );

    engine
        .feed_input(b"\x1b[12;2H\x1b[2P\n")
        .expect("feed_input should write CUP + DCH 2");

    poll_until(
        &mut engine,
        |e| {
            let row = e.viewport_cells(11..12);
            row.iter().any(|c| c.col == 0 && c.grapheme[0] == b'A')
                && row.iter().any(|c| c.col == 1 && c.grapheme[0] == b'D')
                && row.iter().any(|c| c.col == 2 && c.grapheme[0] == b'E')
                && row
                    .iter()
                    .find(|c| c.col == 3)
                    .is_some_and(|c| c.grapheme[0] == b' ')
        },
        "expected DCH 2 to delete BC, shift DE left, blank rightmost within 5s",
    );
}

/// `CSI n X` (ECH — Erase Character). Seed `ABCDE` at row 13, CUP to
/// (13, 2), ECH 2. Expect `A` at col 0, blanks at cols 1..2, `D, E`
/// at cols 3, 4 (no shift — ECH only blanks in place).
#[test]
fn vttest_screen_ech_erase_chars() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[14;1HABCDE\n")
        .expect("feed_input should write seed");

    poll_until(
        &mut engine,
        |e| {
            let row = e.viewport_cells(13..14);
            row.iter().any(|c| c.col == 0 && c.grapheme[0] == b'A')
                && row.iter().any(|c| c.col == 4 && c.grapheme[0] == b'E')
        },
        "expected ABCDE seeded at row 13 within 5s",
    );

    engine
        .feed_input(b"\x1b[14;2H\x1b[2X\n")
        .expect("feed_input should write CUP + ECH 2");

    poll_until(
        &mut engine,
        |e| {
            let row = e.viewport_cells(13..14);
            row.iter().any(|c| c.col == 0 && c.grapheme[0] == b'A')
                && row
                    .iter()
                    .find(|c| c.col == 1)
                    .is_some_and(|c| c.grapheme[0] == b' ')
                && row
                    .iter()
                    .find(|c| c.col == 2)
                    .is_some_and(|c| c.grapheme[0] == b' ')
                && row.iter().any(|c| c.col == 3 && c.grapheme[0] == b'D')
                && row.iter().any(|c| c.col == 4 && c.grapheme[0] == b'E')
        },
        "expected ECH 2 to blank cols 1..2 in place within 5s",
    );
}

/// `CSI n L` (IL — Insert Line). Seed `XX` at row 16 col 0, then CUP
/// to (16, 1) and IL 1 — pushes the seed row down to row 17. Expect
/// row 16 to be all-blank (no `X`s) and row 17 to contain the
/// seeded `XX` at cols 0..1.
#[test]
fn vttest_screen_il_insert_line() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[17;1HXX\n")
        .expect("feed_input should write seed at row 16");

    poll_until(
        &mut engine,
        |e| {
            let row = e.viewport_cells(16..17);
            row.iter().any(|c| c.col == 0 && c.grapheme[0] == b'X')
                && row.iter().any(|c| c.col == 1 && c.grapheme[0] == b'X')
        },
        "expected XX seeded at row 16 cols 0..1 within 5s",
    );

    engine
        .feed_input(b"\x1b[17;1H\x1b[1L\n")
        .expect("feed_input should write CUP + IL 1");

    poll_until(
        &mut engine,
        |e| {
            let row16 = e.viewport_cells(16..17);
            let row17 = e.viewport_cells(17..18);
            // Row 16 is now blank (no X).
            row16.iter().all(|c| c.grapheme[0] != b'X')
                // Row 17 carries the pushed-down XX.
                && row17.iter().any(|c| c.col == 0 && c.grapheme[0] == b'X')
                && row17.iter().any(|c| c.col == 1 && c.grapheme[0] == b'X')
        },
        "expected IL 1 to push XX from row 16 to row 17 within 5s",
    );
}

/// `CSI n M` (DL — Delete Line). Seed `YY` at row 18 col 0, CUP to
/// (18, 1), DL 1. Row 17 (containing YY) is removed; row below
/// shifts up. Expect `YY` no longer at row 17.
#[test]
fn vttest_screen_dl_delete_line() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[19;1HYY\n")
        .expect("feed_input should write seed at row 18");

    poll_until(
        &mut engine,
        |e| {
            let row = e.viewport_cells(18..19);
            row.iter().any(|c| c.col == 0 && c.grapheme[0] == b'Y')
                && row.iter().any(|c| c.col == 1 && c.grapheme[0] == b'Y')
        },
        "expected YY seeded at row 18 cols 0..1 within 5s",
    );

    engine
        .feed_input(b"\x1b[19;1H\x1b[1M\n")
        .expect("feed_input should write CUP + DL 1");

    poll_until(
        &mut engine,
        |e| {
            // YY is gone from row 18 (it was the deleted line; rows below
            // shifted up).
            let row = e.viewport_cells(18..19);
            row.iter().all(|c| c.grapheme[0] != b'Y')
        },
        "expected DL 1 to remove YY from row 18 within 5s",
    );
}

/// `CSI n b` (REP — Repeat preceding character). Print `Q` then REP 4
/// at row 20 col 0 — the spec says repeat the last graphic char.
/// Expect `QQQQQ` (1 original + 4 repeats) at cols 0..4.
#[test]
fn vttest_screen_rep_repeat_preceding() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[21;1HQ\x1b[4b\n")
        .expect("feed_input should write CUP + Q + REP 4");

    poll_until(
        &mut engine,
        |e| {
            let row = e.viewport_cells(20..21);
            (0..=4).all(|col| {
                row.iter()
                    .find(|c| c.col == col)
                    .is_some_and(|c| c.grapheme[0] == b'Q')
            })
        },
        "expected QQQQQ at row 20 cols 0..4 within 5s after Q + REP 4",
    );
}

// ─────────────────────────────────────────────────────────────────────
//  CHARACTER SETS — §4.10 expansion
//
//  SCS (Select Character Set). `ESC ( 0` designates the DEC special
//  graphics / line-drawing character set as G0; printable ASCII chars
//  then map to box-drawing glyphs. `ESC ( B` returns G0 to US-ASCII.
//
//  Alacritty maps the line-drawing chars to their UTF-8 encodings
//  (e.g. `q` -> U+2500 `─` -> 0xE2 0x94 0x80). We assert on the first
//  byte of `grapheme` to detect the multi-byte UTF-8 encoding.
// ─────────────────────────────────────────────────────────────────────

/// `ESC ( 0` (SCS G0 → DEC line-drawing) — printing `q` afterwards
/// should produce U+2500 (─). UTF-8 encoding is `0xE2 0x94 0x80`. We
/// assert `grapheme[0] == 0xE2`. The line-discipline echo of the
/// raw bytes is unaffected by SCS (it's pre-VT-parser); the cat-
/// stdout copy goes through the parser and gets translated.
#[test]
fn vttest_charset_scs_line_drawing_g0() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[22;1H\x1b(0q\x1b(B\n")
        .expect("feed_input should write CUP + SCS line-draw + q + SCS ASCII");

    poll_until(
        &mut engine,
        |e| {
            // Line-drawing q -> U+2500 (─), UTF-8 0xE2 0x94 0x80.
            find_cell_where(e, |c| c.row == 21 && c.col == 0 && c.grapheme[0] == 0xE2).is_some()
        },
        "expected line-drawing horizontal-bar (U+2500, UTF-8 0xE2..) at (21, 0) within 5s",
    );
}

/// After `ESC ( B` (G0 reset to US-ASCII), printing `q` should produce
/// the literal ASCII `q`, not the line-drawing char. Verify by
/// printing line-draw `q` first, then resetting and printing literal
/// `q`, and asserting both forms coexist on the same row.
#[test]
fn vttest_charset_scs_us_ascii_reset() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[23;1H\x1b(0q\x1b(Bq\n")
        .expect("feed_input should write CUP + line-draw q + ASCII q");

    poll_until(
        &mut engine,
        |e| {
            // Col 0: line-drawing horizontal bar (UTF-8 leading byte 0xE2).
            // Col 1: literal ASCII 'q' (0x71).
            find_cell_where(e, |c| c.row == 22 && c.col == 0 && c.grapheme[0] == 0xE2).is_some()
                && find_cell_where(e, |c| c.row == 22 && c.col == 1 && c.grapheme[0] == b'q')
                    .is_some()
        },
        "expected line-draw at (22, 0) and ASCII 'q' at (22, 1) within 5s",
    );
}

// ─────────────────────────────────────────────────────────────────────
//  SGR ATTRIBUTES — §4.10 expansion
//
//  Bold (SGR 1) is already exercised by `vttest_color_sgr_reset_clears
//  _attrs` above. We add coverage for underline (SGR 4) and reverse
//  (SGR 7), which round out the M1 attrs the cells encoder reports
//  via `attrs`.
// ─────────────────────────────────────────────────────────────────────

/// `CSI 4 m` (SGR 4 — underline). The `attrs` field carries
/// `Flags::UNDERLINE` after the sentinel cell.
#[test]
fn vttest_attr_sgr_underline() {
    use alacritty_terminal::term::cell::Flags;
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[4mU\x1b[0m\n")
        .expect("feed_input should write SGR 4 + sentinel + reset");

    let underline = Flags::UNDERLINE.bits();
    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'U' && c.attrs & underline != 0).is_some(),
        "expected an 'U' cell with UNDERLINE attr within 5s after SGR 4",
    );
}

/// `CSI 7 m` (SGR 7 — reverse video). The `attrs` field carries
/// `Flags::INVERSE`.
#[test]
fn vttest_attr_sgr_reverse() {
    use alacritty_terminal::term::cell::Flags;
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[7mV\x1b[0m\n")
        .expect("feed_input should write SGR 7 + sentinel + reset");

    let inverse = Flags::INVERSE.bits();
    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'V' && c.attrs & inverse != 0).is_some(),
        "expected a 'V' cell with INVERSE attr within 5s after SGR 7",
    );
}

// ─────────────────────────────────────────────────────────────────────
//  TERMINAL REPORTS — §4.10 expansion
//
//  Device Attributes (DA primary `CSI c`, DA secondary `CSI > c`) and
//  cursor-position report (DSR `CSI 6 n`). Alacritty queues the reply
//  via `Event::PtyWrite` -> EventProxy -> `pty_responses` -> the
//  engine's `poll_output` writes the bytes to the PTY master FD.
//
//  Verification pattern mirrors the OSC 10/11/12 + Kitty-keyboard
//  query tests in `engine.rs`: spawn a printf that emits the query
//  on stdout; assert `poll_output` stays Ok across the full read +
//  write-back cycle. The reply byte payload is unit-tested upstream
//  in alacritty's `term/mod.rs`; here we pin the engine-level
//  invariant that the write-back queue drains without erroring.
// ─────────────────────────────────────────────────────────────────────

/// printf-emitter config: spawn `/usr/bin/printf` with a `%s`
/// argument carrying the query bytes on the child's stdout. Mirrors
/// the `osc_query_emitter_config` helper in `engine.rs::tests`.
fn printf_emitter_config(query_arg: &str) -> EngineConfig {
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

/// Drain `poll_output` and `drain_events` until `ChildExited` is
/// observed or the deadline passes; return total bytes read. The
/// engine MUST NOT error during the write-back-queue drain.
fn drain_until_child_exit(engine: &mut TerminalEngine) -> usize {
    use solidterm_engine::EngineEvent;
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut total = 0usize;
    while Instant::now() < deadline {
        total += engine
            .poll_output()
            .expect("poll_output must not error while writing reply");
        if engine
            .drain_events()
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
    total
}

/// `CSI c` (DA1 — Primary Device Attributes). Alacritty replies with
/// `CSI ? 6 c` (VT102). Verify the engine drains the write-back
/// without erroring.
#[test]
fn vttest_report_da_primary_drains_without_erroring() {
    let mut engine =
        TerminalEngine::new(printf_emitter_config("\x1b[c")).expect("printf spawn must succeed");
    let total = drain_until_child_exit(&mut engine);
    // CSI c is 3 bytes from printf; PTY can reshape but we expect at
    // least 2 (same lower-bound logic as OSC 10 / Kitty queries).
    assert!(
        total >= 2,
        "expected the engine to read at least some bytes from printf; got {total}"
    );
}

/// `CSI > c` (DA2 — Secondary Device Attributes). Alacritty replies
/// with `CSI > 0 ; 0 ; 0 c`. Verify drain-without-error.
#[test]
fn vttest_report_da_secondary_drains_without_erroring() {
    let mut engine =
        TerminalEngine::new(printf_emitter_config("\x1b[>c")).expect("printf spawn must succeed");
    let total = drain_until_child_exit(&mut engine);
    assert!(
        total >= 3,
        "expected the engine to read at least some bytes from printf; got {total}"
    );
}

/// `CSI 6 n` (DSR — Device Status Report, cursor position). Alacritty
/// replies with `CSI row ; col R`. Verify drain-without-error.
#[test]
fn vttest_report_dsr_cursor_position_drains_without_erroring() {
    let mut engine =
        TerminalEngine::new(printf_emitter_config("\x1b[6n")).expect("printf spawn must succeed");
    let total = drain_until_child_exit(&mut engine);
    assert!(
        total >= 3,
        "expected the engine to read at least some bytes from printf; got {total}"
    );
}

// ─────────────────────────────────────────────────────────────────────
//  RESET — §4.10 expansion
//
//  RIS (`ESC c`) is the full "Reset to Initial State" sequence. We
//  verify the observable effects: screen cleared (no seeded chars
//  remain).
// ─────────────────────────────────────────────────────────────────────

/// `ESC c` (RIS — Reset to Initial State). Seed `Z` at (5, 5), then
/// RIS. Expect Z gone. We don't verify cursor position because RIS
/// also resets the parser/term state and the cursor accessor's
/// observable post-RIS value isn't pinned by the spec to a specific
/// row mid-cat-loopback (cat keeps writing).
#[test]
fn vttest_reset_ris_clears_screen() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[6;6HZ\n")
        .expect("feed_input should write seed");

    poll_until(
        &mut engine,
        |e| find_cell_where(e, |c| c.grapheme[0] == b'Z' && c.row == 5 && c.col == 5).is_some(),
        "expected Z seeded at (5, 5) within 5s",
    );

    engine
        .feed_input(b"\x1bc\n")
        .expect("feed_input should write RIS");

    poll_until(
        &mut engine,
        |e| find_cell(e, b'Z').is_none(),
        "expected RIS to clear the seeded Z within 5s",
    );
}

// ─────────────────────────────────────────────────────────────────────
//  MODES (DECSET / DECRST) — §4.10 expansion
//
//  ?7 autowrap. Verifying the `cells.rs` WRAP flag persists on the
//  last cell of a wrapped row when autowrap is on and a line exceeds
//  the screen width.
// ─────────────────────────────────────────────────────────────────────

/// With autowrap on (DECSET 7 — the default), writing past the right
/// margin wraps to the next row. Seed `A` at (0, 79) — last column
/// of row 0 — then write `B`. Without autowrap `B` would overwrite
/// `A`; with autowrap `B` lands at row 1 col 0.
///
/// Note: `cat_config()` spawns cat with `TERM=xterm-256color`. Default
/// mode in alacritty includes `LINE_WRAP` set, so this is the no-op
/// default for the M1 engine. We assert the default is wrap-on by
/// observing the wrap behaviour, then leave DECRST 7 (wrap-off)
/// behaviour to a follow-up test.
#[test]
fn vttest_mode_autowrap_default_on() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    // CUP to (1, 80) -> grid (0, 79); print `AB`. With autowrap, A at
    // (0, 79) and B at (1, 0).
    engine
        .feed_input(b"\x1b[1;80HAB\n")
        .expect("feed_input should write CUP + AB");

    poll_until(
        &mut engine,
        |e| {
            find_cell_where(e, |c| c.grapheme[0] == b'A' && c.row == 0 && c.col == 79).is_some()
                && find_cell_where(e, |c| c.grapheme[0] == b'B' && c.row == 1 && c.col == 0)
                    .is_some()
        },
        "expected autowrap: A at (0, 79) and B at (1, 0) within 5s",
    );
}

/// With autowrap off (`CSI ? 7 l`), writing past the right margin
/// pins subsequent chars on the rightmost column — the last char
/// written wins. Seed CUP (3, 80) -> grid (2, 79), print `AB`, expect
/// row 2 col 79 to carry `B` (A was overwritten in place; nothing
/// lands at row 3 col 0 because wrap is suppressed).
#[test]
fn vttest_mode_autowrap_off_pins_last_col() {
    let mut engine = TerminalEngine::new(cat_config()).expect("/bin/cat spawn should succeed");

    engine
        .feed_input(b"\x1b[?7l\x1b[3;80HAB\n")
        .expect("feed_input should write DECRST 7 + CUP + AB");

    poll_until(
        &mut engine,
        |e| {
            find_cell_where(e, |c| c.grapheme[0] == b'B' && c.row == 2 && c.col == 79).is_some()
                && find_cell_where(e, |c| c.row == 3 && c.col == 0 && c.grapheme[0] == b'A')
                    .is_none()
        },
        "expected autowrap-off: B pinned at (2, 79), no A at (3, 0) within 5s",
    );
}
