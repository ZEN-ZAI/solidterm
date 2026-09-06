// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

//! Regression tests for the 2026-08-22 whole-app hang: closing a
//! window dropped the engine on the main thread, and alacritty's
//! `Pty::Drop` blocked in `wait4` while the child was itself blocked
//! in `write(2)` on a full PTY whose reader thread was send-parked on
//! the full flood-cap channel — a four-way cycle nobody could exit.
//! `TerminalEngine::shutdown_detached` must (a) never block the
//! caller and (b) guarantee the child is reaped even when it ignores
//! SIGHUP and the reader channel is wedged full.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use solidterm_engine::{EngineConfig, TerminalEngine};

fn config_with(command: Vec<String>) -> EngineConfig {
    EngineConfig {
        rows: 24,
        cols: 80,
        env: vec![("TERM".to_string(), "xterm-256color".to_string())],
        command,
        cwd: PathBuf::from("/tmp"),
        scrollback_lines: 1_000,
    }
}

/// Poll `kill(pid, 0)` until it errors (ESRCH): the child is not just
/// dead but *reaped* — a zombie still passes the existence check, so
/// success here proves the detached teardown thread ran `Pty::Drop`'s
/// `wait()` to completion.
// unsafe_code allow: `kill(pid, 0)` existence probe only — no signal
// is delivered, no memory crosses the boundary.
#[allow(unsafe_code)]
fn child_fully_reaped(pid: i32, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if unsafe { libc::kill(pid, 0) } == -1 {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

/// Caller-latency budget for `shutdown_detached`: it does two `kill`
/// syscalls and one `pthread_create` — microseconds. 100 ms leaves two
/// orders of magnitude of CI headroom while still failing loudly if a
/// blocking wait ever sneaks back into the calling thread.
const CALLER_BUDGET: Duration = Duration::from_millis(100);

/// A child that ignores SIGHUP must still be torn down: the grace
/// window expires, SIGKILL lands, and the teardown thread reaps.
#[test]
fn hup_immune_child_is_killed_without_blocking_caller() {
    let engine = TerminalEngine::new(config_with(vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        "trap '' HUP; while :; do sleep 1; done".to_string(),
    ]))
    .expect("spawn should succeed");
    // `child_pid` is a `u32` (std `Child::id`); kernel pids fit i32.
    #[allow(clippy::cast_possible_wrap)]
    let pid = engine.child_pid() as i32;

    let t0 = Instant::now();
    engine.shutdown_detached();
    assert!(
        t0.elapsed() < CALLER_BUDGET,
        "shutdown_detached blocked the caller for {:?}",
        t0.elapsed()
    );
    assert!(
        child_fully_reaped(pid, Duration::from_secs(3)),
        "HUP-immune child (pid {pid}) was never SIGKILLed + reaped"
    );
}

/// The exact production shape: the child floods the PTY while nobody
/// calls `poll_output` (a hung/busy UI), so the reader thread fills
/// the flood-cap channel and parks in `send`, the kernel PTY buffer
/// fills, and the child blocks in `write(2)` where it cannot act on
/// SIGHUP. Pre-fix, dropping the engine here deadlocked forever.
#[test]
fn send_blocked_reader_and_write_blocked_child_do_not_deadlock() {
    let engine = TerminalEngine::new(config_with(vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        // `trap '' HUP` models a child that cannot exit on SIGHUP
        // (production zsh had the signal queued behind a blocked
        // write); the flood wedges reader + kernel buffer.
        "trap '' HUP; /usr/bin/yes solidterm-flood".to_string(),
    ]))
    .expect("spawn should succeed");
    // `child_pid` is a `u32` (std `Child::id`); kernel pids fit i32.
    #[allow(clippy::cast_possible_wrap)]
    let pid = engine.child_pid() as i32;

    // No poll_output at all: let the flood fill the bounded channel
    // (512 × ≤4 KiB) and park the reader thread in `send`.
    std::thread::sleep(Duration::from_millis(400));

    let t0 = Instant::now();
    engine.shutdown_detached();
    assert!(
        t0.elapsed() < CALLER_BUDGET,
        "shutdown_detached blocked the caller for {:?}",
        t0.elapsed()
    );
    assert!(
        child_fully_reaped(pid, Duration::from_secs(3)),
        "write-blocked child (pid {pid}) was never torn down"
    );
}

/// A cooperative child (default HUP disposition) should die from the
/// polite SIGHUP and be reaped promptly — the escalation path is a
/// backstop, not the norm.
#[test]
fn cooperative_child_exits_on_sighup() {
    let engine = TerminalEngine::new(config_with(vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        "while :; do sleep 1; done".to_string(),
    ]))
    .expect("spawn should succeed");
    // `child_pid` is a `u32` (std `Child::id`); kernel pids fit i32.
    #[allow(clippy::cast_possible_wrap)]
    let pid = engine.child_pid() as i32;

    engine.shutdown_detached();
    assert!(
        child_fully_reaped(pid, Duration::from_secs(3)),
        "cooperative child (pid {pid}) was never reaped"
    );
}
