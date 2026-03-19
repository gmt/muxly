const std = @import("std");
const muxly = @import("../muxly.zig");

pub const total_steps: usize = 4;

const Fixture = struct {
    document: muxly.document.Document,
    status_id: muxly.ids.NodeId,
    controls_id: muxly.ids.NodeId,
    thread_leaf_id: muxly.ids.NodeId,
    activity_status_id: muxly.ids.NodeId,
    activity_leaf_id: muxly.ids.NodeId,
    subagent_status_id: muxly.ids.NodeId,
    subagent_leaf_id: muxly.ids.NodeId,

    fn deinit(self: *Fixture) void {
        self.document.deinit();
    }
};

const LocalStateBuilder = struct {
    focused_node_id: ?muxly.ids.NodeId = null,
    offsets: [4]muxly.projection.ScrollOffset = undefined,
    len: usize = 0,

    fn push(self: *LocalStateBuilder, node_id: muxly.ids.NodeId, top_line: usize) void {
        self.offsets[self.len] = .{ .node_id = node_id, .top_line = top_line };
        self.len += 1;
    }

    fn localState(self: *const LocalStateBuilder) muxly.projection.LocalState {
        return .{
            .focused_node_id = self.focused_node_id,
            .scroll_offsets = self.offsets[0..self.len],
        };
    }
};

pub fn renderStep(allocator: std.mem.Allocator, step_index: usize, rows: u16, cols: u16) ![]u8 {
    var fixture = try initFixture(allocator);
    defer fixture.deinit();

    var local_state_builder = LocalStateBuilder{};
    try applyStep(&fixture, step_index, &local_state_builder);

    var projection_json = std.array_list.Managed(u8).init(allocator);
    defer projection_json.deinit();
    try muxly.projection.writeProjectionJson(allocator, &fixture.document, .{
        .rows = rows,
        .cols = cols,
        .local_state = local_state_builder.localState(),
    }, projection_json.writer());

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, projection_json.items, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var rendered = std.array_list.Managed(u8).init(allocator);
    errdefer rendered.deinit();
    try muxly.viewer_render.renderProjectionValue(allocator, parsed.value, rendered.writer());
    return rendered.toOwnedSlice();
}

fn initFixture(allocator: std.mem.Allocator) !Fixture {
    var document = try muxly.document.Document.init(allocator, 1, "muxguide");

    const status_id = try document.appendNode(document.root_node_id, .modeline_region, "status", .{ .none = {} });
    const controls_id = try document.appendNode(document.root_node_id, .menu_region, "controls", .{ .none = {} });
    const stage_id = try document.appendNode(document.root_node_id, .h_container, "stage", .{ .none = {} });

    const thread_scroll_id = try document.appendNode(stage_id, .scroll_region, "thread-pane", .{ .none = {} });
    const thread_leaf_id = try document.appendNode(thread_scroll_id, .text_leaf, "thread", .{ .none = {} });

    const side_stack_id = try document.appendNode(stage_id, .v_container, "activities", .{ .none = {} });

    const activity_stage_id = try document.appendNode(side_stack_id, .subdocument, "activity", .{ .none = {} });
    const activity_status_id = try document.appendNode(activity_stage_id, .modeline_region, "activity-status", .{ .none = {} });
    const activity_scroll_id = try document.appendNode(activity_stage_id, .scroll_region, "activity-log", .{ .none = {} });
    const activity_leaf_id = try document.appendNode(activity_scroll_id, .text_leaf, "worker-log", .{ .none = {} });

    const subagent_stage_id = try document.appendNode(side_stack_id, .subdocument, "sub-agent", .{ .none = {} });
    const subagent_status_id = try document.appendNode(subagent_stage_id, .modeline_region, "subagent-status", .{ .none = {} });
    const subagent_scroll_id = try document.appendNode(subagent_stage_id, .scroll_region, "subagent-log", .{ .none = {} });
    const subagent_leaf_id = try document.appendNode(subagent_scroll_id, .text_leaf, "worker-thread", .{ .none = {} });

    try document.setNodeContent(status_id, "muxguide :: staged viewer tour");
    try document.setNodeContent(controls_id, "[q] quit  [auto] step tour  [snapshot] deterministic frame");
    try document.setNodeContent(thread_leaf_id, "user: build a browsing metaphor\nassistant: model the thread as a stage\nassistant: make chrome and activity explicit");
    try document.setNodeContent(activity_status_id, "activity :: waiting for worker handoff");
    try document.setNodeContent(activity_leaf_id, "planner: identify the next truth boundary");
    try document.setNodeContent(subagent_status_id, "subagent :: dormant");
    try document.setNodeContent(subagent_leaf_id, "no nested worker yet");

    return .{
        .document = document,
        .status_id = status_id,
        .controls_id = controls_id,
        .thread_leaf_id = thread_leaf_id,
        .activity_status_id = activity_status_id,
        .activity_leaf_id = activity_leaf_id,
        .subagent_status_id = subagent_status_id,
        .subagent_leaf_id = subagent_leaf_id,
    };
}

