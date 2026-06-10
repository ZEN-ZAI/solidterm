//! Implements spec/m1-task-breakdown.md §1.3 — PTY spawn + reader thread.
//!
//! `alacritty_terminal::tty::new` opens a pseudoterminal pair, fork/execs
//! the configured shell, and returns a `Pty` whose master file is the
//! reader/writer for the parent side. We spawn a dedicated `std::thread`
//! that performs blocking reads from a clone of the master `File` and
//! pushes byte chunks into a `crossbeam-channel` the engine drains.
//!
//! Threading: this is the first of the Ghostty-pattern three-thread-
//! per-pane model (see spec/rust-core-modules.md §Threading). Today:
//! PTY read thread (here). Next: VT/Grid thread (task 1.4 wires
//! `Term::advance_bytes`). Render thread is Swift-side (FFI).
//!
//! Cleanup: `Pty`'s own `Drop` sends `SIGHUP` to the child + waits.
//! When the engine drops `pty`, the child closes the slave; the master
//! read returns EOF; the reader thread exits its loop; its
//! `JoinHandle` is held by `PtyReader`, whose `Drop` joins to confirm
//! clean teardown. We don't write any cleanup alacritty already wrote.

use std::io::{self, Read};
use std::thread;
use std::time::Duration;

use crossbeam_channel::{bounded, Receiver, Sender};

/// Upper bound on buffered PTY output: 512 chunks × ≤4 KiB ≈ 2 MiB.
/// `poll_output` drains the channel completely on every display-link
/// tick, so steady state never approaches the cap. When the UI stalls
/// (modal drag loop, beachball) and a child floods, the reader thread
/// blocks on `send` instead of growing RSS without bound; the kernel
/// PTY buffer then fills and the child blocks in write(2) — standard
/// TTY flow control, identical to every other terminal.
const PTY_CHANNEL_CAP: usize = 512;

/// Sleep duration for the `WouldBlock` retry path. alacritty sets the
/// PTY master to `O_NONBLOCK` on construction (see
/// `alacritty_terminal::tty::unix.rs:293`), and our `try_clone`'d
/// `File` inherits that flag — so blocking-style `read()` on this
/// thread returns `WouldBlock` whenever no bytes have arrived. We
/// handle it like `EINTR` (sleep + retry) rather than reaching for
/// `fcntl` to swap the cloned FD back to blocking. 1 ms balances "no
/// busy-loop CPU cost" against "no perceptible read-path latency",
/// matching the cadence of the engine's tick loop.
const WOULDBLOCK_BACKOFF: Duration = Duration::from_millis(1);

/// Reader-side handle for a spawned PTY.
///
/// Owns the reader thread `JoinHandle` and the receiver end of the
/// bytes channel. The engine writes to the PTY through its own copy of
/// the master `File`; this struct only handles the read side.
pub struct PtyReader {
    /// Receiver end of the bounded channel the reader thread populates
    /// with raw byte chunks read from the PTY master. Wrapped in
    /// `Option` so `Drop` can `take()` it before joining the thread:
    /// dropping the receiver disconnects the channel, unblocking a
    /// reader thread that is parked in `send` on a full channel
    /// (crossbeam wakes a blocked sender with `Err` on disconnect).
    /// `None` only after `Drop` has taken it.
    rx: Option<Receiver<Vec<u8>>>,
    /// Reader thread handle. `None` after `Drop` consumes it via
    /// `take()`. Held purely for clean teardown.
    handle: Option<thread::JoinHandle<()>>,
}

impl PtyReader {
    /// Spawn a reader thread that pumps bytes from `reader_file` into
    /// a fresh channel. The caller passes a `try_clone()`d view of the
    /// PTY master so this thread owns one copy of the FD; the engine
    /// keeps the original for writes.
    ///
    /// The thread loops on blocking `Read::read` into a 4 KiB buffer
    /// and sends each chunk down the channel. It exits cleanly on:
    /// - EOF (`Ok(0)`) when the slave PTY is closed (typically because
    ///   the child process exited and `Pty::Drop` sent SIGHUP).
    /// - Any `io::Error` (master FD revoked, channel-receiver dropped,
    ///   etc.). The error is logged via `tracing` for postmortem; the
    ///   thread doesn't propagate it because there's no consumer once
    ///   the receiver is gone.
    #[must_use]
    pub fn spawn<R>(mut reader_file: R) -> Self
    where
        R: Read + Send + 'static,
    {
        let (tx, rx) = bounded::<Vec<u8>>(PTY_CHANNEL_CAP);
        let handle = thread::Builder::new()
            .name("solidterm-pty-reader".to_string())
            .spawn(move || pty_read_loop(&mut reader_file, &tx))
            .expect("spawning a thread on macOS should not fail");

        Self {
            rx: Some(rx),
            handle: Some(handle),
        }
    }

