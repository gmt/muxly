//! Source metadata for TOM leaf content.
//!
//! Structure and source remain separate axes in muxly. A node kind describes
//! where a region sits in the TOM; a source describes where a leaf's content
//! comes from or what durable artifact it has become.

const std = @import("std");

/// File-backed leaf behavior.
pub const FileMode = enum {
    /// The daemon should monitor the file and refresh derived content over time.
    monitored,
    /// The file is treated as static input.
    static,
};

/// Provenance for a live tty-backed leaf.
pub const TtySource = struct {
    session_name: []u8,
    window_id: ?[]u8 = null,
    pane_id: ?[]u8 = null,

    pub fn clone(self: TtySource, allocator: std.mem.Allocator) !TtySource {
        return .{
            .session_name = try allocator.dupe(u8, self.session_name),
            .window_id = if (self.window_id) |value| try allocator.dupe(u8, value) else null,
            .pane_id = if (self.pane_id) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *TtySource, allocator: std.mem.Allocator) void {
        allocator.free(self.session_name);
        if (self.window_id) |value| allocator.free(value);
        if (self.pane_id) |value| allocator.free(value);
    }
};

/// Durable terminal artifact family.
pub const TerminalArtifactKind = enum {
    /// Append/history-oriented transcript capture.
    text,
    /// Visible surface-oriented capture for fullscreen/raw/alternate-screen cases.
    surface,
};

/// Payload shape used by a terminal artifact.
pub const TerminalArtifactContentFormat = enum {
    /// Plain text payload.
    plain_text,
    /// Sectioned text payload with named regions such as `surface`.
    sectioned_text,
};

/// First-pass section flags carried by sectioned terminal-artifact payloads.
pub const TerminalArtifactSections = struct {
    surface: bool = false,
    alternate: bool = false,

    pub fn isEmpty(self: TerminalArtifactSections) bool {
        return !self.surface and !self.alternate;
    }
};

/// Original source family from which a terminal artifact was captured.
pub const TerminalArtifactOriginKind = enum {
    tty,
};

/// Durable metadata for a frozen terminal artifact.
pub const TerminalArtifactSource = struct {
    artifact_kind: TerminalArtifactKind,
    content_format: TerminalArtifactContentFormat,
    sections: TerminalArtifactSections = .{},
    origin: TerminalArtifactOriginKind = .tty,
    session_name: ?[]u8 = null,
    window_id: ?[]u8 = null,
    pane_id: ?[]u8 = null,

    pub fn fromTty(
        allocator: std.mem.Allocator,
        tty: TtySource,
        artifact_kind: TerminalArtifactKind,
        sections: TerminalArtifactSections,
    ) !TerminalArtifactSource {
        return .{
            .artifact_kind = artifact_kind,
            .content_format = switch (artifact_kind) {
                .text => .plain_text,
                .surface => .sectioned_text,
            },
            .sections = sections,
            .origin = .tty,
            .session_name = try allocator.dupe(u8, tty.session_name),
            .window_id = if (tty.window_id) |value| try allocator.dupe(u8, value) else null,
            .pane_id = if (tty.pane_id) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn clone(self: TerminalArtifactSource, allocator: std.mem.Allocator) !TerminalArtifactSource {
        return .{
            .artifact_kind = self.artifact_kind,
            .content_format = self.content_format,
            .sections = self.sections,
            .origin = self.origin,
            .session_name = if (self.session_name) |value| try allocator.dupe(u8, value) else null,
            .window_id = if (self.window_id) |value| try allocator.dupe(u8, value) else null,
            .pane_id = if (self.pane_id) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *TerminalArtifactSource, allocator: std.mem.Allocator) void {
        if (self.session_name) |value| allocator.free(value);
        if (self.window_id) |value| allocator.free(value);
        if (self.pane_id) |value| allocator.free(value);
    }
};

/// File provenance for file-backed leaves.
pub const FileSource = struct {
    path: []u8,
    mode: FileMode,

    pub fn clone(self: FileSource, allocator: std.mem.Allocator) !FileSource {
        return .{
            .path = try allocator.dupe(u8, self.path),
            .mode = self.mode,
        };
    }

    pub fn deinit(self: *FileSource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

/// Discriminator for leaf source metadata.
pub const SourceKind = enum {
    none,
    tty,
    terminal_artifact,
    file,
};

/// Leaf source metadata attached to TOM nodes.
pub const Source = union(SourceKind) {
    none: void,
    tty: TtySource,
    terminal_artifact: TerminalArtifactSource,
    file: FileSource,

    pub fn clone(self: Source, allocator: std.mem.Allocator) !Source {
        return switch (self) {
            .none => .{ .none = {} },
            .tty => |tty| .{ .tty = try tty.clone(allocator) },
            .terminal_artifact => |artifact| .{ .terminal_artifact = try artifact.clone(allocator) },
            .file => |file| .{ .file = try file.clone(allocator) },
        };
    }

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .none => {},
            .tty => |*tty| tty.deinit(allocator),
            .terminal_artifact => |*artifact| artifact.deinit(allocator),
            .file => |*file| file.deinit(allocator),
        }
        self.* = .{ .none = {} };
    }
};
