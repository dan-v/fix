//! Path-based import resolution: dedup, cycle detection, file read,
//! and the back-call into the evaluator for parse+compile+eval.
//!
//! Each `ImportEntry` wraps a `runtime.thunk.Future` — the same
//! claim+wait state machine `Thunk` uses. The first fiber to claim
//! runs `compileImportPath` inline; concurrent fibers enroll on the
//! future's waiter list and yield. Same protocol, same primitive: a
//! Future is a Future whether it backs a thunk or a path.
//!
//! There is no main/helper asymmetry. Cycle detection is per-fiber
//! by `ClaimerId` (stable across migration); same-fiber recursion
//! shows up as `Future.tryForce` returning `.blackhole`, which we
//! translate to `error.ImportCycle`.
//!
//! Scoped imports skip this dedup — each call carries a distinct scope
//! Value — so cycle detection for them is a thread-local linked list
//! threaded through the import call stack.
//!
//! The top-level functions (importPath, forceEntry, scopedImportPath)
//! take `ev: anytype` so the evaluator stays loosely coupled and we
//! don't introduce a cycle in the @import graph.

const std = @import("std");
const Value = @import("runtime").value.Value;
const thunk_mod = @import("runtime").thunk;
const fiber_mod = @import("parallel").fiber;
const worker_mod = @import("worker.zig");
const SpinMutex = @import("runtime").stable_segments.SpinMutex;
const timeline = @import("../probe/timeline.zig");

/// Path → in-flight `ImportEntry`. The mutex is held only briefly
/// during lookup/insert; the entry's own `Future` coordinates the
/// actual evaluation.
pub const Registry = struct {
    entries: std.StringHashMapUnmanaged(*ImportEntry) = .empty,
    mu: SpinMutex = .{},

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            if (entry.error_info) |info| {
                if (info.message) |msg| allocator.free(msg);
                allocator.destroy(info);
            }
            allocator.free(kv.key_ptr.*);
            allocator.destroy(entry);
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
        entry.* = .{ .future = thunk_mod.Future.init() };
        try self.entries.put(allocator, key, entry);
        return entry;
    }
};

