//! Stateless convenience wrappers over common muxly JSON-RPC operations.
//!
//! These helpers are intentionally thin: they return the raw UTF-8 JSON-RPC
//! response payload so higher layers can decide how much of the wire shape they
//! want to interpret. They are best suited for examples, small tools, and
//! bindings that want library-managed transport without committing to a richer
//! Zig object model.

const std = @import("std");
const builtin = @import("builtin");
const client_mod = @import("client.zig");
const projection_mod = @import("../core/projection.zig");

/// Verifies that a daemon is reachable and responsive.
pub fn ping(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "ping", "{}");
}

/// Performs the initial protocol handshake and capability readout.
pub fn initialize(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "initialize", "{}");
}

/// Returns the full shared document payload, including nodes and shared view
/// state.
pub fn documentGet(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "document.get", "{}");
}

/// Returns the current graph/document payload through the graph alias surface.
pub fn graphGet(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "graph.get", "{}");
}

/// Returns a smaller lifecycle/count-oriented document summary.
pub fn documentStatus(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "document.status", "{}");
}

/// Appends a new child node beneath `parent_id`.
///
/// `kind` is the daemon-recognized node kind string such as `subdocument` or
/// `scroll_region`.
pub fn nodeAppend(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    parent_id: u64,
    kind: []const u8,
    title: []const u8,
) ![]u8 {
    const kind_json = try std.json.Stringify.valueAlloc(allocator, kind, .{});
    defer allocator.free(kind_json);
    const title_json = try std.json.Stringify.valueAlloc(allocator, title, .{});
    defer allocator.free(title_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"parentId\":{d},\"kind\":{s},\"title\":{s}}}",
        .{ parent_id, kind_json, title_json },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "node.append", params_json);
}

/// Updates a node title or content.
///
/// Exactly one of `title` or `content` is serialized by this helper.
pub fn nodeUpdate(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    node_id: u64,
    title: ?[]const u8,
    content: ?[]const u8,
) ![]u8 {
    if (title) |value| {
        const title_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(title_json);
        const params_json = try std.fmt.allocPrint(
            allocator,
            "{{\"nodeId\":{d},\"title\":{s}}}",
            .{ node_id, title_json },
        );
        defer allocator.free(params_json);
        return try request(allocator, socket_path, "node.update", params_json);
    }
    if (content) |value| {
        const content_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(content_json);
        const params_json = try std.fmt.allocPrint(
            allocator,
            "{{\"nodeId\":{d},\"content\":{s}}}",
            .{ node_id, content_json },
        );
        defer allocator.free(params_json);
        return try request(allocator, socket_path, "node.update", params_json);
    }
    return error.InvalidArguments;
}

/// Freezes a tty-backed node into a captured terminal artifact.
///
/// `artifact_kind` is currently `"text"` or `"surface"`.
pub fn nodeFreeze(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    node_id: u64,
    artifact_kind: []const u8,
) ![]u8 {
    const artifact_kind_json = try std.json.Stringify.valueAlloc(allocator, artifact_kind, .{});
    defer allocator.free(artifact_kind_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"nodeId\":{d},\"artifactKind\":{s}}}",
        .{ node_id, artifact_kind_json },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "node.freeze", params_json);
}

/// Removes a leaf node from the document.
pub fn nodeRemove(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "node.remove", params_json);
}

/// Freezes the document lifecycle.
pub fn documentFreeze(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "document.freeze", "{}");
}

/// Serializes the current document as muxml/XML.
pub fn documentSerialize(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "document.serialize", "{}");
}

/// Returns the current view/document payload as consumed by the reference
/// viewer.
pub fn viewGet(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "view.get", "{}");
}

/// Returns a boxed viewer projection for one viewport and optional local state.
pub fn projectionGet(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    request_value: projection_mod.Request,
) ![]u8 {
    var params = std.array_list.Managed(u8).init(allocator);
    defer params.deinit();
    try projection_mod.writeRequestJson(params.writer(), request_value);
    return try request(allocator, socket_path, "projection.get", params.items);
}

/// Clears the shared document-scoped view root.
pub fn viewClearRoot(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "view.clearRoot", "{}");
}

