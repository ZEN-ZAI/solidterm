// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// M1 task 3.10 — typing-to-pixel latency measurement infrastructure.
// The renderer feeds per-keystroke samples (one per visible state
// change) into `LatencyMeter`, which keeps a fixed-capacity ring of
// milliseconds and reports p50 / p99 / min / max once a target sample
// count lands.
//
// Used by `LatencyMeasurementTests` to drive 1000 synthetic NSEvent
// keystrokes through the renderer and read back the percentiles. The
// meter stays in production code — its cost is one float append + one
// counter increment per keystroke, and it self-quiesces after the
// summary is logged. Future #17 (FrameDelta consumption) keeps it
// active so a real-input regression surface immediately.

import Foundation

/// Fixed-capacity sample buffer for typing-to-pixel deltas. Writes are
/// coalesced through a `DispatchQueue` so the renderer's completion
/// handler (which fires on a Metal-internal thread) and the test
/// harness reader (main) don't race.
final class LatencyMeter {
    /// Reported percentile snapshot.
    struct Summary: Equatable {
        let count: Int
        let minMs: Double
        let p50Ms: Double
        let p99Ms: Double
        let maxMs: Double
    }

    let targetSampleCount: Int
    private let queue = DispatchQueue(
        label: "com.zenzai.SolidTerm.LatencyMeter", qos: .userInteractive)
    private var samples: [Double] = []
    private var summaryLogged = false

    /// When true, `MetalRenderer.recordKeystroke` and the
    /// `addCompletedHandler` callback emit timestamped NSLog lines so
    /// future harness-corruption diagnostics can correlate "did the
    /// keystroke reach recordKeystroke" against "did the completion
    /// handler ever fire" against wallclock time. Default false in
    /// production; `LatencyMeasurementTests` flips it true.
    ///
    /// Kept as a stored property (not `#if DEBUG`-gated) per task #36 —
    /// the harness corruption was transient and not reproduced at
    /// commit time, so the instrumentation lives on as a low-cost
    /// regression diagnostic. Enable from any test that wants the
    /// trace; flip back to false at teardown to avoid leaking logs
    /// into production runs in the same process.
    var diagnosticsEnabled = false

    /// When true, `MetalRenderer.recordKeystroke` cycles cell (0,0)
    /// through the atlas's pre-rasterized A-Z + 0-9 set and queues the
    /// keystroke timestamp for the next frame's completion handler.
    /// This is the "guaranteed visible state change per keystroke"
    /// invariant the latency harness needs (per
    /// `feedback_meaningful_latency_measurement`).
    ///
    /// Default false in production: cell-(0,0) pollution would be
    /// user-visible on every keystroke, with the M1 PTY path live the
    /// shell's own echo provides the visible state change anyway.
    /// `LatencyMeasurementTests` flips it true in setUp + back to
    /// false in tearDown.
    var harnessActive = false

    init(targetSampleCount: Int = 1000) {
        self.targetSampleCount = targetSampleCount
        self.samples.reserveCapacity(targetSampleCount)
    }

    /// Append one millisecond sample. Thread-safe.
    func record(_ ms: Double) {
        queue.sync {
            self.samples.append(ms)
            if !self.summaryLogged && self.samples.count >= self.targetSampleCount {
                self.summaryLogged = true
                let s = Self.percentiles(self.samples)
                NSLog(
                    "typing-to-pixel (n=%d): p50=%.3f ms, p99=%.3f ms, min=%.3f ms, max=%.3f ms",
                    s.count, s.p50Ms, s.p99Ms, s.minMs, s.maxMs)
            }
        }
    }

    /// Snapshot current state. Safe to call any time.
    func snapshot() -> Summary {
        queue.sync { Self.percentiles(self.samples) }
    }

    /// Clear all samples and re-arm the summary. Used by the test
    /// harness so multiple runs don't pollute each other.
    func reset() {
        queue.sync {
            self.samples.removeAll(keepingCapacity: true)
            self.summaryLogged = false
        }
    }

    static func percentiles(_ values: [Double]) -> Summary {
        guard !values.isEmpty else {
            return Summary(count: 0, minMs: 0, p50Ms: 0, p99Ms: 0, maxMs: 0)
        }
        let sorted = values.sorted()
        let last = sorted.count - 1
        return Summary(
            count: sorted.count,
            minMs: sorted[0],
            p50Ms: sorted[sorted.count / 2],
            p99Ms: sorted[Int(Double(last) * 0.99)],
            maxMs: sorted[last])
    }
}
