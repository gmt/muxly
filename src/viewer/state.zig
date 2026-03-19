const std = @import("std");
const muxly = @import("muxly");
const input_mod = @import("input.zig");

pub const RegionInfo = struct {
    node_id: u64,
    kind: []const u8,
    title: []const u8,
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
};

pub const ViewerSession = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    mode: input_mod.InputMode = .navigate,
    selected_index: usize = 0,
    regions: std.ArrayListUnmanaged(RegionInfo) = .{},
    view_root_node_id: ?u64 = null,
    status_message: []const u8 = "",
    status_owned: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) ViewerSession {
        return .{
            .allocator = allocator,
            .socket_path = socket_path,
        };
    }

    pub fn deinit(self: *ViewerSession) void {
        self.clearRegions();
        if (self.status_owned) |owned| self.allocator.free(owned);
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
            const info = parseRegionInfo(region) orelse continue;
            self.regions.append(self.allocator, info) catch continue;
        }

        if (self.selected_index >= self.regions.items.len and self.regions.items.len > 0) {
            self.selected_index = self.regions.items.len - 1;
        }
    }

    pub fn selectedRegion(self: *const ViewerSession) ?RegionInfo {
        if (self.selected_index >= self.regions.items.len) return null;
        return self.regions.items[self.selected_index];
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
            self.mode = .focused_pane;
            self.setStatus("focused pane mode -- press Escape to return");
            return;
        }

        const params = std.fmt.allocPrint(self.allocator, "{{\"nodeId\":{d}}}", .{region.node_id}) catch return;
        defer self.allocator.free(params);
        self.callDaemon("view.setRoot", params);
        self.setStatus("drilled into region");
    }

    pub fn backOut(self: *ViewerSession) void {
        if (self.mode == .focused_pane) {
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
        const params = std.fmt.allocPrint(
            self.allocator,
            "{{\"paneId\":\"{d}\",\"enabled\":{s}}}",
            .{ region.node_id, if (region.follow_tail) "false" else "true" },
        ) catch return;
        defer self.allocator.free(params);
        self.callDaemon("pane.followTail", params);
    }

    pub fn resetView(self: *ViewerSession) void {
        self.callDaemon("view.reset", "{}");
        self.selected_index = 0;
        self.setStatus("view reset");
    }

    fn callDaemon(self: *ViewerSession, method: []const u8, params: []const u8) void {
        const response = muxly.api.request(self.allocator, self.socket_path, method, params) catch return;
        self.allocator.free(response);
    }

    fn setStatus(self: *ViewerSession, message: []const u8) void {
        if (self.status_owned) |owned| self.allocator.free(owned);
        self.status_owned = null;
        self.status_message = message;
    }

    fn clearRegions(self: *ViewerSession) void {
        self.regions.deinit(self.allocator);
        self.regions = .{};
    }

    fn parseRegionInfo(region: std.json.Value) ?RegionInfo {
        const node_id_val = region.object.get("nodeId") orelse return null;
        if (node_id_val != .integer) return null;
        const kind_val = region.object.get("kind") orelse return null;
        if (kind_val != .string) return null;
        const title_val = region.object.get("title") orelse return null;
        if (title_val != .string) return null;

        return .{
            .node_id = @intCast(node_id_val.integer),
            .kind = kind_val.string,
            .title = title_val.string,
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