fn applyStep(fixture: *Fixture, step_index: usize, local_state: *LocalStateBuilder) !void {
    const step = @min(step_index, total_steps - 1);
    switch (step) {
        0 => {
            try fixture.document.setNodeContent(fixture.status_id, "muxguide :: staged viewer tour :: bootstrap");
            try fixture.document.setNodeContent(fixture.controls_id, "[q] quit  [auto] step tour  [focus] thread");
            local_state.focused_node_id = fixture.thread_leaf_id;
        },
        1 => {
            try fixture.document.setNodeContent(fixture.status_id, "muxguide :: staged viewer tour :: live activity");
            try fixture.document.setNodeContent(fixture.activity_status_id, "activity :: worker wiring projection.get");
            try fixture.document.setNodeContent(
                fixture.activity_leaf_id,
                "worker: add text_leaf and split containers\nworker: route projection.get through JSON-RPC\nworker: keep view.get document-scoped\nworker: leave tmux passthrough for later",
            );
            local_state.focused_node_id = fixture.activity_leaf_id;
        },
        2 => {
            try fixture.document.setNodeContent(fixture.status_id, "muxguide :: staged viewer tour :: nested worker");
            try fixture.document.setNodeContent(fixture.subagent_status_id, "subagent :: synthesizing boxed renderer");
            try fixture.document.setNodeContent(
                fixture.subagent_leaf_id,
                "subagent: render parents first\nsubagent: clip text locally\nsubagent: mark focused region\nsubagent: keep tty as textual fallback",
            );
            try fixture.document.appendTextToNode(
                fixture.thread_leaf_id,
                "\nassistant: local viewer state belongs in projection params\nassistant: the live activity is another stage\nassistant: nested worker focuses the renderer seam",
            );
            local_state.focused_node_id = fixture.subagent_leaf_id;
            local_state.push(fixture.thread_leaf_id, 2);
        },
        else => {
            try fixture.document.setNodeContent(fixture.status_id, "muxguide :: staged viewer tour :: complete");
            try fixture.document.setNodeContent(fixture.controls_id, "[q] quit  [snapshot --step N] inspect checkpoints");
            try fixture.document.setNodeContent(fixture.activity_status_id, "activity :: projection and renderer agree");
            try fixture.document.setNodeContent(fixture.subagent_status_id, "subagent :: viewer stays honest about scope");
            try fixture.document.setNodeContent(
                fixture.thread_leaf_id,
                "user: build a browsing metaphor\nassistant: model the thread as a stage\nassistant: make chrome and activity explicit\nassistant: projection.get now carries viewport-local state\nassistant: muxview paints boxes instead of tree text\nassistant: guided tour demonstrates nested stage locality",
            );
            local_state.focused_node_id = fixture.thread_leaf_id;
            local_state.push(fixture.thread_leaf_id, 3);
        },
    }
}
