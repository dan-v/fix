//! Path-based import resolution: dedup, cycle detection, file read,
//! and the back-call into the evaluator for parse+compile+eval.
//!
//! `ImportEntry` is the futex-backed claim+wait protocol for path
//! deduplication: the first thread to cmpxchg UNRESOLVED→EVALUATING
//! does the work; others either wait on the futex (main thread) or
//! bail with `error.ImportContended` (helpers, to avoid deadlock with
//! a main thread holding a contended thunk).
//!
//! Scoped imports skip this dedup — each call carries a distinct scope
//! Value — so cycle detection for them is a thread-local linked list
//! threaded through the import call stack.
//!
//! The top-level functions (importPath, forceEntry, scopedImportPath)
//! take `ev: anytype` so the evaluator stays loosely coupled and we
//! don't introduce a cycle in the @import graph.

const std = @import("std");
const Value = @import("../runtime/value.zig").Value;
const worker_id_mod = @import("../runtime/worker_id.zig");

pub const INVALID_CLAIMER: u8 = 0xFF;

/// Path → in-flight `ImportEntry`. The mutex is held only briefly
/// during lookup/insert; the entry's own atomics + futex coordinate
/// the actual evaluation.
pub const Registry = struct {
    entries: std.StringHashMapUnmanaged(*ImportEntry) = .empty,
    mu: @import("../runtime/stable_segments.zig").SpinMutex = .{},

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.destroy(kv.value_ptr.*);
        }
        self.entries.deinit(allocator);
    }

    pub fn lookupOrCreate(
        self: *Registry,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !*ImportEntry {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.entries.get(path)) |entry| return entry;

        const key = try allocator.dupe(u8, path);
        errdefer allocator.free(key);
        const entry = try allocator.create(ImportEntry);
        errdefer allocator.destroy(entry);
        entry.* = .{};
        try self.entries.put(allocator, key, entry);
        return entry;
    }
};

pub const ImportEntry = struct {
    pub const STATE_UNRESOLVED: u32 = 0;
    pub const STATE_EVALUATING: u32 = 1;
    pub const STATE_RESOLVED: u32 = 2;
    pub const STATE_FAILED: u32 = 3;

    state: std.atomic.Value(u32) = .init(STATE_UNRESOLVED),
    claimer: std.atomic.Value(u8) = .init(INVALID_CLAIMER),
    result: Value = Value.null_val,

    pub fn waitForChange(self: *ImportEntry, from: u32) void {
        switch (@import("builtin").os.tag) {
            .linux => {
                _ = std.os.linux.futex_4arg(
                    @ptrCast(&self.state),
                    .{ .cmd = .WAIT, .private = true },
                    from,
                    null,
                );
            },
            else => std.Thread.yield() catch {},
        }
    }

    pub fn wakeAll(self: *ImportEntry) void {
        switch (@import("builtin").os.tag) {
            .linux => {
                _ = std.os.linux.futex_3arg(
                    @ptrCast(&self.state),
                    .{ .cmd = .WAKE, .private = true },
                    std.math.maxInt(i32),
                );
            },
            else => {},
        }
    }
};

/// Per-thread linked list of in-progress *scoped* import paths.
/// `pushFrame` returns the prior top so the caller can restore it on
/// scope exit; `checkCycle` walks the chain looking for `path`.
pub const ScopedFrame = struct {
    path: []const u8,
    next: ?*const ScopedFrame,
};

threadlocal var scoped_stack_top: ?*const ScopedFrame = null;

pub fn scopedStackTop() ?*const ScopedFrame {
    return scoped_stack_top;
}

pub fn pushScopedFrame(frame: *ScopedFrame) ?*const ScopedFrame {
    const prev = scoped_stack_top;
    frame.next = prev;
    scoped_stack_top = frame;
    return prev;
}

pub fn popScopedFrame(prev: ?*const ScopedFrame) void {
    scoped_stack_top = prev;
}

pub fn checkScopedCycle(path: []const u8) !void {
    var cursor = scoped_stack_top;
    while (cursor) |node| {
        if (std.mem.eql(u8, node.path, path)) return error.ImportCycle;
        cursor = node.next;
    }
}

/// Resolve `path` against `ev.base_path` if relative, then dedup
/// through the registry and force the entry to completion. The
/// evaluator is passed by anytype to avoid an @import cycle; it must
/// expose `allocator`, `imports`, `files`, `progress*`, `evaluateSource`,
/// and `resolveHostPath`.
pub fn importPath(ev: anytype, path: []const u8) !Value {
    const resolved = try ev.resolveHostPath(path);
    defer if (resolved.owned) ev.allocator.free(resolved.text);
    return importResolvedPath(ev, resolved.text);
}

pub fn importResolvedPath(ev: anytype, path: []const u8) anyerror!Value {
    const entry = try ev.imports.lookupOrCreate(ev.allocator, path);
    return forceEntry(ev, path, entry);
}

