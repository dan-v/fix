//! DerivationStore: the evaluation-wide registry mapping each .drv path to its
//! hash-modulo and output names (the resolver for input-addressed hashing),
//! plus the lazy-derivation Value cache and optional debug-record capture.
//! Read-mostly but written from any worker thread: `mu` guards the record maps
//! and a separate `lazy_drv_mu` spinlock guards the lazy value cache.

const std = @import("std");
const builtin = @import("builtin");
const derivation = @import("../derivation.zig");
const drv_mod = derivation.drv;
const types = derivation.types;
const stable = @import("base").sync;
const runtime = @import("runtime");
const host = @import("../host.zig");
const rstore = host.store;
const FileCache = host.FileCache;
const DaemonRuntime = host.DaemonRuntime;
const Future = runtime.thunk.Future;
const Waiter = runtime.thunk.Waiter;
const eval_memo = @import("eval_memo.zig");
const recipe_graph = @import("recipe_graph.zig");

/// Injected `vm.io_offload.runOnPool`: submit `work(conn)` to the pool and park
/// the caller. `ctx` is the `*DaemonPool`; `conn` is the worker's connection.
const OffloadFn = *const fn (ctx: *anyopaque, work: *const fn (conn: ?*anyopaque, work_ctx: *anyopaque) void, work_ctx: *anyopaque) void;

/// Injected `vm.io_offload.fiberPark`: park the current compute fiber on `future`
/// (a realization claim). Returns false if not on a fiber — the caller then waits
/// on the thread itself (the main-thread realize / tests).
const FiberParkFn = *const fn (future: *Future) bool;

/// The progress-span groups the derivation store reports into. Mirrors the
/// observ `SpanGroup`, but named locally: the derivation module must not import
/// observ (same layer), so the eval layer maps these onto the real groups.
pub const SpanGroup = recipe_graph.SpanGroup;

/// Injected concurrent progress-span hooks for the store's real writes: a
/// `.store` span around a `.drv` transfer and a `.source` span around a source
/// copy, both reported in `applyDaemonOp` past the `isValidPath` guard (so the
/// counts are actual writes, not per-coercion / per-recorded-recipe). The eval
/// layer adapts its observ `SpanSink` into these opaque fn pointers. `begin`
/// opens a span labeled with `label` and returns its token; `end` closes it.
/// A span may open on a pool worker / compute fiber and close after the write.
const SpanBeginFn = *const fn (ctx: *anyopaque, group: SpanGroup, label: []const u8) usize;
const SpanEndFn = *const fn (ctx: *anyopaque, token: usize) void;
const SpanHooks = struct {
    ctx: *anyopaque,
    begin: SpanBeginFn,
    end: SpanEndFn,
};

/// The daemon connection the current thread's in-flight op runs against. Set at
/// each offload boundary (a pool worker running one op, or the inline dispatch)
/// so the whole nested closure walk — `ensureClosure` → writes/queries — reaches
/// its connection without threading a `conn` parameter through every function.
/// Per-thread: each pool worker has its own, concurrent walks never collide, and
/// the parked submitting fiber never runs the closure itself.
threadlocal var active_conn: ?*rstore.DaemonStore = null;

const DebugRecord = types.DebugRecord;
const ComputedPaths = types.ComputedPaths;
const Drv = drv_mod.Drv;
const DrvOutput = types.DrvOutput;
const HashModuloResolver = types.HashModuloResolver;
const HashModuloView = types.HashModuloView;

/// Thread safety: all access to `records` and `debug_records` goes through
/// `mu`. The store is read-mostly during evaluation but writes (record /
/// recordDebug) happen on whichever worker forces the originating thunk.
/// The name portion of a store path: `/nix/store/<hash>-<name>` -> `<name>`.
/// Store hashes are 32 base32 chars followed by `-`. Used as the `name` arg to
/// `addTextToStore`, which recomputes the full path from name+content+refs.
fn storePathName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (base.len > 33 and base[32] == '-') return base[33..];
    return base;
}

