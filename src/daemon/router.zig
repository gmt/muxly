const std = @import("std");
const muxly = @import("muxly");
const protocol = muxly.protocol;
const errors = muxly.errors;
const store_mod = @import("state/store.zig");

pub fn handleRequest(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    request_bytes: []const u8,
) ![]u8 {
    const parsed = protocol.parseRequest(allocator, request_bytes) catch {
        return try buildError(allocator, null, .parse_error, "invalid JSON-RPC payload");
    };
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.jsonrpc, protocol.JsonRpcVersion)) {
        return try buildError(allocator, parsed.value.id, .invalid_request, "jsonrpc must be 2.0");
    }

    const document_path = protocol.requestDocumentPath(parsed.value) catch {
        return try buildError(allocator, parsed.value.id, .invalid_params, "target.documentPath must be an absolute path");
    };
    _ = store.documentForPath(document_path) catch |err| switch (err) {
        error.UnsupportedDocumentPath => {
            const message = try std.fmt.allocPrint(
                allocator,
                "document path {f} is not supported yet",
                .{std.json.fmt(document_path, .{})},
            );
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .unsupported, message);
        },
        else => return err,
    };

    store.pumpTmuxBackend() catch |err| switch (err) {
        error.FileNotFound, error.TmuxCommandFailed, error.ControlModeUnavailable => {},
        else => return err,
    };

    if (std.mem.eql(u8, parsed.value.method, "ping")) {
        return try buildResult(allocator, parsed.value.id, "{\"pong\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "initialize") or std.mem.eql(u8, parsed.value.method, "capabilities.get")) {
        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try store.capabilities.writeJson(result.writer());
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "document.get") or
        std.mem.eql(u8, parsed.value.method, "graph.get") or
        std.mem.eql(u8, parsed.value.method, "view.get"))
    {
        try store.refreshSources();
        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try store.document.writeJson(result.writer());
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "projection.get")) {
        try store.refreshSources();
        const request_value = parseProjectionRequest(allocator, parsed.value.params) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "invalid projection params: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .invalid_params, message);
        };
        defer if (request_value.local_state.scroll_offsets.len != 0) allocator.free(request_value.local_state.scroll_offsets);

        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try muxly.projection.writeProjectionJson(allocator, &store.document, request_value, result.writer());
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "document.status")) {
        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try store.document.writeStatusJson(result.writer());
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "node.get")) {
        const node_id = protocol.getInteger(parsed.value.params, "nodeId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "nodeId is required");
        const node = store.document.findNode(@intCast(node_id)) orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "unknown nodeId");
        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try node.writeJson(result.writer());
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "session.list")) {
        try store.refreshTmuxPaneSnapshots();
        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try writeSessionList(store, result.writer());
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "window.list")) {
        try store.refreshTmuxPaneSnapshots();
        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try writeWindowList(store, result.writer());
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "pane.list")) {
        try store.refreshTmuxPaneSnapshots();
        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try writePaneList(store, result.writer());
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "document.serialize")) {
        try store.refreshSources();
        var xml = std.array_list.Managed(u8).init(allocator);
        defer xml.deinit();
        try store.document.writeXml(xml.writer());

        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try result.writer().writeAll("{\"format\":\"xml\",\"document\":");
        try result.writer().print("{f}", .{std.json.fmt(xml.items, .{})});
        try result.writer().writeAll("}");
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "document.freeze")) {
        store.document.freeze();
        return try buildResult(allocator, parsed.value.id, "{\"lifecycle\":\"frozen\"}");
    }

    if (std.mem.eql(u8, parsed.value.method, "node.append")) {
        const parent_id = protocol.getInteger(parsed.value.params, "parentId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "parentId is required");
        const kind_name = protocol.getString(parsed.value.params, "kind") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "kind is required");
        const title = protocol.getString(parsed.value.params, "title") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "title is required");
        const kind = parseNodeKind(kind_name) orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "unsupported node kind");
        const node_id = store.appendNode(@intCast(parent_id), kind, title) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to append node: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .invalid_params, message);
        };
        return try buildNodeAttached(allocator, parsed.value.id, node_id, @tagName(kind));
    }

    if (std.mem.eql(u8, parsed.value.method, "node.update")) {
        const node_id = protocol.getInteger(parsed.value.params, "nodeId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "nodeId is required");
        const title = protocol.getString(parsed.value.params, "title");
        const content = protocol.getString(parsed.value.params, "content");
        store.updateNode(@intCast(node_id), title, content) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to update node: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .invalid_params, message);
        };
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "node.freeze")) {
        const node_id = protocol.getInteger(parsed.value.params, "nodeId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "nodeId is required");
        const artifact_kind_name = protocol.getString(parsed.value.params, "artifactKind") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "artifactKind is required");
        const artifact_kind = parseTerminalArtifactKind(artifact_kind_name) orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "unsupported artifactKind");
        store.freezeTerminalNode(@intCast(node_id), artifact_kind) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to freeze node: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .invalid_params, message);
        };
        const node = store.document.findNode(@intCast(node_id)) orelse
            return try buildError(allocator, parsed.value.id, .internal_error, "frozen node missing from document");
        const artifact = switch (node.source) {
            .terminal_artifact => |value| value,
            else => return try buildError(allocator, parsed.value.id, .internal_error, "frozen node did not transition source"),
        };

        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try result.writer().print(
            "{{\"ok\":true,\"nodeId\":{d},\"lifecycle\":\"frozen\",\"artifactKind\":\"{s}\",\"contentFormat\":\"{s}\",\"sections\":[",
            .{ node_id, @tagName(artifact_kind), @tagName(artifact.content_format) },
        );
        if (artifact.sections.surface) {
            try result.writer().writeAll("\"surface\"");
            if (artifact.sections.alternate) {
                try result.writer().writeAll(",\"alternate\"");
            }
        } else if (artifact.sections.alternate) {
            try result.writer().writeAll("\"alternate\"");
        }
        try result.writer().writeAll("]}");
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "node.remove")) {
        const node_id = protocol.getInteger(parsed.value.params, "nodeId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "nodeId is required");
        store.removeNode(@intCast(node_id)) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to remove node: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .invalid_params, message);
        };
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "session.create")) {
        const parent_id: u64 = if (protocol.getInteger(parsed.value.params, "parentId")) |value| blk: {
            if (value < 0) {
                return try buildError(allocator, parsed.value.id, .invalid_params, "parentId must be non-negative");
            }
            break :blk @intCast(value);
        } else store.document.root_node_id;
        const session_name = protocol.getString(parsed.value.params, "sessionName") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "sessionName is required");
        const command = protocol.getString(parsed.value.params, "command");
        const node_id = store.createTmuxSession(parent_id, session_name, command) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to create tmux session: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .backend_unavailable, message);
        };
        return try buildNodeAttached(allocator, parsed.value.id, node_id, "tty");
    }

    if (std.mem.eql(u8, parsed.value.method, "window.create")) {
        const target = protocol.getString(parsed.value.params, "target") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "target is required");
        const window_name = protocol.getString(parsed.value.params, "windowName");
        const command = protocol.getString(parsed.value.params, "command");
        const node_id = store.createTmuxWindow(target, window_name, command) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to create tmux window: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .backend_unavailable, message);
        };
        return try buildNodeAttached(allocator, parsed.value.id, node_id, "tty");
    }

    if (std.mem.eql(u8, parsed.value.method, "pane.split")) {
        const target = protocol.getString(parsed.value.params, "target") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "target is required");
        const direction = protocol.getString(parsed.value.params, "direction") orelse "below";
        const command = protocol.getString(parsed.value.params, "command");
        const node_id = store.splitTmuxPane(target, direction, command) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to split tmux pane: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .backend_unavailable, message);
        };
        return try buildNodeAttached(allocator, parsed.value.id, node_id, "tty");
    }

    if (std.mem.eql(u8, parsed.value.method, "pane.capture")) {
        const pane_id = protocol.getString(parsed.value.params, "paneId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "paneId is required");
        const capture = store.captureTmuxPane(pane_id) catch
            return try buildError(allocator, parsed.value.id, .backend_unavailable, "unable to capture tmux pane");
        defer allocator.free(capture);
        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try result.writer().writeAll("{\"paneId\":");
        try result.writer().print("{f}", .{std.json.fmt(pane_id, .{})});
        try result.writer().writeAll(",\"content\":");
        try result.writer().print("{f}", .{std.json.fmt(capture, .{})});
        try result.writer().writeAll("}");
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "pane.scroll")) {
        const pane_id = protocol.getString(parsed.value.params, "paneId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "paneId is required");
        const start_line = protocol.getInteger(parsed.value.params, "startLine") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "startLine is required");
        const end_line = protocol.getInteger(parsed.value.params, "endLine") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "endLine is required");
        const capture = store.scrollTmuxPane(pane_id, start_line, end_line) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to scroll tmux pane: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .backend_unavailable, message);
        };
        defer allocator.free(capture);
        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try result.writer().writeAll("{\"paneId\":");
        try result.writer().print("{f}", .{std.json.fmt(pane_id, .{})});
        try result.writer().writeAll(",\"content\":");
        try result.writer().print("{f}", .{std.json.fmt(capture, .{})});
        try result.writer().writeAll("}");
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "pane.resize")) {
        const pane_id = protocol.getString(parsed.value.params, "paneId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "paneId is required");
        const direction = protocol.getString(parsed.value.params, "direction") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "direction is required");
        const amount = protocol.getInteger(parsed.value.params, "amount") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "amount is required");
        store.resizeTmuxPane(pane_id, direction, amount) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to resize tmux pane: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .backend_unavailable, message);
        };
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "pane.focus")) {
        const pane_id = protocol.getString(parsed.value.params, "paneId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "paneId is required");
        store.focusTmuxPane(pane_id) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to focus tmux pane: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .backend_unavailable, message);
        };
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "pane.sendKeys")) {
        const pane_id = protocol.getString(parsed.value.params, "paneId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "paneId is required");
        const keys = protocol.getString(parsed.value.params, "keys") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "keys is required");
        const press_enter = protocol.getBool(parsed.value.params, "enter") orelse false;
        store.sendKeysTmuxPane(pane_id, keys, press_enter) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to send tmux keys: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .backend_unavailable, message);
        };
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "pane.close")) {
        const pane_id = protocol.getString(parsed.value.params, "paneId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "paneId is required");
        store.closeTmuxPane(pane_id) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to close tmux pane: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .backend_unavailable, message);
        };
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "pane.followTail")) {
        const pane_id = protocol.getString(parsed.value.params, "paneId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "paneId is required");
        const enabled = protocol.getBool(parsed.value.params, "enabled") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "enabled is required");
        store.setPaneFollowTail(pane_id, enabled) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to set pane follow tail: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .backend_unavailable, message);
        };
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "view.setRoot")) {
        const node_id = protocol.getInteger(parsed.value.params, "nodeId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "nodeId is required");
        store.document.setViewRoot(@intCast(node_id)) catch
            return try buildError(allocator, parsed.value.id, .invalid_params, "unknown nodeId");
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "view.clearRoot")) {
        store.clearViewRoot();
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "view.elide")) {
        const node_id = protocol.getInteger(parsed.value.params, "nodeId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "nodeId is required");
        store.document.toggleElided(@intCast(node_id)) catch
            return try buildError(allocator, parsed.value.id, .invalid_params, "unknown nodeId");
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "view.expand")) {
        const node_id = protocol.getInteger(parsed.value.params, "nodeId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "nodeId is required");
        store.expandNode(@intCast(node_id)) catch
            return try buildError(allocator, parsed.value.id, .invalid_params, "unknown nodeId");
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "leaf.source.attach")) {
        const kind = protocol.getString(parsed.value.params, "kind") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "kind is required");

        if (std.mem.eql(u8, kind, "static-file") or std.mem.eql(u8, kind, "monitored-file")) {
            const path = protocol.getString(parsed.value.params, "path") orelse
                return try buildError(allocator, parsed.value.id, .invalid_params, "path is required");
            const node_id = store.attachFile(path, if (std.mem.eql(u8, kind, "static-file")) .static else .monitored) catch |err| {
                const message = try std.fmt.allocPrint(allocator, "unable to attach file source: {s}", .{@errorName(err)});
                defer allocator.free(message);
                return try buildError(allocator, parsed.value.id, .source_error, message);
            };
            return try buildNodeAttached(allocator, parsed.value.id, node_id, kind);
        }

        if (std.mem.eql(u8, kind, "tty")) {
            const session_name = protocol.getString(parsed.value.params, "sessionName") orelse
                return try buildError(allocator, parsed.value.id, .invalid_params, "sessionName is required");
            const node_id = store.attachTty(session_name) catch |err| {
                const message = try std.fmt.allocPrint(allocator, "unable to attach tty source: {s}", .{@errorName(err)});
                defer allocator.free(message);
                return try buildError(allocator, parsed.value.id, .source_error, message);
            };
            return try buildNodeAttached(allocator, parsed.value.id, node_id, kind);
        }

        return try buildError(allocator, parsed.value.id, .invalid_params, "unsupported leaf source kind");
    }

    if (std.mem.eql(u8, parsed.value.method, "leaf.source.get")) {
        const node_id = protocol.getInteger(parsed.value.params, "nodeId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "nodeId is required");
        const node = store.document.findNode(@intCast(node_id)) orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "unknown nodeId");

        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try result.writer().print("{{\"nodeId\":{d},\"source\":", .{node.id});
        try muxly.muxml.writeSourceJson(node.source, result.writer());
        try result.writer().writeAll("}");
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "file.capture")) {
        const node_id = protocol.getInteger(parsed.value.params, "nodeId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "nodeId is required");
        const capture = store.captureFileNode(@intCast(node_id)) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to capture file node: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .source_error, message);
        };
        defer allocator.free(capture);
        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        try result.writer().print("{{\"nodeId\":{d},\"content\":", .{node_id});
        try result.writer().print("{f}", .{std.json.fmt(capture, .{})});
        try result.writer().writeAll("}");
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "file.followTail")) {
        const node_id = protocol.getInteger(parsed.value.params, "nodeId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "nodeId is required");
        const enabled = protocol.getBool(parsed.value.params, "enabled") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "enabled is required");
        store.setFileFollowTail(@intCast(node_id), enabled) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "unable to set file follow tail: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return try buildError(allocator, parsed.value.id, .source_error, message);
        };
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "view.reset")) {
        store.resetView();
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "bindings.inspect") or
        std.mem.eql(u8, parsed.value.method, "bindings.validate") or
        std.mem.eql(u8, parsed.value.method, "bindings.propose"))
    {
        return try buildError(allocator, parsed.value.id, .unsupported, "keybinding analysis is scaffolded but not implemented in this slice");
    }

    if (std.mem.eql(u8, parsed.value.method, "mouse.set")) {
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true,\"policy\":\"viewer-owned-region-targeting\"}");
    }

    if (std.mem.eql(u8, parsed.value.method, "modeline.set") or
        std.mem.eql(u8, parsed.value.method, "menu.set") or
        std.mem.eql(u8, parsed.value.method, "menu.project"))
    {
        return try buildError(allocator, parsed.value.id, .unsupported, "menu/modeline infrastructure is scaffolded but not implemented in this slice");
    }

    if (std.mem.eql(u8, parsed.value.method, "nvim.attach") or
        std.mem.eql(u8, parsed.value.method, "nvim.detach"))
    {
        return try buildError(allocator, parsed.value.id, .unsupported, "Neovim integration is scaffolded but not implemented in this slice");
    }

    return try buildError(allocator, parsed.value.id, .method_not_found, "unknown method");
}

