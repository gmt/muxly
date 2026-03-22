const std = @import("std");

pub const Renderer = struct {
    supports_mouse: bool = true,
};

pub const ProjectionFrame = struct {
    rows: usize,
    cols: usize,
    view_root_node_id: ?u64 = null,
    regions: []ProjectionRegion,

    pub fn deinit(self: *ProjectionFrame, allocator: std.mem.Allocator) void {
        for (self.regions) |*region| region.deinit(allocator);
        allocator.free(self.regions);
        self.* = undefined;
    }

    pub fn findRegionByNodeId(self: *ProjectionFrame, node_id: u64) ?*ProjectionRegion {
        for (self.regions) |*region| {
            if (region.node_id == node_id) return region;
        }
        return null;
    }
};

pub const ProjectionRegion = struct {
    node_id: u64,
    kind: []u8,
    title: []u8,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    focused: bool,
    follow_tail: bool,
    scrollable: bool,
    scroll_top: usize,
    scroll_max: usize,
    elided: bool,
    lines: [][]u8,

    pub fn deinit(self: *ProjectionRegion, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.title);
        self.clearLines(allocator);
        self.* = undefined;
    }

    pub fn replaceLines(
        self: *ProjectionRegion,
        allocator: std.mem.Allocator,
        lines: []const []const u8,
    ) !void {
        var owned_lines = try allocator.alloc([]u8, lines.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_lines[0..initialized]) |line| allocator.free(line);
            allocator.free(owned_lines);
        }

        for (lines, 0..) |line, index| {
            owned_lines[index] = try allocator.dupe(u8, line);
            initialized += 1;
        }

        self.clearLines(allocator);
        self.lines = owned_lines;
    }

    fn clearLines(self: *ProjectionRegion, allocator: std.mem.Allocator) void {
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
        self.lines = undefined;
    }
};

pub fn parseProjectionValue(
    allocator: std.mem.Allocator,
    projection_value: std.json.Value,
) !ProjectionFrame {
    if (projection_value != .object) return error.InvalidProjection;

    const rows = try requireUsize(projection_value, "rows");
    const cols = try requireUsize(projection_value, "cols");
    const view_root_node_id = try optionalU64(projection_value, "viewRootNodeId");

    const regions_value = projection_value.object.get("regions") orelse return error.InvalidProjection;
    if (regions_value != .array) return error.InvalidProjection;

    var regions = try allocator.alloc(ProjectionRegion, regions_value.array.items.len);

    var initialized: usize = 0;
    errdefer {
        for (regions[0..initialized]) |*region| region.deinit(allocator);
        allocator.free(regions);
    }

    for (regions_value.array.items, 0..) |region_value, index| {
        regions[index] = try parseRegion(allocator, region_value);
        initialized += 1;
    }

    return .{
        .rows = rows,
        .cols = cols,
        .view_root_node_id = view_root_node_id,
        .regions = regions,
    };
}

pub fn renderProjectionValue(
    allocator: std.mem.Allocator,
    projection_value: std.json.Value,
    writer: anytype,
) !void {
    var frame = try parseProjectionValue(allocator, projection_value);
    defer frame.deinit(allocator);
    try renderProjectionFrame(allocator, &frame, writer);
}

pub fn renderProjectionFrame(
    allocator: std.mem.Allocator,
    frame: *const ProjectionFrame,
    writer: anytype,
) !void {
    var canvas = try Canvas.init(allocator, frame.rows, frame.cols);
    defer canvas.deinit(allocator);

    for (frame.regions) |region| {
        try renderRegion(&canvas, region);
    }

    try canvas.write(writer);
}