    /// Try to receive the next chunk from the reader thread without
    /// blocking. Returns `None` if the channel is empty, closed, or
    /// the receiver has already been taken by `Drop`.
    /// Used by `poll_output` to drain pending bytes each tick.
    #[must_use]
    pub fn try_recv(&self) -> Option<Vec<u8>> {
        self.rx.as_ref().and_then(|rx| rx.try_recv().ok())
    }

    /// Block until the next chunk arrives or the channel closes.
    /// Returns `None` on close (reader thread exited) or if the
    /// receiver has been taken by `Drop`. Used only by integration
    /// tests; production drains via `try_recv` from the tick loop.
    #[must_use]
    pub fn recv_blocking(&self) -> Option<Vec<u8>> {
        self.rx.as_ref().and_then(|rx| rx.recv().ok())
    }
}

impl Drop for PtyReader {
    fn drop(&mut self) {
        // Disconnect the channel FIRST by dropping our receiver end.
        // With a bounded channel, a reader thread blocked in `send`
        // (channel full) would never reach the next `read()` call, so
        // EOF from the PTY master cannot unblock it — joining without
        // this step would deadlock. Dropping the receiver causes
        // crossbeam to wake any pending `send` with `Err(SendError)`
        // immediately, letting the thread see the disconnection and
        // exit its loop. EOF (child-closed slave) remains the normal-
        // exit path when the channel is not full; this disconnect just
        // guarantees unblocking in all cases — including a child that
        // is SIGSTOPped with a full channel.
        drop(self.rx.take());

        if let Some(handle) = self.handle.take() {
            // Now safe to join: the reader thread will exit as soon as
            // its current (or next) `send` / `read` resolves.
            //
            // Errors here are logged but not panicked: a poisoned
            // thread shouldn't tear down the test runner / app.
            if let Err(panic) = handle.join() {
                tracing::warn!(?panic, "PTY reader thread panicked during teardown");
            }
        }
    }
}

fn pty_read_loop<R: Read>(reader: &mut R, tx: &Sender<Vec<u8>>) {
    let mut buf = [0u8; 4096];
    loop {
        match reader.read(&mut buf) {
            Ok(0) => {
                tracing::debug!("PTY reader thread: EOF, exiting cleanly");
                return;
            }
            Ok(n) => {
                if tx.send(buf[..n].to_vec()).is_err() {
                    // Receiver dropped (engine torn down). Exit.
                    tracing::debug!("PTY reader thread: receiver dropped, exiting");
                    return;
                }
            }
            Err(err) if err.kind() == io::ErrorKind::Interrupted => {
                // EINTR — fall through to the next iteration; the
                // outer `loop` retries the read.
            }
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                // EAGAIN/EWOULDBLOCK — alacritty's PTY master is set
                // non-blocking (see WOULDBLOCK_BACKOFF doc above).
                // Sleep briefly, then retry; the next `read()` will
                // either return bytes or another `WouldBlock`.
                thread::sleep(WOULDBLOCK_BACKOFF);
            }
            Err(err) => {
                tracing::debug!(?err, "PTY reader thread: read error, exiting");
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::PtyReader;
    use std::io::{Cursor, Read};

    /// Exercises the reader-thread loop with an in-memory `Cursor`
    /// rather than a real PTY. Verifies the thread:
    /// - Forwards multiple chunks down the channel.
    /// - Exits cleanly on EOF (the cursor returns `Ok(0)` after its
    ///   buffer is drained).
    /// - Yields its `JoinHandle` cleanly through `Drop`.
    ///
    /// Real PTY spawn coverage lives in `tests/spawn_smoke.rs`.
    #[test]
    fn spawn_forwards_bytes_to_channel_until_eof() {
        let payload: Vec<u8> = (0..16_384u32).map(|i| (i & 0xff) as u8).collect();
        let cursor: Cursor<Vec<u8>> = Cursor::new(payload.clone());
        let reader = PtyReader::spawn(cursor);

        // Drain until the channel goes quiet (thread hit EOF and
        // exited; subsequent recvs see the channel close).
        let mut received: Vec<u8> = Vec::new();
        while let Some(chunk) = reader.recv_blocking() {
            received.extend_from_slice(&chunk);
        }

        assert_eq!(received, payload);
        // Drop runs here — joins the thread.
    }

    #[test]
    fn spawn_with_empty_reader_exits_immediately() {
        let cursor: Cursor<Vec<u8>> = Cursor::new(Vec::new());
        let reader = PtyReader::spawn(cursor);
        // First recv on an empty source: the thread sees EOF and
        // exits without sending anything. The channel closes; recv
        // returns None.
        assert!(reader.recv_blocking().is_none());
    }

    /// Compile-time check that the spawn type-bound is the documented
    /// `Read + Send + 'static` (anything less restrictive would be
    /// unsafe to send across the thread boundary).
    #[test]
    fn spawn_accepts_a_send_static_reader() {
        struct DummyReader;
        impl Read for DummyReader {
            fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
                Ok(0)
            }
        }
        let _ = PtyReader::spawn(DummyReader);
    }
}
