// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

//! M1 task 1.2 — `EngineConfig`, validated configuration for
//! `TerminalEngine` (rows / cols / env / command / cwd /
//! `scrollback_lines`).
//!
//! This is engine-internal config; the FFI-side `SessionConfig` /
//! `SessionConfigSnapshot` (in `session.rs`) are the swift-bridge wire
//! format and the FFI-decoded snapshot, respectively. They're for
//! different consumers — keeping them separate avoids conflating engine
//! state with the FFI boundary.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// Upper bound on `scrollback_lines`. Spec default is `100_000`; one
/// million is far past any realistic terminal use and protects against
/// pathological config values that would allocate >100 MB of grid
/// history at typical row widths.
pub const MAX_SCROLLBACK_LINES: u32 = 1_000_000;

/// Default scrollback.
pub const DEFAULT_SCROLLBACK_LINES: u32 = 100_000;

/// Validated engine configuration. Construct via direct field
/// initialization; call [`EngineConfig::validate`] before handing to
/// [`crate::TerminalEngine::new`].
///
/// Field shape:
/// - `command` is `Vec<String>` (e.g. `["/bin/zsh", "-l"]`) — the first
///   element is the executable path, the rest are argv.
/// - `env` is `Vec<(String, String)>` so order is preserved (matters
///   for `PATH` overrides) and `Command::envs` accepts it directly.
/// - `cwd` must be an absolute path; the PTY-spawn task (1.3) needs a
///   resolved path for `Command::current_dir`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EngineConfig {
    pub rows: u16,
    pub cols: u16,
    pub env: Vec<(String, String)>,
    pub command: Vec<String>,
    pub cwd: PathBuf,
    pub scrollback_lines: u32,
}

/// Validation errors for [`EngineConfig`].
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum EngineConfigError {
    #[error("invalid geometry: rows={rows}, cols={cols} (both must be > 0)")]
    InvalidGeometry { rows: u16, cols: u16 },

    #[error("command must contain at least one element (the executable path)")]
    EmptyCommand,

    #[error("cwd must be an absolute path: {0}")]
    RelativeCwd(PathBuf),

    #[error("scrollback_lines={got} exceeds the {max} maximum (default is {default})")]
    ScrollbackTooLarge { got: u32, max: u32, default: u32 },
}

impl EngineConfig {
    /// Run all validation checks. Returns `Ok(())` on a valid config.
    ///
    /// Cheap to call; no allocation, no I/O. Idempotent.
    pub fn validate(&self) -> Result<(), EngineConfigError> {
        if self.rows == 0 || self.cols == 0 {
            return Err(EngineConfigError::InvalidGeometry {
                rows: self.rows,
                cols: self.cols,
            });
        }
        if self.command.is_empty() {
            return Err(EngineConfigError::EmptyCommand);
        }
        if !self.cwd.is_absolute() {
            return Err(EngineConfigError::RelativeCwd(self.cwd.clone()));
        }
        if self.scrollback_lines > MAX_SCROLLBACK_LINES {
            return Err(EngineConfigError::ScrollbackTooLarge {
                got: self.scrollback_lines,
                max: MAX_SCROLLBACK_LINES,
                default: DEFAULT_SCROLLBACK_LINES,
            });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{EngineConfig, EngineConfigError, DEFAULT_SCROLLBACK_LINES, MAX_SCROLLBACK_LINES};
    use std::path::PathBuf;

    fn valid_config() -> EngineConfig {
        EngineConfig {
            rows: 24,
            cols: 80,
            env: vec![
                ("TERM".to_string(), "xterm-256color".to_string()),
                ("LANG".to_string(), "en_US.UTF-8".to_string()),
            ],
            command: vec!["/bin/zsh".to_string(), "-l".to_string()],
            cwd: PathBuf::from("/tmp"),
            scrollback_lines: DEFAULT_SCROLLBACK_LINES,
        }
    }

    #[test]
    fn validate_accepts_a_realistic_config() {
        valid_config().validate().expect("valid config must pass");
    }

    #[test]
    fn validate_rejects_zero_rows() {
        let mut cfg = valid_config();
        cfg.rows = 0;
        assert_eq!(
            cfg.validate(),
            Err(EngineConfigError::InvalidGeometry { rows: 0, cols: 80 })
        );
    }

    #[test]
    fn validate_rejects_zero_cols() {
        let mut cfg = valid_config();
        cfg.cols = 0;
        assert_eq!(
            cfg.validate(),
            Err(EngineConfigError::InvalidGeometry { rows: 24, cols: 0 })
        );
    }

    #[test]
    fn validate_rejects_empty_command() {
        let mut cfg = valid_config();
        cfg.command = Vec::new();
        assert_eq!(cfg.validate(), Err(EngineConfigError::EmptyCommand));
    }

    #[test]
    fn validate_rejects_relative_cwd() {
        let mut cfg = valid_config();
        cfg.cwd = PathBuf::from("relative/path");
        assert_eq!(
            cfg.validate(),
            Err(EngineConfigError::RelativeCwd(PathBuf::from(
                "relative/path"
            )))
        );
    }

    #[test]
    fn validate_rejects_scrollback_over_one_million() {
        let mut cfg = valid_config();
        cfg.scrollback_lines = MAX_SCROLLBACK_LINES + 1;
        assert_eq!(
            cfg.validate(),
            Err(EngineConfigError::ScrollbackTooLarge {
                got: MAX_SCROLLBACK_LINES + 1,
                max: MAX_SCROLLBACK_LINES,
                default: DEFAULT_SCROLLBACK_LINES,
            })
        );
    }

    #[test]
    fn validate_accepts_scrollback_at_the_limit() {
        let mut cfg = valid_config();
        cfg.scrollback_lines = MAX_SCROLLBACK_LINES;
        cfg.validate().expect("limit value must pass");
    }

    #[test]
    fn validate_accepts_zero_scrollback() {
        // Zero scrollback is unusual but legal: alacritty's grid handles
        // a history of zero lines without panicking. Document this so a
        // future reader who wants to reject it has to deliberately
        // change the validator.
        let mut cfg = valid_config();
        cfg.scrollback_lines = 0;
        cfg.validate().expect("zero scrollback is permitted");
    }

    #[test]
    fn serde_roundtrip_via_json() {
        let original = valid_config();
        let json = serde_json::to_string(&original).expect("serialize");
        let decoded: EngineConfig = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded, original);
    }
}
