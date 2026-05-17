//! Implements spec/m1-task-breakdown.md §1.10 — Criterion baseline for
//! the engine's hot path (`vte::ansi::Processor` →
//! `Term::<EventListener>` grid mutation).
//!
//! # What this measures
//!
//! Throughput of pushing 1 MiB of realistic terminal-output bytes
//! through the parser → grid pipeline that `TerminalEngine::poll_output`
//! drives in production. The bench reports MB/s and per-iteration wall
//! time. This is a **regression detector**, not a tuning target — the
//! value is in catching silent drift from FFI / alacritty-bump churn,
//! not in optimising absolute numbers.
//!
//! # Path: parser-bypass (NOT PTY round-trip)
//!
//! The first attempt drove `feed_input` / `poll_output` through a real
//! PTY against `/bin/cat`. That path is unworkable for bulk bench
//! feeds because alacritty's `Pty` puts the master FD in non-blocking
//! mode (`O_NONBLOCK`), so `Pty::writer().write_all()` returns
//! `EAGAIN`/`WouldBlock` the moment the kernel pipe (~64 KiB on
//! macOS) fills. The renderer-driven production path is rate-limited
//! by display-link cadence; a bench feeding 1 MiB at once is not.
//!
//! Building a partial-write retry harness around `feed_input` would
//! turn the bench into a kernel-scheduler benchmark rather than a
//! parser benchmark, which is the opposite of what this task wants.
//! The brief explicitly allows this fallback ("feel free to bypass
//! the PTY round-trip and feed raw bytes directly into the parser …
//! but document the choice").
//!
//! Concretely, the bench constructs the same `Term<L>` +
//! `vte::ansi::Processor` pair that lives inside `TerminalEngine`
//! (via `alacritty_terminal`'s own public re-exports) and calls
//! `parser.advance(&mut term, &chunk)` — the exact line `poll_output`
//! runs at `engine.rs:339`. This isolates parser + grid cost from
//! kernel + scheduler noise. If the renderer-side hot path ever
//! diverges from this shape we'll need to expose a parser-feed entry
//! on `TerminalEngine`; today it doesn't.
//!
//! # Workload composition
//!
//! 1 MiB total, deterministic seed, mix:
//!   - 70% plain ASCII with `\n` every ~80 chars (grid wrap + scroll)
//!   - 20% SGR color sequences (CSI dispatch + Term color state)
//!   - 10% cursor positioning (`Term::goto` + bounds checks)
//!
//! # Running
//!
//! ```sh
//! # First baseline (saves to target/criterion/<bench>/main):
//! cargo bench --bench hot_feed_1mb -- --save-baseline main
//!
//! # Compare a future run against the saved baseline:
//! cargo bench --bench hot_feed_1mb -- --baseline main
//! ```
//!
//! `target/criterion/` is gitignored; baselines are local-only.

use std::time::Duration;

use criterion::{black_box, criterion_group, criterion_main, Criterion, Throughput};

use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::{Config as AlacrittyTermConfig, Term};
use alacritty_terminal::vte::ansi;

/// 1 MiB workload size — Criterion reports MB/s using this as the
/// per-iter byte count via `Throughput::Bytes`.
const WORKLOAD_BYTES: usize = 1024 * 1024;

/// Chunk granularity matching realistic PTY read sizes. The reader
/// thread (`pty.rs`) reads in 4 KiB chunks today; 16 KiB is a
/// renderer-tick-realistic upper bound. We split the 1 MiB workload
/// into 16 KiB chunks and call `parser.advance` once per chunk, the
/// same pattern `TerminalEngine::poll_output` runs.
const CHUNK_BYTES: usize = 16 * 1024;

/// Bench-side mirror of `solidterm_engine::engine::EngineDimensions`
/// (which is private). `Term::new` only consults `screen_lines` /
/// `columns` / `total_lines`, so this minimal adapter suffices.
struct BenchDimensions {
    rows: usize,
    cols: usize,
}

