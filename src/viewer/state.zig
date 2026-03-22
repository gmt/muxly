const std = @import("std");
const muxly = @import("muxly");
const input_mod = @import("input.zig");

pub const RegionInfo = struct {
    node_id: u64,
    kind: []u8,
    title: []u8,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    has_children: bool,
    is_tty: bool,
    elided: bool,
    follow_tail: bool,
    scrollable: bool,
    scroll_top: usize,
    scroll_max: usize,

    pub fn deinit(self: *RegionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.title);
    }
};

pub const ViewerSession = struct {
    allocator: std.mem.Allocator,
    client: muxly.client.ConversationClient,
    tty_session: ?muxly.client.TtyConversation = null,
    tty_output_stream: ?muxly.client.TtyOutputStream = null,
    tty_output_buffer: std.ArrayListUnmanaged(u8) = .{},
    mode: input_mod.InputMode = .navigate,
    selected_index: usize = 0,
    regions: std.ArrayListUnmanaged(RegionInfo) = .{},
    view_root_node_id: ?u64 = null,
    status_message: []const u8 = "",
    status_owned: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, transport_spec: []const u8) !ViewerSession {
        return .{
            .allocator = allocator,
            .client = try muxly.client.ConversationClient.init(allocator, transport_spec),
        };
    }

    pub fn deinit(self: *ViewerSession) void {
        self.clearRegions();
        if (self.status_owned) |owned| self.allocator.free(owned);
        self.clearTtyOutputState();
        if (self.tty_session) |*tty| tty.deinit();
        self.client.deinit();
    }

    pub fn refreshRegions(self: *ViewerSession, projection_value: std.json.Value) void {
        self.clearRegions();

        if (projection_value != .object) return;
        const view_root = projection_value.object.get("viewRootNodeId");
        if (view_root) |v| {
            if (v == .integer) {
                self.view_root_node_id = @intCast(v.integer);
            } else {
                self.view_root_node_id = null;
            }
        }

        const regions = projection_value.object.get("regions") orelse return;
        if (regions != .array) return;

        for (regions.array.items) |region| {
            if (region != .object) continue;
            var info = parseRegionInfo(self.allocator, region) orelse continue;
            self.regions.append(self.allocator, info) catch {
                info.deinit(self.allocator);
                continue;
            };
        }

        if (self.selected_index >= self.regions.items.len and self.regions.items.len > 0) {
            self.selected_index = self.regions.items.len - 1;
        }
    }

    /// The returned pointer is borrowed from `self.regions` and is invalidated
    /// by the next region refresh or any other mutation of that list.
    pub fn selectedRegion(self: *const ViewerSession) ?*const RegionInfo {
        if (self.selected_index >= self.regions.items.len) return null;
        return &self.regions.items[self.selected_index];
    }

    pub fn selectNext(self: *ViewerSession) void {
        if (self.regions.items.len == 0) return;
        if (self.selected_index + 1 < self.regions.items.len) {
            self.selected_index += 1;
        }
    }

    pub fn selectPrev(self: *ViewerSession) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
        }
    }

    pub fn drillIn(self: *ViewerSession) void {
        const region = self.selectedRegion() orelse return;
        if (!region.has_children and !region.is_tty) return;

        if (region.is_tty) {
            var tty = self.ensureTtySessionForNode(region.node_id) catch {
                self.setStatus("tty interaction unavailable");
                return;
            };
            self.ensureTtyOutputStreamForSession(tty) catch {};
            self.mode = .tty_interact;
            self.setStatus("tty interaction mode -- press Escape to return");
            return;
        }

        const params = std.fmt.allocPrint(self.allocator, "{{\"nodeId\":{d}}}", .{region.node_id}) catch return;
        defer self.allocator.free(params);
        self.callDaemon("view.setRoot", params);
        self.setStatus("drilled into region");
    }

    pub fn backOut(self: *ViewerSession) void {
        if (self.mode == .tty_interact) {
            self.clearTtyOutputState();
            if (self.tty_session) |*tty| {
                tty.deinit();
                self.tty_session = null;
            }
            self.mode = .navigate;
            self.setStatus("navigation mode");
            return;
        }
        if (self.view_root_node_id != null) {
            self.callDaemon("view.clearRoot", "{}");
            self.setStatus("returned to document root");
        }
    }

    pub fn toggleElide(self: *ViewerSession) void {
        const region = self.selectedRegion() orelse return;
        const params = std.fmt.allocPrint(self.allocator, "{{\"nodeId\":{d}}}", .{region.node_id}) catch return;
        defer self.allocator.free(params);
        if (region.elided) {
            self.callDaemon("view.expand", params);
        } else {
            self.callDaemon("view.elide", params);
        }
    }

    pub fn toggleFollowTail(self: *ViewerSession) void {
        const region = self.selectedRegion() orelse return;
        if (!region.is_tty) return;
        var tty = self.ensureTtySessionForNode(region.node_id) catch return;
        tty.setFollowTail(!region.follow_tail) catch return;
    }

    pub fn resetView(self: *ViewerSession) void {
        self.callDaemon("view.reset", "{}");
        self.selected_index = 0;
        self.setStatus("view reset");
    }

    pub fn sendTtyInput(self: *ViewerSession, input: []const u8) void {
        const region = self.selectedRegion() orelse return;
        if (!region.is_tty) return;

        var tty = self.ensureTtySessionForNode(region.node_id) catch return;
        tty.sendInput(input) catch return;
    }

    fn callDaemon(self: *ViewerSession, method: []const u8, params: []const u8) void {
        const response = self.client.request(method, params) catch return;
        self.allocator.free(response);
    }

    fn ensureTtySessionForNode(self: *ViewerSession, node_id: u64) !*muxly.client.TtyConversation {
        if (self.tty_session) |*tty| {
            if (tty.info.node_id == node_id) return tty;
            self.clearTtyOutputState();
            tty.deinit();
            self.tty_session = null;
        }

        self.tty_session = try self.client.openTty(.{
            .documentPath = self.client.documentPath(),
            .nodeId = node_id,
        }, .{});
        return &self.tty_session.?;
    }

    pub fn drainTtyOutput(self: *ViewerSession) void {
        var stream = if (self.tty_output_stream) |*value| value else return;
        while (true) {
            const polled = stream.pollChunk() catch return;
            switch (polled) {
                .pending => return,
                .closed => {
                    self.clearTtyOutputState();
                    self.setStatus("tty stream closed");
                    return;
                },
                .overflow => self.setStatus("tty output overflowed; showing live tail"),
                .data => |bytes| {
                    defer self.allocator.free(bytes);
                    self.appendTtyBytes(bytes) catch return;
                },
            }
        }
    }

    pub fn overlayTtyProjection(self: *ViewerSession, projection_value: *std.json.Value) void {
        if (self.mode != .tty_interact) return;
        if (projection_value.* != .object) return;
        const tty = if (self.tty_session) |value| value else return;
        const regions_value = projection_value.object.getPtr("regions") orelse return;
        if (regions_value.* != .array) return;

        for (regions_value.array.items) |*region| {
            if (region.* != .object) continue;
            const node_id_value = region.object.get("nodeId") orelse continue;
            if (node_id_value != .integer or node_id_value.integer < 0) continue;
            if (@as(u64, @intCast(node_id_value.integer)) != tty.info.node_id) continue;
            self.replaceRegionLines(region) catch {};
            return;
        }
    }

    fn ensureTtyOutputStreamForSession(self: *ViewerSession, tty: *muxly.client.TtyConversation) !void {
        if (self.tty_output_stream) |*stream| {
            if (stream.node_id == tty.info.node_id) return;
            self.clearTtyOutputState();
        }

        self.tty_output_stream = tty.openOutputStream() catch return;
    }

    fn appendTtyBytes(self: *ViewerSession, bytes: []const u8) !void {
        try self.tty_output_buffer.appendSlice(self.allocator, bytes);
        const max_bytes: usize = 256 * 1024;
        if (self.tty_output_buffer.items.len <= max_bytes) return;
        const trim = self.tty_output_buffer.items.len - max_bytes;
        std.mem.copyForwards(
            u8,
            self.tty_output_buffer.items[0 .. self.tty_output_buffer.items.len - trim],
            self.tty_output_buffer.items[trim..],
        );
        self.tty_output_buffer.items.len -= trim;
    }

    fn replaceRegionLines(self: *ViewerSession, region: *std.json.Value) !void {
        const height = getUsize(region.*, "height");
        const inner_height = if (height > 2) height - 2 else 0;
        const slices = try self.renderTtyLines(inner_height);
        defer self.allocator.free(slices);

        var values = try self.allocator.alloc(std.json.Value, slices.len);
        for (slices, 0..) |line, index| {
            values[index] = .{ .string = line };
        }

        try region.object.put("lines", .{ .array = .{
            .items = values,
            .capacity = values.len,
        } });

        const scroll_max = countRenderedScrollMax(self.tty_output_buffer.items, inner_height);
        try region.object.put("scrollable", .{ .bool = scroll_max != 0 });
        try region.object.put("scrollTop", .{ .integer = @intCast(scroll_max) });
        try region.object.put("scrollMax", .{ .integer = @intCast(scroll_max) });
    }

    fn renderTtyLines(self: *ViewerSession, max_lines: usize) ![][]const u8 {
        var all_lines = std.ArrayListUnmanaged([]const u8){};
        defer all_lines.deinit(self.allocator);

        var iter = std.mem.splitScalar(u8, self.tty_output_buffer.items, '\n');
        while (iter.next()) |line| {
            try all_lines.append(self.allocator, trimTrailingCarriageReturn(line));
        }
        while (all_lines.items.len != 0 and all_lines.items[all_lines.items.len - 1].len == 0) {
            _ = all_lines.pop();
        }

        const start = if (all_lines.items.len > max_lines) all_lines.items.len - max_lines else 0;
        const visible = all_lines.items[start..];
        const owned = try self.allocator.alloc([]const u8, visible.len);
        for (visible, 0..) |line, index| {
            owned[index] = line;
        }
        return owned;
    }

    fn clearTtyOutputState(self: *ViewerSession) void {
        if (self.tty_output_stream) |*stream| {
            stream.deinit();
            self.tty_output_stream = null;
        }
        self.tty_output_buffer.deinit(self.allocator);
        self.tty_output_buffer = .{};
    }

    fn setStatus(self: *ViewerSession, message: []const u8) void {
        if (self.status_owned) |owned| self.allocator.free(owned);
        self.status_owned = null;
        self.status_message = message;
    }

    fn clearRegions(self: *ViewerSession) void {
        for (self.regions.items) |*region| region.deinit(self.allocator);
        self.regions.deinit(self.allocator);
        self.regions = .{};
    }

    fn parseRegionInfo(allocator: std.mem.Allocator, region: std.json.Value) ?RegionInfo {
        const node_id_val = region.object.get("nodeId") orelse return null;
        if (node_id_val != .integer) return null;
        const kind_val = region.object.get("kind") orelse return null;
        if (kind_val != .string) return null;
        const title_val = region.object.get("title") orelse return null;
        if (title_val != .string) return null;

        const kind = allocator.dupe(u8, kind_val.string) catch return null;
        const title = allocator.dupe(u8, title_val.string) catch {
            allocator.free(kind);
            return null;
        };

        return .{
            .node_id = @intCast(node_id_val.integer),
            .kind = kind,
            .title = title,
            .x = getU16(region, "x"),
            .y = getU16(region, "y"),
            .width = getU16(region, "width"),
            .height = getU16(region, "height"),
            .has_children = kind_val.string.len > 0 and
                (std.mem.eql(u8, kind_val.string, "document") or
                    std.mem.eql(u8, kind_val.string, "subdocument") or
                    std.mem.eql(u8, kind_val.string, "container") or
                    std.mem.eql(u8, kind_val.string, "h_container") or
                    std.mem.eql(u8, kind_val.string, "v_container")),
            .is_tty = std.mem.eql(u8, kind_val.string, "tty_leaf"),
            .elided = getBool(region, "elided"),
            .follow_tail = getBool(region, "followTail"),
            .scrollable = getBool(region, "scrollable"),
            .scroll_top = getUsize(region, "scrollTop"),
            .scroll_max = getUsize(region, "scrollMax"),
        };
    }

    fn getU16(value: std.json.Value, field: []const u8) u16 {
        const f = value.object.get(field) orelse return 0;
        if (f != .integer or f.integer < 0) return 0;
        return @intCast(@min(f.integer, std.math.maxInt(u16)));
    }

    fn getUsize(value: std.json.Value, field: []const u8) usize {
        const f = value.object.get(field) orelse return 0;
        if (f != .integer or f.integer < 0) return 0;
        return @intCast(f.integer);
    }

    fn getBool(value: std.json.Value, field: []const u8) bool {
        const f = value.object.get(field) orelse return false;
        if (f != .bool) return false;
        return f.bool;
    }
};

fn trimTrailingCarriageReturn(line: []const u8) []const u8 {
    return if (line.len != 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

fn countRenderedScrollMax(buffer: []const u8, inner_height: usize) usize {
    if (inner_height == 0) return 0;
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, buffer, '\n');
    while (iter.next()) |_| count += 1;
    if (count == 0) return 0;
    while (count != 0 and buffer.len != 0 and buffer[buffer.len - 1] == '\n') count -= 1;
    return if (count > inner_height) count - inner_height else 0;
}
