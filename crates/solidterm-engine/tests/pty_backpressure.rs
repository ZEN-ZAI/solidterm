// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

//! Teardown must not deadlock when the bounded PTY channel is full and
//! the reader thread is parked in `send` (the Drop disconnect-before-
//! join contract from pty.rs).
//!
//! The test's value is that it returns at all: a regression in Drop
//! ordering (join before receiver-drop) would hang indefinitely when
//! the channel is full and the child is still writing.

use std::path::PathBuf;
use std::time::Duration;

use solidterm_engine::{EngineConfig, TerminalEngine};

/// Build an `EngineConfig` that runs `/usr/bin/yes`, which floods the
/// PTY master with "y\n" at full kernel speed. Uses a minimal 24×80
/// viewport and no scrollback to keep memory footprint tiny.
fn yes_config() -> EngineConfig {
    EngineConfig {
        rows: 24,
        cols: 80,
        env: vec![("TERM".to_string(), "xterm-256color".to_string())],
        command: vec!["/usr/bin/yes".to_string()],
        cwd: PathBuf::from("/tmp"),
        scrollback_lines: 0,
    }
}

/// Start `/usr/bin/yes`, deliberately never call `poll_output` so the
/// bounded PTY channel fills up, then drop the engine. The test passes
/// if it returns at all — a regression in the Drop ordering (joining
/// the reader thread before dropping the receiver) would deadlock here
/// because the reader thread is blocked in `send` on a full channel
/// and can never exit its loop without the receiver being disconnected
/// first.
#[test]
fn drop_does_not_deadlock_when_channel_full() {
    let engine = TerminalEngine::new(yes_config()).expect("/usr/bin/yes spawn should succeed");

    // Give the child time to flood output so the bounded channel fills
    // and the reader thread parks in `send`. 300 ms is conservative;
    // at PTY speeds the channel (512 × 4 KiB ≈ 2 MiB) fills in well
    // under 100 ms on any modern machine.
    std::thread::sleep(Duration::from_millis(300));

    // Drop engine here. The Drop impl in PtyReader must disconnect the
    // receiver before joining the reader thread. If it doesn't, this
    // line never returns.
    drop(engine);

    // Reaching this point proves the join completed without deadlock.
}