/// Sets the shared document-scoped view root to `node_id`.
pub fn viewSetRoot(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "view.setRoot", params_json);
}

/// Hides a node through shared document elision state.
pub fn viewElide(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "view.elide", params_json);
}

/// Removes one node from shared document elision state.
pub fn viewExpand(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "view.expand", params_json);
}

/// Captures visible/history text for a tmux pane.
pub fn paneCapture(allocator: std.mem.Allocator, socket_path: []const u8, pane_id: []const u8) ![]u8 {
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const params_json = try std.fmt.allocPrint(allocator, "{{\"paneId\":{s}}}", .{pane_id_json});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.capture", params_json);
}

/// Requests a scrollback slice from one tmux pane.
pub fn paneScroll(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    pane_id: []const u8,
    start_line: i64,
    end_line: i64,
) ![]u8 {
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"paneId\":{s},\"startLine\":{d},\"endLine\":{d}}}",
        .{ pane_id_json, start_line, end_line },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.scroll", params_json);
}

/// Splits a tmux pane and projects the new pane into the document.
pub fn paneSplit(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    target: []const u8,
    direction: []const u8,
    command: ?[]const u8,
) ![]u8 {
    const target_json = try std.json.Stringify.valueAlloc(allocator, target, .{});
    defer allocator.free(target_json);
    const direction_json = try std.json.Stringify.valueAlloc(allocator, direction, .{});
    defer allocator.free(direction_json);

    const params_json = if (command) |value| blk: {
        const command_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(command_json);
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"target\":{s},\"direction\":{s},\"command\":{s}}}",
            .{ target_json, direction_json, command_json },
        );
    } else try std.fmt.allocPrint(
        allocator,
        "{{\"target\":{s},\"direction\":{s}}}",
        .{ target_json, direction_json },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.split", params_json);
}

/// Resizes a tmux pane in one direction by `amount`.
pub fn paneResize(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    pane_id: []const u8,
    direction: []const u8,
    amount: i64,
) ![]u8 {
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const direction_json = try std.json.Stringify.valueAlloc(allocator, direction, .{});
    defer allocator.free(direction_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"paneId\":{s},\"direction\":{s},\"amount\":{d}}}",
        .{ pane_id_json, direction_json, amount },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.resize", params_json);
}

/// Focuses a tmux pane.
pub fn paneFocus(allocator: std.mem.Allocator, socket_path: []const u8, pane_id: []const u8) ![]u8 {
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const params_json = try std.fmt.allocPrint(allocator, "{{\"paneId\":{s}}}", .{pane_id_json});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.focus", params_json);
}

/// Sends keystrokes to a tmux pane, optionally pressing Enter afterward.
pub fn paneSendKeys(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    pane_id: []const u8,
    keys: []const u8,
    press_enter: bool,
) ![]u8 {
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const keys_json = try std.json.Stringify.valueAlloc(allocator, keys, .{});
    defer allocator.free(keys_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"paneId\":{s},\"keys\":{s},\"enter\":{s}}}",
        .{ pane_id_json, keys_json, if (press_enter) "true" else "false" },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.sendKeys", params_json);
}

/// Closes a tmux pane and prunes any now-empty projected containers.
pub fn paneClose(allocator: std.mem.Allocator, socket_path: []const u8, pane_id: []const u8) ![]u8 {
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const params_json = try std.fmt.allocPrint(allocator, "{{\"paneId\":{s}}}", .{pane_id_json});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.close", params_json);
}

/// Stores the follow-tail preference on the node projected from one pane.
pub fn paneFollowTail(allocator: std.mem.Allocator, socket_path: []const u8, pane_id: []const u8, enabled: bool) ![]u8 {
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"paneId\":{s},\"enabled\":{s}}}",
        .{ pane_id_json, if (enabled) "true" else "false" },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.followTail", params_json);
}

/// Creates a tmux window under `target`, optionally naming it and running a
/// command in its first pane.
pub fn windowCreate(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    target: []const u8,
    window_name: ?[]const u8,
    command: ?[]const u8,
) ![]u8 {
    const target_json = try std.json.Stringify.valueAlloc(allocator, target, .{});
    defer allocator.free(target_json);

    const params_json = if (window_name) |name| blk: {
        const name_json = try std.json.Stringify.valueAlloc(allocator, name, .{});
        defer allocator.free(name_json);
        if (command) |value| {
            const command_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
            defer allocator.free(command_json);
            break :blk try std.fmt.allocPrint(
                allocator,
                "{{\"target\":{s},\"windowName\":{s},\"command\":{s}}}",
                .{ target_json, name_json, command_json },
            );
        }
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"target\":{s},\"windowName\":{s}}}",
            .{ target_json, name_json },
        );
    } else try std.fmt.allocPrint(allocator, "{{\"target\":{s}}}", .{target_json});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "window.create", params_json);
}