pub const DerivationStore = struct {
    allocator: std.mem.Allocator,
    store_dir: []const u8 = "/nix/store",
    registry: derivation.Registry,
    memo: eval_memo.EvalMemo,
    graph: recipe_graph.Graph,

    /// Guards the small shared state every pool worker touches: the `instantiated`
    /// cache and `last_error_msg`. Held only for brief in-memory updates, never
    /// across a daemon round-trip (those run on the worker's own connection).
    daemon_mu: stable.BlockingMutex = .{},
    /// First failing daemon op's message, copied out of its (transient) pool
    /// connection so `lastStoreError` can surface it after the op is gone.
    last_error_msg: ?[]u8 = null,
    /// Store paths we've already ensured are present this run — either because
    /// we wrote them, or because a pre-write `isValidPath` confirmed the daemon
    /// already has them. Both cases mean a re-force can skip re-sending the
    /// bytes. Empty at process start, so the first force of an already-present
    /// path pays one cheap `isValidPath` round-trip instead of streaming the
    /// whole text/NAR the daemon would just hash and discard.
    instantiated: std.StringHashMapUnmanaged(void) = .empty,
    io: ?std.Io = null,
    /// Path to the nix-daemon socket. Defaults to Nix's well-known location;
    /// `setDaemonSocket` (from `$NIX_DAEMON_SOCKET_PATH`) overrides it, pointing
    /// at `daemon_socket_owned`.
    daemon_socket: []const u8 = rstore.default_socket_path,
    daemon_socket_owned: ?[]u8 = null,
    /// Per-connection daemon settings (`--cores`/`--max-jobs`/`--fallback`/…),
    /// sent via `set_options` right after the handshake. Null = send nothing
    /// (the daemon uses its own config). Its `overrides` slice is owned via
    /// `daemon_overrides` below.
    daemon_options: ?rstore.BuildSettings = null,
    daemon_overrides: std.ArrayListUnmanaged(rstore.Setting) = .empty,
    /// Whether forced derivations, their sources, and fetched trees are
    /// materialized to the store (`fix instantiate`/`build` enable it). Off for
    /// plain `eval` so the hot eval path never does store I/O per derivation
    /// and fetches stay local/offline (returning their download-cache path).
    store_writes_enabled: bool = false,

    /// Concurrent progress-span hooks for real store writes (see `SpanHooks`):
    /// a `.store` span per actual `.drv` transfer, a `.source` span per actual
    /// source copy — both reported in `applyDaemonOp`, past the validity guard.
    /// Set by the evaluator alongside the demand-fiber stage sink. They count
    /// actual writes — not per instantiated derivation / per coercion, which only
    /// record an in-memory recipe or hit the memo. Null when progress isn't drawn.
    span_hooks: ?SpanHooks = null,

    /// The pool-offload entry (`vm.io_offload.runOnPool`), injected by the eval
    /// layer: submits one daemon op to `pool` and parks the caller (fiber yields).
    /// Null → no fiber machinery (tests): the pool's `submitBlocking` runs the op
    /// on a worker and blocks the caller. Either way every op goes to the pool.
    offload_run: ?OffloadFn = null,
    /// Injected fiber-park for a realization-claim wait (null in tests → the
    /// waiter blocks its thread on a semaphore instead).
    fiber_park: ?FiberParkFn = null,
    /// The Evaluator- (or test-) owned runtime that owns the connection pool.
    daemon_runtime: ?*DaemonRuntime = null,
    /// The hot-connection pool, obtained from `daemon_runtime` — started eagerly
    /// by `enableStoreWrites` (store-writing commands) so connections warm while
    /// eval runs, or lazily on the first daemon op for plain-eval IFD. Guarded by
    /// `pool_mu`.
    pool: ?*rstore.DaemonPool = null,
    pool_mu: stable.BlockingMutex = .{},
    /// Test-only: a `DaemonRuntime` the test harness had this store own (so tests
    /// don't manage its lifetime separately). Deinitialized + freed in `deinit`.
    test_owned_runtime: if (builtin.is_test) ?*DaemonRuntime else void = if (builtin.is_test) null else {},

    pub const RootClaimHook = recipe_graph.RootClaimHook;

    pub fn setRootClaimHookForTest(self: *DerivationStore, hook: ?RootClaimHook) void {
        if (comptime builtin.is_test) {
            self.graph.test_root_claim_hook = hook;
        } else unreachable;
    }

    /// Test-only producer-boundary seam. Producers call this after the owned
    /// allocation is created, independently of whether registration succeeds.
    pub fn noteProducerPayloadForTest(self: *DerivationStore, store_path: []const u8, payload: []const u8) !void {
        if (comptime builtin.is_test) {
            self.graph.mu.lock();
            defer self.graph.mu.unlock();
            const owned_path = try self.allocator.dupe(u8, store_path);
            const result = self.graph.test_producer_payload_pointers.getOrPut(self.allocator, owned_path) catch |err| {
                self.allocator.free(owned_path);
                return err;
            };
            if (result.found_existing) {
                self.allocator.free(owned_path);
            } else {
                result.value_ptr.* = .empty;
            }
            const pointer = @intFromPtr(payload.ptr);
            for (result.value_ptr.items) |observed| if (observed == pointer) return;
            result.value_ptr.append(self.allocator, pointer) catch |err| {
                if (!result.found_existing) {
                    const removed = self.graph.test_producer_payload_pointers.fetchRemove(store_path).?;
                    self.allocator.free(removed.key);
                }
                return err;
            };
        }
    }

    /// Consume the allocation observations for `store_path`, returning the one
    /// actually retained by the recipe. A non-matching first observation keeps
    /// identity failures visible. Consumption prevents stale-map false passes.
    pub fn producerPayloadPointerForTest(self: *DerivationStore, store_path: []const u8) ?usize {
        if (comptime builtin.is_test) {
            self.graph.mu.lock();
            defer self.graph.mu.unlock();
            var removed = self.graph.test_producer_payload_pointers.fetchRemove(store_path) orelse return null;
            defer self.allocator.free(removed.key);
            defer removed.value.deinit(self.allocator);
            const retained = if (self.graph.recipes.get(store_path)) |recipe| recipe.payloadPointer() else null;
            if (retained) |pointer| {
                for (removed.value.items) |observed| if (observed == pointer) return observed;
            }
            return if (removed.value.items.len == 0) null else removed.value.items[0];
        } else return null;
    }

    pub const RecipeVariantForTest = recipe_graph.RecipeVariantForTest;

    pub fn recipeCountForTest(self: *DerivationStore) usize {
        if (comptime builtin.is_test) {
            self.graph.mu.lock();
            defer self.graph.mu.unlock();
            return self.graph.recipes.count();
        } else return 0;
    }

    pub fn recipeVariantForTest(self: *DerivationStore, store_path: []const u8) ?RecipeVariantForTest {
        if (comptime builtin.is_test) {
            self.graph.mu.lock();
            defer self.graph.mu.unlock();
            const recipe = self.graph.recipes.get(store_path) orelse return null;
            return switch (recipe.payload) {
                .text => .text,
                .nar => .nar,
                .flat => .flat,
            };
        } else return null;
    }

    pub fn recipePayloadPointerForTest(self: *DerivationStore, store_path: []const u8) ?usize {
        if (comptime builtin.is_test) {
            self.graph.mu.lock();
            defer self.graph.mu.unlock();
            return (self.graph.recipes.get(store_path) orelse return null).payloadPointer();
        } else return null;
    }

    pub fn recipePayloadBytesForTest(self: *DerivationStore, store_path: []const u8) ?[]const u8 {
        if (comptime builtin.is_test) {
            self.graph.mu.lock();
            defer self.graph.mu.unlock();
            const recipe = self.graph.recipes.get(store_path) orelse return null;
            return switch (recipe.payload) {
                .text => |text| text.bytes,
                .nar => |bytes| bytes,
                .flat => |bytes| bytes.bytes(),
            };
        } else return null;
    }

    pub fn recipeReferencesForTest(self: *DerivationStore, store_path: []const u8) ?[]const []const u8 {
        if (comptime builtin.is_test) {
            self.graph.mu.lock();
            defer self.graph.mu.unlock();
            return (self.graph.recipes.get(store_path) orelse return null).references();
        } else return null;
    }

    /// A source-memo hit, with slices duplicated into the *caller's* allocator
    /// so it can be dropped into an `Ingested` (which is caller-owned).
    pub const SourceMemoHit = eval_memo.SourceMemoHit;

    pub const PendingFetch = recipe_graph.PendingFetch;

    /// Register a deferred fetch for `store_path` (no-op if one already exists).
    pub fn recordPendingFetch(self: *DerivationStore, store_path: []const u8, url: []const u8, name: []const u8, recursive: bool, hash_hex: []const u8) !void {
        return self.graph.recordPendingFetch(store_path, url, name, recursive, hash_hex);
    }

    /// Return an owned copy of the deferred fetch for exactly `store_path`, or
    /// null. The entry is left in place — concurrent demands each materialize
    /// against the (memoized) fetch cache; `removePendingFetch` drops it once a
    /// flat file is seeded. Caller owns the copy and must `deinit` it.
    pub fn peekPendingFetch(self: *DerivationStore, store_path: []const u8) !?PendingFetch {
        return self.graph.peekPendingFetch(store_path);
    }

    pub fn removePendingFetch(self: *DerivationStore, store_path: []const u8) void {
        self.graph.removePendingFetch(store_path);
    }

    const Recipe = recipe_graph.Recipe;
    const RealizationClaim = recipe_graph.Claim;

    pub fn init(allocator: std.mem.Allocator) DerivationStore {
        return .{
            .allocator = allocator,
            .registry = derivation.Registry.init(allocator),
            .memo = eval_memo.EvalMemo.init(allocator),
            .graph = recipe_graph.Graph.init(allocator),
        };
    }

    pub fn deinit(self: *DerivationStore) void {
        // Tear down a test-owned runtime first (joins pool workers → closes their
        // connections), before the fake daemon it talks to is stopped.
        if (comptime builtin.is_test) {
            if (self.test_owned_runtime) |rt| {
                rt.deinit();
                self.allocator.destroy(rt);
                self.test_owned_runtime = null;
            }
        }
        self.graph.deinit();
        self.registry.deinit();
        self.memo.deinit();
        var inst = self.instantiated.keyIterator();
        while (inst.next()) |key| self.allocator.free(key.*);
        self.instantiated.deinit(self.allocator);
        for (self.daemon_overrides.items) |o| {
            self.allocator.free(o.name);
            self.allocator.free(o.value);
        }
        self.daemon_overrides.deinit(self.allocator);
        if (self.daemon_socket_owned) |owned| self.allocator.free(owned);
        if (self.last_error_msg) |msg| self.allocator.free(msg);
    }

    /// Set the per-connection daemon settings to apply on connect. Dupes the
    /// overrides into owned storage (freed in `deinit`).
    pub fn setBuildSettings(self: *DerivationStore, settings: rstore.BuildSettings) !void {
        for (self.daemon_overrides.items) |o| {
            self.allocator.free(o.name);
            self.allocator.free(o.value);
        }
        self.daemon_overrides.clearRetainingCapacity();
        for (settings.overrides) |o| {
            try self.daemon_overrides.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, o.name),
                .value = try self.allocator.dupe(u8, o.value),
            });
        }
        var owned = settings;
        owned.overrides = self.daemon_overrides.items;
        self.daemon_options = owned;
    }

    /// Override the nix-daemon socket path (from `$NIX_DAEMON_SOCKET_PATH`).
    /// Dupes `path` into owned storage (freed in `deinit`); a no-op if empty.
    pub fn setDaemonSocket(self: *DerivationStore, path: []const u8) !void {
        if (path.len == 0) return;
        const owned = try self.allocator.dupe(u8, path);
        if (self.daemon_socket_owned) |old| self.allocator.free(old);
        self.daemon_socket_owned = owned;
        self.daemon_socket = owned;
    }

    /// Provide the IO handle used to connect to the daemon on demand.
    pub fn setIo(self: *DerivationStore, io: std.Io) void {
        self.io = io;
    }

    /// Enable writing forced derivations + their sources to the store
    /// (`fix instantiate`/`build`). Off by default so plain eval stays pure.
    /// Eagerly starts the connection pool (io + socket + options are configured
    /// by now) so its connections warm concurrently with eval instead of on a
    /// compute fiber's critical path at the first store op.
    pub fn enableStoreWrites(self: *DerivationStore) void {
        self.store_writes_enabled = true;
        _ = self.ensurePool() catch {};
    }

    /// Install (or clear) the concurrent progress-span hooks. A null `ctx` clears
    /// them (progress not drawn). Set by the evaluator when a progress sink is
    /// (re)installed; safe to change between top-level runs.
    pub fn setSpanHooks(self: *DerivationStore, ctx: ?*anyopaque, begin: SpanBeginFn, end: SpanEndFn) void {
        self.span_hooks = if (ctx) |c| .{ .ctx = c, .begin = begin, .end = end } else null;
    }

    /// Open a concurrent progress span for real store work, or null when progress
    /// isn't drawn. Pair with `endSpan` (defer). The label is borrowed for the
    /// call only. See `SpanHooks`.
    pub fn beginSpan(self: *DerivationStore, group: SpanGroup, label: []const u8) ?usize {
        const hooks = self.span_hooks orelse return null;
        return hooks.begin(hooks.ctx, group, label);
    }

    /// Close a span opened by `beginSpan` (no-op on null / no hooks).
    pub fn endSpan(self: *DerivationStore, token: ?usize) void {
        const t = token orelse return;
        const hooks = self.span_hooks orelse return;
        hooks.end(hooks.ctx, t);
    }

    /// Install the pool-offload entry (from the vm layer). Must be set before any
    /// forcing begins, and cleared (`clearOffload`) before the runtime is torn
    /// down. `rt` owns the connection pool this store submits to.
    pub fn setOffload(self: *DerivationStore, rt: *DaemonRuntime, run: OffloadFn, fiber_park: FiberParkFn) void {
        self.daemon_runtime = rt;
        self.offload_run = run;
        self.fiber_park = fiber_park;
    }

    pub fn clearOffload(self: *DerivationStore) void {
        self.offload_run = null;
        self.fiber_park = null;
        self.daemon_runtime = null;
        self.pool = null;
    }

    /// Test-only: hand this store a `DaemonRuntime` to use (as its pool source)
    /// and own (torn down in `deinit`). No `offload_run`, so ops go through the
    /// pool's blocking submit. See `recipe_tests`.
    pub fn setTestRuntime(self: *DerivationStore, rt: *DaemonRuntime) void {
        if (comptime !builtin.is_test) unreachable;
        self.daemon_runtime = rt;
        self.test_owned_runtime = rt;
    }

    /// The connection pool, starting it on first need (idempotent). Errors if no
    /// runtime/io was installed (tests / `fix store`, which use the inline path).
    fn ensurePool(self: *DerivationStore) !*rstore.DaemonPool {
        self.pool_mu.lock();
        defer self.pool_mu.unlock();
        if (self.pool) |p| return p;
        const rt = self.daemon_runtime orelse return error.StoreUnavailable;
        const io = self.io orelse return error.StoreUnavailable;
        const p = try rt.ensurePool(self.allocator, io, self.daemon_socket, self.daemon_options, self.store_writes_enabled);
        self.pool = p;
        return p;
    }

    /// The connection the current op runs against (see `active_conn`). A null
    /// means the pool worker could not open a connection — surface it as the
    /// store being unavailable rather than dereferencing null.
    fn currentConn(_: *DerivationStore) !*rstore.DaemonStore {
        return active_conn orelse error.StoreUnavailable;
    }

    /// Run one daemon op: submit it to the pool and park the caller (a compute
    /// fiber yields; the main thread / tests block). `work(conn)` reads its
    /// connection through `active_conn`, set by whichever pool worker runs it.
    fn runOnDaemon(self: *DerivationStore, work: *const fn (conn: ?*anyopaque, work_ctx: *anyopaque) void, work_ctx: *anyopaque) !void {
        const p = try self.ensurePool();
        if (self.offload_run) |offload| {
            offload(p, work, work_ctx);
        } else {
            p.submitBlocking(work, work_ctx);
        }
    }

    /// Copy a failing op's daemon message out of its (transient) pool connection
    /// so `lastStoreError` can surface it after the connection is reused. First
    /// writer wins.
    fn captureDaemonError(self: *DerivationStore, conn: *rstore.DaemonStore) void {
        const msg = conn.last_error orelse return;
        self.daemon_mu.lock();
        defer self.daemon_mu.unlock();
        if (self.last_error_msg != null) return;
        self.last_error_msg = self.allocator.dupe(u8, msg) catch null;
    }

    /// Read the last daemon error message (for surfacing `error.DaemonError`),
    /// captured from the pool connection whose op failed.
    pub fn lastStoreError(self: *DerivationStore) ?[]const u8 {
        self.daemon_mu.lock();
        defer self.daemon_mu.unlock();
        return self.last_error_msg;
    }

    /// Write `drv_path`'s `.drv` to the store (text-addressed), gated on
    /// `store_writes_enabled`. Inputs are forced before dependents, so a
    /// `.drv`'s referenced input `.drv`s are already written when we get here.
    pub fn instantiateDrv(self: *DerivationStore, drv_path: []const u8, aterm: []const u8, references: []const []const u8) !void {
        return self.instantiateText(drv_path, aterm, references);
    }

    /// Write a text-addressed object (a `.drv` or `builtins.toFile` result),
    /// gated on `store_writes_enabled` (off during plain eval).
    pub fn instantiateText(self: *DerivationStore, store_path: []const u8, text: []const u8, references: []const []const u8) !void {
        if (!self.store_writes_enabled) return;
        return self.runDaemonOp(.{ .text = .{ .store_path = store_path, .text = text, .references = references } }, .store);
    }

    /// Write a NAR-serialized source tree, gated on `store_writes_enabled`.
    /// Sources ingest during derivation normalization — before the `.drv` that
    /// references them — so `input_srcs` are valid in time.
    pub fn instantiatePath(self: *DerivationStore, store_path: []const u8, nar_bytes: []const u8) !void {
        if (!self.store_writes_enabled) return;
        // Used by `ingestSerializedNar` (fetchTarball) — a fetch, shown under `.fetch`.
        return self.runDaemonOp(.{ .path = .{ .store_path = store_path, .nar_bytes = nar_bytes } }, null);
    }

    /// Add a flat file's raw bytes to the store (fetchurl), gated on
    /// `store_writes_enabled`.
    pub fn instantiateFlat(self: *DerivationStore, store_path: []const u8, bytes: []const u8) !void {
        if (!self.store_writes_enabled) return;
        return self.runDaemonOp(.{ .flat = .{ .store_path = store_path, .bytes = bytes } }, null);
    }

    /// Is `store_path` already valid in the store? Used to skip fetching an
    /// input we already have (content-addressed, so a valid path for a given
    /// hash IS the right content). Only meaningful with store writes enabled
    /// (else there is no daemon); returns false otherwise. Offloaded like the
    /// writes so the calling fiber parks rather than blocking on the socket.
    pub fn pathIsValid(self: *DerivationStore, store_path: []const u8) !bool {
        if (!self.store_writes_enabled) return false;
        return self.queryPathValid(store_path);
    }

    fn queryPathValid(self: *DerivationStore, store_path: []const u8) !bool {
        // Caller-side cache hit: skip the pool round-trip entirely (the closure
        // walk hits this for every already-present path).
        if (self.cacheContains(store_path)) return true;
        var cell: QueryCell = .{ .store = self, .store_path = store_path };
        try self.runOnDaemon(QueryCell.run, &cell);
        if (cell.err) |e| return e;
        return cell.valid;
    }

    const QueryCell = struct {
        store: *DerivationStore,
        store_path: []const u8,
        valid: bool = false,
        err: ?anyerror = null,

        fn run(conn: ?*anyopaque, p: *anyopaque) void {
            const c: *QueryCell = @ptrCast(@alignCast(p));
            const prev = active_conn;
            active_conn = if (conn) |x| @ptrCast(@alignCast(x)) else null;
            defer active_conn = prev;
            c.valid = c.store.applyIsValid(c.store_path) catch |e| {
                c.err = e;
                return;
            };
        }
    };

    /// `isValidPath` against the current connection (`active_conn`), consulting +
    /// populating the `instantiated` cache. The daemon round-trip runs without
    /// `daemon_mu` held (it guards only the brief cache touches), so concurrent
    /// pool workers don't serialize on it.
    fn applyIsValid(self: *DerivationStore, store_path: []const u8) !bool {
        if (self.cacheContains(store_path)) return true;
        const conn = try self.currentConn();
        const valid = try conn.isValidPath(store_path);
        // A path valid now stays valid for the eval (same assumption the cache
        // already makes for writes), so a later demand skips the round-trip.
        if (valid) self.cacheMark(store_path);
        return valid;
    }

    /// Realize `derived_paths` (`<drvpath>!<outputs>`, legacy format) via the
    /// daemon, forwarding the build activity/log stream to `sink` if given.
    /// Dispatched to the pool (fiber parks / main thread blocks) so the whole
    /// build runs on a warm worker connection, not a compute worker.
    pub fn buildPaths(self: *DerivationStore, derived_paths: []const []const u8, sink: ?rstore.BuildSink, mode: rstore.BuildMode) !void {
        var cell: BuildCell = .{ .store = self, .paths = derived_paths, .sink = sink, .mode = mode };
        try self.runOnDaemon(BuildCell.run, &cell);
        return cell.err;
    }

    /// Realize `derived_paths` for import-from-derivation. Same as `buildPaths`;
    /// kept as a distinct entry for the `run`/`shell` realize call sites.
    pub fn realizePaths(self: *DerivationStore, derived_paths: []const []const u8, mode: rstore.BuildMode) !void {
        return self.buildPaths(derived_paths, null, mode);
    }

    /// Build against the current connection (used both by `BuildCell` and, inside
    /// an already-active op, by `realizeOutputInline`'s build step).
    fn buildOnConn(self: *DerivationStore, derived_paths: []const []const u8, sink: ?rstore.BuildSink, mode: rstore.BuildMode) !void {
        const conn = try self.currentConn();
        conn.buildPaths(derived_paths, sink, mode) catch |err| {
            self.captureDaemonError(conn);
            return err;
        };
    }

    const BuildCell = struct {
        store: *DerivationStore,
        paths: []const []const u8,
        sink: ?rstore.BuildSink = null,
        mode: rstore.BuildMode,
        err: anyerror!void = {},

        fn run(conn: ?*anyopaque, p: *anyopaque) void {
            const self: *BuildCell = @ptrCast(@alignCast(p));
            const prev = active_conn;
            active_conn = if (conn) |x| @ptrCast(@alignCast(x)) else null;
            defer active_conn = prev;
            self.err = self.store.buildOnConn(self.paths, self.sink, self.mode);
        }
    };

    /// Register `link_path` (an existing absolute symlink into the store) as an
    /// indirect GC root via the daemon.
    pub fn addIndirectRoot(self: *DerivationStore, link_path: []const u8) !void {
        var cell: RootCell = .{ .store = self, .link_path = link_path };
        try self.runOnDaemon(RootCell.run, &cell);
        return cell.err;
    }

    const RootCell = struct {
        store: *DerivationStore,
        link_path: []const u8,
        err: anyerror!void = {},

        fn run(conn: ?*anyopaque, p: *anyopaque) void {
            const self: *RootCell = @ptrCast(@alignCast(p));
            const prev = active_conn;
            active_conn = if (conn) |x| @ptrCast(@alignCast(x)) else null;
            defer active_conn = prev;
            self.err = blk: {
                const c = self.store.currentConn() catch |e| break :blk e;
                break :blk c.addIndirectRoot(self.link_path);
            };
        }
    };

    const DaemonOp = union(enum) {
        text: struct { store_path: []const u8, text: []const u8, references: []const []const u8 },
        path: struct { store_path: []const u8, nar_bytes: []const u8 },
        flat: struct { store_path: []const u8, bytes: []const u8 },
    };

    /// Dispatch a store write to the pool (parking the caller) or inline. The op's
    /// args are borrowed and stay valid across the transfer because the calling
    /// fiber parks (its stack — holding the NAR/text buffers — is preserved).
    /// `span_group` is the progress group the actual transfer reports under (null
    /// for writes shown elsewhere, e.g. fetches under `.fetch`).
    fn runDaemonOp(self: *DerivationStore, op: DaemonOp, span_group: ?SpanGroup) !void {
        var cell: OpCell = .{ .store = self, .op = op, .span_group = span_group };
        try self.runOnDaemon(OpCell.run, &cell);
        return cell.err;
    }

    const OpCell = struct {
        store: *DerivationStore,
        op: DaemonOp,
        span_group: ?SpanGroup = null,
        err: anyerror!void = {},

        fn run(conn: ?*anyopaque, p: *anyopaque) void {
            const self: *OpCell = @ptrCast(@alignCast(p));
            const prev = active_conn;
            active_conn = if (conn) |x| @ptrCast(@alignCast(x)) else null;
            defer active_conn = prev;
            self.err = self.store.applyDaemonOp(self.op, self.span_group);
        }
    };

    /// Perform a store write against the current connection. Skips the transfer
    /// when the path is already valid (cache or a daemon check). Cache touches are
    /// briefly guarded; the daemon round-trips run without `daemon_mu`.
    fn applyDaemonOp(self: *DerivationStore, op: DaemonOp, span_group: ?SpanGroup) !void {
        const store_path = switch (op) {
            inline else => |o| o.store_path,
        };
        if (self.cacheContains(store_path)) return;
        const daemon = try self.currentConn();
        if (try daemon.isValidPath(store_path)) return self.cacheMark(store_path);
        // Report a progress span around the actual transfer, under the caller's
        // group: `.store` for a `.drv`, `.source` for a local source copy, null for
        // a fetch (shown under `.fetch` at download). Reporting here — only past the
        // validity guard — means the count is actual writes, not coercions/records.
        // The span may open here (on a pool worker) and close after the write.
        const span_token: ?usize = if (span_group) |group| self.beginSpan(group, storePathName(store_path)) else null;
        defer self.endSpan(span_token);
        const written = switch (op) {
            .text => |o| daemon.addTextToStore(self.allocator, storePathName(store_path), o.text, o.references),
            .path => |o| daemon.addPath(self.allocator, storePathName(store_path), o.nar_bytes, &.{}),
            .flat => |o| daemon.addFlatFile(self.allocator, storePathName(store_path), o.bytes, &.{}),
        } catch |err| {
            self.captureDaemonError(daemon);
            return err;
        };
        self.allocator.free(written);
        self.cacheMark(store_path);
    }

    /// Is `store_path` known present this run? Guarded read of `instantiated`.
    fn cacheContains(self: *DerivationStore, store_path: []const u8) bool {
        self.daemon_mu.lock();
        defer self.daemon_mu.unlock();
        return self.instantiated.contains(store_path);
    }

    /// Record `store_path` as present (a write landed, or a query confirmed it).
    /// Best-effort: a cache-insert OOM just means a later redundant round-trip.
    fn cacheMark(self: *DerivationStore, store_path: []const u8) void {
        self.daemon_mu.lock();
        defer self.daemon_mu.unlock();
        self.markInstantiated(store_path) catch {};
    }

    fn markInstantiated(self: *DerivationStore, store_path: []const u8) !void {
        const key = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(key);
        try self.instantiated.put(self.allocator, key, {});
    }

    pub fn recordOwnedTextRecipe(self: *DerivationStore, store_path: []const u8, text: []u8, references: []const []const u8) !void {
        return self.graph.recordOwnedText(store_path, text, references);
    }

    pub fn recordOwnedNarRecipe(self: *DerivationStore, store_path: []const u8, nar_bytes: []u8) !void {
        return self.graph.recordOwnedNar(store_path, nar_bytes);
    }

    /// `span_group` names the progress group the eventual write reports under —
    /// `.source` for a flat local source (`builtins.path { recursive = false; }`),
    /// null for a fetched flat file (shown under `.fetch` at download time).
    pub fn recordFlatRecipe(self: *DerivationStore, store_path: []const u8, handle: FileCache.ImmutableBytes, span_group: ?SpanGroup) !void {
        return self.graph.recordFlat(store_path, handle, span_group);
    }

    pub fn releaseRecipePayloads(self: *DerivationStore) void {
        self.graph.releaseRecipePayloads();
    }

    const Visit = struct {
        path: []const u8,
        claim: *RealizationClaim,
        parent: ?*const Visit,
    };

    /// Materialize `store_path`'s closure. Runs on the DEMANDING caller — a
    /// compute fiber for IFD (`demandPathArg`), the main thread for the terminal
    /// realize/instantiate — so a wait on another realizer's claim is a normal
    /// fiber park (or a thread block off a fiber). Only the individual daemon
    /// round-trips (queries/writes/builds) are offloaded to the pool.
    pub fn ensureClosure(self: *DerivationStore, store_path: []const u8) anyerror!void {
        return self.ensureClosureInner(store_path, null);
    }

    fn ensureClosureInner(self: *DerivationStore, store_path: []const u8, parent: ?*const Visit) anyerror!void {
        while (true) {
            // Deps-first: a path's references are realized (and land in the store)
            // before the path itself. Each daemon round-trip goes to the pool; a
            // concurrent realizer of the same path deduplicates via the claim.
            if (try self.queryPathValid(store_path)) return;
            if (visitContains(parent, store_path)) return error.RecipeCycle;

            const claim_result = try self.claimMissingPath(store_path);
            const claim = claim_result.claim;
            defer claim.release(self.allocator);

            if (comptime builtin.is_test) {
                if (claim_result.writer and parent == null) {
                    if (self.graph.test_root_claim_hook) |hook| hook.observe(hook.ctx, store_path);
                }
            }

            if (!claim_result.writer) {
                const wait_source: ?*RealizationClaim = if (parent) |visit| blk: {
                    if (self.beginClaimWait(visit.claim, claim)) return error.RecipeCycle;
                    break :blk visit.claim;
                } else null;
                const state = self.waitForClaim(claim);
                if (wait_source) |source| self.endClaimWait(source, claim);
                switch (state) {
                    .success => return,
                    .retry => continue,
                    .permanent_failure => return claim.err.?,
                    .writing => unreachable,
                }
            }

            // Double-check now that we hold the writer claim. Another writer may
            // have realized (and cached) this path between our top-of-loop
            // validity check and claiming — its claim (and single-use recipe) is
            // gone now, so without this we'd become a spurious second writer and
            // hit MissingStoreRecipe. It marks the cache before releasing its
            // claim, so a cache hit here means it finished.
            if (self.cacheContains(store_path)) {
                self.finishSuccessfulClaim(store_path, claim);
                return;
            }

            const visit: Visit = .{ .path = store_path, .claim = claim, .parent = parent };
            self.ensureClosureWriter(store_path, &visit) catch |err| {
                if (retryableRealizationError(err)) {
                    self.finishRetryableClaim(store_path, claim, err);
                } else {
                    claim.publish(.permanent_failure, err);
                }
                return err;
            };
            self.finishSuccessfulClaim(store_path, claim);
            return;
        }
    }

    /// Realize `drv_path`'s outputs (IFD / terminal build). Runs on the demanding
    /// caller (see `ensureClosure`): the closure is materialized deps-first, then
    /// the build is offloaded to the pool. A concurrent realizer of the same
    /// output deduplicates via the claim (a normal fiber park / thread block).
    pub fn realizeOutput(self: *DerivationStore, drv_path: []const u8, outputs: []const []const u8) !void {
        try self.ensureClosureInner(drv_path, null);
        const derived = try self.derivedPathString(drv_path, outputs);
        defer self.allocator.free(derived);

        while (true) {
            self.graph.mu.lock();
            const already_realized = self.graph.realized_outputs.contains(derived);
            self.graph.mu.unlock();
            if (already_realized) return;

            const claim_result = try self.claimMissingPath(derived);
            const claim = claim_result.claim;
            defer claim.release(self.allocator);
            if (!claim_result.writer) {
                switch (self.waitForClaim(claim)) {
                    .success => return,
                    .retry => continue,
                    .permanent_failure => return claim.err.?,
                    .writing => unreachable,
                }
            }

            // The build itself is offloaded to the pool (the demanding caller
            // parks / blocks); the `.drv` closure is already on disk above.
            self.buildPaths(&.{derived}, null, .normal) catch |err| {
                if (retryableRealizationError(err)) {
                    self.finishRetryableClaim(derived, claim, err);
                } else {
                    claim.publish(.permanent_failure, err);
                }
                return err;
            };
            self.markOutputRealized(derived) catch |err| {
                self.finishRetryableClaim(derived, claim, err);
                return err;
            };
            self.finishSuccessfulClaim(derived, claim);
            return;
        }
    }

    fn markOutputRealized(self: *DerivationStore, derived: []const u8) !void {
        const key = try self.allocator.dupe(u8, derived);
        errdefer self.allocator.free(key);
        self.graph.mu.lock();
        defer self.graph.mu.unlock();
        const result = try self.graph.realized_outputs.getOrPut(self.allocator, key);
        if (result.found_existing) self.allocator.free(key);
    }

    fn ensureClosureWriter(self: *DerivationStore, store_path: []const u8, visit: *const Visit) anyerror!void {
        const recipe = blk: {
            self.graph.mu.lock();
            defer self.graph.mu.unlock();
            break :blk self.graph.recipes.get(store_path) orelse return error.MissingStoreRecipe;
        };

        for (recipe.references()) |reference| try self.ensureClosureInner(reference, visit);
        // References are on disk now; write this path (offloaded to the pool). The
        // recipe's `span_group` picks the progress group for the actual transfer.
        const group = recipe.span_group;
        switch (recipe.payload) {
            .text => |text| try self.runDaemonOp(.{ .text = .{ .store_path = store_path, .text = text.bytes, .references = text.references } }, group),
            .nar => |nar_bytes| try self.runDaemonOp(.{ .path = .{ .store_path = store_path, .nar_bytes = nar_bytes } }, group),
            .flat => |bytes| try self.runDaemonOp(.{ .flat = .{ .store_path = store_path, .bytes = bytes.bytes() } }, group),
        }
        self.releaseRecipeForPath(store_path);
    }

    fn claimMissingPath(self: *DerivationStore, store_path: []const u8) !struct { claim: *RealizationClaim, writer: bool } {
        self.graph.mu.lock();
        defer self.graph.mu.unlock();

        if (self.graph.claims.get(store_path)) |claim| {
            claim.retain();
            return .{ .claim = claim, .writer = false };
        }

        const claim = try self.allocator.create(RealizationClaim);
        errdefer self.allocator.destroy(claim);
        claim.* = .{};
        claim.retain();
        errdefer claim.release(self.allocator);

        const key = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(key);
        try self.graph.claims.put(self.allocator, key, claim);
        return .{ .claim = claim, .writer = true };
    }

    fn visitContains(parent: ?*const Visit, path: []const u8) bool {
        var cursor = parent;
        while (cursor) |visit| : (cursor = visit.parent) {
            if (std.mem.eql(u8, visit.path, path)) return true;
        }
        return false;
    }

    /// Add one cold-path wait-for edge and report whether it closes a cycle.
    /// The edge retains its target and is visible only under `recipe_mu`.
    fn beginClaimWait(self: *DerivationStore, source: *RealizationClaim, target: *RealizationClaim) bool {
        self.graph.mu.lock();
        defer self.graph.mu.unlock();
        std.debug.assert(source.waiting_on == null);
        target.retain();
        source.waiting_on = target;

        var cursor: ?*RealizationClaim = target;
        while (cursor) |claim| : (cursor = claim.waiting_on) {
            if (claim == source) {
                source.waiting_on = null;
                target.release(self.allocator);
                return true;
            }
        }
        return false;
    }

    fn endClaimWait(self: *DerivationStore, source: *RealizationClaim, target: *RealizationClaim) void {
        self.graph.mu.lock();
        defer self.graph.mu.unlock();
        if (source.waiting_on == target) {
            source.waiting_on = null;
            target.release(self.allocator);
        }
    }

    fn waitForClaim(self: *DerivationStore, claim: *RealizationClaim) RealizationClaim.State {
        while (true) {
            claim.mu.lock();
            const state = claim.state;
            claim.mu.unlock();
            if (state != .writing) return state;
            // Park until the claim's future is published, then re-read the state.
            // A compute fiber yields (`fiber_park`); anything else (main-thread
            // realize, tests) blocks on a semaphore woken by the same publish.
            if (self.fiber_park) |park| {
                if (park(&claim.future)) continue;
            }
            var w: SemaphoreWaiter = .{ .waiter = .{ .wake_fn = SemaphoreWaiter.wake } };
            if (claim.future.enrollWaiter(&w.waiter)) w.sem.acquire();
        }
    }

    /// A `Future` waiter that wakes a blocked thread (no fiber to park): its
    /// `wake_fn` releases the semaphore the waiter is parked on. Lives on the
    /// waiting thread's stack — safe because `wakeFiberWaiters` reads `next`
    /// before calling `wake_fn`.
    const SemaphoreWaiter = struct {
        waiter: Waiter,
        sem: stable.Semaphore = stable.Semaphore.init(0),

        fn wake(waiter: *Waiter) void {
            const self: *SemaphoreWaiter = @fieldParentPtr("waiter", waiter);
            self.sem.release();
        }
    };

    fn finishSuccessfulClaim(self: *DerivationStore, store_path: []const u8, claim: *RealizationClaim) void {
        self.removeClaim(store_path, claim);
        claim.publish(.success, null);
    }

    fn finishRetryableClaim(self: *DerivationStore, store_path: []const u8, claim: *RealizationClaim, err: anyerror) void {
        self.removeClaim(store_path, claim);
        claim.publish(.retry, err);
    }

    fn removeClaim(self: *DerivationStore, store_path: []const u8, claim: *RealizationClaim) void {
        self.graph.mu.lock();
        defer self.graph.mu.unlock();
        const removed = self.graph.claims.fetchRemove(store_path) orelse return;
        std.debug.assert(removed.value == claim);
        self.allocator.free(removed.key);
        claim.release(self.allocator);
    }

    fn releaseRecipeForPath(self: *DerivationStore, store_path: []const u8) void {
        self.graph.mu.lock();
        defer self.graph.mu.unlock();
        const removed = self.graph.recipes.fetchRemove(store_path) orelse return;
        self.allocator.free(removed.key);
        removed.value.deinit(self.allocator);
    }

    fn derivedPathString(self: *DerivationStore, drv_path: []const u8, outputs: []const []const u8) ![]u8 {
        var rendered: std.ArrayListUnmanaged(u8) = .empty;
        errdefer rendered.deinit(self.allocator);
        try rendered.appendSlice(self.allocator, drv_path);
        // The classic `buildPaths` worker op parses each request with Nix/Lix's
        // legacy `DerivedPath::parseLegacy`, which splits on `!` (a `^` is not
        // recognized and the whole string is parsed as a store path — the daemon
        // then rejects the `^` as an illegal character). So render `<drv>!<outs>`.
        try rendered.append(self.allocator, '!');
        if (outputs.len == 0) {
            try rendered.append(self.allocator, '*');
        } else {
            const ordered = try self.allocator.alloc([]const u8, outputs.len);
            defer self.allocator.free(ordered);
            @memcpy(ordered, outputs);
            std.mem.sort([]const u8, ordered, {}, struct {
                fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                    return std.mem.order(u8, left, right) == .lt;
                }
            }.lessThan);

            var previous: ?[]const u8 = null;
            for (ordered) |output| {
                if (previous) |seen| {
                    if (std.mem.eql(u8, seen, output)) continue;
                    try rendered.append(self.allocator, ',');
                }
                try rendered.appendSlice(self.allocator, output);
                previous = output;
            }
        }
        return rendered.toOwnedSlice(self.allocator);
    }

    fn retryableRealizationError(err: anyerror) bool {
        return switch (err) {
            // A null pool connection (the worker could not reach the daemon) —
            // transient, like the raw connect errors below (which the pool
            // surfaces as this once it abstracts the per-connection open).
            error.StoreUnavailable,
            error.OutOfMemory,
            error.FileNotFound,
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            error.BrokenPipe,
            error.SystemResources,
            error.WouldBlock,
            error.TemporaryNameServerFailure,
            error.NetworkSubsystemFailed,
            error.Unexpected,
            => true,
            else => false,
        };
    }

    /// Look up a memoized ingestion. On a hit, the store path + NAR hash are
    /// duplicated into `out_allocator` (caller-owned, for an `Ingested`).
    ///
    /// `filter_id`/`token` are null for unfiltered ingests (keyed purely on
    /// content-stable path+name, so they survive GCs). For a *filtered* ingest
    /// the key includes the filter lambda's ObjectId, which a GC can reuse for a
    /// different lambda — so `token` (the heap GC token) is stored per entry and
    /// a mismatch is treated as a miss, exactly like `lookupLazyDerivation`.
    /// The single-flight stripe lock for an unfiltered ingest of `(path, name)`.
    /// Callers lock it, re-check the memo, serialize on a miss, and unlock — so
    /// concurrent coercers of the same source don't each re-serialize. See
    /// `source_ingest_locks`.
    pub fn sourceIngestLock(self: *DerivationStore, path: []const u8, name: []const u8) *stable.BlockingMutex {
        return self.memo.sourceIngestLock(path, name);
    }

    pub fn lookupSourceMemo(
        self: *DerivationStore,
        out_allocator: std.mem.Allocator,
        path: []const u8,
        name: []const u8,
        recursive: bool,
        filter_id: ?u32,
        token: ?u64,
    ) !?SourceMemoHit {
        return self.memo.lookupSource(out_allocator, path, name, recursive, filter_id, token);
    }

    /// Record a computed ingestion for reuse this eval. Dupes the key and both
    /// slices into `self.allocator`. On a key collision: an unfiltered entry (or
    /// a filtered entry whose token still matches) is a genuine race — drop the
    /// new copy; a filtered entry whose token differs is stale (the filter's
    /// ObjectId was reused after a GC) — replace it.
    pub fn storeSourceMemo(
        self: *DerivationStore,
        path: []const u8,
        name: []const u8,
        recursive: bool,
        filter_id: ?u32,
        token: u64,
        store_path: []const u8,
        nar_hash: []const u8,
    ) !void {
        return self.memo.storeSource(path, name, recursive, filter_id, token, store_path, nar_hash);
    }

    /// Look up a cached `buildForcedDerivationValue(.lazy)` result.
    /// Returns the cached `Value.bits` if present, `null` otherwise.
    pub fn lookupLazyDerivation(self: *DerivationStore, attrs_id: u32, token: u64) ?u64 {
        return self.memo.lookupLazyDerivation(attrs_id, token);
    }

    /// Cache the result of `buildForcedDerivationValue(.lazy)` for
    /// future per-attr lookups against the same input attrs.
    pub fn cacheLazyDerivation(self: *DerivationStore, attrs_id: u32, token: u64, value_bits: u64) !void {
        return self.memo.cacheLazyDerivation(attrs_id, token, value_bits);
    }

    pub fn visitLiveLazyDerivations(self: *DerivationStore, token: u64, context: anytype, comptime visit: anytype) void {
        self.memo.visitLiveLazyValues(token, context, visit);
    }

    pub fn setDebugEnabled(self: *DerivationStore, enabled: bool) void {
        self.registry.setDebugEnabled(enabled);
    }

    pub fn debugEnabled(self: *DerivationStore) bool {
        return self.registry.debugEnabled();
    }

    pub fn clearDebugRecords(self: *DerivationStore) void {
        self.registry.clearDebugRecords();
    }

    /// Returns a borrowed slice. Caller must not invoke `record*` concurrently.
    /// Used at end-of-evaluation from the main thread after helpers have quiesced.
    pub fn debugRecords(self: *const DerivationStore) []const DebugRecord {
        return self.registry.debugRecords();
    }

    pub fn resolver(self: *DerivationStore) HashModuloResolver {
        return self.registry.resolver(self.store_dir);
    }

    pub fn record(self: *DerivationStore, drv_path: []const u8, hash_modulo: HashModuloView, outputs: []const DrvOutput) !void {
        return self.registry.record(drv_path, hash_modulo, outputs);
    }

    pub fn recordDebug(self: *DerivationStore, drv: *const Drv, computed: ComputedPaths) !void {
        return self.registry.recordDebug(self.store_dir, drv, computed);
    }

    pub fn outputNames(self: *DerivationStore, drv_path: []const u8) ?[]const []const u8 {
        return self.registry.outputNames(drv_path);
    }
};
