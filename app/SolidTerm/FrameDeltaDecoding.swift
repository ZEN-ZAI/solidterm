// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Swift-side decoder (ADR-0006) for the
// `FrameDelta.cells: Vec<u8>` payload produced by Rust's
// `encode_cells` (CellDeltaWire records, 48 bytes each, little-endian
// native ABI).
//
// The byte layout is the cross-language contract; field offsets MUST
// stay in sync with `crates/solidterm-ffi/src/bridge.rs`'s
// `CellDeltaWire`.

import Foundation

/// Swift mirror of Rust's `CellDeltaWire`. Field order, sizes, and
/// offsets MUST match `crates/solidterm-ffi/src/bridge.rs`.
public struct CellDeltaSwift: Equatable {
    public var row: UInt16
    public var col: UInt16
    public var grapheme: [UInt8]  // 32 bytes, UTF-8, null-padded
    public var fg: UInt32
    public var bg: UInt32
    public var attrs: UInt16
    public var width: UInt8

    public init(
        row: UInt16, col: UInt16, grapheme: [UInt8],
        fg: UInt32, bg: UInt32, attrs: UInt16, width: UInt8
    ) {
        self.row = row
        self.col = col
        self.grapheme = grapheme
        self.fg = fg
        self.bg = bg
        self.attrs = attrs
        self.width = width
    }
}

/// Decode the `FrameDelta.cells: Vec<u8>` byte payload into Swift
/// `CellDeltaSwift` records. Throws on malformed input (length not a
/// multiple of 48, the CellDeltaWire wire size).
public enum FrameDeltaDecoding {
    public static let cellWireSize: Int = 48

    public enum DecodeError: Error, Equatable {
        case malformedPayload(byteCount: Int)
    }

    /// Read records from a `[UInt8]` produced by Rust's `encode_cells`.
    public static func decodeCells(_ bytes: [UInt8]) throws -> [CellDeltaSwift] {
        guard bytes.count % cellWireSize == 0 else {
            throw DecodeError.malformedPayload(byteCount: bytes.count)
        }
        return bytes.withUnsafeBufferPointer { decodeCellsBuffer($0) }
    }

    /// Read records from a `RustVec<UInt8>` (the swift-bridge wire form
    /// of `Vec<u8>` on `FrameDelta.cells`). Reads directly from the
    /// Rust-owned buffer via `as_ptr()` — no per-byte FFI calls, no
    /// intermediate Swift array. The pointer is valid for the duration
    /// of this call: `vec` is held by reference, so its `deinit` (which
    /// frees the Rust `Vec<u8>`) cannot fire until we return.
    public static func decodeCells(_ vec: RustVec<UInt8>) throws -> [CellDeltaSwift] {
        let length = vec.len()
        guard length % cellWireSize == 0 else {
            throw DecodeError.malformedPayload(byteCount: length)
        }
        // `withExtendedLifetime` keeps the RustVec (and thus the Rust-owned
        // buffer `as_ptr()` points into) alive across the entire read.
        // Without it, ARC may release `vec` after its last syntactic use
        // (the `as_ptr()` call) — before `decodeCellsBuffer` finishes —
        // since that callee only sees the raw pointer, not the owner.
        // That is a use-after-free in optimized release builds.
        return withExtendedLifetime(vec) {
            let buf = UnsafeBufferPointer(start: vec.as_ptr(), count: length)
            return decodeCellsBuffer(buf)
        }
    }

    /// Decode an already-validated buffer of wire bytes into Swift records.
    /// Caller has confirmed `buf.count % cellWireSize == 0`.
    private static func decodeCellsBuffer(
        _ buf: UnsafeBufferPointer<UInt8>
    ) -> [CellDeltaSwift] {
        let n = buf.count / cellWireSize
        var out: [CellDeltaSwift] = []
        out.reserveCapacity(n)

        for i in 0..<n {
            let base = i * cellWireSize
            // Field offsets per the wire layout table in bridge.rs.
            let row = readU16(buf, at: base + 0)
            let col = readU16(buf, at: base + 2)
            var grapheme = [UInt8](repeating: 0, count: 32)
            for k in 0..<32 { grapheme[k] = buf[base + 4 + k] }
            let fg = readU32(buf, at: base + 36)
            let bg = readU32(buf, at: base + 40)
            let attrs = readU16(buf, at: base + 44)
            let width = buf[base + 46]
            out.append(
                CellDeltaSwift(
                    row: row, col: col, grapheme: grapheme,
                    fg: fg, bg: bg, attrs: attrs, width: width
                ))
        }
        return out
    }

    /// Encode `CellDeltaSwift` records into the wire payload Rust expects.
    /// Mirrors the Rust `encode_cells` function so Swift round-trip tests
    /// can verify byte-level symmetry. Production cells flow Rust→Swift,
    /// so this is primarily for tests.
    public static func encodeCells(_ cells: [CellDeltaSwift]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cells.count * cellWireSize)
        out.withUnsafeMutableBufferPointer { buf in
            for (i, c) in cells.enumerated() {
                let base = i * cellWireSize
                writeU16(buf, at: base + 0, c.row)
                writeU16(buf, at: base + 2, c.col)
                let limit = min(c.grapheme.count, 32)
                for k in 0..<limit { buf[base + 4 + k] = c.grapheme[k] }
                writeU32(buf, at: base + 36, c.fg)
                writeU32(buf, at: base + 40, c.bg)
                writeU16(buf, at: base + 44, c.attrs)
                buf[base + 46] = c.width
                buf[base + 47] = 0  // reserved
            }
        }
        return out
    }

    // MARK: - Little-endian primitive readers/writers
    //
    // The wire layout uses native ABI ordering. SolidTerm targets arm64
    // (Apple Silicon, little-endian); we encode/decode explicitly little-
    // endian so a hypothetical big-endian build would still round-trip
    // bit-identical bytes between Rust and Swift.

    private static func readU16(_ buf: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt16 {
        UInt16(buf[offset]) | (UInt16(buf[offset + 1]) << 8)
    }

    private static func readU32(_ buf: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt32 {
        UInt32(buf[offset])
            | (UInt32(buf[offset + 1]) << 8)
            | (UInt32(buf[offset + 2]) << 16)
            | (UInt32(buf[offset + 3]) << 24)
    }

    private static func writeU16(
        _ buf: UnsafeMutableBufferPointer<UInt8>, at offset: Int, _ value: UInt16
    ) {
        buf[offset] = UInt8(value & 0xFF)
        buf[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func writeU32(
        _ buf: UnsafeMutableBufferPointer<UInt8>, at offset: Int, _ value: UInt32
    ) {
        buf[offset] = UInt8(value & 0xFF)
        buf[offset + 1] = UInt8((value >> 8) & 0xFF)
        buf[offset + 2] = UInt8((value >> 16) & 0xFF)
        buf[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}

/// Encode env pairs as `KEY=VALUE\n`-joined UTF-8 bytes for
/// `SessionConfig.env`. Mirror of Rust's `decode_env` (Swift→Rust
/// direction). Values containing literal `\n` are not representable —
/// callers should validate at the source.
public enum EnvEncoding {
    public static func encode(_ pairs: [(String, String)]) -> [UInt8] {
        var s = ""
        for (k, v) in pairs {
            s.append(k)
            s.append("=")
            s.append(v)
            s.append("\n")
        }
        return Array(s.utf8)
    }
}