/// Creates a tmux session at the document root.
pub fn sessionCreate(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    session_name: []const u8,
    command: ?[]const u8,
) ![]u8 {
    return try sessionCreateAt(allocator, socket_path, null, session_name, command);
}

/// Creates a tmux session, optionally nesting its projection beneath `parent_id`.
pub fn sessionCreateAt(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    parent_id: ?u64,
    session_name: []const u8,
    command: ?[]const u8,
) ![]u8 {
    const session_name_json = try std.json.Stringify.valueAlloc(allocator, session_name, .{});
    defer allocator.free(session_name_json);

    const params_json = if (parent_id) |value|
        if (command) |command_value| blk: {
            const command_json = try std.json.Stringify.valueAlloc(allocator, command_value, .{});
            defer allocator.free(command_json);
            break :blk try std.fmt.allocPrint(
                allocator,
                "{{\"parentId\":{d},\"sessionName\":{s},\"command\":{s}}}",
                .{ value, session_name_json, command_json },
            );
        } else try std.fmt.allocPrint(
            allocator,
            "{{\"parentId\":{d},\"sessionName\":{s}}}",
            .{ value, session_name_json },
        )
    else if (command) |command_value| blk: {
        const command_json = try std.json.Stringify.valueAlloc(allocator, command_value, .{});
        defer allocator.free(command_json);
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"sessionName\":{s},\"command\":{s}}}",
            .{ session_name_json, command_json },
        );
    } else try std.fmt.allocPrint(
        allocator,
        "{{\"sessionName\":{s}}}",
        .{session_name_json},
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "session.create", params_json);
}

/// Lists tmux sessions known to the backend.
pub fn sessionList(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "session.list", "{}");
}

/// Lists tmux windows known to the backend.
pub fn windowList(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "window.list", "{}");
}

/// Lists tmux panes known to the backend.
pub fn paneList(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "pane.list", "{}");
}

/// Returns source metadata for one leaf node.
pub fn leafSourceGet(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "leaf.source.get", params_json);
}

/// Attaches a file-backed leaf source by kind and path.
pub fn leafAttachFile(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    kind: []const u8,
    path: []const u8,
) ![]u8 {
    const kind_json = try std.json.Stringify.valueAlloc(allocator, kind, .{});
    defer allocator.free(kind_json);
    const path_json = try std.json.Stringify.valueAlloc(allocator, path, .{});
    defer allocator.free(path_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"kind\":{s},\"path\":{s}}}",
        .{ kind_json, path_json },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "leaf.source.attach", params_json);
}

/// Attaches a tty-backed leaf source by tmux session name.
pub fn leafAttachTty(allocator: std.mem.Allocator, socket_path: []const u8, session_name: []const u8) ![]u8 {
    const session_name_json = try std.json.Stringify.valueAlloc(allocator, session_name, .{});
    defer allocator.free(session_name_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"tty\",\"sessionName\":{s}}}",
        .{session_name_json},
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "leaf.source.attach", params_json);
}

/// Captures current file content into its derived leaf payload.
pub fn fileCapture(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "file.capture", params_json);
}

/// Stores the follow-tail preference for a file-backed leaf.
pub fn fileFollowTail(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64, enabled: bool) ![]u8 {
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"nodeId\":{d},\"enabled\":{s}}}",
        .{ node_id, if (enabled) "true" else "false" },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "file.followTail", params_json);
}

