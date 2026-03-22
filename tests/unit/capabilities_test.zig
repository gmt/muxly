const std = @import("std");
const builtin = @import("builtin");
const muxly = @import("muxly");

test "capabilities describe current phase-2 semantics truthfully" {
    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try (muxly.capabilities.Capabilities{}).writeJson(buffer.writer());

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"conversationApi\":\"library-first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"ttyApiShape\":\"neutral-conversation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"ttySizeNegotiation\":\"requested-vs-actual-local-only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"followTailSemantics\":\"stored-node-preference\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"viewStateScope\":\"shared-document-transitional\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"viewerCompositionLocation\":\"client\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"bufferPolicy\":\"runtime-configurable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"paneCaptureStreaming\":\"h2-and-h3wt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"maxMessageBytes\":134217728") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"maxDocumentContentBytes\":1073741824") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"tmuxBackendMode\":\"hybrid-control-invalidation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"tmuxTargetScope\":\"root-document-only\"") != null);

    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"supportsUnixSocket\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"supportsTcpSocket\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"implementedTransports\":[]") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"supportsUnixSocket\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"supportsTcpSocket\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"implementedTransports\":[\"unix-domain-socket\",\"tcp\",\"http\",\"h2\",\"h3wt\"]") != null);
    }

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"supportsNamedPipes\":false") != null);
}
