//! Immutable arena-backed compatibility JSON model used during CLI output.

pub const Value = union(enum) {
    int: i64,
    float: f64,
    str: []const u8,
    boolean: bool,
    nul,
    array: []const Value,
    object: []const Field,

    pub const Field = struct { key: []const u8, val: Value };
};
