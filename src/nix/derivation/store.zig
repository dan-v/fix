//! DerivationStore: the evaluation-wide registry mapping each .drv path to its
//! hash-modulo and output names (the resolver for input-addressed hashing),
//! plus the lazy-derivation Value cache and optional debug-record capture.
//! Read-mostly but written from any worker thread: `mu` guards the record maps
//! and a separate `lazy_drv_mu` spinlock guards the lazy value cache.

const std = @import("std");
const debug_record_mod = @import("debug_record.zig");
const drv_mod = @import("drv.zig");
const types = @import("types.zig");
const clone = @import("clone.zig");
const stable = @import("base").sync;
const rstore = @import("runtime").store;

const DebugRecord = types.DebugRecord;
const ComputedPaths = types.ComputedPaths;
const Drv = drv_mod.Drv;
const DrvOutput = types.DrvOutput;
const HashModulo = types.HashModulo;
const HashModuloResolver = types.HashModuloResolver;
const HashModuloView = types.HashModuloView;
const cloneHashModulo = clone.cloneHashModulo;
const cloneOutputNames = clone.cloneOutputNames;
const freeOutputNames = clone.freeOutputNames;

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
    records: std.StringHashMapUnmanaged(Record) = .empty,
    debug_enabled: bool = false,
    debug_records: std.ArrayListUnmanaged(DebugRecord) = .empty,
    mu: stable.BlockingMutex = .{},
    /// Cache of fully-built lazy derivation values keyed by the
    /// input `attrs_id` to `buildForcedDerivationValue(.lazy)`. The
    /// `builtinDerivationLazyAttr` path was rebuilding the entire
    /// derivation on every per-attr access (drvPath, outPath,
    /// outputName, named outputs, ...) — the cache deduplicates so
    /// the first access pays and the rest just look the result up.
    ///
    /// `u64` storage instead of `Value` to keep this header from having to
    /// know about the runtime Value type; the caller round-trips through the
    /// `Value.bits` field. Keyed by attrs ObjectId; the `token` guards against
    /// GC id-reuse (see `lookupLazyDerivation`).
    lazy_drv_cache: std.AutoHashMapUnmanaged(u32, LazyDrvEntry) = .empty,
    lazy_drv_mu: stable.SpinMutex = .{},

    /// The nix-daemon connection, connected lazily on the first store write and
    /// owned/closed here (like Nix, which only touches the store on demand).
    /// Guarded by `daemon_mu` so parallel forcing fibers serialize on the one
    /// socket; `instantiated` de-dupes writes across re-forces.
    daemon: ?*rstore.DaemonStore = null,
    daemon_mu: stable.BlockingMutex = .{},
    /// Store paths we've already ensured are present this run — either because
    /// we wrote them, or because a pre-write `isValidPath` confirmed the daemon
    /// already has them. Both cases mean a re-force can skip re-sending the
    /// bytes. Empty at process start, so the first force of an already-present
    /// path pays one cheap `isValidPath` round-trip instead of streaming the
    /// whole text/NAR the daemon would just hash and discard.
    instantiated: std.StringHashMapUnmanaged(void) = .empty,
    io: ?std.Io = null,
    daemon_socket: []const u8 = rstore.default_socket_path,
    /// Whether forced derivations, their sources, and fetched trees are
    /// materialized to the store (`fix instantiate`/`build` enable it). Off for
    /// plain `eval` so the hot eval path never does store I/O per derivation
    /// and fetches stay local/offline (returning their download-cache path).
    store_writes_enabled: bool = false,

    /// Optional off-thread executor for blocking daemon ops. When set (by the
    /// Evaluator, once the worker pool + IoRuntime exist), each store write runs
    /// on the shared IO thread while the calling fiber parks — keeping the
    /// socket syscalls off the compute workers. Null → ops run inline on the
    /// caller (the `fix store` CLI and tests, which have no fiber to park).
    offload: ?Offload = null,

    /// Vtable injected by the vm/eval layer (`vm.io_offload.run`). Runs `work`
    /// on the IO thread and blocks the calling fiber until it returns.
    pub const Offload = struct {
        ctx: *anyopaque,
        run: *const fn (ctx: *anyopaque, work: *const fn (*anyopaque) void, work_ctx: *anyopaque) void,
    };

    const LazyDrvEntry = struct { token: u64, bits: u64 };

    const Record = struct {
        hash_modulo: HashModulo,
        outputs: []const []const u8,

        fn deinit(self: Record, allocator: std.mem.Allocator) void {
            self.hash_modulo.deinit(allocator);
            for (self.outputs) |output| allocator.free(output);
            allocator.free(self.outputs);
        }
    };

    pub fn init(allocator: std.mem.Allocator) DerivationStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DerivationStore) void {
        self.clearDebugRecords();
        self.debug_records.deinit(self.allocator);
        var it = self.records.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.records.deinit(self.allocator);
        self.lazy_drv_cache.deinit(self.allocator);
        var inst = self.instantiated.keyIterator();
        while (inst.next()) |key| self.allocator.free(key.*);
        self.instantiated.deinit(self.allocator);
        if (self.daemon) |d| d.deinit();
    }

    /// Provide the IO handle used to connect to the daemon on demand.
    pub fn setIo(self: *DerivationStore, io: std.Io) void {
        self.io = io;
    }

    /// Enable writing forced derivations + their sources to the store
    /// (`fix instantiate`/`build`). Off by default so plain eval stays pure.
    pub fn enableStoreWrites(self: *DerivationStore) void {
        self.store_writes_enabled = true;
    }

    /// Install the off-thread daemon-op executor. Must be called before any
    /// forcing begins, and cleared (`clearOffload`) before the IO runtime is
    /// torn down.
    pub fn setOffload(self: *DerivationStore, off: Offload) void {
        self.offload = off;
    }

    pub fn clearOffload(self: *DerivationStore) void {
        self.offload = null;
    }

    /// Connect to the daemon on first use and return it (owned here). Errors if
    /// no IO handle was set or the daemon is unreachable — matching Nix, which
    /// fails a store op when the daemon is down. Caller must hold `daemon_mu`.
    fn ensureDaemon(self: *DerivationStore) !*rstore.DaemonStore {
        if (self.daemon) |d| return d;
        const io = self.io orelse return error.StoreUnavailable;
        const d = try rstore.DaemonStore.connect(self.allocator, io, self.daemon_socket);
        self.daemon = d;
        return d;
    }

    /// Read the last daemon error message (for surfacing `error.DaemonError`).
    pub fn lastStoreError(self: *DerivationStore) ?[]const u8 {
        return if (self.daemon) |d| d.last_error else null;
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
        return self.runDaemonOp(.{ .text = .{ .store_path = store_path, .text = text, .references = references } });
    }

    /// Write a NAR-serialized source tree, gated on `store_writes_enabled`.
    /// Sources ingest during derivation normalization — before the `.drv` that
    /// references them — so `input_srcs` are valid in time.
    pub fn instantiatePath(self: *DerivationStore, store_path: []const u8, nar_bytes: []const u8) !void {
        if (!self.store_writes_enabled) return;
        return self.runDaemonOp(.{ .path = .{ .store_path = store_path, .nar_bytes = nar_bytes } });
    }

    /// Add a flat file's raw bytes to the store (fetchurl), gated on
    /// `store_writes_enabled`.
    pub fn instantiateFlat(self: *DerivationStore, store_path: []const u8, bytes: []const u8) !void {
        if (!self.store_writes_enabled) return;
        return self.runDaemonOp(.{ .flat = .{ .store_path = store_path, .bytes = bytes } });
    }

    /// Realize `derived_paths` (`<drvpath>^<outputs>`) via the daemon,
    /// forwarding the build activity/log stream to `sink` if given.
    pub fn buildPaths(self: *DerivationStore, derived_paths: []const []const u8, sink: ?rstore.BuildSink) !void {
        self.daemon_mu.lock();
        defer self.daemon_mu.unlock();
        const daemon = try self.ensureDaemon();
        try daemon.buildPaths(derived_paths, sink);
    }

    const DaemonOp = union(enum) {
        text: struct { store_path: []const u8, text: []const u8, references: []const []const u8 },
        path: struct { store_path: []const u8, nar_bytes: []const u8 },
        flat: struct { store_path: []const u8, bytes: []const u8 },
    };

    /// Dispatch a store write onto the IO thread (when an offload is installed
    /// and we're on a fiber) or inline on the caller. The op's args are borrowed
    /// and, in the offloaded path, stay valid because the calling fiber parks —
    /// its stack (holding the non-GC NAR/text buffers) is preserved for the
    /// whole transfer, so no copy is needed.
    fn runDaemonOp(self: *DerivationStore, op: DaemonOp) !void {
        if (self.offload) |off| {
            var cell: OpCell = .{ .store = self, .op = op };
            off.run(off.ctx, OpCell.run, &cell);
            return cell.err;
        }
        return self.applyDaemonOp(op);
    }

    const OpCell = struct {
        store: *DerivationStore,
        op: DaemonOp,
        err: anyerror!void = {},

        fn run(p: *anyopaque) void {
            const self: *OpCell = @ptrCast(@alignCast(p));
            self.err = self.store.applyDaemonOp(self.op);
        }
    };

    /// Perform a store write against the daemon. Runs on the IO thread when
    /// offloaded (the single serial consumer of the connection), else inline;
    /// `daemon_mu` still guards against a concurrent inline `buildPaths`. Skips
    /// the transfer when the path is already valid (see `instantiated`).
    fn applyDaemonOp(self: *DerivationStore, op: DaemonOp) !void {
        self.daemon_mu.lock();
        defer self.daemon_mu.unlock();
        const store_path = switch (op) {
            inline else => |o| o.store_path,
        };
        if (self.instantiated.contains(store_path)) return;
        const daemon = try self.ensureDaemon();
        if (try daemon.isValidPath(store_path)) return self.markInstantiated(store_path);
        const written = switch (op) {
            .text => |o| try daemon.addTextToStore(self.allocator, storePathName(store_path), o.text, o.references),
            .path => |o| try daemon.addPath(self.allocator, storePathName(store_path), o.nar_bytes, &.{}),
            .flat => |o| try daemon.addFlatFile(self.allocator, storePathName(store_path), o.bytes, &.{}),
        };
        self.allocator.free(written);
        try self.markInstantiated(store_path);
    }

    fn markInstantiated(self: *DerivationStore, store_path: []const u8) !void {
        const key = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(key);
        try self.instantiated.put(self.allocator, key, {});
    }

    /// Look up a cached `buildForcedDerivationValue(.lazy)` result.
    /// Returns the cached `Value.bits` if present, `null` otherwise.
    pub fn lookupLazyDerivation(self: *DerivationStore, attrs_id: u32, token: u64) ?u64 {
        self.lazy_drv_mu.lock();
        defer self.lazy_drv_mu.unlock();
        const entry = self.lazy_drv_cache.get(attrs_id) orelse return null;
        // The key is a raw ObjectId; after a GC the attrs may be swept and its
        // id reused for a different attrs. `token` bumps every collection, so a
        // stale entry must miss — else we'd return another derivation's value
        // for a reused id (a reuse-only bug the -Dgc detector can't see).
        if (entry.token != token) return null;
        return entry.bits;
    }

    /// Cache the result of `buildForcedDerivationValue(.lazy)` for
    /// future per-attr lookups against the same input attrs.
    pub fn cacheLazyDerivation(self: *DerivationStore, attrs_id: u32, token: u64, value_bits: u64) !void {
        self.lazy_drv_mu.lock();
        defer self.lazy_drv_mu.unlock();
        try self.lazy_drv_cache.put(self.allocator, attrs_id, .{ .token = token, .bits = value_bits });
    }

    pub fn setDebugEnabled(self: *DerivationStore, enabled: bool) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.debug_enabled = enabled;
        if (!enabled) self.clearDebugRecordsLocked();
    }

    pub fn clearDebugRecords(self: *DerivationStore) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.clearDebugRecordsLocked();
    }

    fn clearDebugRecordsLocked(self: *DerivationStore) void {
        for (self.debug_records.items) |debug_record| debug_record.deinit(self.allocator);
        self.debug_records.clearRetainingCapacity();
    }

    /// Returns a borrowed slice. Caller must not invoke `record*` concurrently.
    /// Used at end-of-evaluation from the main thread after helpers have quiesced.
    pub fn debugRecords(self: *const DerivationStore) []const DebugRecord {
        return self.debug_records.items;
    }

    pub fn resolver(self: *DerivationStore) HashModuloResolver {
        return .{ .store_dir = self.store_dir, .context = self, .resolve = resolveHashModulo };
    }

    pub fn record(self: *DerivationStore, drv_path: []const u8, hash_modulo: HashModuloView, outputs: []const DrvOutput) !void {
        // Fast path: another thread already recorded this drv_path. Drv paths
        // are content-addressed by their inputs, so two records for the same
        // path must carry equal hash_modulos — overwriting would invalidate
        // any HashModuloView still in flight on another worker.
        {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.records.contains(drv_path)) return;
        }

        const value: Record = blk: {
            const cloned_hash_modulo = try cloneHashModulo(self.allocator, hash_modulo);
            errdefer cloned_hash_modulo.deinit(self.allocator);
            const cloned_outputs = try cloneOutputNames(self.allocator, outputs);
            errdefer freeOutputNames(self.allocator, cloned_outputs);
            break :blk .{
                .hash_modulo = cloned_hash_modulo,
                .outputs = cloned_outputs,
            };
        };

        self.mu.lock();
        defer self.mu.unlock();

        // Recheck under the lock — a racing recorder may have landed between
        // the optimistic check and now.
        if (self.records.contains(drv_path)) {
            value.deinit(self.allocator);
            return;
        }
        const key = try self.allocator.dupe(u8, drv_path);
        errdefer self.allocator.free(key);
        try self.records.put(self.allocator, key, value);
    }

    pub fn recordDebug(self: *DerivationStore, drv: *const Drv, computed: ComputedPaths) !void {
        // Read-then-act on debug_enabled needs to hold the lock so a
        // concurrent setDebugEnabled doesn't tear our decision.
        self.mu.lock();
        const enabled = self.debug_enabled;
        if (!enabled) {
            self.mu.unlock();
            return;
        }
        self.mu.unlock();

        var new_record = try debug_record_mod.debugRecordFromDrv(self.allocator, drv, computed.drv_path, self.resolver());
        errdefer new_record.deinit(self.allocator);

        self.mu.lock();
        defer self.mu.unlock();
        try self.debug_records.append(self.allocator, new_record);
    }

    pub fn outputNames(self: *DerivationStore, drv_path: []const u8) ?[]const []const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const value = self.records.getPtr(drv_path) orelse return null;
        return value.outputs;
    }

    fn resolveHashModulo(context: *anyopaque, drv_path: []const u8) anyerror!?HashModuloView {
        const self: *DerivationStore = @ptrCast(@alignCast(context));
        self.mu.lock();
        defer self.mu.unlock();
        const value = self.records.getPtr(drv_path) orelse return null;
        return value.hash_modulo.view();
    }
};
