// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Cross-cell shaping — Swift-side post-FFI grapheme
// cluster shaper. Detects adjacent CellDeltaSwift records that belong
// to one Unicode extended grapheme cluster (Thai SARA AM, regional
// indicator flag pairs, ZWJ spillover) and merges them into a single
// CoalescedCell with a `cellSpan` that the renderer extends quads over.
//
// Driven by ADR-0003 (Stack A — CoreText is the only cluster authority,
// so the coalescer lives Swift-side, not in Rust).

import Foundation

/// Renderer-facing cell record. Carries an owned `grapheme` String (vs
/// CellDeltaSwift's 32-byte buffer) so the coalesced cluster can exceed
/// 32 bytes when a ZWJ family spills across cells.
public struct CoalescedCell: Equatable {
    public var row: UInt16
    public var col: UInt16
    public var grapheme: String
    public var fg: UInt32
    public var bg: UInt32
    public var attrs: UInt16
    /// Display width of the primary cell (1 or 2). The renderer pairs
    /// this with `cellSpan` to size the atlas quad.
    public var width: UInt8
    /// Number of source-cell columns this entry covers. 1 for an
    /// untouched cell; ≥ 2 when adjacent cells were absorbed.
    public var cellSpan: UInt8

    public init(
        row: UInt16, col: UInt16, grapheme: String,
        fg: UInt32, bg: UInt32, attrs: UInt16,
        width: UInt8, cellSpan: UInt8
    ) {
        self.row = row
        self.col = col
        self.grapheme = grapheme
        self.fg = fg
        self.bg = bg
        self.attrs = attrs
        self.width = width
        self.cellSpan = cellSpan
    }
}

public enum GraphemeClusterCoalescer {
    /// Row-major sweep. O(n) on ASCII (fast-path candidate() exits on
    /// the first byte compare); allocations only on confirmed clusters.
    ///
    /// Chain growth: we track the *accumulated* cluster's leading scalar
    /// (`headScalar`) and trailing scalar (`tailScalar`) instead of
    /// looking back at `cells[j-1]`. That matters for Thai vowel+tone
    /// stacks (e.g. ก + ื + ่) where the second mark only joins if the
    /// rule fires against the **consonant** at the head, not the
    /// preceding mark.
    public static func coalesce(_ cells: [CellDeltaSwift]) -> [CoalescedCell] {
        var out: [CoalescedCell] = []
        out.reserveCapacity(cells.count)

        var i = 0
        while i < cells.count {
            let primary = cells[i]
            var grapheme = decodeGrapheme(primary.grapheme)
            var span: UInt8 = primary.width == 0 ? 1 : primary.width
            var headScalar = firstScalar(of: primary.grapheme) ?? 0
            var tailScalar = lastScalar(of: primary.grapheme) ?? 0
            var prevCol = primary.col
            var prevWidth = primary.width == 0 ? 1 : primary.width
            var j = i + 1
            while j < cells.count {
                let next = cells[j]
                // Adjacency: same row, next.col == prev.col + prev.width.
                guard next.row == primary.row,
                    prevCol &+ UInt16(prevWidth) == next.col
                else { break }
                guard let bHead = firstScalar(of: next.grapheme) else { break }
                guard
                    candidate(
                        headScalar: headScalar,
                        tailScalar: tailScalar,
                        bHead: bHead)
                else { break }

                let nextGrapheme = decodeGrapheme(next.grapheme)
                let joined = grapheme + nextGrapheme
                if shouldMerge(headScalar: headScalar, joined: joined) {
                    grapheme = joined
                    let nextWidth = next.width == 0 ? 1 : next.width
                    span = span &+ nextWidth
                    tailScalar = lastScalar(of: next.grapheme) ?? tailScalar
                    prevCol = next.col
                    prevWidth = nextWidth
                    j += 1
                } else {
                    break
                }
            }
            out.append(
                CoalescedCell(
                    row: primary.row, col: primary.col, grapheme: grapheme,
                    fg: primary.fg, bg: primary.bg, attrs: primary.attrs,
                    width: primary.width == 0 ? 1 : primary.width,
                    cellSpan: span))
            i = j
        }
        return out
    }

