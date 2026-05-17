# Sub-project memory

This crate uses async-tokio specifically.

- Tests in `tests/` use `#[tokio::test]`.
- Don't add `std::sync::Mutex` here — use `parking_lot::Mutex`.
