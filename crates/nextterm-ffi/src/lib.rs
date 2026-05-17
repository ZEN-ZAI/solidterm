// swift-bridge FFI surface. Pure data across the boundary — Stack A.
// See spec/ffi-boundary.md.

mod bridge;

pub use bridge::{
    decode_env, echo_cell_delta, echo_frame_delta, echo_input_event, echo_session_config,
    encode_cells, encode_search_matches, ffi_greet, kinds, CellDeltaWire, SearchMatchWire,
    TerminalSession,
};
