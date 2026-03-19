const std = @import("std");

pub const Renderer = struct {
    supports_mouse: bool = false,
};

pub fn renderProjectionValue(
    allocator: std.mem.Allocator,
    projection_value: std.json.Value,
    writer: anytype,
) !void {
    if (projection_value != .object) return error.InvalidProjection;

    const rows = try requireUsize(projection_value, "rows");
    const cols = try requireUsize(projection_value, "cols");
    const regions = projection_value.object.get("regions") orelse return error.InvalidProjection;
    if (regions != .array) return error.InvalidProjection;

    var canvas = try Canvas.init(allocator, rows, cols);
    defer canvas.deinit(allocator);

    for (regions.array.items) |region| {
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

fn renderRegion(canvas: *Canvas, region_value: std.json.Value) !void {
    if (region_value != .object) return error.InvalidProjection;

    const x = try requireUsize(region_value, "x");
    const y = try requireUsize(region_value, "y");
    const width = try requireUsize(region_value, "width");
    const height = try requireUsize(region_value, "height");
    if (width == 0 or height == 0) return;

    const title_value = region_value.object.get("title") orelse return error.InvalidProjection;
    if (title_value != .string) return error.InvalidProjection;
    const kind_value = region_value.object.get("kind") orelse return error.InvalidProjection;
    if (kind_value != .string) return error.InvalidProjection;
    const focused = try requireBool(region_value, "focused");
    const follow_tail = try requireBool(region_value, "followTail");
    const scrollable = try requireBool(region_value, "scrollable");
    const scroll_top = try requireUsize(region_value, "scrollTop");
    const scroll_max = try requireUsize(region_value, "scrollMax");
    const elided = try requireBool(region_value, "elided");
    const lines_value = region_value.object.get("lines") orelse return error.InvalidProjection;
    if (lines_value != .array) return error.InvalidProjection;

    drawBox(canvas, x, y, width, height, focused);

    const header_width = if (width > 2) width - 2 else 0;
    if (header_width != 0) {
        var header = HeaderBuilder{};
        try appendHeader(&header, kind_value.string, title_value.string, focused, follow_tail, scrollable, scroll_top, scroll_max, elided);
        canvas.writeText(x + 1, y, header.slice(), header_width);
    }

    const inner_width = if (width > 2) width - 2 else 0;
    const inner_height = if (height > 2) height - 2 else 0;
    if (inner_width == 0 or inner_height == 0) return;

    for (lines_value.array.items, 0..) |line_value, index| {
        if (index >= inner_height) break;
        if (line_value != .string) return error.InvalidProjection;
        canvas.writeText(x + 1, y + 1 + index, line_value.string, inner_width);
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
