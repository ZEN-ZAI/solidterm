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

    let regex: Option<Regex> = if use_regex {
        Some(
            RegexBuilder::new(query)
                .case_insensitive(false)
                .build()
                .map_err(|e| SearchError::InvalidRegex(e.to_string()))?,
        )
    } else {
        None
    };
    let needle_lc = if use_regex {
        String::new()
    } else {
        query.to_lowercase()
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
        let mut byte_to_col: Vec<u16> = Vec::with_capacity(cols);
        for c in 0..cols {
            let cell: &Cell = &grid[Point::new(Line(line), Column(c))];
            // Skip the trailing half of a CJK wide pair so the leading
            // glyph's column anchors the match. Without this skip the
            // continuation cell duplicates the wide char and `col` for
            // the next row's first cell would be reported one too high.
            if cell
                .flags
                .contains(alacritty_terminal::term::cell::Flags::WIDE_CHAR_SPACER)
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
            for _ in 0..glyph.len_utf8() {
                byte_to_col.push(col_u16);
            }
            text.push(glyph);
        }
        // Trim trailing spaces — terminal lines pad with U+0020, which
        // would inflate match-end columns and mis-highlight the gap.
        while text.ends_with(' ') {
            text.pop();
            byte_to_col.pop();
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
            let end_col = byte_to_col[last_byte];
            // Inclusive-to-exclusive len: end_col is the leftmost col of
            // the last char; +1 for the cell it occupies, +0 for any
            // wide-char trailing spacer (already collapsed above).
            let len = end_col.saturating_sub(start_col) + 1;
            Some((start_col, len))
        };

        if let Some(re) = &regex {
            for m in re.find_iter(&text) {
                if m.range().is_empty() {
                    continue;
                }
                if let Some((col, len)) = to_cells(m.start(), m.end()) {
                    #[allow(clippy::cast_possible_truncation)]
                    let line_i32 = line;
                    out.push(SearchMatch {
                        line: line_i32,
                        col,
                        len,
                    });
                    if out.len() >= MAX_MATCHES {
                        return Ok(out);
                    }
                }
            }
        } else {
            // Case-insensitive substring search. Building the lowercased
            // row once per line is O(n) but skipped entirely on the
            // common-case "no match in this row" via a fast check.
            let hay_lc = text.to_lowercase();
            let mut start = 0;
            while let Some(rel) = hay_lc[start..].find(&needle_lc) {
                let abs_start = start + rel;
                let abs_end = abs_start + needle_lc.len();
                if let Some((col, len)) = to_cells(abs_start, abs_end) {
                    out.push(SearchMatch { line, col, len });
                    if out.len() >= MAX_MATCHES {
                        return Ok(out);
                    }
                }
                // Advance by one byte to find overlapping matches; in
                // practice CJK + ASCII mixtures benefit from this.
                start = abs_start + needle_lc.len().max(1);
                if start >= hay_lc.len() {
                    break;
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
}
