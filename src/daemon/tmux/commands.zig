const std = @import("std");

pub const pane_snapshot_format =
    "#{session_name}\t#{session_id}\t#{window_id}\t#{window_name}\t#{pane_id}\t#{pane_title}\t#{pane_active}";

pub fn listSessions() []const u8 {
    return "list-sessions";
}

pub fn listPanesAll(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "list-panes -a -F \"{s}\"",
        .{pane_snapshot_format},
    );
}
