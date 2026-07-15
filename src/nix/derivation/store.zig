//! DerivationStore: the evaluation-wide registry mapping each .drv path to its
//! hash-modulo and output names (the resolver for input-addressed hashing),
//! plus the lazy-derivation Value cache and optional debug-record capture.
//! Read-mostly but written from any worker thread: `mu` guards the record maps
//! and a separate `lazy_drv_mu` spinlock guards the lazy value cache.

const std = @import("std");
const builtin = @import("builtin");
const debug_record_mod = @import("debug_record.zig");
const drv_mod = @import("drv.zig");
const types = @import("types.zig");
const clone = @import("clone.zig");
const stable = @import("base").sync;
const runtime = @import("runtime");
const rstore = runtime.store;
const nar = runtime.nar;
const FileCache = runtime.file_cache.FileCache;
const DaemonRuntime = runtime.daemon_runtime.DaemonRuntime;

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

    /// In-eval source-copy memo — fix's analogue of Nix's `EvalState::srcToStore`.
    /// Maps an *unfiltered* source ingestion (keyed by `<r|f><name>\x00<abs-path>`)
    /// to its computed store path + NAR hash, so repeatedly coercing the same
    /// source (`src = ./.` referenced many times) NAR-serializes + hashes the tree
    /// once instead of on every coercion. Only unfiltered ingests are memoized: a
    /// `filter` makes the result depend on a Nix predicate whose behavior can't be
    /// keyed cheaply (and would need the GC-id-reuse guard `lazy_drv_cache` uses).
    /// The source content is frozen for the eval by `FileCache`, so this makes the
    /// same immutability assumption Nix's `srcToStore` does. Guarded by
    /// `source_memo_mu`. Both the key and the stored slices are owned by
    /// `allocator`, freed in `deinit`.
    source_memo: std.StringHashMapUnmanaged(SourceMemoEntry) = .empty,
    source_memo_mu: stable.SpinMutex = .{},

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
    /// The evaluator's FileCache, set alongside the runtime. Lets a deferred
    /// `lazy_source` recipe re-serialize its source from disk on demand (IFD /
    /// closure write) instead of retaining the NAR bytes from eval. Safe because
    /// FileCache freezes source content for the eval's lifetime, and lazy_source
    /// recipes are only produced (and only replayed) during eval. Null in tests
    /// and the `fix store` CLI → sources fall back to eager NAR retention.
    files: ?*FileCache = null,
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

    /// Eval/build pipelining: when enabled (build/run/shell/switch, unless
    /// `FIX_NO_EAGER_BUILD`), the DaemonRuntime's work graph is running. It makes
    /// `.drv` writes async + dependency-ordered (overlapping the rest of eval) and
    /// serves as the single builder for IFD-demanded outputs (`demandPathArg`).
    /// It does NOT build derivations merely because they were instantiated — only
    /// IFD and the final authoritative closure build realize outputs. Off for
    /// `eval`/`instantiate` (no realization) and plain eval. See `graphActive`.
    eager_build_enabled: bool = false,
    /// The Evaluator-owned runtime that hosts the eager-build lane (set by the
    /// Evaluator alongside `offload`); `null` outside an Evaluator (tests).
    daemon_runtime: ?*DaemonRuntime = null,
    /// Owned copy of the first eager-build failure message, surfaced through
    /// `lastStoreError` (the build lane has its own connection, so its error is
    /// not on `daemon.last_error`).
    eager_error_msg: ?[]u8 = null,

    /// Optional off-thread executor for blocking daemon ops. When set (by the
    /// Evaluator, once the worker pool + IoRuntime exist), each store write runs
    /// on the shared IO thread while the calling fiber parks — keeping the
    /// socket syscalls off the compute workers. Null → ops run inline on the
    /// caller (the `fix store` CLI and tests, which have no fiber to park).
    offload: ?Offload = null,

    /// Store-owned IFD recipes, keyed by full store path. Separate from the
    /// derivation/debug registry so unrelated eval hot paths add no recipe
    /// locking or payload refcount traffic.
    recipes: std.StringHashMapUnmanaged(*Recipe) = .empty,
    realization_claims: std.StringHashMapUnmanaged(*RealizationClaim) = .empty,
    realized_outputs: std.StringHashMapUnmanaged(void) = .empty,
    /// Deferred fetch specs, keyed by the fixed-output store path a
    /// `builtins.fetchurl`/`fetchTarball` with a known hash resolves to. In
    /// plain eval the path is fully determined by (name, sha256), so it is
    /// returned without touching the network; the download runs lazily only if
    /// the path's *content* is later demanded (readFile/import/realization),
    /// keeping path-only use offline while preserving import-from-derivation.
    /// Guarded by `recipe_mu`.
    pending_fetches: std.StringHashMapUnmanaged(PendingFetch) = .empty,
    recipe_mu: stable.BlockingMutex = .{},
    /// Test-only deterministic scheduling hook. This field is zero-bit `void`
    /// and all access is compiled out of production builds.
    test_root_claim_hook: if (builtin.is_test) ?RootClaimHook else void = if (builtin.is_test) null else {},
    /// Original payload allocations observed at producer allocation boundaries.
    /// A path can be produced more than once, so tests retain every observation
    /// until recipe identity is compared and then consume the whole entry. The
    /// field is zero-bit and all calls compile away outside tests.
    test_producer_payload_pointers: if (builtin.is_test) std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)) else void = if (builtin.is_test) .empty else {},

    /// Vtable injected by the vm/eval layer (`vm.io_offload.run`). Runs `work`
    /// on the IO thread and blocks the calling fiber until it returns.
    pub const Offload = struct {
        ctx: *anyopaque,
        run: *const fn (ctx: *anyopaque, work: *const fn (*anyopaque) void, work_ctx: *anyopaque) void,
    };

    pub const RootClaimHook = struct {
        ctx: *anyopaque,
        observe: *const fn (ctx: *anyopaque, store_path: []const u8) void,
    };

    pub fn setRootClaimHookForTest(self: *DerivationStore, hook: ?RootClaimHook) void {
        if (comptime builtin.is_test) {
            self.test_root_claim_hook = hook;
        } else unreachable;
    }

    /// Test-only producer-boundary seam. Producers call this after the owned
    /// allocation is created, independently of whether registration succeeds.
    pub fn noteProducerPayloadForTest(self: *DerivationStore, store_path: []const u8, payload: []const u8) !void {
        if (comptime builtin.is_test) {
            self.recipe_mu.lock();
            defer self.recipe_mu.unlock();
            const owned_path = try self.allocator.dupe(u8, store_path);
            const result = self.test_producer_payload_pointers.getOrPut(self.allocator, owned_path) catch |err| {
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
                    const removed = self.test_producer_payload_pointers.fetchRemove(store_path).?;
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
            self.recipe_mu.lock();
            defer self.recipe_mu.unlock();
            var removed = self.test_producer_payload_pointers.fetchRemove(store_path) orelse return null;
            defer self.allocator.free(removed.key);
            defer removed.value.deinit(self.allocator);
            const retained = if (self.recipes.get(store_path)) |recipe| recipePayloadPointer(recipe) else null;
            if (retained) |pointer| {
                for (removed.value.items) |observed| if (observed == pointer) return observed;
            }
            return if (removed.value.items.len == 0) null else removed.value.items[0];
        } else return null;
    }

    pub const RecipeVariantForTest = enum { text, nar, flat, lazy_source };

    pub fn recipeCountForTest(self: *DerivationStore) usize {
        if (comptime builtin.is_test) {
            self.recipe_mu.lock();
            defer self.recipe_mu.unlock();
            return self.recipes.count();
        } else return 0;
    }

    pub fn recipeVariantForTest(self: *DerivationStore, store_path: []const u8) ?RecipeVariantForTest {
        if (comptime builtin.is_test) {
            self.recipe_mu.lock();
            defer self.recipe_mu.unlock();
            const recipe = self.recipes.get(store_path) orelse return null;
            return switch (recipe.payload) {
                .text => .text,
                .nar => .nar,
                .flat => .flat,
                .lazy_source => .lazy_source,
            };
        } else return null;
    }

    pub fn recipePayloadPointerForTest(self: *DerivationStore, store_path: []const u8) ?usize {
        if (comptime builtin.is_test) {
            self.recipe_mu.lock();
            defer self.recipe_mu.unlock();
            return recipePayloadPointer(self.recipes.get(store_path) orelse return null);
        } else return null;
    }

    pub fn recipePayloadBytesForTest(self: *DerivationStore, store_path: []const u8) ?[]const u8 {
        if (comptime builtin.is_test) {
            self.recipe_mu.lock();
            defer self.recipe_mu.unlock();
            const recipe = self.recipes.get(store_path) orelse return null;
            return switch (recipe.payload) {
                .text => |text| text.bytes,
                .nar => |bytes| bytes,
                .flat => |bytes| bytes.bytes(),
                .lazy_source => null, // no eval-time bytes; re-serialized on demand
            };
        } else return null;
    }

    pub fn recipeReferencesForTest(self: *DerivationStore, store_path: []const u8) ?[]const []const u8 {
        if (comptime builtin.is_test) {
            self.recipe_mu.lock();
            defer self.recipe_mu.unlock();
            return (self.recipes.get(store_path) orelse return null).references();
        } else return null;
    }

    const LazyDrvEntry = struct { token: u64, bits: u64 };

    /// A memoized source ingestion. Both slices are owned by the
    /// `DerivationStore.allocator` and freed in `deinit`. `token` is the heap GC
    /// token at store time — only meaningful for filtered entries (whose key
    /// includes a reusable ObjectId); unfiltered entries ignore it.
    const SourceMemoEntry = struct { store_path: []u8, nar_hash: []u8, token: u64 };

    /// A source-memo hit, with slices duplicated into the *caller's* allocator
    /// so it can be dropped into an `Ingested` (which is caller-owned).
    pub const SourceMemoHit = struct { store_path: []u8, nar_hash: []u8 };

    const Record = struct {
        hash_modulo: HashModulo,
        outputs: []const []const u8,

        fn deinit(self: Record, allocator: std.mem.Allocator) void {
            self.hash_modulo.deinit(allocator);
            for (self.outputs) |output| allocator.free(output);
            allocator.free(self.outputs);
        }
    };

    /// A deferred `fetchurl`/`fetchTarball`: the download spec plus the expected
    /// content hash, materialized on demand. `recursive` distinguishes a flat
    /// file (fetchurl) from an unpacked tree (fetchTarball).
    pub const PendingFetch = struct {
        url: []u8,
        name: []u8,
        recursive: bool,
        hash_hex: []u8,

        pub fn deinit(self: PendingFetch, allocator: std.mem.Allocator) void {
            allocator.free(self.url);
            allocator.free(self.name);
            allocator.free(self.hash_hex);
        }

        fn clone(self: PendingFetch, allocator: std.mem.Allocator) !PendingFetch {
            const url = try allocator.dupe(u8, self.url);
            errdefer allocator.free(url);
            const name = try allocator.dupe(u8, self.name);
            errdefer allocator.free(name);
            const hash_hex = try allocator.dupe(u8, self.hash_hex);
            return .{ .url = url, .name = name, .recursive = self.recursive, .hash_hex = hash_hex };
        }
    };

    /// Register a deferred fetch for `store_path` (no-op if one already exists).
    pub fn recordPendingFetch(self: *DerivationStore, store_path: []const u8, url: []const u8, name: []const u8, recursive: bool, hash_hex: []const u8) !void {
        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();
        if (self.pending_fetches.contains(store_path)) return;
        const key = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(key);
        const url_copy = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(url_copy);
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const hash_copy = try self.allocator.dupe(u8, hash_hex);
        errdefer self.allocator.free(hash_copy);
        try self.pending_fetches.put(self.allocator, key, .{ .url = url_copy, .name = name_copy, .recursive = recursive, .hash_hex = hash_copy });
    }

    /// Return an owned copy of the deferred fetch for exactly `store_path`, or
    /// null. The entry is left in place — concurrent demands each materialize
    /// against the (memoized) fetch cache; `removePendingFetch` drops it once a
    /// flat file is seeded. Caller owns the copy and must `deinit` it.
    pub fn peekPendingFetch(self: *DerivationStore, store_path: []const u8) !?PendingFetch {
        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();
        const entry = self.pending_fetches.get(store_path) orelse return null;
        return try entry.clone(self.allocator);
    }

    pub fn removePendingFetch(self: *DerivationStore, store_path: []const u8) void {
        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();
        const removed = self.pending_fetches.fetchRemove(store_path) orelse return;
        self.allocator.free(removed.key);
        removed.value.deinit(self.allocator);
    }

    const Recipe = struct {
        payload: Payload,

        const TextPayload = struct {
            bytes: []u8,
            references: [][]u8,
        };

        /// A deferred source: re-serialize the NAR from `path` (a filesystem
        /// source) on demand rather than retaining the eval-time bytes. Used only
        /// in plain eval for unfiltered sources; replayed via the store's
        /// FileCache (which holds the frozen content), so the re-serialized bytes
        /// match the store path computed at eval time.
        const LazySource = struct {
            path: []u8,
            name: []u8,
        };

        const Payload = union(enum) {
            text: TextPayload,
            nar: []u8,
            flat: FileCache.ImmutableBytes,
            lazy_source: LazySource,
        };

        fn deinit(self: *Recipe, allocator: std.mem.Allocator) void {
            switch (self.payload) {
                .text => |text| {
                    allocator.free(text.bytes);
                    for (text.references) |reference| allocator.free(reference);
                    allocator.free(text.references);
                },
                .nar => |nar_bytes| allocator.free(nar_bytes),
                .flat => |*bytes| bytes.release(),
                .lazy_source => |src| {
                    allocator.free(src.path);
                    allocator.free(src.name);
                },
            }
            allocator.destroy(self);
        }

        fn textMatches(self: *const Recipe, text: []const u8, refs: []const []const u8) bool {
            const existing = switch (self.payload) {
                .text => |payload| payload,
                else => return false,
            };
            if (!std.mem.eql(u8, existing.bytes, text) or existing.references.len != refs.len) return false;
            for (existing.references, refs) |left, right| {
                if (!std.mem.eql(u8, left, right)) return false;
            }
            return true;
        }

        fn narMatches(self: *const Recipe, nar_bytes: []const u8) bool {
            return switch (self.payload) {
                .nar => |existing| std.mem.eql(u8, existing, nar_bytes),
                else => false,
            };
        }

        fn flatMatches(self: *const Recipe, handle: FileCache.ImmutableBytes) bool {
            return switch (self.payload) {
                .flat => |existing| std.mem.eql(u8, existing.bytes(), handle.bytes()),
                else => false,
            };
        }

        fn references(self: *const Recipe) []const []const u8 {
            return switch (self.payload) {
                .text => |text| text.references,
                else => &.{},
            };
        }

        /// Whether this is a deferred (re-serialize-on-demand) source. A store
        /// path is content-addressed, so a second recording of the same path —
        /// even by a different ingest route (e.g. `filterSource (_: true)` on a
        /// single file yields the same NAR as the bare coercion) — represents
        /// identical content; recording sites treat an existing lazy_source as
        /// compatible rather than a `RecipeConflict`, keeping the deferred form.
        fn isLazySource(self: *const Recipe) bool {
            return self.payload == .lazy_source;
        }
    };

    fn recipePayloadPointer(recipe: *const Recipe) usize {
        return switch (recipe.payload) {
            .text => |text| @intFromPtr(text.bytes.ptr),
            .nar => |bytes| @intFromPtr(bytes.ptr),
            .flat => |bytes| @intFromPtr(bytes.bytes().ptr),
            .lazy_source => |src| @intFromPtr(src.path.ptr),
        };
    }

    const RealizationClaim = struct {
        mu: stable.BlockingMutex = .{},
        seq: std.atomic.Value(u32) = .init(0),
        refs: std.atomic.Value(usize) = .init(1),
        state: State = .writing,
        err: ?anyerror = null,
        /// Cold-path wait-for edge, guarded by `recipe_mu`. A retained target
        /// keeps graph traversal safe while concurrent claims complete.
        waiting_on: ?*RealizationClaim = null,

        const State = enum {
            writing,
            success,
            retry,
            permanent_failure,
        };

        fn retain(self: *RealizationClaim) void {
            _ = self.refs.fetchAdd(1, .monotonic);
        }

        fn release(self: *RealizationClaim, allocator: std.mem.Allocator) void {
            if (self.refs.fetchSub(1, .acq_rel) != 1) return;
            allocator.destroy(self);
        }

        fn publish(self: *RealizationClaim, state: State, err: ?anyerror) void {
            self.mu.lock();
            self.state = state;
            self.err = err;
            self.mu.unlock();
            _ = self.seq.fetchAdd(1, .release);
            stable.Futex.wake(&self.seq, std.math.maxInt(u32));
        }
    };

    pub fn init(allocator: std.mem.Allocator) DerivationStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DerivationStore) void {
        // The build lane is owned + joined by the Evaluator's DaemonRuntime
        // (before this runs); here we only free our own retained error message.
        if (self.eager_error_msg) |msg| self.allocator.free(msg);
        self.releaseRecipePayloads();
        self.recipes.deinit(self.allocator);
        self.recipe_mu.lock();
        var claims = self.realization_claims.iterator();
        while (claims.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.release(self.allocator);
        }
        self.realization_claims.deinit(self.allocator);
        var realized = self.realized_outputs.keyIterator();
        while (realized.next()) |key| self.allocator.free(key.*);
        self.realized_outputs.deinit(self.allocator);
        var pending = self.pending_fetches.iterator();
        while (pending.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.pending_fetches.deinit(self.allocator);
        if (comptime builtin.is_test) {
            var producer_pointers = self.test_producer_payload_pointers.iterator();
            while (producer_pointers.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            self.test_producer_payload_pointers.deinit(self.allocator);
        }
        self.recipe_mu.unlock();
        self.clearDebugRecords();
        self.debug_records.deinit(self.allocator);
        var it = self.records.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.records.deinit(self.allocator);
        self.lazy_drv_cache.deinit(self.allocator);
        var src_memo = self.source_memo.iterator();
        while (src_memo.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.store_path);
            self.allocator.free(entry.value_ptr.nar_hash);
        }
        self.source_memo.deinit(self.allocator);
        var inst = self.instantiated.keyIterator();
        while (inst.next()) |key| self.allocator.free(key.*);
        self.instantiated.deinit(self.allocator);
        for (self.daemon_overrides.items) |o| {
            self.allocator.free(o.name);
            self.allocator.free(o.value);
        }
        self.daemon_overrides.deinit(self.allocator);
        if (self.daemon_socket_owned) |owned| self.allocator.free(owned);
        if (self.daemon) |d| d.deinit();
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

    /// Provide the evaluator's FileCache so deferred `lazy_source` recipes can
    /// re-serialize from disk on demand (see the `files` field).
    pub fn setFileCache(self: *DerivationStore, files: *FileCache) void {
        self.files = files;
    }

    /// Enable writing forced derivations + their sources to the store
    /// (`fix instantiate`/`build`). Off by default so plain eval stays pure.
    pub fn enableStoreWrites(self: *DerivationStore) void {
        self.store_writes_enabled = true;
    }

    /// Start eval/build pipelining: launch the work graph (its own pool of daemon
    /// connections) that writes `.drv`s + realizes derivations as they are
    /// instantiated. `spans` drives live per-build progress (may be null).
    /// Requires store writes enabled and a daemon socket via `setIo`. A no-op if
    /// `FIX_NO_EAGER_BUILD` is set in `env`.
    pub fn startEagerBuilds(self: *DerivationStore, env: ?*const std.process.Environ.Map, spans: ?DaemonRuntime.BuildSpans, mode: rstore.BuildMode) !void {
        if (!self.store_writes_enabled) return;
        if (env) |em| if (em.get("FIX_NO_EAGER_BUILD") != null) return;
        const rt = self.daemon_runtime orelse return;
        const io = self.io orelse return;
        const dedup: DaemonRuntime.Dedup = .{ .ctx = self, .known = dedupKnown, .mark = dedupMark };
        try rt.startGraph(self.allocator, io, self.daemon_socket, self.daemon_options, spans, dedup, mode);
        self.eager_build_enabled = true;
    }

    /// Thread-safe views of the `instantiated` cache for the work graph's write
    /// workers (guarded by `daemon_mu`, like every other `instantiated` access).
    fn dedupKnown(ctx: *anyopaque, path: []const u8) bool {
        const self: *DerivationStore = @ptrCast(@alignCast(ctx));
        self.daemon_mu.lock();
        defer self.daemon_mu.unlock();
        return self.instantiated.contains(path);
    }
    fn dedupMark(ctx: *anyopaque, path: []const u8) void {
        const self: *DerivationStore = @ptrCast(@alignCast(ctx));
        self.daemon_mu.lock();
        defer self.daemon_mu.unlock();
        self.markInstantiated(path) catch {};
    }

    /// Is the pipelining work graph running? When true, `.drv` writes are async
    /// graph nodes and IFD realizes route through the graph builder; when false
    /// there is no graph and callers drive the daemon directly (`instantiate`).
    pub fn graphActive(self: *const DerivationStore) bool {
        return self.eager_build_enabled;
    }

    /// Drain and join the build lane (call once evaluation has finished, before
    /// the final authoritative build). Returns the first eager-build error, if
    /// any — its message is retained in `eager_error_msg` for `lastStoreError`.
    pub fn finishEagerBuilds(self: *DerivationStore) !void {
        if (!self.eager_build_enabled) return;
        self.eager_build_enabled = false;
        const rt = self.daemon_runtime orelse return;
        const err = rt.finishGraph();
        if (rt.takeErrorMsg()) |msg| {
            if (self.eager_error_msg) |old| self.allocator.free(old);
            self.eager_error_msg = msg;
        }
        if (err) |e| return e;
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
        errdefer d.deinit();
        // Apply per-connection settings once, before any build op — but only for
        // store-writing commands (build/instantiate/run/shell). Plain `eval` that
        // realizes on demand (import-from-derivation) must NOT push fix's resolved
        // config: fix lacks Nix's compiled-in defaults (e.g. `sandbox-paths`'s
        // `/bin/sh=<busybox>`), so its `extra-sandbox-paths`-only value would
        // *replace* the daemon's richer default and strip `/bin/sh` from the build
        // sandbox. The daemon already reads the same nix.conf, so its own config is
        // authoritative here.
        if (self.store_writes_enabled) {
            if (self.daemon_options) |opts| try d.setOptions(opts);
        }
        self.daemon = d;
        return d;
    }

    /// Read the last daemon error message (for surfacing `error.DaemonError`).
    /// Prefers an eager-build failure (the pump has its own connection, so its
    /// error is not on the eval `daemon`), else the eval connection's last error.
    pub fn lastStoreError(self: *DerivationStore) ?[]const u8 {
        if (self.eager_error_msg) |msg| return msg;
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
        if (self.offload) |off| {
            var cell: QueryCell = .{ .store = self, .store_path = store_path };
            off.run(off.ctx, QueryCell.run, &cell);
            if (cell.err) |e| return e;
            return cell.valid;
        }
        return self.applyIsValid(store_path);
    }

    const QueryCell = struct {
        store: *DerivationStore,
        store_path: []const u8,
        valid: bool = false,
        err: ?anyerror = null,

        fn run(p: *anyopaque) void {
            const c: *QueryCell = @ptrCast(@alignCast(p));
            c.valid = c.store.applyIsValid(c.store_path) catch |e| {
                c.err = e;
                return;
            };
        }
    };

    fn applyIsValid(self: *DerivationStore, store_path: []const u8) !bool {
        self.daemon_mu.lock();
        defer self.daemon_mu.unlock();
        if (self.instantiated.contains(store_path)) return true;
        const daemon = try self.ensureDaemon();
        return daemon.isValidPath(store_path);
    }

    /// Realize `derived_paths` (`<drvpath>!<outputs>`, legacy format) via the
    /// daemon, forwarding the build activity/log stream to `sink` if given.
    pub fn buildPaths(self: *DerivationStore, derived_paths: []const []const u8, sink: ?rstore.BuildSink, mode: rstore.BuildMode) !void {
        // If the work graph ran, its build workers left warm (options-applied)
        // connections in the runtime's pool. Reuse one for the terminal build
        // instead of forking a fresh `self.daemon` on the critical path. The
        // graph is finished by now (finishEagerBuilds joined its workers), so the
        // pool is idle and stable.
        if (self.daemon_runtime) |rt| {
            if (rt.hasBuildPool()) {
                rt.buildOnPool(derived_paths, sink, mode) catch |err| {
                    if (rt.takeErrorMsg()) |msg| {
                        if (self.eager_error_msg) |old| self.allocator.free(old);
                        self.eager_error_msg = msg;
                    }
                    return err;
                };
                return;
            }
        }
        self.daemon_mu.lock();
        defer self.daemon_mu.unlock();
        const daemon = try self.ensureDaemon();
        try daemon.buildPaths(derived_paths, sink, mode);
    }

    /// Realize `derived_paths` for import-from-derivation: like `buildPaths`,
    /// but dispatched onto the IO thread (when an offload is installed and we're
    /// on a fiber) so the demand fiber parks rather than blocking a compute
    /// worker on the daemon socket for the whole build. Inline otherwise (the
    /// `run`/`shell` main-thread callers). The borrowed `derived_paths` stay
    /// valid because the parked fiber's stack is preserved for the transfer.
    pub fn realizePaths(self: *DerivationStore, derived_paths: []const []const u8, mode: rstore.BuildMode) !void {
        if (self.offload) |off| {
            var cell: BuildCell = .{ .store = self, .paths = derived_paths, .mode = mode };
            off.run(off.ctx, BuildCell.run, &cell);
            return cell.err;
        }
        return self.buildPaths(derived_paths, null, mode);
    }

    const BuildCell = struct {
        store: *DerivationStore,
        paths: []const []const u8,
        mode: rstore.BuildMode,
        err: anyerror!void = {},

        fn run(p: *anyopaque) void {
            const self: *BuildCell = @ptrCast(@alignCast(p));
            self.err = self.store.buildPaths(self.paths, null, self.mode);
        }
    };

    /// Register `link_path` (an existing absolute symlink into the store) as an
    /// indirect GC root via the daemon.
    pub fn addIndirectRoot(self: *DerivationStore, link_path: []const u8) !void {
        self.daemon_mu.lock();
        defer self.daemon_mu.unlock();
        const daemon = try self.ensureDaemon();
        try daemon.addIndirectRoot(link_path);
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

    pub fn recordOwnedTextRecipe(self: *DerivationStore, store_path: []const u8, text: []u8, references: []const []const u8) !void {
        if (self.store_writes_enabled) {
            // With the work graph active (build/run/shell/switch), the `.drv`
            // write is asynchronous + dependency-ordered: hand `text` to the
            // graph (which owns it) and DON'T park — the graph writes it, ordered
            // after its referenced `.drv` writes, on a pool of connections. Plain
            // `instantiate` (no graph) keeps the synchronous parked write.
            if (self.eager_build_enabled) {
                return self.daemon_runtime.?.submitWrite(store_path, text, references);
            }
            defer self.allocator.free(text);
            return self.runDaemonOp(.{ .text = .{ .store_path = store_path, .text = text, .references = references } });
        }

        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();

        if (self.recipes.get(store_path)) |recipe| {
            defer self.allocator.free(text);
            if (recipe.isLazySource() or recipe.textMatches(text, references)) return;
            return error.RecipeConflict;
        }

        errdefer self.allocator.free(text);
        const recipe = try self.allocator.create(Recipe);
        errdefer self.allocator.destroy(recipe);
        const owned_refs = try cloneOwnedStrings(self.allocator, references);
        errdefer freeOwnedStrings(self.allocator, owned_refs);
        recipe.* = .{ .payload = .{ .text = .{ .bytes = text, .references = owned_refs } } };

        const key = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(key);
        try self.recipes.put(self.allocator, key, recipe);
    }

    pub fn recordOwnedNarRecipe(self: *DerivationStore, store_path: []const u8, nar_bytes: []u8) !void {
        if (self.store_writes_enabled) {
            defer self.allocator.free(nar_bytes);
            return self.runDaemonOp(.{ .path = .{ .store_path = store_path, .nar_bytes = nar_bytes } });
        }

        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();

        if (self.recipes.get(store_path)) |recipe| {
            defer self.allocator.free(nar_bytes);
            if (recipe.isLazySource() or recipe.narMatches(nar_bytes)) return;
            return error.RecipeConflict;
        }

        errdefer self.allocator.free(nar_bytes);
        const recipe = try self.allocator.create(Recipe);
        errdefer self.allocator.destroy(recipe);
        recipe.* = .{ .payload = .{ .nar = nar_bytes } };

        const key = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(key);
        try self.recipes.put(self.allocator, key, recipe);
    }

    /// Record a deferred plain-eval source: instead of retaining the eval-time
    /// NAR bytes, remember the (path, name) and re-serialize on demand (see
    /// `LazySource`). `store_path` is content-addressed, so an existing recipe of
    /// any kind for it already yields the same bytes — keep it. Only valid off
    /// the store-writes path (plain eval); the caller gates on `store_writes_enabled`.
    pub fn recordLazySourceRecipe(self: *DerivationStore, store_path: []const u8, path: []const u8, name: []const u8) !void {
        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();

        if (self.recipes.contains(store_path)) return;

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const recipe = try self.allocator.create(Recipe);
        errdefer self.allocator.destroy(recipe);
        recipe.* = .{ .payload = .{ .lazy_source = .{ .path = owned_path, .name = owned_name } } };

        const key = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(key);
        try self.recipes.put(self.allocator, key, recipe);
    }

    pub fn recordFlatRecipe(self: *DerivationStore, store_path: []const u8, handle: FileCache.ImmutableBytes) !void {
        if (self.store_writes_enabled) {
            return self.runDaemonOp(.{ .flat = .{ .store_path = store_path, .bytes = handle.bytes() } });
        }

        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();

        var retained = handle.retain();
        if (self.recipes.get(store_path)) |recipe| {
            defer retained.release();
            if (recipe.isLazySource() or recipe.flatMatches(handle)) return;
            return error.RecipeConflict;
        }
        errdefer retained.release();

        const recipe = try self.allocator.create(Recipe);
        errdefer self.allocator.destroy(recipe);
        recipe.* = .{ .payload = .{ .flat = retained } };

        const key = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(key);
        try self.recipes.put(self.allocator, key, recipe);
    }

    pub fn releaseRecipePayloads(self: *DerivationStore) void {
        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();
        var it = self.recipes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.recipes.clearRetainingCapacity();
    }

    const Visit = struct {
        path: []const u8,
        claim: *RealizationClaim,
        parent: ?*const Visit,
    };

    pub fn ensureClosure(self: *DerivationStore, store_path: []const u8) anyerror!void {
        if (self.offload) |off| {
            var cell: EnsureClosureCell = .{ .store = self, .store_path = store_path };
            off.run(off.ctx, EnsureClosureCell.run, &cell);
            return cell.err;
        }
        return self.ensureClosureInner(store_path, null);
    }

    const EnsureClosureCell = struct {
        store: *DerivationStore,
        store_path: []const u8,
        err: anyerror!void = {},

        fn run(pointer: *anyopaque) void {
            const self: *EnsureClosureCell = @ptrCast(@alignCast(pointer));
            self.err = self.store.ensureClosureInner(self.store_path, null);
        }
    };

    fn ensureClosureInner(self: *DerivationStore, store_path: []const u8, parent: ?*const Visit) anyerror!void {
        while (true) {
            // This runs inside the one outer realization offload when an I/O
            // executor is installed. Keep nested daemon operations inline on
            // that I/O thread so concurrent realization jobs cannot enqueue
            // work behind themselves.
            if (try self.applyIsValid(store_path)) return;
            if (visitContains(parent, store_path)) return error.RecipeCycle;

            const claim_result = try self.claimMissingPath(store_path);
            const claim = claim_result.claim;
            defer claim.release(self.allocator);

            if (comptime builtin.is_test) {
                if (claim_result.writer and parent == null) {
                    if (self.test_root_claim_hook) |hook| hook.observe(hook.ctx, store_path);
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

    pub fn realizeOutput(self: *DerivationStore, drv_path: []const u8, outputs: []const []const u8) !void {
        if (self.offload) |off| {
            var cell: RealizeOutputCell = .{ .store = self, .drv_path = drv_path, .outputs = outputs };
            off.run(off.ctx, RealizeOutputCell.run, &cell);
            return cell.err;
        }
        return self.realizeOutputInline(drv_path, outputs);
    }

    const RealizeOutputCell = struct {
        store: *DerivationStore,
        drv_path: []const u8,
        outputs: []const []const u8,
        err: anyerror!void = {},

        fn run(pointer: *anyopaque) void {
            const self: *RealizeOutputCell = @ptrCast(@alignCast(pointer));
            self.err = self.store.realizeOutputInline(self.drv_path, self.outputs);
        }
    };

    fn realizeOutputInline(self: *DerivationStore, drv_path: []const u8, outputs: []const []const u8) !void {
        try self.ensureClosureInner(drv_path, null);
        const derived = try self.derivedPathString(drv_path, outputs);
        defer self.allocator.free(derived);

        while (true) {
            self.recipe_mu.lock();
            const already_realized = self.realized_outputs.contains(derived);
            self.recipe_mu.unlock();
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
        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();
        const result = try self.realized_outputs.getOrPut(self.allocator, key);
        if (result.found_existing) self.allocator.free(key);
    }

    fn ensureClosureWriter(self: *DerivationStore, store_path: []const u8, visit: *const Visit) anyerror!void {
        const recipe = blk: {
            self.recipe_mu.lock();
            defer self.recipe_mu.unlock();
            break :blk self.recipes.get(store_path) orelse return error.MissingStoreRecipe;
        };

        for (recipe.references()) |reference| try self.ensureClosureInner(reference, visit);
        switch (recipe.payload) {
            .text => |text| try self.applyDaemonOp(.{ .text = .{ .store_path = store_path, .text = text.bytes, .references = text.references } }),
            .nar => |nar_bytes| try self.applyDaemonOp(.{ .path = .{ .store_path = store_path, .nar_bytes = nar_bytes } }),
            .flat => |bytes| try self.applyDaemonOp(.{ .flat = .{ .store_path = store_path, .bytes = bytes.bytes() } }),
            .lazy_source => |src| {
                // Deferred plain-eval source: re-serialize the NAR from disk now
                // (FileCache holds the eval-time content, so the bytes — and thus
                // the hash — match the store path computed at eval time), then add.
                const files = self.files orelse return error.MissingStoreRecipe;
                const nar_bytes = try nar.serialize(self.allocator, files, src.path, null);
                defer self.allocator.free(nar_bytes);
                try self.applyDaemonOp(.{ .path = .{ .store_path = store_path, .nar_bytes = nar_bytes } });
            },
        }
        self.releaseRecipeForPath(store_path);
    }

    fn claimMissingPath(self: *DerivationStore, store_path: []const u8) !struct { claim: *RealizationClaim, writer: bool } {
        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();

        if (self.realization_claims.get(store_path)) |claim| {
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
        try self.realization_claims.put(self.allocator, key, claim);
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
        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();
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
        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();
        if (source.waiting_on == target) {
            source.waiting_on = null;
            target.release(self.allocator);
        }
    }

    fn waitForClaim(self: *DerivationStore, claim: *RealizationClaim) RealizationClaim.State {
        _ = self;
        while (true) {
            claim.mu.lock();
            const state = claim.state;
            if (state != .writing) {
                claim.mu.unlock();
                return state;
            }
            const seq = claim.seq.load(.acquire);
            claim.mu.unlock();
            stable.Futex.wait(&claim.seq, seq);
        }
    }

    fn finishSuccessfulClaim(self: *DerivationStore, store_path: []const u8, claim: *RealizationClaim) void {
        self.removeClaim(store_path, claim);
        claim.publish(.success, null);
    }

    fn finishRetryableClaim(self: *DerivationStore, store_path: []const u8, claim: *RealizationClaim, err: anyerror) void {
        self.removeClaim(store_path, claim);
        claim.publish(.retry, err);
    }

    fn removeClaim(self: *DerivationStore, store_path: []const u8, claim: *RealizationClaim) void {
        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();
        const removed = self.realization_claims.fetchRemove(store_path) orelse return;
        std.debug.assert(removed.value == claim);
        self.allocator.free(removed.key);
        claim.release(self.allocator);
    }

    fn releaseRecipeForPath(self: *DerivationStore, store_path: []const u8) void {
        self.recipe_mu.lock();
        defer self.recipe_mu.unlock();
        const removed = self.recipes.fetchRemove(store_path) orelse return;
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

    fn cloneOwnedStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![][]u8 {
        const result = try allocator.alloc([]u8, strings.len);
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |string| allocator.free(string);
            allocator.free(result);
        }
        while (initialized < result.len) : (initialized += 1) {
            result[initialized] = try allocator.dupe(u8, strings[initialized]);
        }
        return result;
    }

    fn freeOwnedStrings(allocator: std.mem.Allocator, strings: [][]u8) void {
        for (strings) |string| allocator.free(string);
        allocator.free(strings);
    }

    fn retryableRealizationError(err: anyerror) bool {
        return switch (err) {
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

    /// Build the composite source-memo key, owned by `key_allocator`.
    /// Unfiltered: `<r|f><name>\x00<abs-path>`. Filtered: the same, plus
    /// `\x00<filter-object-id>` — so a filtered ingest can never collide with the
    /// unfiltered one (or a different filter) for the same path+name. `name` is a
    /// validated store-path name (no NUL) and `path` is a filesystem path (no
    /// NUL), so the NUL separators are unambiguous.
    fn sourceMemoKey(
        key_allocator: std.mem.Allocator,
        path: []const u8,
        name: []const u8,
        recursive: bool,
        filter_id: ?u32,
    ) ![]u8 {
        const rf: u8 = if (recursive) 'r' else 'f';
        if (filter_id) |fid| {
            return std.fmt.allocPrint(key_allocator, "{c}{s}\x00{s}\x00{d}", .{ rf, name, path, fid });
        }
        return std.fmt.allocPrint(key_allocator, "{c}{s}\x00{s}", .{ rf, name, path });
    }

    /// Look up a memoized ingestion. On a hit, the store path + NAR hash are
    /// duplicated into `out_allocator` (caller-owned, for an `Ingested`).
    ///
    /// `filter_id`/`token` are null for unfiltered ingests (keyed purely on
    /// content-stable path+name, so they survive GCs). For a *filtered* ingest
    /// the key includes the filter lambda's ObjectId, which a GC can reuse for a
    /// different lambda — so `token` (the heap GC token) is stored per entry and
    /// a mismatch is treated as a miss, exactly like `lookupLazyDerivation`.
    pub fn lookupSourceMemo(
        self: *DerivationStore,
        out_allocator: std.mem.Allocator,
        path: []const u8,
        name: []const u8,
        recursive: bool,
        filter_id: ?u32,
        token: ?u64,
    ) !?SourceMemoHit {
        const key = try sourceMemoKey(self.allocator, path, name, recursive, filter_id);
        defer self.allocator.free(key);
        self.source_memo_mu.lock();
        defer self.source_memo_mu.unlock();
        const entry = self.source_memo.get(key) orelse return null;
        if (token) |t| if (entry.token != t) return null; // filter-id reused after GC
        const store_path = try out_allocator.dupe(u8, entry.store_path);
        errdefer out_allocator.free(store_path);
        const nar_hash = try out_allocator.dupe(u8, entry.nar_hash);
        return SourceMemoHit{ .store_path = store_path, .nar_hash = nar_hash };
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
        const key = try sourceMemoKey(self.allocator, path, name, recursive, filter_id);
        errdefer self.allocator.free(key);
        const owned_store_path = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(owned_store_path);
        const owned_nar_hash = try self.allocator.dupe(u8, nar_hash);
        errdefer self.allocator.free(owned_nar_hash);

        self.source_memo_mu.lock();
        defer self.source_memo_mu.unlock();
        const gop = try self.source_memo.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(key);
            const stale = filter_id != null and gop.value_ptr.token != token;
            if (!stale) {
                self.allocator.free(owned_store_path);
                self.allocator.free(owned_nar_hash);
                return;
            }
            self.allocator.free(gop.value_ptr.store_path);
            self.allocator.free(gop.value_ptr.nar_hash);
        }
        gop.value_ptr.* = .{ .store_path = owned_store_path, .nar_hash = owned_nar_hash, .token = token };
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
