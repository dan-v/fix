//! Path-based import resolution: dedup, cycle detection, file read,
//! and the back-call into the evaluator for parse+compile+eval.
//!
//! `ImportEntry` is a fiber-park claim+wait protocol: the first fiber
//! to cmpxchg UNRESOLVED→EVALUATING runs `compileImportPath` inline.
//! Concurrent fibers enroll on the entry's waiter list and yield —
//! their workers drain other work meanwhile. When the claimer
//! publishes, the resolver drains the waiter list and each parked
//! fiber observes the terminal state. Same model as `Thunk`.
//!
//! There is no main/helper asymmetry: every fiber follows the same
//! claim-or-park protocol. Cycle detection is per-fiber by
//! `ClaimerId` (stable across migration).
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
const thunk_mod = @import("../runtime/thunk.zig");
const fiber_mod = @import("../fiber.zig");
const worker_mod = @import("../worker.zig");
const stable = @import("../runtime/stable_segments.zig");

/// Path → in-flight `ImportEntry`. The mutex is held only briefly
/// during lookup/insert; the entry's own atomics + waiter list
/// coordinate the actual evaluation.
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
    /// Globally-unique fiber id of the claimer (matches
    /// `VM.claimer_id`). `INVALID_CLAIMER` when unclaimed. Same-fiber
    /// re-entry while `EVALUATING` is `error.ImportCycle`.
    claimer: std.atomic.Value(thunk_mod.ClaimerId) = .init(thunk_mod.INVALID_CLAIMER),
    result: Value = Value.null_val,
    /// Fibers parked on this entry. Manipulated only under
    /// `waiters_mu`. The resolver drains outside the lock so a slow
    /// wake doesn't block other resolvers — mirrors
    /// `Thunk.wakeFiberWaiters`.
    waiters_head: ?*thunk_mod.Waiter = null,
    waiters_mu: stable.SpinMutex = .{},

    pub fn enrollWaiter(self: *ImportEntry, waiter: *thunk_mod.Waiter) bool {
        self.waiters_mu.lock();
        defer self.waiters_mu.unlock();
        if (self.state.load(.acquire) != STATE_EVALUATING) return false;
        waiter.next = self.waiters_head;
        self.waiters_head = waiter;
        return true;
    }

    fn wakeWaiters(self: *ImportEntry) void {
        self.waiters_mu.lock();
        var head = self.waiters_head;
        self.waiters_head = null;
        self.waiters_mu.unlock();
        while (head) |w| {
            const next = w.next;
            w.next = null;
            w.wake_fn(w);
            head = next;
        }
    }

    pub fn publishResolved(self: *ImportEntry, value: Value) void {
        self.result = value;
        self.claimer.store(thunk_mod.INVALID_CLAIMER, .release);
        self.state.store(STATE_RESOLVED, .release);
        self.wakeWaiters();
    }

    pub fn publishFailed(self: *ImportEntry) void {
        self.claimer.store(thunk_mod.INVALID_CLAIMER, .release);
        self.state.store(STATE_FAILED, .release);
        self.wakeWaiters();
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

/// Drive the claim protocol on `entry`. The first fiber to CAS
/// UNRESOLVED→EVALUATING runs `compileImportPath` inline; concurrent
/// fibers enroll on the waiter list and yield until the claimer
/// publishes a terminal state. Cycle detection is per-fiber: same
/// fiber id observing its own claim → `error.ImportCycle`.
pub fn forceEntry(ev: anytype, path: []const u8, entry: *ImportEntry) anyerror!Value {
    const me = currentClaimer();
    while (true) {
        const state = entry.state.load(.acquire);
        switch (state) {
            ImportEntry.STATE_RESOLVED => return entry.result,
            ImportEntry.STATE_FAILED => return error.ImportFailed,
            ImportEntry.STATE_EVALUATING => {
                if (entry.claimer.load(.acquire) == me) return error.ImportCycle;
                const inner = fiber_mod.currentFiber() orelse
                    @panic("forceEntry hit EVALUATING outside a fiber");
                const wf: *worker_mod.Fiber = @fieldParentPtr("inner", inner);
                if (entry.enrollWaiter(&wf.waiter)) {
                    wf.state = .suspended;
                    fiber_mod.Fiber.yield();
                    wf.state = .running;
                }
                continue;
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
                    entry.publishFailed();
                    return err;
                };
                entry.publishResolved(value);
                return value;
            },
            else => unreachable,
        }
    }
}

fn currentClaimer() thunk_mod.ClaimerId {
    const inner = fiber_mod.currentFiber() orelse return thunk_mod.INVALID_CLAIMER;
    const wf: *worker_mod.Fiber = @fieldParentPtr("inner", inner);
    return wf.vm.claimer_id;
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