impl Dimensions for BenchDimensions {
    fn total_lines(&self) -> usize {
        self.rows
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

/// Build the 1 MiB synthetic terminal-output stream once, deterministic
/// across runs. Composition:
///   - 70% plain ASCII (`a`-`z` rotating, with `\n` every 80 chars)
///   - 20% SGR sequences (a small alphabet of common `\x1b[..m` forms)
///   - 10% cursor positioning (`\x1b[H` and `\x1b[<r>;<c>H`)
///
/// We use a tiny LCG (no rand crate dep) to interleave the three
/// classes deterministically.
fn build_workload() -> Vec<u8> {
    let mut buf = Vec::with_capacity(WORKLOAD_BYTES + 256);
    // Linear congruential generator — Numerical Recipes constants. Seed
    // is fixed so workload is deterministic across runs.
    let mut state: u32 = 0x1234_5678;
    let mut next = || {
        state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        state
    };

    // Pre-baked SGR sequences chosen to exercise the parser's CSI
    // dispatch + Term's rendition state without overflowing the
    // workload with a single shape.
    let sgr_palette: &[&[u8]] = &[
        b"\x1b[1m",       // bold
        b"\x1b[0m",       // reset
        b"\x1b[31m",      // fg red
        b"\x1b[32m",      // fg green
        b"\x1b[44m",      // bg blue
        b"\x1b[1;33m",    // bold + fg yellow
        b"\x1b[38;5;42m", // 256-color fg
        b"\x1b[39m",      // default fg
    ];

    // Column counter so we can inject `\n` every ~80 ASCII chars to
    // trigger grid wrapping.
    let mut col: u32 = 0;
    while buf.len() < WORKLOAD_BYTES {
        let class = next() % 100;
        if class < 70 {
            // Plain ASCII run (length 4-16 chars).
            let run_len = 4 + (next() % 13) as usize;
            for _ in 0..run_len {
                let ch = b'a' + (next() % 26) as u8;
                buf.push(ch);
                col += 1;
                if col >= 80 {
                    buf.push(b'\n');
                    col = 0;
                }
            }
        } else if class < 90 {
            // SGR sequence (no column advance — escape bytes don't
            // print; the parser consumes them into Term state).
            let seq = sgr_palette[(next() as usize) % sgr_palette.len()];
            buf.extend_from_slice(seq);
        } else {
            // Cursor positioning — half home, half explicit (r, c).
            if next() % 2 == 0 {
                buf.extend_from_slice(b"\x1b[H");
            } else {
                let row = 1 + (next() % 24);
                let col_pos = 1 + (next() % 80);
                buf.extend_from_slice(format!("\x1b[{row};{col_pos}H").as_bytes());
            }
            col = 0; // cursor positioning resets our line tracking
        }
    }
    // Trim to exactly WORKLOAD_BYTES.
    buf.truncate(WORKLOAD_BYTES);
    buf
}

/// Build a fresh `Term<VoidListener>` + `Processor` matching the
/// production engine's construction (80×120 grid, 1 000-line scrollback,
/// alacritty defaults for everything else). `VoidListener` discards
/// `EventListener` callbacks — we don't measure event-channel work
/// here because `poll_output`'s event drain is renderer-frame paced,
/// not parser paced.
fn build_term_and_parser() -> (Term<VoidListener>, ansi::Processor) {
    let alacritty_config = AlacrittyTermConfig {
        scrolling_history: 1_000,
        ..AlacrittyTermConfig::default()
    };
    let dims = BenchDimensions {
        rows: 80,
        cols: 120,
    };
    let term = Term::new(alacritty_config, &dims, VoidListener);
    let parser = ansi::Processor::new();
    (term, parser)
}

/// Drive the workload through the parser → grid pipeline in
/// CHUNK_BYTES-sized slices, mirroring the canonical
/// `parser.advance(&mut term, &chunk)` loop in
/// `TerminalEngine::poll_output`.
fn feed_workload(term: &mut Term<VoidListener>, parser: &mut ansi::Processor, workload: &[u8]) {
    let mut i = 0;
    while i < workload.len() {
        let end = (i + CHUNK_BYTES).min(workload.len());
        parser.advance(term, &workload[i..end]);
        i = end;
    }
}

fn bench_hot_feed_1mb(c: &mut Criterion) {
    // Build the workload once, outside the timed section.
    let workload = build_workload();
    assert_eq!(workload.len(), WORKLOAD_BYTES);

    let mut group = c.benchmark_group("hot_feed_1mb");
    // 1 MiB per iter — Criterion reports MB/s.
    group.throughput(Throughput::Bytes(WORKLOAD_BYTES as u64));
    // 30 samples keeps total bench wall under ~10 s while still giving
    // Criterion room to compute a confidence interval.
    group.sample_size(30);
    // Extend measurement window past Criterion's 5 s default so the
    // 30-sample budget completes even if iters run >100 ms.
    group.measurement_time(Duration::from_secs(15));

    group.bench_function("parser_bypass", |b| {
        b.iter_batched_ref(
            // Setup: fresh Term + Processor per iter so the prior
            // iter's grid + scrollback state doesn't pollute the next
            // one. Construction cost is excluded from the timed
            // section by `iter_batched_ref`.
            build_term_and_parser,
            |(term, parser)| {
                feed_workload(term, parser, black_box(&workload));
                // Black-box the term so the optimizer can't elide
                // grid mutation under "result unused" reasoning.
                black_box(&term);
            },
            criterion::BatchSize::PerIteration,
        );
    });

    group.finish();
}

criterion_group!(benches, bench_hot_feed_1mb);
criterion_main!(benches);
