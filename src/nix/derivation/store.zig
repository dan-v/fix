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
