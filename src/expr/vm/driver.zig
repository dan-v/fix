//! Top-level VM execution entry point.

const context = @import("context.zig");
const stack = @import("stack.zig");
const run = @import("run.zig");
const errors = @import("errors.zig");

pub const driver: context.Driver = .{ .eval = eval };

fn eval(self: *context.VM, chunk_id: @import("runtime").types.ChunkId) !@import("runtime").value.Value {
    const chunk = self.registry.get(chunk_id) orelse return error.InvalidChunk;

    // The top-level expression is not a function application, so the initial
    // passthrough frame starts at logical call depth zero.
    try stack.pushFrame(self, chunk, chunk_id, 0, null, null, false);
    return run.run(self) catch |err| {
        errors.captureErrorTrace(self, err) catch {};
        return err;
    };
}