/// Drive the futex protocol on `entry`. The first thread to claim it
/// runs `compileImportPath` and publishes; later arrivals either wait
/// (main thread) or bail with `ImportContended` (helpers, to keep a
/// contended-thunk deadlock from forming).
pub fn forceEntry(ev: anytype, path: []const u8, entry: *ImportEntry) anyerror!Value {
    const me = worker_id_mod.current;
    while (true) {
        const state = entry.state.load(.acquire);
        switch (state) {
            ImportEntry.STATE_RESOLVED => return entry.result,
            ImportEntry.STATE_FAILED => return error.ImportFailed,
            ImportEntry.STATE_EVALUATING => {
                const claimer = entry.claimer.load(.acquire);
                if (claimer == me) return error.ImportCycle;
                if (me != 0) return error.ImportContended;
                entry.waitForChange(ImportEntry.STATE_EVALUATING);
            },
            ImportEntry.STATE_UNRESOLVED => {
                if (entry.state.cmpxchgWeak(
                    ImportEntry.STATE_UNRESOLVED,
                    ImportEntry.STATE_EVALUATING,
                    .acquire,
                    .monotonic,
                )) |_| continue;
                entry.claimer.store(me, .release);
                const value = compileImportPath(ev, path) catch |err| {
                    entry.state.store(ImportEntry.STATE_FAILED, .release);
                    entry.wakeAll();
                    return err;
                };
                entry.result = value;
                entry.state.store(ImportEntry.STATE_RESOLVED, .release);
                entry.wakeAll();
                return value;
            },
            else => unreachable,
        }
    }
}

/// Caller has already claimed the `ImportEntry`. Reads the source
/// (or returns the synthetic corepkgs string), then evaluates.
pub fn compileImportPath(ev: anytype, path: []const u8) anyerror!Value {
    const stable_path = try ev.allocator.dupe(u8, path);
    defer ev.allocator.free(stable_path);

    ev.progressBegin(.import, stable_path);
    defer ev.progressEnd(.import, stable_path);

    const source = if (corepkgsSource(stable_path)) |core_source|
        core_source
    else
        ev.files.readFile(stable_path) catch |err| switch (err) {
            error.IsDir => return importDirectory(ev, stable_path),
            else => return err,
        };
    const source_base = std.fs.path.dirname(stable_path) orelse "/";
    return ev.evaluateSource(source, source_base, stable_path, null);
}

pub fn scopedImportPath(ev: anytype, scope: Value, path: []const u8) !Value {
    const resolved = try ev.resolveHostPath(path);
    defer if (resolved.owned) ev.allocator.free(resolved.text);
    return scopedImportResolvedPath(ev, scope, resolved.text);
}

pub fn scopedImportResolvedPath(ev: anytype, scope: Value, path: []const u8) anyerror!Value {
    const stable_path = try ev.allocator.dupe(u8, path);
    defer ev.allocator.free(stable_path);

    try checkScopedCycle(stable_path);
    var frame: ScopedFrame = .{ .path = stable_path, .next = null };
    const prev = pushScopedFrame(&frame);
    defer popScopedFrame(prev);

    ev.progressBegin(.import, stable_path);
    defer ev.progressEnd(.import, stable_path);

    const source = if (corepkgsSource(stable_path)) |core_source|
        core_source
    else
        ev.files.readFile(stable_path) catch |err| switch (err) {
            error.IsDir => return scopedImportDirectory(ev, scope, stable_path),
            else => return err,
        };
    const source_base = std.fs.path.dirname(stable_path) orelse "/";
    return ev.evaluateSource(source, source_base, stable_path, scope);
}

pub fn importDirectory(ev: anytype, path: []const u8) anyerror!Value {
    const default_path = try std.fs.path.resolve(ev.allocator, &.{ path, "default.nix" });
    defer ev.allocator.free(default_path);
    return importResolvedPath(ev, default_path);
}

pub fn scopedImportDirectory(ev: anytype, scope: Value, path: []const u8) anyerror!Value {
    const default_path = try std.fs.path.resolve(ev.allocator, &.{ path, "default.nix" });
    defer ev.allocator.free(default_path);
    return scopedImportResolvedPath(ev, scope, default_path);
}

/// Synthetic source for `<nix/fetchurl.nix>`, hard-coded so the
/// evaluator doesn't need a corepkgs store path on disk.
pub fn corepkgsSource(path: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, path, "/__corepkgs__/fetchurl.nix")) return null;
    return
    \\{
    \\  name ? baseNameOf url,
    \\  url,
    \\  hash ? "",
    \\  sha256 ? "",
    \\  executable ? false,
    \\  ...
    \\}:
    \\let
    \\  outputHash = if hash != "" then hash else sha256;
    \\in
    \\derivation {
    \\  inherit name url executable;
    \\  urls = [ url ];
    \\  builder = "builtin:fetchurl";
    \\  system = "builtin";
    \\  inherit outputHash;
    \\  outputHashAlgo = if hash != "" then null else "sha256";
    \\  outputHashMode = if executable then "recursive" else "flat";
    \\  preferLocalBuild = true;
    \\  impureEnvVars = [ "http_proxy" "https_proxy" "ftp_proxy" "all_proxy" "no_proxy" ];
    \\  unpack = false;
    \\}
    ;
}
