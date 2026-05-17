//! Implements spec/m1-task-breakdown.md §1.7+ cursor accessor for the
//! FFI integration atomic (#56). Engine-side cursor snapshot returned
//! by [`crate::TerminalEngine::cursor`].
//!
//! Type-decoupling rationale: `vte::ansi::CursorStyle` /
//! `CursorShape` are upstream types we don't want to leak through the
//! FFI crate's import surface. `CursorReadback` is a small typed
//! shape that `bridge.rs` translates into `ffi::CursorState` (the
//! swift-bridge wire type) without ever importing alacritty/vte
//! types. Symmetric with how `DirtyRows` (#53) and `CellView` (#54)
//! decouple engine internals from the FFI boundary.

use alacritty_terminal::vte::ansi::CursorShape as VteCursorShape;

/// Snapshot of the terminal cursor at the moment of read.
/// Translates alacritty's `CursorStyle` + `Term::mode()` (for
/// visibility) into a flat shape ready for FFI transcode.
///
/// `row` / `col` are viewport-relative (`0..screen_lines` /
/// `0..columns`); vi-mode scrollback cursors aren't on the M1 path so
/// we don't model negative-line offsets here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CursorReadback {
    pub row: u16,
    pub col: u16,
    pub shape: CursorShape,
    pub blink: bool,
    pub visible: bool,
}

/// Cursor shape, narrowed from alacritty's 5-variant
/// `vte::ansi::CursorShape` to the 4 we render at M1.
///
/// `HollowBlock` from upstream maps to `Block` here — at M1 we don't
/// distinguish hollow from filled rendering. M2+ rendering can split
/// when the renderer's cursor protocol gains the variant.
///
/// `Hidden` from upstream maps to our `Hidden`; the bridge layer can
/// also force `visible = false` via `Term::mode()` not containing
/// `SHOW_CURSOR`. Both signals are honoured at the FFI boundary.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CursorShape {
    Block,
    Beam,
    Underline,
    Hidden,
}

impl CursorShape {
    /// Map alacritty's upstream `CursorShape` to our narrowed enum.
    /// `pub(crate)` — engine-internal helper used by
    /// [`crate::TerminalEngine::cursor`].
    pub(crate) fn from_alacritty(shape: VteCursorShape) -> Self {
        match shape {
            VteCursorShape::Block | VteCursorShape::HollowBlock => Self::Block,
            VteCursorShape::Beam => Self::Beam,
            VteCursorShape::Underline => Self::Underline,
            VteCursorShape::Hidden => Self::Hidden,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{CursorShape, VteCursorShape};

    #[test]
    fn from_alacritty_block() {
        assert_eq!(
            CursorShape::from_alacritty(VteCursorShape::Block),
            CursorShape::Block
        );
    }

    #[test]
    fn from_alacritty_hollow_block_collapses_to_block() {
        // M1 simplification: HollowBlock isn't rendered distinctly.
        assert_eq!(
            CursorShape::from_alacritty(VteCursorShape::HollowBlock),
            CursorShape::Block
        );
    }

    #[test]
    fn from_alacritty_beam() {
        assert_eq!(
            CursorShape::from_alacritty(VteCursorShape::Beam),
            CursorShape::Beam
        );
    }

    #[test]
    fn from_alacritty_underline() {
        assert_eq!(
            CursorShape::from_alacritty(VteCursorShape::Underline),
            CursorShape::Underline
        );
    }

    #[test]
    fn from_alacritty_hidden() {
        assert_eq!(
            CursorShape::from_alacritty(VteCursorShape::Hidden),
            CursorShape::Hidden
        );
    }
}
