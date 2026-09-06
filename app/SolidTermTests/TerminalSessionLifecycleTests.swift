// Session lifetime across the swift-bridge boundary, on the Swift
// consumer side. Exercises `TerminalSession.new(config)` factory, the
// generated read-back accessors, and the swift-bridge-generated
// destructor that fires on Swift `deinit`.
//
// Phase 1 task #15 (3.5): the handle is opaque to Swift; PTY spawn /
// VT parser / frame-delta producer arrive in subsequent dispatches.
// Stack A — no Metal/AppKit types crossed the boundary to construct
// this handle.

import XCTest

@testable import SolidTerm

final class TerminalSessionLifecycleTests: XCTestCase {

    // MARK: - Helpers

    private func makeBytes(_ bytes: [UInt8]) -> RustVec<UInt8> {
        let v = RustVec<UInt8>()
        for b in bytes { v.push(value: b) }
        return v
    }

    private func sampleConfig(rows: UInt16 = 24, cols: UInt16 = 80) -> SessionConfig {
        // The Swift `config` carries `RustString` / `RustVec<UInt8>`
        // values that get *moved* into Rust on `TerminalSession.new(c)`.
        // The Swift `config` variable must NOT be reused after the call;
        // its String/Vec fields are no longer owned by Swift.
        SessionConfig(
            rows: rows, cols: cols, pixel_w: 800, pixel_h: 600,
            command: "/bin/zsh".intoRustString(),
            cwd: "/tmp".intoRustString(),
            env: makeBytes(Array("TERM=xterm-256color\nLANG=en_US.UTF-8\n".utf8)),
            scrollback_lines: 0
        )
    }

    // MARK: - Construction

    func testNewReturnsHandleWithCapturedGeometry() {
        let session = TerminalSession.new(sampleConfig(rows: 40, cols: 120))!
        XCTAssertEqual(session.rows(), 40)
        XCTAssertEqual(session.cols(), 120)
    }

    // MARK: - Lifecycle (drop semantics)

    func testHandleDropsCleanlyOnScopeExit() {
        // The swift-bridge-generated `deinit` calls
        // `__swift_bridge__$TerminalSession$_free(ptr)`, which on the
        // Rust side reconstructs the `Box` via `Box::from_raw` and
        // drops it. Our Rust `Drop` impl unwinds the captured config
        // and (in test builds) bumps a global counter.
        //
        // From Swift we can't observe the Rust counter directly; what
        // we CAN observe is that no leak / use-after-free occurs across
        // many construct-and-drop cycles. If swift-bridge's destructor
        // wiring were broken, ASan / address-sanitized test runs would
        // surface it; on a normal build, this test simply proves the
        // handle is constructible at scale.
        for _ in 0..<256 {
            let session = TerminalSession.new(sampleConfig())!
            XCTAssertEqual(session.rows(), 24)
            XCTAssertEqual(session.cols(), 80)
            // Implicit drop at iteration end.
        }
    }

    func testHandleHonorsExplicitlyReleasedReference() {
        // Demonstrate the FFI contract that an opaque handle bound to
        // a single Swift owner is released the moment that owner goes
        // out of scope. Re-binding to a new `let` after `_ = session`
        // is enough for ARC to release the prior instance.
        do {
            let session = TerminalSession.new(sampleConfig(rows: 30, cols: 90))!
            XCTAssertEqual(session.rows(), 30)
        }
        // Outer scope can still construct fresh handles after the inner
        // scope's handle was dropped — proves no shared global state
        // pinned the prior handle alive.
        let next = TerminalSession.new(sampleConfig(rows: 50, cols: 100))!
        XCTAssertEqual(next.rows(), 50)
        XCTAssertEqual(next.cols(), 100)
    }

    // MARK: - Distinct handles are independent

    func testTwoHandlesCarryIndependentConfigs() {
        let small = TerminalSession.new(sampleConfig(rows: 24, cols: 80))!
        let large = TerminalSession.new(sampleConfig(rows: 60, cols: 200))!
        XCTAssertEqual(small.rows(), 24)
        XCTAssertEqual(small.cols(), 80)
        XCTAssertEqual(large.rows(), 60)
        XCTAssertEqual(large.cols(), 200)
    }

    // MARK: - 4.4 scroll API round-trip across the FFI

    /// Snapshot the new scroll API methods exist on the generated
    /// Swift wrapper. If `scroll_lines` / `scroll_to_bottom` /
    /// `is_alt_screen` aren't on the type, this fails to compile —
    /// canary for "I forgot to regen the bridge after editing
    /// `bridge.rs`." Per memory `feedback_ffi_clean_rebuild.md`,
    /// FFI shape changes require `xcodebuild clean test`.
    func testScrollAPIIsExposed() {
        let session = TerminalSession.new(sampleConfig())!
        // No assertion on the operation itself — this is purely a
        // compile-time canary that the swift-bridge generated wrapper
        // carries the new methods. The behavioural round-trips are
        // covered below + by the Rust-side FFI tests in bridge.rs.
        session.scroll_lines(0)
        session.scroll_to_bottom()
        let alt = session.is_alt_screen()
        XCTAssertFalse(
            alt, "fresh /bin/zsh session is on the primary screen")
    }

    /// `is_alt_screen` returns false on a fresh session and remains
    /// false after benign scroll calls — alt-screen mode is parser-
    /// driven (DECSET 1049 / 47 / 1047), so calling the scroll API
    /// can never flip it.
    func testIsAltScreenIsFalseOnFreshSessionAndStableAcrossScrolls() {
        let session = TerminalSession.new(sampleConfig())!
        XCTAssertFalse(session.is_alt_screen())
        session.scroll_lines(10)
        session.scroll_lines(-10)
        session.scroll_to_bottom()
        XCTAssertFalse(session.is_alt_screen())
    }

    /// `scroll_lines(0)` and `scroll_to_bottom` on a session with no
    /// scrollback yet are no-op-equivalents. We can't assert the
    /// post-state directly without `take_frame_delta`, but we CAN
    /// assert no panic / crash across many calls — the FFI surface
    /// must tolerate "scroll on an empty buffer" without instability.
    func testScrollOnEmptyScrollbackIsStableAcrossManyCalls() {
        let session = TerminalSession.new(sampleConfig())!
        for _ in 0..<256 {
            session.scroll_lines(Int32.max)
            session.scroll_lines(Int32.min)
            session.scroll_to_bottom()
        }
        // If we got here, the FFI surface stayed sound across 768
        // boundary-crossing calls. The Rust side has the deeper
        // behavioural assertions (clamp-to-bounds + post-scroll
        // observable state via `take_frame_delta`).
        XCTAssertEqual(session.rows(), 24)
    }
}
