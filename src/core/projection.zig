//! Current boxed projection helpers over the daemon-owned TOM.
//!
//! The live document owns structure, source metadata, follow-tail defaults, and
//! shared view state such as root and elision. This module turns that shared
//! state plus viewer-local inputs like viewport size and scroll offsets into the
//! current boxed layout/projection cutline used by the reference viewer.

const std = @import("std");
const document_mod = @import("document.zig");
const ids = @import("ids.zig");
const muxml = @import("muxml.zig");
const source_mod = @import("source.zig");
const types = @import("types.zig");

pub const ScrollOffset = struct {
    node_id: ids.NodeId,
    top_line: usize,
};

pub const LocalState = struct {
    focused_node_id: ?ids.NodeId = null,
    /// Borrowed from the caller; keep this slice alive for any projection or
    /// request write that uses the enclosing `LocalState`.
    scroll_offsets: []const ScrollOffset = &.{},

    pub fn scrollTop(self: LocalState, node_id: ids.NodeId) ?usize {
        for (self.scroll_offsets) |offset| {
            if (offset.node_id == node_id) return offset.top_line;
        }
        return null;
    }
};

pub const Request = struct {
    rows: u16 = 24,
    cols: u16 = 80,
    local_state: LocalState = .{},
};

const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

const JsonState = struct {
    wrote_region: bool = false,
};

const ContentView = struct {
    visible_lines: std.ArrayListUnmanaged([]u8) = .{},
    full_line_count: usize = 0,
    scroll_top: usize = 0,
    scroll_max: usize = 0,

    fn deinit(self: *ContentView, allocator: std.mem.Allocator) void {
        for (self.visible_lines.items) |line| allocator.free(line);
        self.visible_lines.deinit(allocator);
    }
};

pub fn writeRequestJson(writer: anytype, request: Request) !void {
    try writer.print("{{\"rows\":{d},\"cols\":{d}", .{ request.rows, request.cols });
    if (request.local_state.focused_node_id) |focused_node_id| {
        try writer.print(",\"focusedNodeId\":{d}", .{focused_node_id});
    }
    try writer.writeAll(",\"scrollOffsets\":[");
    for (request.local_state.scroll_offsets, 0..) |offset, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"nodeId\":{d},\"topLine\":{d}}}", .{ offset.node_id, offset.top_line });
    }
    try writer.writeAll("]}");
}

pub fn writeProjectionJson(
    allocator: std.mem.Allocator,
    document: *const document_mod.Document,
    request: Request,
    writer: anytype,
) anyerror!void {
    return try writeProjectionJsonForRoot(allocator, document, null, request, writer);
}

pub fn writeProjectionJsonForRoot(
    allocator: std.mem.Allocator,
    document: *const document_mod.Document,
    root_override: ?ids.NodeId,
    request: Request,
    writer: anytype,
) anyerror!void {
    const rows = clampDimension(request.rows, 8);
    const cols = clampDimension(request.cols, 24);
    const root_node_id = root_override orelse document.view_root_node_id orelse document.root_node_id;

    try writer.writeAll("{");
    try writer.writeAll("\"title\":");
    try writer.print("{f}", .{std.json.fmt(document.title, .{})});
    try writer.print(",\"rows\":{d},\"cols\":{d},\"rootNodeId\":{d}", .{ rows, cols, root_node_id });
    if (root_override) |view_root_node_id| {
        try writer.print(",\"viewRootNodeId\":{d}", .{view_root_node_id});
    } else if (document.view_root_node_id) |view_root_node_id| {
        try writer.print(",\"viewRootNodeId\":{d}", .{view_root_node_id});
    } else {
        try writer.writeAll(",\"viewRootNodeId\":null");
    }
    if (request.local_state.focused_node_id) |focused_node_id| {
        try writer.print(",\"focusedNodeId\":{d}", .{focused_node_id});
    } else {
        try writer.writeAll(",\"focusedNodeId\":null");
    }
    try writer.writeAll(",\"regions\":[");

    var json_state = JsonState{};
    try writeProjectedNode(
        allocator,
        document,
        root_node_id,
        .{ .x = 0, .y = 0, .width = cols, .height = rows },
        request.local_state,
        &json_state,
        writer,
    );

    try writer.writeAll("]}");
}

