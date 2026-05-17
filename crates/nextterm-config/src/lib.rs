//! Config — terminal config (TOML) + Claude Code settings.json hierarchy.
//!
//! See `decisions/07-claude-integration-mode.md` and `raw/cc-docs-c-settings-hosted.md`.

pub mod claude_md;

pub use claude_md::{resolve, MergedClaudeMd, ProvenanceSpan, MAX_IMPORT_DEPTH};

/// Placeholder; real loader lands in M5.
#[derive(Debug, Default)]
pub struct Config;
