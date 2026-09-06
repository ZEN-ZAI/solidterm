// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

use super::*;
use alacritty_terminal::event::VoidListener;
use alacritty_terminal::term::test::TermSize;
use alacritty_terminal::term::Term;
use alacritty_terminal::vte::ansi::Processor;

fn make_term(rows: usize, cols: usize) -> Term<VoidListener> {
    let cfg = alacritty_terminal::term::Config {
        scrolling_history: 100,
        ..Default::default()
    };
    let size = TermSize::new(cols, rows);
    Term::new(cfg, &size, VoidListener)
}

fn feed(term: &mut Term<VoidListener>, bytes: &[u8]) {
    let mut processor = Processor::<alacritty_terminal::vte::ansi::StdSyncHandler>::new();
    for &b in bytes {
        processor.advance(term, &[b]);
    }
}

#[test]
fn empty_query_returns_no_matches() {
    let term = make_term(5, 20);
    let hits = search(term.grid(), "", false).unwrap();
    assert!(hits.is_empty());
}

#[test]
fn plain_substring_finds_in_viewport() {
    let mut term = make_term(5, 40);
    feed(&mut term, b"hello world\r\n");
    let hits = search(term.grid(), "world", false).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].line, 0);
    assert_eq!(hits[0].col, 6);
    assert_eq!(hits[0].len, 5);
}

#[test]
fn plain_substring_is_case_insensitive() {
    let mut term = make_term(5, 40);
    feed(&mut term, b"Hello WORLD\r\n");
    let hits = search(term.grid(), "world", false).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].col, 6);
}

#[test]
fn regex_invalid_returns_error() {
    let term = make_term(5, 20);
    let err = search(term.grid(), "(", true).unwrap_err();
    match err {
        SearchError::InvalidRegex(_) => {}
    }
}

#[test]
fn regex_finds_pattern() {
    let mut term = make_term(5, 40);
    feed(&mut term, b"error: file not found\r\n");
    let hits = search(term.grid(), r"\w+: ", true).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].col, 0);
    // "error: " — 7 cells.
    assert_eq!(hits[0].len, 7);
}

#[test]
fn search_walks_scrollback() {
    // Rows = 3, scrolling_history = 100. Feed enough lines to push
    // the first row into scrollback, then search for it.
    let mut term = make_term(3, 40);
    feed(&mut term, b"alpha\r\n");
    for _ in 0..10 {
        feed(&mut term, b"filler\r\n");
    }
    let hits = search(term.grid(), "alpha", false).unwrap();
    assert_eq!(hits.len(), 1, "alpha should be found in scrollback");
    // First feed lands at line 0; scrolled up by 10 → line -10.
    // Exact value depends on alacritty's bookkeeping; assert
    // negative + that the char anchor is column 0.
    assert!(
        hits[0].line < 0,
        "alpha should be in scrollback, got line={}",
        hits[0].line
    );
    assert_eq!(hits[0].col, 0);
    assert_eq!(hits[0].len, 5);
}

#[test]
fn multiple_matches_per_row() {
    let mut term = make_term(3, 40);
    feed(&mut term, b"foo bar foo baz foo\r\n");
    let hits = search(term.grid(), "foo", false).unwrap();
    assert_eq!(hits.len(), 3);
    assert_eq!(hits[0].col, 0);
    assert_eq!(hits[1].col, 8);
    assert_eq!(hits[2].col, 16);
}

#[test]
fn no_match_returns_empty() {
    let mut term = make_term(3, 40);
    feed(&mut term, b"hello\r\n");
    let hits = search(term.grid(), "zzz", false).unwrap();
    assert!(hits.is_empty());
}

#[test]
fn plain_columns_correct_after_multibyte_lowercasing_char() {
    // 'K' (KELVIN SIGN U+212A, 3 bytes) lowercases to 'k' (1 byte).
    // The old plain path searched a separately-lowercased haystack
    // but indexed a column table built from the original text, so the
    // byte-length change desynced the reported column. The match
    // after the Kelvin sign must still land at the right column.
    let mut term = make_term(3, 40);
    feed(&mut term, "\u{212A} hello\r\n".as_bytes());
    let hits = search(term.grid(), "hello", false).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].col, 2, "column must account for the 3-byte 'K'");
    assert_eq!(hits[0].len, 5);
}

#[test]
fn match_ending_on_wide_char_counts_both_cells() {
    // A match ending on a double-width CJK glyph must report the two
    // cells it occupies, not one.
    let mut term = make_term(3, 40);
    feed(&mut term, "a\u{4E16}\r\n".as_bytes()); // "a世"
    let hits = search(term.grid(), "a\u{4E16}", false).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].col, 0);
    assert_eq!(hits[0].len, 3, "'a' (1) + '世' (2) = 3 cells");
}