fn writeProjectedNode(
    allocator: std.mem.Allocator,
    document: *const document_mod.Document,
    node_id: ids.NodeId,
    rect: Rect,
    local_state: LocalState,
    json_state: *JsonState,
    writer: anytype,
) anyerror!void {
    const node = document.findNodeConst(node_id) orelse return error.UnknownNode;
    const elided = isElided(document, node_id);
    const emit_region = shouldEmitRegion(node, elided);

    if (emit_region) {
        var content_view = try buildContentView(allocator, node, rect, local_state, elided);
        defer content_view.deinit(allocator);

        if (json_state.wrote_region) try writer.writeAll(",");
        json_state.wrote_region = true;

        try writer.writeAll("{");
        try writer.print("\"nodeId\":{d},\"kind\":\"{s}\",", .{ node.id, @tagName(node.kind) });
        try writer.writeAll("\"title\":");
        try writer.print("{f}", .{std.json.fmt(node.title, .{})});
        try writer.print(",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}", .{
            rect.x,
            rect.y,
            rect.width,
            rect.height,
        });
        try writer.print(",\"focused\":{},\"followTail\":{},\"scrollable\":{},\"scrollTop\":{d},\"scrollMax\":{d},\"elided\":{}", .{
            local_state.focused_node_id != null and local_state.focused_node_id.? == node.id,
            node.follow_tail,
            content_view.scroll_max != 0,
            content_view.scroll_top,
            content_view.scroll_max,
            elided,
        });
        try writer.writeAll(",\"lines\":[");
        for (content_view.visible_lines.items, 0..) |line, index| {
            if (index != 0) try writer.writeAll(",");
            try writer.print("{f}", .{std.json.fmt(line, .{})});
        }
        try writer.writeAll("]}");
    }

    if (elided or !shouldProjectChildren(node.kind) or node.children.items.len == 0) return;

    const child_rect = if (emit_region) insetRect(rect) else rect;
    if (child_rect.width == 0 or child_rect.height == 0) return;

    switch (layoutAxis(node.kind)) {
        .horizontal => try writeHorizontalChildren(allocator, document, node, child_rect, local_state, json_state, writer),
        .vertical => try writeVerticalChildren(allocator, document, node, child_rect, local_state, json_state, writer),
    }
}

const Axis = enum {
    horizontal,
    vertical,
};

fn layoutAxis(kind: types.NodeKind) Axis {
    return switch (kind) {
        .h_container => .horizontal,
        else => .vertical,
    };
}

fn writeHorizontalChildren(
    allocator: std.mem.Allocator,
    document: *const document_mod.Document,
    node: *const muxml.Node,
    rect: Rect,
    local_state: LocalState,
    json_state: *JsonState,
    writer: anytype,
) anyerror!void {
    const child_count = node.children.items.len;
    if (child_count == 0) return;

    const base_width: u16 = rect.width / @as(u16, @intCast(child_count));
    var remainder: u16 = rect.width % @as(u16, @intCast(child_count));
    var cursor_x = rect.x;

    for (node.children.items) |child_id| {
        var width = base_width;
        if (remainder != 0) {
            width += 1;
            remainder -= 1;
        }
        const child_rect = Rect{
            .x = cursor_x,
            .y = rect.y,
            .width = width,
            .height = rect.height,
        };
        try writeProjectedNode(allocator, document, child_id, child_rect, local_state, json_state, writer);
        cursor_x +%= width;
    }
}

fn writeVerticalChildren(
    allocator: std.mem.Allocator,
    document: *const document_mod.Document,
    node: *const muxml.Node,
    rect: Rect,
    local_state: LocalState,
    json_state: *JsonState,
    writer: anytype,
) anyerror!void {
    const child_count = node.children.items.len;
    if (child_count == 0) return;

    var fixed_total: u16 = 0;
    var flexible_count: usize = 0;
    for (node.children.items) |child_id| {
        const child = document.findNodeConst(child_id) orelse continue;
        if (isSingleLineChrome(child.kind)) {
            fixed_total +|= @min(rect.height, @as(u16, 3));
        } else {
            flexible_count += 1;
        }
    }

    if (fixed_total >= rect.height or fixed_total + flexible_count > rect.height) {
        try writeEvenVerticalChildren(allocator, document, node, rect, local_state, json_state, writer);
        return;
    }

    const remaining_height = rect.height - fixed_total;
    const base_flexible_height: u16 = if (flexible_count == 0) 0 else remaining_height / @as(u16, @intCast(flexible_count));
    var flexible_remainder: u16 = if (flexible_count == 0) 0 else remaining_height % @as(u16, @intCast(flexible_count));
    var cursor_y = rect.y;

    for (node.children.items) |child_id| {
        const child = document.findNodeConst(child_id) orelse return error.UnknownNode;
        var height: u16 = if (isSingleLineChrome(child.kind)) 3 else base_flexible_height;
        if (!isSingleLineChrome(child.kind) and flexible_remainder != 0) {
            height += 1;
            flexible_remainder -= 1;
        }
        const child_rect = Rect{
            .x = rect.x,
            .y = cursor_y,
            .width = rect.width,
            .height = height,
        };
        try writeProjectedNode(allocator, document, child_id, child_rect, local_state, json_state, writer);
        cursor_y +%= height;
    }
}