    /// Cheap adjacency screen. Decides whether `bHead` could continue
    /// the cluster anchored at `headScalar` with current tail
    /// `tailScalar`. Authoritative confirmation is `shouldMerge`.
    static func candidate(
        headScalar: UInt32, tailScalar: UInt32, bHead: UInt32
    ) -> Bool {
        // TM: any Thai consonant at the cluster head allows further
        // Thai marks / SARA AM to be appended, regardless of what the
        // current tail is (a mark itself, or the consonant). This is
        // what makes ก + ื + ่ grow into one cluster.
        if (0x0E01...0x0E2E).contains(headScalar) {
            if (0x0E30...0x0E3A).contains(bHead) { return true }
            if (0x0E47...0x0E4E).contains(bHead) { return true }
            if bHead == 0x0E33 { return true }
        }

        // RI: regional indicator pair → flag. Only valid when current
        // tail is itself an RI (so we don't accidentally chain a third
        // RI onto an already-formed flag — Unicode flags are exactly 2
        // RIs).
        if (0x1F1E6...0x1F1FF).contains(tailScalar),
            (0x1F1E6...0x1F1FF).contains(bHead)
        {
            return true
        }

        // ZWJ-spill: ZWJ continuation crosses cell boundary.
        if tailScalar == 0x200D || bHead == 0x200D { return true }

        // VS-spill: variation selector continues into the next cell.
        if bHead == 0xFE0E || bHead == 0xFE0F { return true }

        // Skin-tone modifier (U+1F3FB..U+1F3FF) continues an emoji base
        // (👍🏽). Both base and modifier are width-2 astrals, so when they
        // don't pack into one 32-byte cell the engine emits them in
        // adjacent cells. This is only an adjacency screen — shouldMerge
        // → isOneCluster confirms the join and rejects a stray modifier
        // with no emoji base, so it can't over-merge.
        if (0x1F3FB...0x1F3FF).contains(bHead) { return true }

        // Generic combining mark (Unicode Mn / Mc / Me): Devanagari
        // matra, Arabic diacritic, Hebrew point, Vietnamese stacked
        // diacritic, enclosing keycap, etc. The engine packs these as
        // zerowidth on the base cell, but a base + long mark run can
        // overflow the 32-byte cell and spill the tail into the next
        // cell; admit marks here so the spill rejoins its base. As with
        // every branch, isOneCluster is the authority — UAX #29 attaches
        // marks to a valid base and rejects a leading/orphan mark, so
        // this screen can't over-merge. Thai marks keep their dedicated
        // rule above: SARA AM (U+0E33) is `Lo`, not a mark category, and
        // UAX #29 splits it, so the generic Mn/Mc/Me screen would miss it.
        if let s = Unicode.Scalar(bHead) {
            switch s.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                return true
            default:
                break
            }
        }

        return false
    }

    /// Commit decision. Accepts either:
    ///   (a) Swift's UAX #29 confirms the joined string is one
    ///       composed character sequence (ZWJ emoji, flag, VS).
    ///   (b) Thai visual cluster — Thai consonant head followed by
    ///       Thai marks / SARA AM only. SARA AM is `Lo` under UAX #29
    ///       so UAX #29 *splits* ท+ำ into two clusters, but visually
    ///       they're one drawn unit; the renderer must treat them as
    ///       one.
    static func shouldMerge(headScalar: UInt32, joined: String) -> Bool {
        if isOneCluster(joined) { return true }
        if (0x0E01...0x0E2E).contains(headScalar),
            isThaiVisualCluster(joined)
        {
            return true
        }
        return false
    }

    /// True iff `s` is exactly: one Thai consonant followed by one or
    /// more Thai marks / SARA AM, and nothing else. Used to override
    /// UAX #29 for SARA AM stacks.
    static func isThaiVisualCluster(_ s: String) -> Bool {
        var first = true
        for scalar in s.unicodeScalars {
            if first {
                guard (0x0E01...0x0E2E).contains(scalar.value) else { return false }
                first = false
                continue
            }
            let v = scalar.value
            let isMark =
                (0x0E30...0x0E3A).contains(v) || (0x0E47...0x0E4E).contains(v) || v == 0x0E33
            if !isMark { return false }
        }
        return !first  // must have at least 2 scalars total
    }

    /// Authoritative cluster check via Swift's UAX #29 implementation.
    /// Only called when `candidate()` returns true.
    static func isOneCluster(_ joined: String) -> Bool {
        var count = 0
        joined.enumerateSubstrings(
            in: joined.startIndex..<joined.endIndex,
            options: .byComposedCharacterSequences
        ) { _, _, _, stop in
            count += 1
            if count > 1 { stop = true }
        }
        return count == 1
    }

    /// Decode the 32-byte UTF-8 grapheme buffer to a Swift String,
    /// trimming trailing nulls. Matches MetalRenderer.decodeGraphemeString
    /// (we keep a local copy so the coalescer doesn't pull in the
    /// renderer's static surface for unit testing).
    static func decodeGrapheme(_ buf: [UInt8]) -> String {
        var end = buf.count
        for (i, byte) in buf.enumerated() where byte == 0 {
            end = i
            break
        }
        if end == 0 { return "" }
        return String(decoding: buf[0..<end], as: UTF8.self)
    }

    /// First Unicode scalar of the 32-byte UTF-8 buffer, or nil on blank.
    static func firstScalar(of buf: [UInt8]) -> UInt32? {
        let s = decodeGrapheme(buf)
        return s.unicodeScalars.first.map { $0.value }
    }

    /// Last Unicode scalar of the 32-byte UTF-8 buffer, or nil on blank.
    static func lastScalar(of buf: [UInt8]) -> UInt32? {
        let s = decodeGrapheme(buf)
        return s.unicodeScalars.last.map { $0.value }
    }
}
