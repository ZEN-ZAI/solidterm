// Implements spec/cross-cell-shaping.md test matrix.

import XCTest

@testable import SolidTerm

final class GraphemeClusterCoalescerTests: XCTestCase {

    // MARK: - Helpers

    private func cell(
        _ row: UInt16, _ col: UInt16, _ s: String, width: UInt8 = 1
    ) -> CellDeltaSwift {
        var buf = [UInt8](repeating: 0, count: 32)
        for (i, b) in s.utf8.enumerated() where i < 32 { buf[i] = b }
        return CellDeltaSwift(
            row: row, col: col, grapheme: buf,
            fg: 0xFFFF_FFFF, bg: 0x0000_00FF,
            attrs: 0, width: width)
    }

    // MARK: - No-op cases

    func testAsciiUntouched() {
        let input = [cell(0, 0, "A"), cell(0, 1, "B"), cell(0, 2, "C")]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.map(\.grapheme), ["A", "B", "C"])
        XCTAssertEqual(out.map(\.cellSpan), [1, 1, 1])
    }

    func testThaiConsonantAloneNoCoalesce() {
        // ก ข — two unrelated consonants, no mark between → no coalesce.
        let input = [cell(0, 0, "ก"), cell(0, 1, "ข")]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map(\.grapheme), ["ก", "ข"])
        XCTAssertEqual(out.map(\.cellSpan), [1, 1])
    }

    func testRowBoundaryNoCoalesce() {
        // Across rows must never coalesce, even if scalars would otherwise match.
        let input = [cell(0, 79, "ก"), cell(1, 0, "ำ")]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map(\.cellSpan), [1, 1])
    }

    func testColumnGapNoCoalesce() {
        // Column gap (not adjacent) must not coalesce.
        let input = [cell(0, 0, "ก"), cell(0, 5, "ำ")]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map(\.cellSpan), [1, 1])
    }

    // MARK: - Thai

    func testThaiSaraAm() {
        // ทำ — consonant ท (U+0E17) + SARA AM (U+0E33). Architectural
        // case that triggered ADR-0003: alacritty splits these into
        // adjacent cells; coalescer must merge them.
        let input = [cell(0, 0, "ท"), cell(0, 1, "ำ")]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].grapheme, "ทำ")
        XCTAssertEqual(out[0].cellSpan, 2)
        XCTAssertEqual(out[0].col, 0)
    }

    func testThaiToneMark() {
        // ก่ — consonant ก (U+0E01) + MAI EK (U+0E48).
        let input = [cell(0, 0, "ก"), cell(0, 1, "\u{0E48}")]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].grapheme, "ก\u{0E48}")
        XCTAssertEqual(out[0].cellSpan, 2)
    }

    func testThaiVowelPlusTone() {
        // ก + ื + ่  — three cells if engine splits each combining mark.
        // Cluster confirm passes only if all three combine into one
        // extended grapheme cluster.
        let input = [
            cell(0, 0, "ก"),
            cell(0, 1, "\u{0E37}"),  // SARA UEE
            cell(0, 2, "\u{0E48}"),  // MAI EK
        ]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].grapheme, "ก\u{0E37}\u{0E48}")
        XCTAssertEqual(out[0].cellSpan, 3)
    }

    // MARK: - Flag (regional indicator pair)

    func testFlagPair() {
        // 🇹🇭 — U+1F1F9 U+1F1ED, both wide (width=2 in alacritty).
        let input = [
            cell(0, 0, "\u{1F1F9}", width: 2),  // RI T
            cell(0, 2, "\u{1F1ED}", width: 2),  // RI H
        ]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].grapheme, "\u{1F1F9}\u{1F1ED}")
        XCTAssertEqual(out[0].cellSpan, 4)
        XCTAssertEqual(out[0].width, 2)
    }

    // MARK: - ZWJ

    func testZwjCoupleAlreadyPackedUntouched() {
        // 👨‍👩 fits in 11 bytes UTF-8 — within the 16-byte buffer, so
        // engine packs the ZWJ continuation as zerowidth in the
        // primary. Coalescer should pass through unchanged.
        // (3-person family 👨‍👩‍👧 is 18 bytes and overflows — that's
        // the testZwjSpillover case below.)
        let couple = "\u{1F468}\u{200D}\u{1F469}"
        let input = [cell(0, 0, couple, width: 2)]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].grapheme, couple)
        XCTAssertEqual(out[0].cellSpan, 2)
    }

    func testZwjSpillover() {
        // Two cells where the first ends in ZWJ and the second is the
        // continuation. This mimics the engine overflow case (cluster
        // would exceed 16 bytes so alacritty puts the trailing emoji
        // in its own cell).
        let input = [
            cell(0, 0, "\u{1F468}\u{200D}", width: 2),  // 👨 + ZWJ
            cell(0, 2, "\u{1F469}", width: 2),  // 👩
        ]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].grapheme, "\u{1F468}\u{200D}\u{1F469}")
        XCTAssertEqual(out[0].cellSpan, 4)
    }

    // MARK: - Variation selector spill

    func testVariationSelectorSpillover() {
        // ⚠ + VS16 — pictographic variation selector continuing into
        // a separate cell. Cluster check should fold them.
        let input = [
            cell(0, 0, "\u{26A0}"),  // ⚠
            cell(0, 1, "\u{FE0F}"),  // VS16
        ]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].grapheme, "\u{26A0}\u{FE0F}")
        XCTAssertEqual(out[0].cellSpan, 2)
    }

    // MARK: - Skin-tone modifier spill (FIX-2)

    func testSkinToneModifierSpillover() {
        // 👍 + 🏽 (U+1F44D + U+1F3FD) — base emoji and skin-tone modifier
        // are both width-2 astrals; when they don't pack into one cell
        // the engine emits them adjacently. Must coalesce into one
        // 4-column cluster.
        let input = [
            cell(0, 0, "\u{1F44D}", width: 2),  // 👍
            cell(0, 2, "\u{1F3FD}", width: 2),  // 🏽 skin-tone modifier
        ]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].grapheme, "\u{1F44D}\u{1F3FD}")
        XCTAssertEqual(out[0].cellSpan, 4)
    }

    func testSkinToneModifierDoesNotSwallowFollowingEmoji() {
        // 👍 + 🏽 + 😀 — the modifier merges with its base, but the chain
        // must STOP there and not absorb the next emoji (over-merge
        // guard). 🏽 (Emoji_Modifier, Grapheme_Cluster_Break=Extend)
        // attaches to whatever precedes it per UAX#29, so a negative
        // "stray modifier after a non-emoji base" case does NOT exist —
        // Swift folds even "A🏽" into one cluster, exactly as the
        // pre-existing VS16 rule already folds "A︎". The real safety
        // property is that the run terminates correctly.
        let input = [
            cell(0, 0, "\u{1F44D}", width: 2),  // 👍
            cell(0, 2, "\u{1F3FD}", width: 2),  // 🏽
            cell(0, 4, "\u{1F600}", width: 2),  // 😀 (separate)
        ]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].grapheme, "\u{1F44D}\u{1F3FD}")
        XCTAssertEqual(out[0].cellSpan, 4)
        XCTAssertEqual(out[1].grapheme, "\u{1F600}")
        XCTAssertEqual(out[1].cellSpan, 2)
    }

    // MARK: - Generic combining-mark spill (FIX-5)

    func testDevanagariMatraSpillover() {
        // क + ी (U+0915 + U+0940 VOWEL SIGN II, a spacing mark Mc) split
        // across cells must coalesce — UAX #29 binds the matra to its
        // consonant. Exercises the generic Mn/Mc/Me screen, not a
        // per-script allowlist.
        let input = [
            cell(0, 0, "\u{0915}"),  // क
            cell(0, 1, "\u{0940}"),  // ◌ी matra
        ]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].grapheme, "\u{0915}\u{0940}")
    }

    func testArabicDiacriticSpillover() {
        // ب + ◌َ (U+0628 BEH + U+064E FATHA, a nonspacing mark Mn).
        let input = [
            cell(0, 0, "\u{0628}"),  // ب
            cell(0, 1, "\u{064E}"),  // ◌َ fatha
        ]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].grapheme, "\u{0628}\u{064E}")
    }

    // MARK: - False-positive guard

    func testCandidateRejectedByClusterCheck() {
        // ZWJ between two characters that don't actually combine
        // (e.g. ZWJ between letter A and letter B). The candidate
        // screen fires (ZWJ-spill rule), but isOneCluster rejects.
        // Verify we DO NOT coalesce.
        let input = [
            cell(0, 0, "A\u{200D}"),  // A + ZWJ
            cell(0, 1, "B"),
        ]
        let out = GraphemeClusterCoalescer.coalesce(input)
        // UAX #29 actually KEEPS A+ZWJ+B as one cluster (the spec
        // treats trailing ZWJ as joining). Verify behaviour matches
        // Swift's own enumerator — the coalescer must agree with it.
        let confirmed = GraphemeClusterCoalescer.isOneCluster("A\u{200D}B")
        if confirmed {
            XCTAssertEqual(out.count, 1)
            XCTAssertEqual(out[0].cellSpan, 2)
        } else {
            XCTAssertEqual(out.count, 2)
            XCTAssertEqual(out.map(\.cellSpan), [1, 1])
        }
    }

    // MARK: - Blank / null grapheme

    func testBlankCellsUntouched() {
        let blank = CellDeltaSwift(
            row: 0, col: 0, grapheme: [UInt8](repeating: 0, count: 16),
            fg: 0, bg: 0, attrs: 0, width: 1)
        let out = GraphemeClusterCoalescer.coalesce([blank, blank])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map(\.cellSpan), [1, 1])
        XCTAssertEqual(out.map(\.grapheme), ["", ""])
    }

    // MARK: - Mixed row

    func testMixedAsciiThaiRow() {
        // "AทำB" — ASCII A, then Thai cluster, then ASCII B.
        let input = [
            cell(0, 0, "A"),
            cell(0, 1, "ท"),
            cell(0, 2, "ำ"),
            cell(0, 3, "B"),
        ]
        let out = GraphemeClusterCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.map(\.grapheme), ["A", "ทำ", "B"])
        XCTAssertEqual(out.map(\.cellSpan), [1, 2, 1])
        XCTAssertEqual(out.map(\.col), [0, 1, 3])
    }
}