pub const ImportEntry = struct {
    future: thunk_mod.Future,
    /// The resolved import value. `Future` is value-less, so the entry
    /// owns its own result slot, written before `future.publish()`.
    result: Value = Value.null_val,
    /// Owned by this entry. Allocated when the compile fails so the
    /// future can transition to `.errored` with a sidecar. Freed by
    /// `Registry.deinit`.
    error_info: ?*thunk_mod.ErrorInfo = null,
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
pub fn importPath(ev: anytype, path: []const u8, parent_depth: u32) !Value {
    const resolved = try ev.resolveHostPath(path);
    defer if (resolved.owned) ev.allocator.free(resolved.text);
    return importResolvedPath(ev, resolved.text, parent_depth);
}

pub fn importResolvedPath(ev: anytype, path: []const u8, parent_depth: u32) anyerror!Value {
    const entry = try ev.imports.lookupOrCreate(ev.allocator, path);
    return forceEntry(ev, path, entry, parent_depth);
}

/// Drive the claim protocol on `entry`. The first fiber to claim
/// runs `compileImportPath` inline; concurrent fibers enroll on the
/// future's waiter list and yield until the claimer publishes a
/// terminal state. Cycle detection comes for free from `Future`:
/// same-claimer recursion returns `.blackhole`, which we translate
/// to `error.ImportCycle`.
pub fn forceEntry(ev: anytype, path: []const u8, entry: *ImportEntry, parent_depth: u32) anyerror!Value {
    const me = currentClaimer();
    while (true) {
        switch (entry.future.tryClaim(me)) {
            .already_resolved => return entry.result,
            .blackhole => return error.ImportCycle,
            .errored => return entry.error_info.?.err,
            .busy => {
                const inner = fiber_mod.currentFiber() orelse
                    @panic("forceEntry hit .busy outside a fiber");
                const wf: *worker_mod.Fiber = @fieldParentPtr("inner", inner);
                if (entry.future.enrollWaiter(&wf.waiter)) {
                    wf.state = .suspended;
                    fiber_mod.Fiber.yield();
                    wf.state = .running;
                }
                continue;
            },
            .claimed => {
                const value = compileImportPath(ev, path, parent_depth) catch |err| {
                    publishCompileFailure(ev, entry, err);
                    return err;
                };
                entry.result = value;
                entry.future.publish();
                return value;
            },
        }
    }
}

/// Cache a compile failure on the entry's future. Allocates an
/// `ErrorInfo` so the same error replays on every subsequent force —
/// imports that fail (file not found, parse error, etc.) almost
/// always fail deterministically. If allocation itself fails, we
/// fall back to `Future.reset` (transient), so the next caller
/// retries.
fn publishCompileFailure(ev: anytype, entry: *ImportEntry, err: anyerror) void {
    const info = ev.allocator.create(thunk_mod.ErrorInfo) catch {
        entry.future.reset();
        return;
    };
    info.* = .{ .err = err, .message = null };
    entry.error_info = info;
    entry.future.publishErrored();
}

fn currentClaimer() thunk_mod.ClaimerId {
    const inner = fiber_mod.currentFiber() orelse return thunk_mod.INVALID_CLAIMER;
    const wf: *worker_mod.Fiber = @fieldParentPtr("inner", inner);
    return wf.vm.claimer_id;
}

/// Caller has already claimed the `ImportEntry`. Reads the source
/// (or returns the synthetic corepkgs string), then evaluates.
pub fn compileImportPath(ev: anytype, path: []const u8, parent_depth: u32) anyerror!Value {
    const stable_path = try ev.allocator.dupe(u8, path);
    defer ev.allocator.free(stable_path);

    ev.progressBegin(.import, stable_path);
    defer ev.progressEnd(.import, stable_path);
    timeline.instant(.import, stable_path);

    const source = if (corepkgsSource(stable_path)) |core_source|
        core_source
    else
        ev.files.readFile(stable_path) catch |err| switch (err) {
            error.IsDir => return importDirectory(ev, stable_path, parent_depth),
            else => return err,
        };
    const source_base = std.fs.path.dirname(stable_path) orelse "/";
    return ev.evaluateSource(source, source_base, stable_path, null, parent_depth);
}

pub fn scopedImportPath(ev: anytype, scope: Value, path: []const u8, parent_depth: u32) !Value {
    const resolved = try ev.resolveHostPath(path);
    defer if (resolved.owned) ev.allocator.free(resolved.text);
    return scopedImportResolvedPath(ev, scope, resolved.text, parent_depth);
}

pub fn scopedImportResolvedPath(ev: anytype, scope: Value, path: []const u8, parent_depth: u32) anyerror!Value {
    const stable_path = try ev.allocator.dupe(u8, path);
    defer ev.allocator.free(stable_path);

    try checkScopedCycle(stable_path);
    var frame: ScopedFrame = .{ .path = stable_path, .next = null };
    const prev = pushScopedFrame(&frame);
    defer popScopedFrame(prev);

    ev.progressBegin(.import, stable_path);
    defer ev.progressEnd(.import, stable_path);
    timeline.instant(.import, stable_path);

    const source = if (corepkgsSource(stable_path)) |core_source|
        core_source
    else
        ev.files.readFile(stable_path) catch |err| switch (err) {
            error.IsDir => return scopedImportDirectory(ev, scope, stable_path, parent_depth),
            else => return err,
        };
    const source_base = std.fs.path.dirname(stable_path) orelse "/";
    return ev.evaluateSource(source, source_base, stable_path, scope, parent_depth);
}

pub fn importDirectory(ev: anytype, path: []const u8, parent_depth: u32) anyerror!Value {
    const default_path = try std.fs.path.resolve(ev.allocator, &.{ path, "default.nix" });
    defer ev.allocator.free(default_path);
    return importResolvedPath(ev, default_path, parent_depth);
}

pub fn scopedImportDirectory(ev: anytype, scope: Value, path: []const u8, parent_depth: u32) anyerror!Value {
    const default_path = try std.fs.path.resolve(ev.allocator, &.{ path, "default.nix" });
    defer ev.allocator.free(default_path);
    return scopedImportResolvedPath(ev, scope, default_path, parent_depth);
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