fn buildNodeAttached(
    allocator: std.mem.Allocator,
    id: ?std.json.Value,
    node_id: u64,
    kind: []const u8,
) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    try buffer.writer().writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |value| {
        try buffer.writer().print("{f}", .{std.json.fmt(value, .{})});
    } else {
        try buffer.writer().writeAll("null");
    }
    try buffer.writer().print(",\"result\":{{\"nodeId\":{d},\"kind\":\"{s}\"}}}}", .{ node_id, kind });
    return try buffer.toOwnedSlice();
}

fn buildResult(
    allocator: std.mem.Allocator,
    id: ?std.json.Value,
    result_json: []const u8,
) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    try protocol.writeSuccess(buffer.writer(), id, result_json);
    return try buffer.toOwnedSlice();
}

fn buildError(
    allocator: std.mem.Allocator,
    id: ?std.json.Value,
    code: errors.RpcErrorCode,
    message: []const u8,
) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    try protocol.writeError(buffer.writer(), id, code, message);
    return try buffer.toOwnedSlice();
}

fn writeSessionList(store: *store_mod.Store, writer: anytype) !void {
    // `seen` borrows ids from `tmux_pane_snapshots`; this helper never mutates or refreshes snapshots while iterating.
    var seen = std.array_list.Managed([]const u8).init(store.allocator);
    defer seen.deinit();
    try writer.writeAll("[");
    var first = true;
    for (store.tmux_pane_snapshots.items) |snapshot| {
        var duplicate = false;
        for (seen.items) |existing| {
            if (std.mem.eql(u8, existing, snapshot.session_id)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        try seen.append(snapshot.session_id);
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.writeAll("{\"sessionName\":");
        try writer.print("{f}", .{std.json.fmt(snapshot.session_name, .{})});
        try writer.writeAll(",\"sessionId\":");
        try writer.print("{f}", .{std.json.fmt(snapshot.session_id, .{})});
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeWindowList(store: *store_mod.Store, writer: anytype) !void {
    const WindowKey = struct { session: []const u8, window: []const u8 };
    // `seen` borrows keys from `tmux_pane_snapshots`; this helper never mutates or refreshes snapshots while iterating.
    var seen = std.array_list.Managed(WindowKey).init(store.allocator);
    defer seen.deinit();
    try writer.writeAll("[");
    var first = true;
    for (store.tmux_pane_snapshots.items) |snapshot| {
        var duplicate = false;
        for (seen.items) |existing| {
            if (std.mem.eql(u8, existing.session, snapshot.session_id) and std.mem.eql(u8, existing.window, snapshot.window_id)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        try seen.append(.{ .session = snapshot.session_id, .window = snapshot.window_id });
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.writeAll("{\"sessionName\":");
        try writer.print("{f}", .{std.json.fmt(snapshot.session_name, .{})});
        try writer.writeAll(",\"sessionId\":");
        try writer.print("{f}", .{std.json.fmt(snapshot.session_id, .{})});
        try writer.writeAll(",\"windowId\":");
        try writer.print("{f}", .{std.json.fmt(snapshot.window_id, .{})});
        try writer.writeAll(",\"windowName\":");
        try writer.print("{f}", .{std.json.fmt(snapshot.window_name, .{})});
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writePaneList(store: *store_mod.Store, writer: anytype) !void {
    try writer.writeAll("[");
    var first = true;
    for (store.tmux_pane_snapshots.items) |snapshot| {
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.writeAll("{");
        if (store.findNodeIdByPaneId(snapshot.pane_id)) |node_id| {
            try writer.writeAll("\"nodeId\":");
            try writer.print("{d}", .{node_id});
            try writer.writeAll(",");
        }
        try writer.writeAll("\"sessionName\":");
        try writer.print("{f}", .{std.json.fmt(snapshot.session_name, .{})});
        try writer.writeAll(",\"sessionId\":");
        try writer.print("{f}", .{std.json.fmt(snapshot.session_id, .{})});
        try writer.writeAll(",\"windowId\":");
        try writer.print("{f}", .{std.json.fmt(snapshot.window_id, .{})});
        try writer.writeAll(",\"windowName\":");
        try writer.print("{f}", .{std.json.fmt(snapshot.window_name, .{})});
        try writer.writeAll(",\"paneId\":");
        try writer.print("{f}", .{std.json.fmt(snapshot.pane_id, .{})});
        try writer.writeAll(",\"paneTitle\":");
        try writer.print("{f}", .{std.json.fmt(snapshot.pane_title, .{})});
        try writer.print(",\"paneActive\":{}", .{snapshot.pane_active});
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn parseNodeKind(name: []const u8) ?muxly.types.NodeKind {
    inline for (std.meta.fields(muxly.types.NodeKind)) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

fn parseTerminalArtifactKind(name: []const u8) ?muxly.source.TerminalArtifactKind {
    if (std.mem.eql(u8, name, "text")) return .text;
    if (std.mem.eql(u8, name, "surface")) return .surface;
    return null;
}

fn parseProjectionRequest(allocator: std.mem.Allocator, params: ?std.json.Value) !muxly.projection.Request {
    const rows_value = protocol.getInteger(params, "rows") orelse return error.MissingRows;
    const cols_value = protocol.getInteger(params, "cols") orelse return error.MissingCols;
    if (rows_value <= 0 or cols_value <= 0) return error.InvalidViewport;

    var request_value = muxly.projection.Request{
        .rows = @intCast(rows_value),
        .cols = @intCast(cols_value),
    };

    if (protocol.getInteger(params, "focusedNodeId")) |focused_node_id| {
        if (focused_node_id < 0) return error.InvalidFocusedNode;
        request_value.local_state.focused_node_id = @intCast(focused_node_id);
    }

    const value = params orelse return request_value;
    if (value != .object) return error.InvalidParamsShape;
    const offsets_value = value.object.get("scrollOffsets") orelse return request_value;
    if (offsets_value != .array) return error.InvalidScrollOffsets;

    var offsets = std.array_list.Managed(muxly.projection.ScrollOffset).init(allocator);
    errdefer offsets.deinit();

    for (offsets_value.array.items) |item| {
        if (item != .object) return error.InvalidScrollOffset;
        const node_id_value = item.object.get("nodeId") orelse return error.InvalidScrollOffset;
        const top_line_value = item.object.get("topLine") orelse return error.InvalidScrollOffset;
        if (node_id_value != .integer or top_line_value != .integer) return error.InvalidScrollOffset;
        if (node_id_value.integer < 0 or top_line_value.integer < 0) return error.InvalidScrollOffset;
        try offsets.append(.{
            .node_id = @intCast(node_id_value.integer),
            .top_line = @intCast(top_line_value.integer),
        });
    }

    request_value.local_state.scroll_offsets = try offsets.toOwnedSlice();
    return request_value;
}
