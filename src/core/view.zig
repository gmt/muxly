//! Shared document/view state helpers.

const ids = @import("ids.zig");

/// First-pass shared view state owned by the daemon.
pub const ViewState = struct {
    root_node_id: ?ids.NodeId = null,
    follow_tail: bool = true,
};
