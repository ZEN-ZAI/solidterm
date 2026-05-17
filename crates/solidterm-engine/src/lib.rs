//! Terminal engine — PTY + VT parsing + grid + scrollback + OSC routing.
//!
//! Wraps `alacritty_terminal` (Apache-2.0) and adds OSC-routing for
//! shell-integration sequences (OSC 7 cwd, OSC 8 hyperlinks, OSC 10-12
//! colors, OSC 52 clipboard, OSC 2026 sync output).

pub mod cells;
pub mod config;
pub mod cursor;
pub mod damage;
pub mod engine;
pub mod events;
pub mod osc;
pub mod panes;
pub mod pty;
pub mod search;

pub use cells::{CellView, Hyperlink};
pub use config::{EngineConfig, EngineConfigError, DEFAULT_SCROLLBACK_LINES, MAX_SCROLLBACK_LINES};
pub use cursor::{CursorReadback, CursorShape};
pub use damage::{DirtyRows, DirtyRowsIter};
pub use engine::{EngineError, KittyKeyboardFlags, SelectionMode, SelectionSpan, TerminalEngine};
pub use events::{ClipboardKind, EngineEvent};
pub use panes::{
    LayoutRect, PaneId, PaneNode, PaneTree, SplitDirection, SplitError, SplitId, DEPTH_CAP,
};
pub use pty::PtyReader;
pub use search::{SearchError, SearchMatch};
