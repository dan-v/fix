//! Shallow compatibility JSON model used during CLI output.

const std = @import("std");

pub const Value = union(enum) {
    int: i64,
    float: f64,
    str: []const u8,
    boolean: bool,
    nul,
    array: []const Value,
    object: []const Field,
    /// A child whose compatibility representation is produced only when the
    /// emitter reaches it. This keeps traversal depth-first instead of
    /// materializing a second tree beside the AST.
    deferred: Deferred,

    pub const Field = struct { key: []const u8, val: Value };

    pub const Deferred = struct {
        context: ?*const anyopaque,
        gpa: std.mem.Allocator,
        source: []const u8,
        write_fn: *const fn (
            context: ?*const anyopaque,
            gpa: std.mem.Allocator,
            source: []const u8,
            writer: *std.Io.Writer,
            indent: usize,
        ) anyerror!void,
    };
};
