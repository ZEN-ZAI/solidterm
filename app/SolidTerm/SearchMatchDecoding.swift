// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// M7-2 ⌘F find — Swift-side decoder for the
// `TerminalSession.search(query, regex_flag) -> Vec<u8>` payload produced
// by Rust's `encode_search_matches` (SearchMatchWire records, 8 bytes
// each, little-endian native ABI).
//
// Cross-language contract pinned to `crates/solidterm-ffi/src/bridge.rs`
// `SearchMatchWire`. Same `Vec<u8>`-of-fixed-records pattern as
// `BlockBoundaryDecoding` — collections cross the FFI as `Vec<u8>` of
// fixed-size records rather than swift-bridge typed collections
// (ADR-0006).

import Foundation

/// Swift mirror of Rust's `solidterm_engine::SearchMatch`.
/// `line` is alacritty-absolute: negative = scrollback row, non-negative
/// = viewport row in `[0..screen_lines)`.
public struct SearchMatchSwift: Equatable {
    public let line: Int32
    public let col: UInt16
    public let len: UInt16

    public init(line: Int32, col: UInt16, len: UInt16) {
        self.line = line
        self.col = col
        self.len = len
    }
}

public enum SearchMatchDecoding {
    /// Wire-record size in bytes. Mirrors
    /// `core::mem::size_of::<SearchMatchWire>() == 8` in `bridge.rs`.
    public static let wireSize: Int = 8

    public enum DecodeError: Error, Equatable {
        case malformedPayload(byteCount: Int)
    }

    public static func decode(_ bytes: [UInt8]) throws -> [SearchMatchSwift] {
        guard bytes.count % wireSize == 0 else {
            throw DecodeError.malformedPayload(byteCount: bytes.count)
        }
        return bytes.withUnsafeBufferPointer { decodeBuffer($0) }
    }

    /// Read records from a swift-bridge `RustVec<UInt8>` (the wire form
    /// of `Vec<u8>` returned by `TerminalSession.search(...)`). Reads
    /// directly from the Rust-owned buffer via `as_ptr()`.
    public static func decode(_ vec: RustVec<UInt8>) throws -> [SearchMatchSwift] {
        let length = vec.len()
        guard length % wireSize == 0 else {
            throw DecodeError.malformedPayload(byteCount: length)
        }
        guard length > 0 else { return [] }
        // `withExtendedLifetime` keeps the RustVec (and thus the Rust-owned
        // buffer `as_ptr()` points into) alive across the entire read.
        // Without it, ARC may release `vec` after its last syntactic use
        // (the `as_ptr()` call) — before `decodeBuffer` finishes —
        // since that callee only sees the raw pointer, not the owner.
        // That is a use-after-free in optimized release builds.
        return withExtendedLifetime(vec) {
            let buf = UnsafeBufferPointer(start: vec.as_ptr(), count: length)
            return decodeBuffer(buf)
        }
    }

    private static func decodeBuffer(
        _ buf: UnsafeBufferPointer<UInt8>
    ) -> [SearchMatchSwift] {
        let n = buf.count / wireSize
        var out: [SearchMatchSwift] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let base = i * wireSize
            let lineBits =
                UInt32(buf[base + 0])
                | (UInt32(buf[base + 1]) << 8)
                | (UInt32(buf[base + 2]) << 16)
                | (UInt32(buf[base + 3]) << 24)
            let line = Int32(bitPattern: lineBits)
            let col = UInt16(buf[base + 4]) | (UInt16(buf[base + 5]) << 8)
            let len = UInt16(buf[base + 6]) | (UInt16(buf[base + 7]) << 8)
            out.append(SearchMatchSwift(line: line, col: col, len: len))
        }
        return out
    }
}
