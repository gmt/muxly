const std = @import("std");
const events = @import("events.zig");

pub fn parseLine(line: []const u8) !events.Event {
    if (line.len == 0) return .{ .output = line };

    if (std.mem.eql(u8, line, "%exit")) return .exit;

    if (std.mem.startsWith(u8, line, "%begin ")) {
        return .{ .begin = try parseBoundary(line["%begin ".len..]) };
    }
    if (std.mem.startsWith(u8, line, "%end ")) {
        return .{ .end = try parseBoundary(line["%end ".len..]) };
    }
    if (std.mem.startsWith(u8, line, "%error ")) {
        return .{ .command_error = try parseBoundary(line["%error ".len..]) };
    }
    if (std.mem.startsWith(u8, line, "%output ")) {
        return .{ .pane_output = try parsePaneOutput(line["%output ".len..]) };
    }
    if (std.mem.startsWith(u8, line, "%extended-output ")) {
        return .{ .pane_output = try parsePaneOutputExtended(line["%extended-output ".len..]) };
    }
    if (line[0] == '%') {
        return .{ .notification = parseNotification(line[1..]) };
    }

    return .{ .output = line };
}

fn parseBoundary(value: []const u8) !events.CommandBoundary {
    var parts = std.mem.splitScalar(u8, value, ' ');
    const timestamp_text = parts.next() orelse return error.InvalidBoundary;
    const command_text = parts.next() orelse return error.InvalidBoundary;
    const flags_text = parts.next() orelse return error.InvalidBoundary;

    return .{
        .timestamp = try std.fmt.parseInt(u64, timestamp_text, 10),
        .command_number = try std.fmt.parseInt(u64, command_text, 10),
        .flags = try std.fmt.parseInt(i64, flags_text, 10),
    };
}

fn parseNotification(value: []const u8) events.Notification {
    if (std.mem.indexOfScalar(u8, value, ' ')) |space_index| {
        return .{
            .name = value[0..space_index],
            .payload = value[space_index + 1 ..],
        };
    }
    return .{
        .name = value,
        .payload = "",
    };
}

fn parsePaneOutput(value: []const u8) !events.PaneOutput {
    if (std.mem.indexOfScalar(u8, value, ' ')) |space_index| {
        return .{
            .pane_id = value[0..space_index],
            .payload = value[space_index + 1 ..],
        };
    }
    return error.InvalidPaneOutput;
}

fn parsePaneOutputExtended(value: []const u8) !events.PaneOutput {
    var parts = std.mem.splitScalar(u8, value, ' ');
    const pane_id = parts.next() orelse return error.InvalidPaneOutput;
    _ = parts.next() orelse return error.InvalidPaneOutput;
    const payload = parts.rest();
    return .{
        .pane_id = pane_id,
        .payload = payload,
    };
}

pub fn parsePaneSnapshotLine(line: []const u8) !events.PaneSnapshot {
    var parts = std.mem.splitScalar(u8, line, '\t');
    const session_name = parts.next() orelse return error.InvalidPaneSnapshot;
    const session_id = parts.next() orelse return error.InvalidPaneSnapshot;
    const window_id = parts.next() orelse return error.InvalidPaneSnapshot;
    const window_name = parts.next() orelse return error.InvalidPaneSnapshot;
    const pane_id = parts.next() orelse return error.InvalidPaneSnapshot;
    const pane_title = parts.next() orelse return error.InvalidPaneSnapshot;
    const pane_active = parts.next() orelse return error.InvalidPaneSnapshot;

    return .{
        .session_name = session_name,
        .session_id = session_id,
        .window_id = window_id,
        .window_name = window_name,
        .pane_id = pane_id,
        .pane_title = pane_title,
        .pane_active = try parseBoolFlag(pane_active),
    };
}

fn parseBoolFlag(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.mem.eql(u8, value, "1")) return true;
    return error.InvalidBoolFlag;
}
