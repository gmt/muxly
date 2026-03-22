//! Default size limits for whole-message and whole-document buffering.
//!
//! These defaults are intentionally generous and are meant to keep the current
//! buffered request/response model from blowing up developer machines while the
//! transport and node payload paths are still being migrated toward async, lazy
//! streaming. Runtime config can override them when needed.

/// Shared whole-message cap for current buffered transport paths.
pub const default_max_message_bytes: usize = 128 * 1024 * 1024;

/// Shared whole-document content cap for current buffered node payload paths.
pub const default_max_document_content_bytes: usize = 1024 * 1024 * 1024;
