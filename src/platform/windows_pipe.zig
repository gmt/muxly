//! Windows named-pipe transport placeholder.
//!
//! The public client surface still reports `error.UnsupportedPlatform` on
//! Windows until a real transport implementation lands here.

/// Stub entry point used to make the current platform posture explicit.
pub fn unavailable() error{UnsupportedPlatform}!void {
    return error.UnsupportedPlatform;
}
