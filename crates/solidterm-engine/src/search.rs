// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

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
/// soft-cap on FFI collection payloads (ADR-0006).
pub const MAX_MATCHES: usize = 10_000;

#[cfg(test)]
mod tests;
