const ids = @import("ids.zig");

pub const ViewState = struct {
    root_node_id: ?ids.NodeId = null,
    follow_tail: bool = true,
};
