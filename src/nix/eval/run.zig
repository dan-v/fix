//! Per-evaluation state.
//!
//! Holds the diagnostic list, the error trace, and an arena for any strings
//! they reference. The arena replaces the two parallel `owned_*` arrays the
//! Evaluator used to maintain alongside the diagnostic list.
//!
//! Concurrent imports on helper threads reach into this struct; the
//! `SpinMutex` protects every mutation. Reads from the main thread after
//! evaluate() returns are unsynchronized but safe because helpers have
//! quiesced by then.

const std = @import("std");
const diagnostic = @import("syntax").diagnostic;
const trace_mod = @import("../observ.zig").trace;
const stable = @import("base").sync;

pub const Diagnostic = diagnostic.Diagnostic;
pub const Trace = trace_mod.Trace;

pub const Run = struct {
    /// Parent allocator. Used for `diagnostics` (which doesn't store strings)
    /// and for the trace's internal allocations.
    allocator: std.mem.Allocator,
    /// Arena backing diagnostic message + source_path strings. Reset on
    /// each `clear()`.
    string_arena: @import("base").arena.ArenaAllocator,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    trace: Trace,
    mu: stable.SpinMutex,

    pub fn init(allocator: std.mem.Allocator) Run {
        return .{
            .allocator = allocator,
            .string_arena = @import("base").arena.ArenaAllocator.init(allocator),
            .diagnostics = .empty,
            .trace = Trace.init(allocator),
            .mu = .{},
        };
    }

    pub fn deinit(self: *Run) void {
        self.trace.deinit();
        self.diagnostics.deinit(self.allocator);
        self.string_arena.deinit();
    }

    pub fn clear(self: *Run) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.clearLocked();
    }

    fn clearLocked(self: *Run) void {
        self.diagnostics.clearRetainingCapacity();
        _ = self.string_arena.reset(.retain_capacity);
        self.trace.clear();
    }

    /// Replace the diagnostic list with `incoming`, duping any borrowed
    /// strings into the run's arena. `fallback_source` and
    /// `fallback_source_path` are used for diagnostics that don't carry
    /// their own.
    pub fn replaceDiagnostics(
        self: *Run,
        incoming: []const Diagnostic,
        fallback_source: []const u8,
        fallback_source_path: ?[]const u8,
    ) !void {
        self.mu.lock();
        defer self.mu.unlock();

        self.clearLocked();
        try self.diagnostics.ensureUnusedCapacity(self.allocator, incoming.len);

        const arena_alloc = self.string_arena.allocator();
        for (incoming) |diag| {
            var copy = diag;
            copy.message = try arena_alloc.dupe(u8, diag.message);
            copy.source = diag.source orelse fallback_source;
            if (diag.source_path orelse fallback_source_path) |path| {
                copy.source_path = try arena_alloc.dupe(u8, path);
            }
            self.diagnostics.appendAssumeCapacity(copy);
        }
    }

    /// Borrowed slice; safe to read after helpers have quiesced.
    pub fn diagnosticsView(self: *const Run) []const Diagnostic {
        return self.diagnostics.items;
    }

    pub fn traceView(self: *const Run) *const Trace {
        return &self.trace;
    }
};
