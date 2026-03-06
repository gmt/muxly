pub const ConflictSeverity = enum {
    none,
    warning,
    impossible,
};

pub const BindingConflict = struct {
    description: []const u8,
    severity: ConflictSeverity,
};
