// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

//! M1 task 1.6 — `DirtyRows`, the
//! engine-side damage snapshot returned by [`crate::TerminalEngine::take_damage`].
//!
//! Mirrors `alacritty_terminal::term::TermDamage` (upstream
//! `term/mod.rs:178`) but drops the `'a` lifetime and per-line column
//! bounds: M1 scope is row-level repaint, and decoupling from
//! alacritty's borrowed iterator lets engine consumers hold a
//! `DirtyRows` across `&mut self` calls (`poll_output`, `feed_input`,
//! `resize`, etc.) without lifetime gymnastics.
//!
//! Forward-compat upgrade path: if M3+ partial-row blits or task 1.7's
//! `viewport_cells` want per-cell granularity, `Partial(Vec<u16>)`
//! upgrades to `Partial(Vec<RowDamage { line: u16, left: u16, right:
//! u16 }>)`. Same enum shape, additional struct fields — no semantics
//! drift.

/// Row-level grid damage snapshot returned by [`crate::TerminalEngine::take_damage`].
///
/// `Full` means the whole viewport must be repainted (resize, mode
/// change, scroll while `display_offset != 0`); `Partial(rows)`
/// carries the specific viewport-relative row indices that need
/// repaint, sorted ascending with no duplicates.
///
/// Empty `Partial(vec![])` is **not** the post-fresh-spawn state:
/// alacritty constructs `Term` with the entire viewport marked
/// `full = true` (`term/mod.rs:230` upstream), so the very first
/// `take_damage()` call after construction returns `Full`. Subsequent
/// calls return `Partial` (typically containing at least the cursor
/// row, since `Term::damage()` re-marks the cursor on every call by
/// design — `term/mod.rs:480` upstream).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DirtyRows {
    /// The entire viewport is damaged. Renderers should treat this
    /// as "repaint whole grid" rather than enumerating row indices.
    Full,
    /// Specific viewport-relative row indices that need repaint,
    /// sorted ascending with no duplicates.
    Partial(Vec<u16>),
}

impl DirtyRows {
    /// `true` if the snapshot is `Full`. Renderers branch on this
    /// before enumerating: `Full` skips the per-row loop entirely.
    #[must_use]
    pub fn is_full(&self) -> bool {
        matches!(self, Self::Full)
    }

    /// `true` if the snapshot is `Partial` with no rows. This is the
    /// "engine has nothing to repaint" signal; only reachable after
    /// at least one preceding `take_damage()` call (the initial state
    /// is `Full`, see the type-level doc comment).
    #[must_use]
    pub fn is_empty(&self) -> bool {
        matches!(self, Self::Partial(rows) if rows.is_empty())
    }

    /// Iterator over damaged row indices for `Partial`; empty for
    /// `Full`. Callers that need to distinguish "no rows" from "all
    /// rows" must check [`Self::is_full`] first — iterating over
    /// `Full` yields zero items, which is *not* the same semantic.
    #[must_use]
    pub fn iter(&self) -> DirtyRowsIter<'_> {
        self.into_iter()
    }
}

impl<'a> IntoIterator for &'a DirtyRows {
    type Item = u16;
    type IntoIter = DirtyRowsIter<'a>;

    fn into_iter(self) -> Self::IntoIter {
        match self {
            DirtyRows::Full => DirtyRowsIter { inner: [].iter() },
            DirtyRows::Partial(rows) => DirtyRowsIter { inner: rows.iter() },
        }
    }
}

/// Iterator over `Partial` row indices. Yields `u16` by value.
/// Empty when constructed from `DirtyRows::Full` — see
/// [`DirtyRows::iter`] for the precondition contract.
pub struct DirtyRowsIter<'a> {
    inner: std::slice::Iter<'a, u16>,
}

impl Iterator for DirtyRowsIter<'_> {
    type Item = u16;

    fn next(&mut self) -> Option<Self::Item> {
        self.inner.next().copied()
    }
}

#[cfg(test)]
mod tests {
    use super::DirtyRows;

    #[test]
    fn full_is_full_and_not_empty() {
        let d = DirtyRows::Full;
        assert!(d.is_full());
        assert!(!d.is_empty());
    }

    #[test]
    fn partial_empty_is_empty_and_not_full() {
        let d = DirtyRows::Partial(Vec::new());
        assert!(!d.is_full());
        assert!(d.is_empty());
    }

    #[test]
    fn partial_with_rows_is_neither_full_nor_empty() {
        let d = DirtyRows::Partial(vec![0, 5, 12]);
        assert!(!d.is_full());
        assert!(!d.is_empty());
    }

    #[test]
    fn iter_yields_partial_rows_in_order() {
        let d = DirtyRows::Partial(vec![0, 3, 7]);
        let collected: Vec<u16> = d.iter().collect();
        assert_eq!(collected, vec![0, 3, 7]);
    }

    #[test]
    fn iter_on_full_yields_nothing() {
        let d = DirtyRows::Full;
        let collected: Vec<u16> = d.iter().collect();
        assert!(
            collected.is_empty(),
            "iter() on Full must be empty — callers gate on is_full() for whole-grid repaint"
        );
    }
}
