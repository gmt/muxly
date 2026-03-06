const std = @import("std");

pub const DocumentId = u64;
pub const NodeId = u64;

pub const IdGenerator = struct {
    next_document_id: DocumentId = 1,
    next_node_id: NodeId = 1,

    pub fn allocDocument(self: *IdGenerator) DocumentId {
        const id = self.next_document_id;
        self.next_document_id += 1;
        return id;
    }

    pub fn allocNode(self: *IdGenerator) NodeId {
        const id = self.next_node_id;
        self.next_node_id += 1;
        return id;
    }
};

pub fn formatDocumentId(id: DocumentId, writer: anytype) !void {
    try writer.print("doc-{d}", .{id});
}

pub fn formatNodeId(id: NodeId, writer: anytype) !void {
    try writer.print("node-{d}", .{id});
}
