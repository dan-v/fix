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
const ChunkId = types.ChunkId;
const InternId = types.InternId;
const ForceResult = types.ForceResult;

pub const ThunkState = enum(u8) {
    unresolved = 0,
    evaluating = 1,
    resolved = 2,
    blackhole = 3,
};

/// A thunk is heap-allocated and shared across threads via atomic operations.
pub const Thunk = struct {
    /// Atomic state.
    state: std.atomic.Value(u8),
    /// The chunk to execute when forcing.
    chunk_id: ChunkId,
    /// Captured environment at creation time (flattened).
    /// The env is a slice of (InternId, Value) pairs stored inline.
    env_pairs_count: u16,
    env_pairs_data: [*]EnvPair,
    /// The resolved value (valid when state == .resolved).
    result: Value,

    const EnvPair = extern struct {
        name: InternId,
        value: Value,
    };

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
        if (self.chunk_id != other.chunk_id) return false;
        if (self.env_pairs_count != other.env_pairs_count) return false;
        const count = self.env_pairs_count;
        var i: u16 = 0;
        while (i < count) : (i += 1) {
            const a = self.env_pairs_data[i];
            const b = other.env_pairs_data[i];
            if (a.name != b.name) return false;
            if (!a.value.memoEq(b.value, @import("intern.zig").InternTable)) return false;
        }
        return true;
    }

    pub fn deinit(self: *Thunk, allocator: std.mem.Allocator) void {
        const ptr: [*]EnvPair = self.env_pairs_data;
        const count = self.env_pairs_count;
        allocator.free(ptr[0..count]);
        allocator.destroy(self);
    }
};
