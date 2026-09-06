//! M7-2 ⌘F find-in-scrollback. Walks the full alacritty grid (history +
//! viewport) row-by-row, reconstructs each row's visible text, and
//! returns plain-substring or regex matches as `(absolute_line, col,
//! len)` triples.
//!
//! Coordinates are alacritty-native: `line` is the absolute `Line`
//! coordinate (negative = scrollback, `[0..screen_lines)` = viewport).
//! Column is 0-indexed cell position; `len` is match length in **cells**
//! (graphemes contribute one cell each in alacritty's grid; CJK
//! double-wide cells contribute two — the search aligns matches to
//! cell boundaries, never half a wide cell).

use alacritty_terminal::grid::{Dimensions, Grid};
use alacritty_terminal::index::{Column, Line, Point};
use alacritty_terminal::term::cell::Cell;
use regex::{Regex, RegexBuilder};

/// One search hit. `line` is alacritty-absolute (negative for scrollback,
/// `0..screen_lines` for the visible viewport).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SearchMatch {
    pub line: i32,
    pub col: u16,
    pub len: u16,
}

/// Caller-facing error: surfaces malformed regex back to Swift so the
/// search panel can render a "syntax error" chip instead of swallowing
/// the typo.
#[derive(Debug, thiserror::Error)]
pub enum SearchError {
    #[error("invalid regex: {0}")]
    InvalidRegex(String),
}

/// Plain-substring or regex search across the full grid (history +
/// viewport). Empty `query` returns an empty match list.
///
/// Match cap (`MAX_MATCHES`) prevents pathological queries (e.g. `.`
/// in a 10k-line scrollback) from saturating the FFI wire payload —
/// 10k matches at 8 bytes/match is 80 KB, still cheap to serialize but
/// a pragmatic ceiling.
///
/// Plain mode is case-insensitive (matches Ghostty / iTerm2 default);
/// regex mode honors the user's `(?i)` / `(?-i)` inline flags.
pub fn search(
    grid: &Grid<Cell>,
    query: &str,
    use_regex: bool,
) -> Result<Vec<SearchMatch>, SearchError> {
    if query.is_empty() {
        return Ok(Vec::new());
    }

    let cols = grid.columns();
    let topmost = grid.topmost_line().0;
    let bottommost = grid.bottommost_line().0;

    // Both modes search `text` directly, so match byte-offsets index the
    // `byte_to_col` table built from the SAME string. Plain mode compiles
    // the query as an escaped, case-insensitive literal (matches Ghostty /
    // iTerm2). This also fixes a prior bug: plain mode searched a
    // separately-lowercased haystack but indexed columns from the
    // original-case text, so any character whose lowercase form changed
    // UTF-8 byte length (e.g. 'K' U+212A → 'k', 'İ' U+0130 → 'i̇') desynced
    // the reported column or dropped the match. Regex mode honors the
    // user's own inline `(?i)` flags.
    let regex: Regex = if use_regex {
        RegexBuilder::new(query)
            .case_insensitive(false)
            .build()
            .map_err(|e| SearchError::InvalidRegex(e.to_string()))?
    } else {
        // `regex::escape` output is always a valid pattern; the map_err is
        // belt-and-suspenders.
        RegexBuilder::new(&regex::escape(query))
            .case_insensitive(true)
            .build()
            .map_err(|e| SearchError::InvalidRegex(e.to_string()))?
    };

    let mut out: Vec<SearchMatch> = Vec::new();

    for line in topmost..=bottommost {
        // Reconstruct row text + a parallel byte→column index so regex /
        // substring offsets can be mapped back to cell columns. CJK
        // wide cells push their continuation cell as a zero-width space
        // marker — but alacritty's `Flags::WIDE_CHAR_SPACER` cells hold
        // the same `c` as the leading wide cell's spacer position, so
        // we explicitly skip them via the flag check below.
        let mut text = String::with_capacity(cols);
        // `byte_to_col[b]` = leftmost column of the cell byte `b` belongs
        // to; `byte_to_col_right[b]` = its RIGHTMOST column (one greater
        // for a double-width CJK cell). Keeping both lets a match ending
        // on a wide char report the two cells it actually spans, not one.
        let mut byte_to_col: Vec<u16> = Vec::with_capacity(cols);
        let mut byte_to_col_right: Vec<u16> = Vec::with_capacity(cols);
        for c in 0..cols {
            use alacritty_terminal::term::cell::Flags;
            let cell: &Cell = &grid[Point::new(Line(line), Column(c))];
            // Skip BOTH wide-char continuation placeholders — the trailing
            // spacer and the LEADING spacer alacritty emits when a wide
            // char would straddle the wrap edge — so the leading glyph's
            // column anchors the match (matching `viewport_cells`, which
            // skips both). Missing the leading variant corrupts the
            // column mapping for wrap-straddling wide chars.
            if cell
                .flags
                .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
            {
                continue;
            }
            let glyph = cell.c;
            // `col` cast: `cols` is `usize` from alacritty but bounded
            // to the EngineConfig u16 range at construction
            // (config.rs). Truncation is unreachable for production
            // configs.
            #[allow(clippy::cast_possible_truncation)]
            let col_u16 = c as u16;
            let right_u16 = col_u16 + u16::from(cell.flags.contains(Flags::WIDE_CHAR));
            for _ in 0..glyph.len_utf8() {
                byte_to_col.push(col_u16);
                byte_to_col_right.push(right_u16);
            }
            text.push(glyph);
        }
        // Trim trailing spaces — terminal lines pad with U+0020, which
        // would inflate match-end columns and mis-highlight the gap.
        while text.ends_with(' ') {
            text.pop();
            byte_to_col.pop();
            byte_to_col_right.pop();
        }

        if text.is_empty() {
            continue;
        }

        // Map a byte range `[start, end)` in `text` to (col, len_cells).
        let to_cells = |start: usize, end: usize| -> Option<(u16, u16)> {
            if start >= byte_to_col.len() {
                return None;
            }
            let last_byte = end.saturating_sub(1).min(byte_to_col.len() - 1);
            let start_col = byte_to_col[start];
            // RIGHTMOST column of the last matched cell, so a match ending
            // on a double-width glyph counts both of its cells.
            let end_col = byte_to_col_right[last_byte];
            let len = end_col.saturating_sub(start_col) + 1;
            Some((start_col, len))
        };

        // Single matcher for both modes (plain mode is the escaped,
        // case-insensitive regex built above). `find_iter` yields
        // non-overlapping matches — the standard highlight behavior.
        for m in regex.find_iter(&text) {
            if m.range().is_empty() {
                continue;
            }
            if let Some((col, len)) = to_cells(m.start(), m.end()) {
                out.push(SearchMatch { line, col, len });
                if out.len() >= MAX_MATCHES {
                    return Ok(out);
                }
            }
        }
    }

    Ok(out)
}

/// Matches over `MAX_MATCHES` are dropped silently. 10k is a comfortable
/// ceiling — 80 KB FFI payload at 8 bytes/match, well below the 1 MB
/// soft-cap noted in `decisions/10-ffi-collection-deferral.md`.
pub const MAX_MATCHES: usize = 10_000;

#[cfg(test)]
mod tests {
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
}
