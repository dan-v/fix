//! Atomic lazy thunk — the core of multithreaded lazy evaluation.
//!
//! A thunk is a suspended computation. Multiple threads may concurrently
//! attempt to force a thunk. The first thread claims it and evaluates;
//! other threads block or spin until the result is available.
//!
//! States (atomic):
//!   UNRESOLVED = 0  → no thread has claimed this yet
//!   EVALUATING = 1  → a thread is currently computing it
//!   RESOLVED   = 2  → the value is ready
//!   BLACKHOLE  = 3  → infinite recursion detected

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const Value = @import("value.zig").Value;
const ForceResult = types.ForceResult;

pub const ThunkState = enum(u8) {
    unresolved = 0,
    evaluating = 1,
    resolved = 2,
    blackhole = 3,
};

pub const Cell = struct {
    value: Value,
};

/// A thunk is heap-allocated and shared across threads via atomic operations.
pub const Thunk = struct {
    /// Atomic state.
    state: std.atomic.Value(u8),
    /// Zero-argument closure to execute when forcing.
    closure: Value,
    /// The resolved value (valid when state == .resolved).
    result: Value,

    pub fn init(closure: Value) Thunk {
        return .{
            .state = std.atomic.Value(u8).init(@intFromEnum(ThunkState.unresolved)),
            .closure = closure,
            .result = Value.null_val,
        };
    }

    /// Try to claim this thunk for evaluation.
    /// Returns the result of the CAS.
    pub fn tryClaim(self: *Thunk) ForceResult {
        const prev = self.state.cmpxchgStrong(
            @intFromEnum(ThunkState.unresolved),
            @intFromEnum(ThunkState.evaluating),
            .acquire,
            .monotonic,
        );
        if (prev == null) return .claimed;
        const s: ThunkState = @enumFromInt(prev.?);
        return switch (s) {
            .resolved => .already_resolved,
            .evaluating, .blackhole => .busy,
            .unresolved => unreachable,
        };
    }

    /// Store the resolved value and mark as resolved.
    pub fn resolve(self: *Thunk, value: Value) void {
        // Write the result before changing state (release ensures visibility).
        self.result = value;
        self.state.store(@intFromEnum(ThunkState.resolved), .release);
    }

    /// Mark a failed evaluation attempt as retryable.
    pub fn reset(self: *Thunk) void {
        self.result = Value.null_val;
        self.state.store(@intFromEnum(ThunkState.unresolved), .release);
    }

    /// Spin until the thunk is resolved, then return the value.
    pub fn waitAndGet(self: *Thunk) Value {
        while (true) {
            const s: ThunkState = @enumFromInt(self.state.load(.acquire));
            switch (s) {
                .resolved => return self.result,
                .blackhole => @panic("infinite recursion detected"),
                else => {
                    // Yield to the OS scheduler so the evaluating thread can run.
                    if (builtin.single_threaded) {
                        @panic("blocked on thunk in single-threaded mode");
                    }
                    // Simple spin with hint.
                    var i: u32 = 0;
                    while (i < 16) : (i += 1) {
                        std.atomic.spinLoopHint();
                    }
                    std.Thread.yield() catch {};
                },
            }
        }
    }

    /// Check structural equality (for memoization). Two thunks are considered
    /// equal if they wrap the same chunk in the same environment.
    pub fn eq(self: *const Thunk, other: *const Thunk) bool {
        return self == other;
    }

    pub fn deinit(self: *Thunk, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

test "thunk reset makes failed claims retryable" {
    var thunk = Thunk.init(Value.null_val);

    try std.testing.expectEqual(ForceResult.claimed, thunk.tryClaim());
    try std.testing.expectEqual(ForceResult.busy, thunk.tryClaim());

    thunk.reset();
    try std.testing.expectEqual(ForceResult.claimed, thunk.tryClaim());

    thunk.resolve(Value.int(42));
    try std.testing.expectEqual(ForceResult.already_resolved, thunk.tryClaim());
}
