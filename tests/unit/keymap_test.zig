const std = @import("std");
const muxly = @import("muxly");

test "keymap conflict severity enum remains ordered" {
    try std.testing.expect(@intFromEnum(muxly.keymap.ConflictSeverity.none) <
        @intFromEnum(muxly.keymap.ConflictSeverity.impossible));
}
