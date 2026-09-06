// Implements spec/ffi-boundary.md — proves the swift-bridge boundary round-trips end-to-end.
// Smoke test: exercise the swift-bridge → Rust → swift-bridge round-trip.
// This is the Phase 0 Day 3-4 proof that the cargo build phase wired the
// static lib + generated Swift shims correctly.

import XCTest

@testable import SolidTerm

final class FFIRoundTripTests: XCTestCase {
    func testGreetReturnsRustFormattedString() {
        let greeting = ffi_greet("world").toString()
        XCTAssertEqual(greeting, "hello world, from rust")
    }
}