fn writeEvenVerticalChildren(
    allocator: std.mem.Allocator,
    document: *const document_mod.Document,
    node: *const muxml.Node,
    rect: Rect,
    local_state: LocalState,
    json_state: *JsonState,
    writer: anytype,
) anyerror!void {
    const child_count = node.children.items.len;
    const base_height: u16 = rect.height / @as(u16, @intCast(child_count));
    var remainder: u16 = rect.height % @as(u16, @intCast(child_count));
    var cursor_y = rect.y;

    for (node.children.items) |child_id| {
        var height = base_height;
        if (remainder != 0) {
            height += 1;
            remainder -= 1;
        }
        const child_rect = Rect{
            .x = rect.x,
            .y = cursor_y,
            .width = rect.width,
            .height = height,
        };
        try writeProjectedNode(allocator, document, child_id, child_rect, local_state, json_state, writer);
        cursor_y +%= height;
    }
}

fn buildContentView(
    allocator: std.mem.Allocator,
    node: *const muxml.Node,
    rect: Rect,
    local_state: LocalState,
    elided: bool,
) !ContentView {
    var content_view = ContentView{};
    const inner_width = innerExtent(rect.width);
    const inner_height = innerExtent(rect.height);
    if (inner_width == 0 or inner_height == 0) return content_view;

    const raw_text = try deriveRenderableText(allocator, node, elided);
    defer if (raw_text.owned) |owned| allocator.free(owned);
    if (raw_text.text.len == 0) return content_view;

    var raw_lines = std.ArrayListUnmanaged([]const u8){};
    defer raw_lines.deinit(allocator);

    var iterator = std.mem.splitScalar(u8, raw_text.text, '\n');
    while (iterator.next()) |line| {
        try raw_lines.append(allocator, trimTrailingCarriageReturn(line));
    }
    while (raw_lines.items.len != 0 and isBlankLine(raw_lines.items[raw_lines.items.len - 1])) {
        _ = raw_lines.pop();
    }
    if (raw_lines.items.len == 0) return content_view;

    content_view.full_line_count = raw_lines.items.len;
    const max_visible_lines: usize = inner_height;
    content_view.scroll_max = if (raw_lines.items.len > max_visible_lines) raw_lines.items.len - max_visible_lines else 0;
    content_view.scroll_top = local_state.scrollTop(node.id) orelse if (node.follow_tail and content_view.scroll_max != 0) content_view.scroll_max else 0;
    if (content_view.scroll_top > content_view.scroll_max) content_view.scroll_top = content_view.scroll_max;

    const end_index = @min(raw_lines.items.len, content_view.scroll_top + max_visible_lines);
    for (raw_lines.items[content_view.scroll_top..end_index]) |line| {
        try content_view.visible_lines.append(allocator, try clipLine(allocator, line, inner_width));
    }
    return content_view;
}

const DerivedText = struct {
    text: []const u8,
    owned: ?[]u8 = null,
};

