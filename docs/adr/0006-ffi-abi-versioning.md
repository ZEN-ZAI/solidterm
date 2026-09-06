# ADR-0006 — The FFI boundary is a versioned fixed-size wire ABI

Status: accepted

## Context

Swift and Rust are compiled separately and linked into one binary. What crosses
between them is not a protocol that can negotiate — it is struct layout. If the
Rust side changes a field's width or order and the Swift decoder is not rebuilt
against the same shape, nothing fails at link time; the app reads the right
bytes at the wrong offsets and paints garbage, or reads past the record and
crashes somewhere unrelated to the change that caused it.

swift-bridge handles the function surface, but the hot path is not a function
per cell. A frame's worth of cell updates has to cross as one payload, and
swift-bridge's typed collections were not taken for it — the collection support
would mean per-element bridging on the path that runs every frame.

## Decision

Bulk data crosses the boundary as `Vec<u8>` carrying a tight array of
fixed-size `#[repr(C)]` records, decoded by offset on the Swift side.

- `CellDeltaWire` is 48 bytes, of which 32 are the cell's grapheme cluster —
  wide enough that a subdivision-flag sequence, a deep ZWJ family or a long
  Thai/Indic mark stack survives the crossing whole. `SearchMatchWire` is
  8 bytes. Field order, sizes and offsets in
  `crates/solidterm-ffi/src/bridge.rs` and in the Swift decoders
  (`FrameDeltaDecoding`, `SearchMatchDecoding`) are one contract; changing one
  side alone is the bug this ADR exists to prevent.
- The boundary carries an explicit version. `ffi_api_version` lives under
  `[package.metadata.solidterm]` in `crates/solidterm-ffi/Cargo.toml` —
  namespaced so the key cannot collide with a future tool convention on the
  bare `[package.metadata]` table — and is bumped on any change to the shape of
  the boundary.
- Payloads are bounded on the producing side. `MAX_MATCHES` caps a search
  response at 10,000 records, which is 80 KB at 8 bytes each and comfortably
  under the size at which a single crossing would be worth reconsidering.
- Nothing Apple-shaped crosses. No Metal, `CAMetalLayer` or Obj-C type appears
  in the bridge — the Swift host owns rendering, the Rust core is data only.

## Consequences

- Drift is caught mechanically rather than by review.
  `scripts/check-ffi-drift.sh` regenerates the committed
  `app/SolidTerm/Generated/` shims and fails CI when they differ from what the
  current bridge would produce, so an edit to `bridge.rs` that forgets the
  regenerated Swift shim cannot ship.
- Round-trip tests exercise the boundary in both directions: Swift constructs a
  value, Rust echoes it, Swift asserts structural identity
  (`FFIDataTypeTests`, `FFIRoundTripTests`).
- The cost is that layout is manual. Adding a field to a wire record means
  touching the Rust struct, the Swift decoder, the version key and the tests
  together — deliberately more friction than adding a field to a Rust type that
  never leaves Rust.
- The 32-byte grapheme budget is a real ceiling. A cluster that exceeds it
  spills into the following cell, which is why cross-cell coalescing exists on
  the Swift side (ADR-0003) rather than being avoidable by a wider record.
