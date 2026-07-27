//! Process-owned capabilities handed explicitly to subcommands.

const std = @import("std");
const engine = @import("expr");
const hugetlb = @import("base").hugetlb;

pub const ProcessContext = struct {
    allocator: std.mem.Allocator,
    eval_release: ?engine.ReleaseAction = null,
    memory_backing: ?*hugetlb.Policy = null,
};
