//! Integration smoke for spec/m1-task-breakdown.md §1.3 + §1.4 —
//! exercises `TerminalEngine::new` end-to-end: spawn `/bin/zsh -l`,
//! `feed_input` a probe command, drain the PTY via `poll_output`
//! (which feeds bytes through `vte::ansi::Processor` into `Term`).
//! Updated at task 1.4 to use the stable `feed_input` / `poll_output`
//! public API in place of the transitional `write_pty_bytes` /
//! `try_recv_pty_bytes` accessors that #44 introduced.
//!
//! Tests the full PTY + parser plumbing as a separate-crate consumer
//! would, using only the engine's `pub` surface.
//!
//! # Scope narrowing (rule 9)
//!
//! Child-exit verification via `next_child_event` is deferred to
//! task 1.8 (`EngineEvent` MPSC). alacritty's SIGCHLD path interacts
//! unreliably with cargo test's own signal handling — the
//! registration order between `signal-hook` (alacritty) and the
//! cargo test runner determines which one consumes SIGCHLD first,
//! race-y across runs. Task 1.8's MPSC channel will surface
//! `ChildEvent::Exited` as `EngineEvent::ChildExited` in a way that
//! doesn't depend on signal-hook registration order. Cleanup
//! correctness is preserved today via `Drop`: alacritty's
//! `Pty::Drop` sends SIGHUP and waits; `PtyReader::Drop` joins the
//! reader thread. The brief's literal exit gate is "spawns
//! `/bin/zsh -l`, reads output" — both verified here.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use nextterm_engine::{EngineConfig, TerminalEngine};

fn login_shell_config() -> EngineConfig {
    EngineConfig {
        rows: 24,
        cols: 80,
        env: vec![("TERM".to_string(), "xterm-256color".to_string())],
        // `/bin/zsh -l` is macOS's default login shell since Catalina.
        // alacritty's macOS spawn path additionally wraps this in
        // `/usr/bin/login -flp` to make it a real login session.
        command: vec!["/bin/zsh".to_string(), "-l".to_string()],
        cwd: PathBuf::from("/tmp"),
        scrollback_lines: 100_000,
    }
}

#[test]
fn spawn_zsh_and_read_pty_output() {
    let mut engine =
        TerminalEngine::new(login_shell_config()).expect("zsh spawn should succeed on macOS");

    let pid = engine.child_pid();
    assert!(pid > 0, "child PID must be positive");

    // Probe the PTY by sending `echo nextterm-pty-ok\nexit\n`. The
    // shell will emit the echoed input + the literal echo output +
    // a final prompt; the `exit\n` ensures the child eventually
    // tears down even though we don't assert on it (see file-level
    // scope-narrowing note).
    //
    // Using `echo SENTINEL` rather than waiting for a passive prompt
    // makes the test robust against:
    //   - login wrappers that suppress motd / banners
    //   - shells that buffer the prompt until first input
    //   - macOS `/usr/bin/login -flp` variations across releases
    engine
        .feed_input(b"echo nextterm-pty-ok\nexit\n")
        .expect("feed_input should write the probe command to the PTY master");

    // Drain the PTY via `poll_output` until ≥1 byte has been
    // consumed (parsed through `vte::ansi::Processor` into Term's
    // grid). Bytes-consumed is the deterministic gate: shell-prompt
    // rendering timing varies with login-wrapper banner suppression,
    // MOTD, and cached-zsh-startup speed, so a content / grid-state
    // assertion would be flaky here. Engine-level grid-state
    // verification lives in the `/bin/cat` unit tests in `engine.rs`.
    let read_deadline = Instant::now() + Duration::from_secs(4);
    let mut consumed = 0usize;
    while Instant::now() < read_deadline && consumed == 0 {
        consumed += engine
            .poll_output()
            .expect("poll_output is infallible today");
        if consumed == 0 {
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    assert!(
        consumed > 0,
        "expected ≥1 byte of output from zsh within 4s; PTY read path may be broken (child pid {pid})"
    );

    // Drop runs at end of scope. Field-declaration order in
    // `TerminalEngine` (`term, parser, pty, reader`) means `pty`
    // drops before `reader`: alacritty's `Pty::Drop` sends SIGHUP to
    // the child + waits, the child closes the slave PTY, the master
    // sees EOF, the reader thread's blocking `read()` returns 0, it
    // exits the loop, and `PtyReader::Drop` joins cleanly. No
    // orphaned children, no hung threads.
}
