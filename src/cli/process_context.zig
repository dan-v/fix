//! Process-owned capabilities handed explicitly to subcommands.

const std = @import("std");
const engine = @import("expr");
const hugetlb = @import("base").hugetlb;

pub const ProcessContext = struct {
    allocator: std.mem.Allocator,
    eval_release: ?engine.ReleaseAction = null,
    memory_backing: ?*hugetlb.Policy = null,
    /// The production CLI exits with `std.process.exit` immediately after
    /// the selected command returns. One-shot commands may leave large,
    /// process-owned heaps to the kernel instead of walking them solely to
    /// free every allocation just before exit. Embedders and tests retain the
    /// default and therefore keep deterministic resource teardown.
    exits_after_command: bool = false,
};