fn deriveRenderableText(
    allocator: std.mem.Allocator,
    node: *const muxml.Node,
    elided: bool,
) !DerivedText {
    if (elided) return .{ .text = "... elided by shared view state ..." };

    switch (node.kind) {
        .document, .subdocument, .container, .h_container, .v_container => return .{ .text = "" },
        .scroll_region => {
            if (node.children.items.len != 0) return .{ .text = "" };
            if (node.content.len != 0) return .{ .text = node.content };
            return .{ .text = "" };
        },
        else => {},
    }

    return switch (node.source) {
        .tty => |tty| blk: {
            if (node.lifecycle == .detached) {
                const label = tty.pane_id orelse tty.session_name;
                const message = if (node.content.len != 0)
                    try std.fmt.allocPrint(allocator, "state :: detached tty source ({s})\n{s}", .{ label, node.content })
                else
                    try std.fmt.allocPrint(allocator, "state :: detached tty source ({s})", .{label});
                break :blk .{ .text = message, .owned = message };
            }
            if (node.content.len != 0) return .{ .text = node.content };
            const label = tty.pane_id orelse tty.session_name;
            const message = try std.fmt.allocPrint(allocator, "tty source {s}", .{label});
            break :blk .{ .text = message, .owned = message };
        },
        .file => |file| blk: {
            if (node.content.len != 0) return .{ .text = node.content };
            const message = try std.fmt.allocPrint(allocator, "file source {s}", .{file.path});
            break :blk .{ .text = message, .owned = message };
        },
        .terminal_artifact => |artifact| blk: {
            const sections = formatArtifactSections(artifact.sections);
            const message = if (node.content.len != 0)
                try std.fmt.allocPrint(
                    allocator,
                    "artifact :: origin={s}, session={s}, window={s}, pane={s}, format={s}, sections={s}\n{s}",
                    .{
                        @tagName(artifact.origin),
                        artifact.session_name orelse "-",
                        artifact.window_id orelse "-",
                        artifact.pane_id orelse "-",
                        @tagName(artifact.content_format),
                        sections,
                        node.content,
                    },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "artifact :: origin={s}, session={s}, window={s}, pane={s}, format={s}, sections={s}",
                    .{
                        @tagName(artifact.origin),
                        artifact.session_name orelse "-",
                        artifact.window_id orelse "-",
                        artifact.pane_id orelse "-",
                        @tagName(artifact.content_format),
                        sections,
                    },
                );
            break :blk .{ .text = message, .owned = message };
        },
        .none => .{ .text = node.content },
    };
}

fn clipLine(allocator: std.mem.Allocator, line: []const u8, width: usize) ![]u8 {
    if (line.len <= width) return allocator.dupe(u8, line);
    if (width <= 1) return allocator.dupe(u8, line[0..width]);

    const clipped_width = width - 1;
    var clipped = try allocator.alloc(u8, width);
    @memcpy(clipped[0..clipped_width], line[0..clipped_width]);
    clipped[width - 1] = '$';
    return clipped;
}

fn shouldProjectChildren(kind: types.NodeKind) bool {
    return switch (kind) {
        .document, .subdocument, .container, .h_container, .v_container, .scroll_region => true,
        else => false,
    };
}

fn shouldEmitRegion(node: *const muxml.Node, elided: bool) bool {
    if (elided) return true;
    return switch (node.kind) {
        .container, .h_container, .v_container => false,
        .subdocument => !(node.children.items.len == 1 and node.content.len == 0),
        .scroll_region => !(node.content.len == 0 and node.children.items.len == 1),
        else => true,
    };
}

fn isSingleLineChrome(kind: types.NodeKind) bool {
    return switch (kind) {
        .modeline_region, .menu_region => true,
        else => false,
    };
}

fn isElided(document: *const document_mod.Document, node_id: ids.NodeId) bool {
    for (document.elided_node_ids.items) |elided_node_id| {
        if (elided_node_id == node_id) return true;
    }
    return false;
}

fn insetRect(rect: Rect) Rect {
    const width = if (rect.width > 2) rect.width - 2 else 0;
    const height = if (rect.height > 2) rect.height - 2 else 0;
    return .{
        .x = rect.x + @as(u16, if (rect.width > 0) 1 else 0),
        .y = rect.y + @as(u16, if (rect.height > 0) 1 else 0),
        .width = width,
        .height = height,
    };
}

fn innerExtent(value: u16) usize {
    return if (value > 2) value - 2 else 0;
}

fn trimTrailingCarriageReturn(line: []const u8) []const u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn clampDimension(value: u16, minimum: u16) u16 {
    return if (value < minimum) minimum else value;
}

fn formatArtifactSections(sections: source_mod.TerminalArtifactSections) []const u8 {
    if (sections.surface and sections.alternate) return "surface,alternate";
    if (sections.surface) return "surface";
    if (sections.alternate) return "alternate";
    return "none";
}

fn isBlankLine(line: []const u8) bool {
    for (line) |char| {
        if (!std.ascii.isWhitespace(char)) return false;
    }
    return true;
}