/// Returns backend and phase capability flags.
pub fn capabilitiesGet(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "capabilities.get", "{}");
}

/// Clears both shared view root and shared elision state.
pub fn viewReset(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "view.reset", "{}");
}

/// Returns one node payload by id.
pub fn nodeGet(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "node.get", params_json);
}

/// Sends one raw JSON-RPC request using a short-lived client handle.
///
/// The returned response is owned by the caller and must be freed with the
/// same allocator passed to this function.
pub fn request(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    var client = try client_mod.Client.init(allocator, socket_path);
    defer client.deinit();
    return try client.request(method, params_json);
}

/// Sends one raw JSON-RPC request using an existing persistent client handle.
pub fn requestWithClient(client: *client_mod.Client, method: []const u8, params_json: []const u8) ![]u8 {
    return try client.request(method, params_json);
}

/// Returns one node payload by id using an existing persistent client handle.
pub fn nodeGetWithClient(client: *client_mod.Client, allocator: std.mem.Allocator, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try requestWithClient(client, "node.get", params_json);
}

/// Returns a boxed viewer projection using an existing persistent client handle.
pub fn projectionGetWithClient(
    client: *client_mod.Client,
    allocator: std.mem.Allocator,
    request_value: projection_mod.Request,
) ![]u8 {
    var params = std.array_list.Managed(u8).init(allocator);
    defer params.deinit();
    try projection_mod.writeRequestJson(params.writer(), request_value);
    return try requestWithClient(client, "projection.get", params.items);
}

/// Returns the daemon transport spec from `MUXLY_TRANSPORT`, falling back to
/// `MUXLY_SOCKET` and then the platform default when unset.
///
/// The returned spec is owned by the caller.
pub fn transportSpecFromEnv(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "MUXLY_TRANSPORT") catch |transport_err| switch (transport_err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "MUXLY_SOCKET") catch |socket_err| switch (socket_err) {
            error.EnvironmentVariableNotFound => try runtimeDefaultTransportSpecOwned(allocator),
            else => return socket_err,
        },
        else => return transport_err,
    };
}

/// Returns the platform-default daemon transport spec as an owned slice.
///
/// Unix-like hosts default to `${XDG_RUNTIME_DIR}/muxly.sock` when available and
/// otherwise `/run/user/<uid>/muxly.sock`, falling back to `/tmp/muxly.sock` if
/// a runtime directory cannot be determined. Windows uses the planned named-pipe
/// path even though the current client transport is not implemented there yet.
pub fn runtimeDefaultTransportSpecOwned(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        return try allocator.dupe(u8, "\\\\.\\pipe\\muxly");
    }

    if (std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR")) |runtime_dir| {
        defer allocator.free(runtime_dir);
        return try std.fs.path.join(allocator, &.{ runtime_dir, "muxly.sock" });
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const uid = std.posix.getuid();
    return std.fmt.allocPrint(allocator, "/run/user/{d}/muxly.sock", .{uid}) catch
        try allocator.dupe(u8, "/tmp/muxly.sock");
}

/// Returns the legacy compile-time daemon transport spec.
///
/// Prefer `runtimeDefaultTransportSpecOwned` for the real runtime default,
/// which now prefers `${XDG_RUNTIME_DIR}/muxly.sock` and then
/// `/run/user/<uid>/muxly.sock` on Unix-like systems.
pub fn defaultTransportSpec() []const u8 {
    return if (builtin.os.tag == .windows)
        "\\\\.\\pipe\\muxly"
    else
        "/tmp/muxly.sock";
}

/// Legacy alias retained for examples and existing callers.
pub fn socketPathFromEnv(allocator: std.mem.Allocator) ![]u8 {
    return try transportSpecFromEnv(allocator);
}

/// Returns the runtime-default daemon socket path as an owned slice.
pub fn runtimeDefaultSocketPathOwned(allocator: std.mem.Allocator) ![]u8 {
    return try runtimeDefaultTransportSpecOwned(allocator);
}

/// Legacy alias retained for examples and existing callers.
pub fn defaultSocketPath() []const u8 {
    return defaultTransportSpec();
}
