// Task #16: Thai-aware backspace. Engine round-trip happens at the
// Rust FFI boundary (`TerminalSession.cell_before_cursor()`), which
// is exercised by nextterm-ffi unit tests. This file pins the pure
// Swift classifier that decides whether the trailing scalar of a
// grapheme cluster is a Thai combining mark — the discriminator
// that decides whether the backspace path intercepts or passes
// through.

import XCTest

@testable import SolidTerm

final class ThaiBackspaceTests: XCTestCase {

    /// Thai upper vowels MAI HAN-AKAT (ั) through SARA AM (ำ) are
    /// non-spacing combining marks; backspace should treat them
    /// independently from the base consonant.
    func testUpperVowelMarksDetected() {
        for scalar in 0x0E30...0x0E3A {
            let s = Unicode.Scalar(scalar)!
            XCTAssertTrue(
                TerminalSurfaceView.isThaiCombiningMark(s),
                "U+\(String(format: "%04X", scalar)) must be detected")
        }
    }

    /// Tone marks (MAI EK, MAI THO, MAI TRI, MAI CHATTAWA), THANTHA-
    /// KHAT (cancellation), and other above-base marks in the
    /// U+0E47..U+0E4E range.
    func testToneAndOtherMarksDetected() {
        for scalar in 0x0E47...0x0E4E {
            let s = Unicode.Scalar(scalar)!
            XCTAssertTrue(
                TerminalSurfaceView.isThaiCombiningMark(s),
                "U+\(String(format: "%04X", scalar)) must be detected")
        }
    }

    /// Base consonants (U+0E01..U+0E2E) and standalone vowel chars
    /// (U+0E40..U+0E44 leading vowels, U+0E50..U+0E5B digits) MUST
    /// NOT trip the classifier — they're full code-point characters
    /// the user expects normal backspace behavior on.
    func testBaseCharsNotFalsePositive() {
        let nonMarks: [UInt32] = [
            0x0E01,  // ก
            0x0E0F,  // ฏ
            0x0E1E,  // พ
            0x0E2D,  // อ
            0x0E40,  // เ
            0x0E41,  // แ
            0x0E50,  // ๐ digit zero
            0x0041,  // ASCII A
        ]
        for v in nonMarks {
            let s = Unicode.Scalar(v)!
            XCTAssertFalse(
                TerminalSurfaceView.isThaiCombiningMark(s),
                "U+\(String(format: "%04X", v)) must NOT be flagged")
        }
    }

    /// Adjacent Unicode-block boundary scalars (U+0E2F, U+0E5C+) MUST
    /// NOT be flagged — defensive against off-by-one in the range.
    func testRangeBoundaries() {
        // Just below the mark range
        XCTAssertFalse(
            TerminalSurfaceView.isThaiCombiningMark(Unicode.Scalar(0x0E2F)!))
        // Between the two ranges
        XCTAssertFalse(
            TerminalSurfaceView.isThaiCombiningMark(Unicode.Scalar(0x0E3B)!))
        XCTAssertFalse(
            TerminalSurfaceView.isThaiCombiningMark(Unicode.Scalar(0x0E46)!))
        // Just above the second range
        XCTAssertFalse(
            TerminalSurfaceView.isThaiCombiningMark(Unicode.Scalar(0x0E4F)!))
    }
}
