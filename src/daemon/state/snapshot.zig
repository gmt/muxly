const document = @import("../../core/document.zig");

pub const Snapshot = struct {
    document_lifecycle: @TypeOf(document.Document.lifecycle) = .live,
    node_count: usize = 0,
};