const Canvas = struct {
    rows: usize,
    cols: usize,
    cells: []u8,

    fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !Canvas {
        const safe_rows = @max(rows, 1);
        const safe_cols = @max(cols, 1);
        const cells = try allocator.alloc(u8, safe_rows * safe_cols);
        @memset(cells, ' ');
        return .{
            .rows = safe_rows,
            .cols = safe_cols,
            .cells = cells,
        };
    }

    fn deinit(self: *Canvas, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
    }

    fn write(self: *const Canvas, writer: anytype) !void {
        for (0..self.rows) |row| {
            const start = row * self.cols;
            const line = std.mem.trimRight(u8, self.cells[start .. start + self.cols], " ");
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
    }

    fn put(self: *Canvas, x: usize, y: usize, value: u8) void {
        if (x >= self.cols or y >= self.rows) return;
        self.cells[y * self.cols + x] = value;
    }

    fn writeText(self: *Canvas, x: usize, y: usize, text: []const u8, max_width: usize) void {
        const width = @min(max_width, text.len);
        for (0..width) |index| {
            self.put(x + index, y, text[index]);
        }
    }
};

fn parseRegion(allocator: std.mem.Allocator, region_value: std.json.Value) !ProjectionRegion {
    if (region_value != .object) return error.InvalidProjection;

    const node_id = try requireU64(region_value, "nodeId");
    const kind = try dupStringField(allocator, region_value, "kind");
    errdefer allocator.free(kind);
    const title = try dupStringField(allocator, region_value, "title");
    errdefer allocator.free(title);

    const lines = try dupLines(allocator, region_value);
    errdefer freeLines(allocator, lines);

    return .{
        .node_id = node_id,
        .kind = kind,
        .title = title,
        .x = try requireU16(region_value, "x"),
        .y = try requireU16(region_value, "y"),
        .width = try requireU16(region_value, "width"),
        .height = try requireU16(region_value, "height"),
        .focused = try requireBool(region_value, "focused"),
        .follow_tail = try requireBool(region_value, "followTail"),
        .scrollable = try requireBool(region_value, "scrollable"),
        .scroll_top = try requireUsize(region_value, "scrollTop"),
        .scroll_max = try requireUsize(region_value, "scrollMax"),
        .elided = try requireBool(region_value, "elided"),
        .lines = lines,
    };
}

fn dupLines(allocator: std.mem.Allocator, region_value: std.json.Value) ![][]u8 {
    const lines_value = region_value.object.get("lines") orelse return error.InvalidProjection;
    if (lines_value != .array) return error.InvalidProjection;

    var lines = try allocator.alloc([]u8, lines_value.array.items.len);

    var initialized: usize = 0;
    errdefer {
        for (lines[0..initialized]) |line| allocator.free(line);
        allocator.free(lines);
    }

    for (lines_value.array.items, 0..) |line_value, index| {
        if (line_value != .string) return error.InvalidProjection;
        lines[index] = try allocator.dupe(u8, line_value.string);
        initialized += 1;
    }
    return lines;
}

fn freeLines(allocator: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

fn renderRegion(canvas: *Canvas, region: ProjectionRegion) !void {
    if (region.width == 0 or region.height == 0) return;

    drawBox(canvas, region.x, region.y, region.width, region.height, region.focused);

    const header_width = if (region.width > 2) region.width - 2 else 0;
    if (header_width != 0) {
        var header = HeaderBuilder{};
        try appendHeader(
            &header,
            region.kind,
            region.title,
            region.focused,
            region.follow_tail,
            region.scrollable,
            region.scroll_top,
            region.scroll_max,
            region.elided,
        );
        canvas.writeText(region.x + 1, region.y, header.slice(), header_width);
    }

    const inner_width = if (region.width > 2) region.width - 2 else 0;
    const inner_height = if (region.height > 2) region.height - 2 else 0;
    if (inner_width == 0 or inner_height == 0) return;

    for (region.lines, 0..) |line, index| {
        if (index >= inner_height) break;
        canvas.writeText(region.x + 1, region.y + 1 + index, line, inner_width);
    }
}

fn drawBox(canvas: *Canvas, x: usize, y: usize, width: usize, height: usize, focused: bool) void {
    const horizontal: u8 = if (focused) '=' else '-';
    const vertical: u8 = if (focused) '!' else '|';
    const corner: u8 = if (focused) '*' else '+';

    if (height == 1) {
        for (0..width) |col| canvas.put(x + col, y, horizontal);
        return;
    }
    if (width == 1) {
        for (0..height) |row| canvas.put(x, y + row, vertical);
        return;
    }

    canvas.put(x, y, corner);
    canvas.put(x + width - 1, y, corner);
    canvas.put(x, y + height - 1, corner);
    canvas.put(x + width - 1, y + height - 1, corner);

    for (1..width - 1) |col| {
        canvas.put(x + col, y, horizontal);
        canvas.put(x + col, y + height - 1, horizontal);
    }
    for (1..height - 1) |row| {
        canvas.put(x, y + row, vertical);
        canvas.put(x + width - 1, y + row, vertical);
    }
}

fn appendHeader(
    header: *HeaderBuilder,
    kind: []const u8,
    title: []const u8,
    focused: bool,
    follow_tail: bool,
    scrollable: bool,
    scroll_top: usize,
    scroll_max: usize,
    elided: bool,
) !void {
    if (focused) try header.appendSlice("> ");
    try header.appendSlice(title);
    if (title.len == 0) try header.appendSlice(kind);
    if (follow_tail) try header.appendSlice(" [tail]");
    if (scrollable) {
        if (scroll_top != 0) {
            try header.appendSlice(" [^]");
        }
        if (scroll_top < scroll_max) {
            try header.appendSlice(" [v]");
        }
    }
    if (elided) try header.appendSlice(" [elided]");
}

const HeaderBuilder = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,

    fn appendSlice(self: *HeaderBuilder, text: []const u8) !void {
        if (self.len + text.len > self.buffer.len) return error.HeaderTooLong;
        @memcpy(self.buffer[self.len .. self.len + text.len], text);
        self.len += text.len;
    }

    fn slice(self: *const HeaderBuilder) []const u8 {
        return self.buffer[0..self.len];
    }
};

fn dupStringField(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    field_name: []const u8,
) ![]u8 {
    const field = value.object.get(field_name) orelse return error.InvalidProjection;
    if (field != .string) return error.InvalidProjection;
    return allocator.dupe(u8, field.string);
}

fn optionalU64(value: std.json.Value, field_name: []const u8) !?u64 {
    const field = value.object.get(field_name) orelse return null;
    return switch (field) {
        .null => null,
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.InvalidProjection,
        else => error.InvalidProjection,
    };
}

fn requireU64(value: std.json.Value, field_name: []const u8) !u64 {
    const field = value.object.get(field_name) orelse return error.InvalidProjection;
    if (field != .integer or field.integer < 0) return error.InvalidProjection;
    return @intCast(field.integer);
}

fn requireU16(value: std.json.Value, field_name: []const u8) !u16 {
    const result = try requireUsize(value, field_name);
    if (result > std.math.maxInt(u16)) return error.InvalidProjection;
    return @intCast(result);
}

fn requireUsize(value: std.json.Value, field_name: []const u8) !usize {
    const field = value.object.get(field_name) orelse return error.InvalidProjection;
    if (field != .integer or field.integer < 0) return error.InvalidProjection;
    return @intCast(field.integer);
}

fn requireBool(value: std.json.Value, field_name: []const u8) !bool {
    const field = value.object.get(field_name) orelse return error.InvalidProjection;
    if (field != .bool) return error.InvalidProjection;
    return field.bool;
}
