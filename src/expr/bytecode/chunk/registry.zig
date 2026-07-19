//! Concurrent chunk registry, deduplication, sidecars, and registry tests.

const std = @import("std");
const types = @import("runtime").types;
const OpCode = @import("../opcode.zig").OpCode;
const Value = @import("runtime").value.Value;
const segments = @import("base").segments;
const sync = @import("base").sync;
const name_tree_mod = @import("../name_tree.zig");
const model = @import("model.zig");
const builder_mod = @import("builder.zig");
const Chunk = model.Chunk;
const LambdaPattern = model.LambdaPattern;
const TrivialBody = model.TrivialBody;
const ChunkBuilder = builder_mod.ChunkBuilder;
const ChunkId = types.ChunkId;
const ConstIdx = types.ConstIdx;
const readU16Inline = builder_mod.readU16Inline;
const readU32Inline = builder_mod.readU32Inline;

/// Well-known chunk ids registered eagerly at `ChunkRegistry.init`. These
/// are tiny stub chunks that builtins use to materialise lazy values
/// without allocating a per-element `builtin_closure` object — see
/// `genlist_apply` for the canonical example.
pub const WellKnownChunks = struct {
    /// Stub chunk for `builtins.genList` element thunks. Body:
    ///   `up_get 0; up_get 1; call_tail; ret; halt`
    /// Upvalues are `[func, index]`. Forcing the thunk calls
    /// `func index` and returns the result. Replaces the
    /// `builtin_closure(.mapValue, [func, index])` per element that
    /// would otherwise allocate one extra Object per genList slot.
    /// Reused by `builtins.map` since the body is the same single-arg
    /// application regardless of whether arg 1 is an index or a list
    /// item.
    genlist_apply: ChunkId,
    /// Stub chunk for `builtins.mapAttrs` element thunks. Body:
    ///   `up_get 0; up_get 1; call; up_get 2; call_tail;
    ///    ret; halt`
    /// Upvalues are `[func, name, value]`. Forcing the thunk calls
    /// `(func name) value` (partial application then tail call).
    /// Replaces the `builtin_closure(.mapAttrValue, ...)` + Thunk pair
    /// the old path allocated per attr.
    mapattrs_apply: ChunkId,
};

/// Global chunk registry. Chunks are stored here and referenced by ChunkId.
/// This is the "program" that the VM executes.
///
/// Thread safety:
///   - `get(id)` is lock-free.
///   - `register(chunk)` serializes on the underlying segments' writer mutex.
pub const ChunkRegistry = struct {
    /// Dense per-chunk slot: the Chunk pointer plus a copy of the hot
    /// scheduling metadata. The thunk-creation path (`thunk`,
    /// ~6M executions per NixOS toplevel) and the speculation gates only
    /// need `trivial`/`body_is_substantial`; reading them through `ptr`
    /// is a cache-missing deref into a heap-scattered Chunk, while the
    /// slot array is dense and hot chunk ids repeat. `ptr` is only
    /// dereferenced by paths that need the code/constants themselves.
    pub const ChunkSlot = struct {
        ptr: *Chunk,
        /// Qualified-name node in `name_tree` (0 = anonymous). Always populated
        /// (not gated), cheap, thread-safe — this is what traces/errors/disasm
        /// read for a chunk's `pkgs.hello`-style name.
        name: name_tree_mod.NameId = name_tree_mod.root_name_id,
        trivial: TrivialBody,
        body_is_substantial: bool,
        /// Untrusted-band bit (see `SchedulingHints.spec_band_small`):
        /// speculative tasks rooted at this chunk run under the hard
        /// creation budget.
        spec_band_small: bool = false,
        strict_param: bool,
        strict_via_upvalue: ?u16,
        /// Novelty gate (`FIX_SPEC_NOVEL`): set by the FIRST creation-time
        /// speculative submission of any thunk of this chunk (see
        /// `markSpecSubmitted`). A never-before-submitted chunk is a new
        /// code region — a potential subsystem/chain root worth running
        /// ahead of the repeat-instance churn; later instances of the same
        /// chunk are the bulk speculation stream.
        spec_submitted: std.atomic.Value(u8) = .init(0),
    };

    const Store = segments.StableSegments(ChunkSlot, .{ .first_segment_size = 64 }, @import("runtime").mem_tag.vma);

    const dedup_shard_count = 64;
    /// One shard of the content-addressed dedup map. `align(cache_line)` on
    /// the shard lock keeps neighboring shards out of each other's cache
    /// lines (each shard is padded to a full line).
    const DedupShard = struct {
        mu: sync.SpinMutex align(std.atomic.cache_line) = .{},
        map: std.AutoHashMapUnmanaged(u64, ChunkId) = .empty,
    };

    allocator: std.mem.Allocator,
    chunks: Store,
    well_known: WellKnownChunks,
    /// Always-on qualified-name tree (see `name_tree.zig`). The compiler
    /// populates it; each `ChunkSlot.name` indexes into it. Unlike the
    /// `capture_names` sidecar below, this is cheap and thread-safe, so names
    /// are available in every run for traces/errors — not just under disasm.
    name_tree: name_tree_mod.NameTree = .{},
    /// Best-effort debugger/disasm sidecars. Populated only while
    /// `capture_names` is set — off by default so ordinary compiles pay nothing
    /// and the hot `Chunk` layout is untouched. The REPL enables these while
    /// retaining parallel import compilation, so map access is synchronized.
    capture_names: bool = false,
    sidecar_mu: sync.BlockingMutex = .{},
    /// The source file each chunk was compiled from (interned path id), so even
    /// chunks with no per-op source map get a file. Populated under name capture.
    files: std.AutoHashMapUnmanaged(ChunkId, types.InternId) = .empty,
    /// Per-chunk upvalue binding names (slot order), from the compiler's capture
    /// list. Slices owned by `allocator`. Chunk *names* live in `name_tree`.
    upvalue_names: std.AutoHashMapUnmanaged(ChunkId, []types.InternId) = .empty,
    /// Per-chunk LOCAL binding names indexed by stack slot (let bindings + lambda
    /// params). Slots are monotonic per chunk, so this is a flat slot→name array.
    /// Used by the debugger to resolve breakpoint-scope identifiers.
    local_names: std.AutoHashMapUnmanaged(ChunkId, []types.InternId) = .empty,
    /// Content-addressed dedup of chunk registrations: structurally identical
    /// chunks are semantically interchangeable, so re-registrations reuse the
    /// first id (the generalization of the hand-picked WellKnownChunks).
    /// Sharded by hash bits (see `DedupShard`): registrations come from every
    /// compiling worker (deferred bodies + speculative compiles, ~264K at
    /// w=8), and one global lock held across the full structural memcmp
    /// burned ~3-4% of all w=8 cycles in spin. Each shard carries its own
    /// lock, and the memcmp runs OUTSIDE it (see `registerDeduped`).
    dedup_shards: [dedup_shard_count]DedupShard = [_]DedupShard{.{}} ** dedup_shard_count,
    /// Single-threaded mode: when the owner guarantees exactly one thread
    /// ever registers chunks (a `--workers=1` evaluator; set before anything
    /// runs), `registerDeduped` skips the dedup shard mutexes and `register`
    /// takes the serial (CAS-free) slot append. ~2 lock RMWs + 1 CAS per
    /// registration elided (~213K registrations per NixOS-toplevel eval).
    /// Reads (`get`) were always lock-free. Default off.
    solo: bool = false,

    pub fn init(allocator: std.mem.Allocator) !ChunkRegistry {
        var self: ChunkRegistry = .{
            .allocator = allocator,
            .chunks = .empty,
            .well_known = .{ .genlist_apply = 0, .mapattrs_apply = 0 },
        };
        errdefer self.deinit();
        self.well_known.genlist_apply = try self.registerGenListApplyChunk();
        self.well_known.mapattrs_apply = try self.registerMapAttrsApplyChunk();
        return self;
    }

    fn registerGenListApplyChunk(self: *ChunkRegistry) !ChunkId {
        var builder = try ChunkBuilder.init(self.allocator);
        defer builder.deinit(self.allocator);

        // up_grab 0 — push func, unforced. builtinMap/builtinGenList
        // force fn_arg before storing it as upvalue 0, so it's already
        // callable.
        try builder.writeOp(self.allocator, .up_grab);
        try builder.writeU16(self.allocator, 0);
        // up_grab 1 — push index or item, *unforced*. Passing
        // unforced lets the user fn decide laziness — same reasoning as
        // the mapattrs_apply value upvalue (see registerMapAttrsApplyChunk).
        try builder.writeOp(self.allocator, .up_grab);
        try builder.writeU16(self.allocator, 1);
        // call_tail      — call func with index/item
        try builder.writeOp(self.allocator, .call_tail);
        // ret            — return result (call_tail to a closure transfers
        //                  control; ret only runs when callee was a builtin)
        try builder.writeOp(self.allocator, .ret);
        // halt           — sentinel
        try builder.writeOp(self.allocator, .halt);

        const chunk = try builder.finish(self.allocator, 0);
        return self.register(chunk);
    }

    fn registerMapAttrsApplyChunk(self: *ChunkRegistry) !ChunkId {
        var builder = try ChunkBuilder.init(self.allocator);
        defer builder.deinit(self.allocator);

        // up_grab 0 — push func, unforced. mapAttrs only takes
        // this path when fn_arg is already callable; no force needed.
        try builder.writeOp(self.allocator, .up_grab);
        try builder.writeU16(self.allocator, 0);
        // up_grab 1 — push name. mapAttrs stores `Value.string`
        // here, so force would be a no-op anyway.
        try builder.writeOp(self.allocator, .up_grab);
        try builder.writeU16(self.allocator, 1);
        // call           — partial = func name (result on stack)
        try builder.writeOp(self.allocator, .call);
        // up_grab 2 — push value *unforced*. `value` is whatever
        // the source attrset stored, typically a thunk. Forcing it here
        // (the old `up_get`) eagerly evaluated entries that the
        // user lambda would otherwise treat lazily — when the lambda
        // captures the parent recursive attrset (typical NixOS module
        // pattern), the eager force routes through that parent and
        // blackholes. Passing unforced lets the user lambda decide.
        try builder.writeOp(self.allocator, .up_grab);
        try builder.writeU16(self.allocator, 2);
        // call_tail      — partial value
        try builder.writeOp(self.allocator, .call_tail);
        try builder.writeOp(self.allocator, .ret);
        try builder.writeOp(self.allocator, .halt);

        const chunk = try builder.finish(self.allocator, 0);
        return self.register(chunk);
    }

    pub fn deinit(self: *ChunkRegistry) void {
        var id: u32 = 0;
        const total = self.chunks.count();
        while (id < total) : (id += 1) {
            const chunk = self.chunks.get(id).ptr;
            chunk.deinit(self.allocator);
            self.allocator.destroy(chunk);
        }
        self.chunks.deinit(self.allocator);
        self.files.deinit(self.allocator);
        var it = self.upvalue_names.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.upvalue_names.deinit(self.allocator);
        var lit = self.local_names.valueIterator();
        while (lit.next()) |v| self.allocator.free(v.*);
        self.local_names.deinit(self.allocator);
        self.name_tree.deinit(self.allocator);
        for (&self.dedup_shards) |*shard| shard.map.deinit(self.allocator);
    }

    /// Record the source file a chunk was compiled from. No-op unless
    /// `capture_names` is on.
    pub fn recordFile(self: *ChunkRegistry, id: ChunkId, file: types.InternId) !void {
        if (!self.capture_names) return;
        self.sidecar_mu.lock();
        defer self.sidecar_mu.unlock();
        try self.files.put(self.allocator, id, file);
    }

    /// Record the chunk's upvalue binding names (slot order). No-op unless
    /// `capture_names` is on; the slice is duped into the registry.
    pub fn recordUpvalueNames(self: *ChunkRegistry, id: ChunkId, names_in: []const types.InternId) !void {
        if (!self.capture_names or names_in.len == 0) return;
        const copy = try self.allocator.dupe(types.InternId, names_in);
        errdefer self.allocator.free(copy);
        self.sidecar_mu.lock();
        defer self.sidecar_mu.unlock();
        const gop = try self.upvalue_names.getOrPut(self.allocator, id);
        // Deduped chunks keep the first registration's diagnostic sidecar.
        // Never replace/free it: readers may hold this append-stable slice
        // after dropping the map lock.
        if (gop.found_existing) {
            self.allocator.free(copy);
            return;
        }
        gop.value_ptr.* = copy;
    }

    /// The chunk's recorded upvalue names (slot order), if any.
    pub fn upvalueNamesOf(self: *const ChunkRegistry, id: ChunkId) ?[]const types.InternId {
        if (!self.capture_names) return null;
        const mutable = @constCast(self);
        mutable.sidecar_mu.lock();
        defer mutable.sidecar_mu.unlock();
        return self.upvalue_names.get(id);
    }

    /// Record the chunk's local binding names indexed by stack slot. No-op
    /// unless `capture_names` is on; the slice is duped into the registry.
    pub fn recordLocalNames(self: *ChunkRegistry, id: ChunkId, names_in: []const types.InternId) !void {
        if (!self.capture_names or names_in.len == 0) return;
        const copy = try self.allocator.dupe(types.InternId, names_in);
        errdefer self.allocator.free(copy);
        self.sidecar_mu.lock();
        defer self.sidecar_mu.unlock();
        const gop = try self.local_names.getOrPut(self.allocator, id);
        if (gop.found_existing) {
            self.allocator.free(copy);
            return;
        }
        gop.value_ptr.* = copy;
    }

    /// The chunk's recorded local names (slot order), if any.
    pub fn localNamesOf(self: *const ChunkRegistry, id: ChunkId) ?[]const types.InternId {
        if (!self.capture_names) return null;
        const mutable = @constCast(self);
        mutable.sidecar_mu.lock();
        defer mutable.sidecar_mu.unlock();
        return self.local_names.get(id);
    }

    /// Write `id`'s always-on qualified name (`pkgs.hello`) into `w`, or nothing
    /// if the chunk is anonymous. Reads the `name_tree`; no allocation, no flag.
    pub fn writeQualifiedName(self: *const ChunkRegistry, w: *std.Io.Writer, id: ChunkId, intern: *const @import("runtime").intern.InternTable) !void {
        const s = self.slot(id) orelse return;
        try self.name_tree.writeQualified(w, s.name, intern);
    }

    /// Whether `id` has an always-on qualified name.
    pub fn hasQualifiedName(self: *const ChunkRegistry, id: ChunkId) bool {
        const s = self.slot(id) orelse return false;
        return self.name_tree.isNamed(s.name);
    }

    /// The qualified-name node attached to a chunk. Anonymous chunks attach to
    /// the implicit root. Used by cold inspection indexes; hot VM paths should
    /// continue reading their purpose-specific fields from `ChunkSlot`.
    pub fn nameOf(self: *const ChunkRegistry, id: ChunkId) ?name_tree_mod.NameId {
        const s = self.slot(id) orelse return null;
        return s.name;
    }

    /// Read-only access to the append-only naming hierarchy for tooling.
    pub fn nameCount(self: *const ChunkRegistry) u32 {
        return self.name_tree.count();
    }

    pub fn nameNode(self: *const ChunkRegistry, id: name_tree_mod.NameId) ?name_tree_mod.NameTree.NodeView {
        return self.name_tree.node(id);
    }

    /// Intern a child name under `parent` for `segment` (compiler use, during
    /// its top-down descent). `synthetic` selects the `·` joiner.
    pub fn childName(self: *ChunkRegistry, parent: name_tree_mod.NameId, segment: types.InternId, synthetic: bool) !name_tree_mod.NameId {
        return self.name_tree.child(self.allocator, parent, segment, synthetic);
    }

    /// The source file recorded for `id`, if any.
    pub fn fileOf(self: *const ChunkRegistry, id: ChunkId) ?types.InternId {
        if (!self.capture_names) return null;
        const mutable = @constCast(self);
        mutable.sidecar_mu.lock();
        defer mutable.sidecar_mu.unlock();
        return self.files.get(id);
    }

    // Every field of `Chunk` must either be covered by `contentHash` AND
    // `contentEql` or be derived from covered fields (`scheduling` is the
    // one derived field today): a semantic field missing from both silently
    // merges chunks that differ in it. If you add a field, teach BOTH
    // functions about it, then bump this count. Diagnostic-only metadata
    // (names, files, upvalue names, ...) belongs in the registry sidecar
    // maps instead — those are keyed by id after registration and never
    // perturb dedup.
    comptime {
        const chunk_field_count = 14;
        if (std.meta.fields(Chunk).len != chunk_field_count)
            @compileError("Chunk changed shape: update contentHash + contentEql (or route diagnostic-only metadata through the registry sidecar), then adjust chunk_field_count.");
    }

    /// Deterministic content hash over everything that makes a chunk what it
    /// is. Optionals/structs are fed field-by-field (never as raw bytes) so
    /// undefined padding can't perturb the hash.
    fn contentHash(chunk: *const Chunk) u64 {
        // The hash is only a bucket key — collisions fall through to
        // `contentEql`, which stays FULL. Instead of per-entry
        // attr_pos/source_map walks (the +512M instr/eval cost measured at
        // 77befca), mix in a cheap positional fingerprint: lens + first/last
        // source-map span line. Position-divergent clones collide into one
        // bucket and the loser registers normally via `contentEql`, so the
        // dedup rate is unchanged.
        var h = std.hash.Wyhash.init(0);
        h.update(chunk.code);
        h.update(std.mem.sliceAsBytes(chunk.constants));
        h.update(std.mem.sliceAsBytes(chunk.attr_names));
        h.update(chunk.capture_bytes);
        h.update(std.mem.sliceAsBytes(chunk.function_args));
        h.update(std.mem.sliceAsBytes(chunk.function_arg_pos));
        var fp: [4]u32 = .{ @intCast(chunk.attr_pos.len), @intCast(chunk.source_map.len), 0, 0 };
        if (chunk.source_map.len > 0) {
            fp[2] = chunk.source_map[0].span.line;
            fp[3] = chunk.source_map[chunk.source_map.len - 1].span.line;
        }
        h.update(std.mem.sliceAsBytes(&fp));
        if (chunk.body_span) |bs| hashSpan(&h, bs);
        h.update(std.mem.asBytes(&chunk.local_count));
        h.update(std.mem.asBytes(&chunk.arity));
        h.update(std.mem.asBytes(&chunk.strict_params));
        switch (chunk.lambda_pattern) {
            .none => h.update(&.{0}),
            .var_pat => |id| {
                h.update(&.{1});
                h.update(std.mem.asBytes(&id));
            },
            .attrs_pat => |ap| {
                h.update(&.{2});
                h.update(std.mem.asBytes(&ap.bind_name));
                h.update(std.mem.asBytes(&ap.has_bind));
                h.update(std.mem.asBytes(&ap.ellipsis));
            },
        }
        return h.final();
    }

    fn hashSpan(h: *std.hash.Wyhash, span: Chunk.SourceSpan) void {
        const file: types.InternId = span.file orelse 0xFFFF_FFFF;
        h.update(std.mem.asBytes(&file));
        h.update(std.mem.asBytes(&span.offset));
        h.update(std.mem.asBytes(&span.len));
        h.update(std.mem.asBytes(&span.line));
        h.update(std.mem.asBytes(&span.column));
    }

    fn spanEql(a: Chunk.SourceSpan, b: Chunk.SourceSpan) bool {
        return std.meta.eql(a.file, b.file) and a.offset == b.offset and a.len == b.len and a.line == b.line and a.column == b.column;
    }

    /// Full structural equality — byte/field-equal chunks are indistinguishable
    /// (identical semantics AND identical diagnostics/positions), so sharing
    /// one registration is observation-free.
    fn contentEql(a: *const Chunk, b: *const Chunk) bool {
        if (a.local_count != b.local_count or a.arity != b.arity or a.strict_params != b.strict_params) return false;
        if (!std.mem.eql(u8, a.code, b.code)) return false;
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(a.constants), std.mem.sliceAsBytes(b.constants))) return false;
        if (!std.mem.eql(types.InternId, a.attr_names, b.attr_names)) return false;
        if (a.attr_pos.len != b.attr_pos.len) return false;
        for (a.attr_pos, b.attr_pos) |x, y| {
            if (x.name != y.name or x.pos.file != y.pos.file or x.pos.line != y.pos.line or x.pos.column != y.pos.column) return false;
        }
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(a.function_args), std.mem.sliceAsBytes(b.function_args))) return false;
        if (a.function_arg_pos.len != b.function_arg_pos.len) return false;
        for (a.function_arg_pos, b.function_arg_pos) |x, y| {
            if (x.name != y.name or x.pos.file != y.pos.file or x.pos.line != y.pos.line or x.pos.column != y.pos.column) return false;
        }
        if (!std.mem.eql(u8, a.capture_bytes, b.capture_bytes)) return false;
        if (a.source_map.len != b.source_map.len) return false;
        for (a.source_map, b.source_map) |x, y| {
            if (x.start != y.start or x.end != y.end or !spanEql(x.span, y.span)) return false;
        }
        if ((a.body_span == null) != (b.body_span == null)) return false;
        if (a.body_span) |ba| if (!spanEql(ba, b.body_span.?)) return false;
        if (!lambdaPatternEql(a.lambda_pattern, b.lambda_pattern)) return false;
        return true;
    }

    fn lambdaPatternEql(a: LambdaPattern, b: LambdaPattern) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .none => true,
            .var_pat => |id| id == b.var_pat,
            .attrs_pat => |ap| ap.bind_name == b.attrs_pat.bind_name and
                ap.has_bind == b.attrs_pat.has_bind and ap.ellipsis == b.attrs_pat.ellipsis,
        };
    }

    /// Register `chunk`, reusing an existing structurally identical
    /// registration when possible (see `dedup_shards`). Returns the id and
    /// whether it was reused — reused=true means the caller still owns (and
    /// must deinit) its own copy of `chunk`.
    pub const RegisterResult = struct {
        id: ChunkId,
        reused: bool,
        /// Slot published by this call. It can differ from `id` when a
        /// concurrent equal registration wins canonical deduplication.
        new_id: ?ChunkId,
    };

    pub fn registerDeduped(self: *ChunkRegistry, chunk: Chunk, name: name_tree_mod.NameId) !RegisterResult {
        const h = contentHash(&chunk);
        const shard = &self.dedup_shards[@as(usize, @intCast(h >> 58))];

        // Snapshot the candidate id under the shard lock; run the full
        // structural memcmp OUTSIDE it. Registered chunks are immutable and
        // ids are never removed, so a snapshot can't go stale — the lock only
        // has to protect the map itself.
        if (!self.solo) shard.mu.lock();
        const candidate = shard.map.get(h);
        if (!self.solo) shard.mu.unlock();

        if (candidate) |existing| {
            if (contentEql(self.get(existing).?, &chunk)) {
                return .{ .id = existing, .reused = true, .new_id = null };
            }
            // Hash collision with different content. `h`'s map entry is
            // permanent (first writer wins, entries are never replaced), so
            // there is nothing to insert: register plain, as before.
            const id = try self.registerNamed(chunk, name);
            return .{ .id = id, .reused = false, .new_id = id };
        }

        const id = try self.registerNamed(chunk, name);
        if (!self.solo) shard.mu.lock();
        const inserted = blk: {
            const gop = shard.map.getOrPut(self.allocator, h) catch |err| {
                if (!self.solo) shard.mu.unlock();
                return err;
            };
            if (gop.found_existing) break :blk gop.value_ptr.*;
            gop.value_ptr.* = id;
            break :blk null;
        };
        if (!self.solo) shard.mu.unlock();
        const winner = inserted orelse return .{ .id = id, .reused = false, .new_id = id };

        // A concurrent registration won the insert race for this hash while
        // we were registering. When it is content-equal (the common case: the
        // same body compiled speculatively on two workers), converge on the
        // winner id so equal registrations always resolve to one id. Our copy
        // is already owned by the registry — report reused=false so the
        // caller doesn't deinit it; it stays registered but unreferenced
        // (benign). A mere hash collision keeps our own id.
        if (contentEql(self.get(winner).?, self.get(id).?)) {
            return .{ .id = winner, .reused = false, .new_id = id };
        }
        return .{ .id = id, .reused = false, .new_id = id };
    }

    pub fn register(self: *ChunkRegistry, chunk: Chunk) !ChunkId {
        return self.registerNamed(chunk, name_tree_mod.root_name_id);
    }

    /// `register`, tagging the chunk with its qualified-name node (see
    /// `name_tree`). The compiler passes the name it built while descending.
    pub fn registerNamed(self: *ChunkRegistry, chunk: Chunk, name: name_tree_mod.NameId) !ChunkId {
        const stored = try self.allocator.create(Chunk);
        errdefer {
            stored.deinit(self.allocator);
            self.allocator.destroy(stored);
        }
        stored.* = chunk;
        // Lock-free registration: many workers compile (deferred bodies +
        // speculative imports) concurrently; the writer-mutex append serialized
        // them per-chunk. `appendAtomic` CAS-bumps the cursor instead. In
        // solo mode (single-worker evaluator) the serial append drops the CAS.
        const new_slot: ChunkSlot = .{
            .ptr = stored,
            .name = name,
            .trivial = stored.scheduling.trivial,
            .body_is_substantial = stored.scheduling.body_is_substantial,
            .spec_band_small = stored.scheduling.spec_band_small,
            .strict_param = stored.scheduling.strict_param,
            .strict_via_upvalue = stored.scheduling.strict_via_upvalue,
        };
        const id = if (self.solo)
            try self.chunks.appendSerial(self.allocator, new_slot)
        else
            try self.chunks.appendAtomic(self.allocator, new_slot);
        return id;
    }

    pub fn get(self: *const ChunkRegistry, id: ChunkId) ?*const Chunk {
        if (id >= self.chunks.count()) return null;
        return self.chunks.get(id).ptr;
    }

    /// Dense-slot accessor for the hot metadata paths (see `ChunkSlot`).
    pub fn slot(self: *const ChunkRegistry, id: ChunkId) ?*const ChunkSlot {
        if (id >= self.chunks.count()) return null;
        return self.chunks.get(id);
    }

    /// Novelty test-and-set (`FIX_SPEC_NOVEL`): returns true exactly once
    /// per chunk — for the first caller ever to submit a creation-time
    /// speculation of this chunk. Atomic swap: concurrent first-instance
    /// creations on different workers race benignly (one wins the novel
    /// slot, the rest take the bulk lane).
    pub fn markSpecSubmitted(self: *ChunkRegistry, id: ChunkId) bool {
        if (id >= self.chunks.count()) return false;
        return self.chunks.getMut(id).spec_submitted.swap(1, .monotonic) == 0;
    }

    pub fn count(self: *const ChunkRegistry) u32 {
        return self.chunks.count();
    }

    pub const Stats = struct {
        chunks: u32,
        code_bytes: u64,
        const_count: u64,
        source_map_entries: u64,
        size_buckets: [6]u32, // <16, <64, <256, <1024, <4096, >=4096
        max_code_bytes: u32,
        /// Chunks with a non-empty strictness signature.
        with_strictness: u32,
        /// Chunks marked `speculatable` by the size heuristic.
        speculatable: u32,
        /// Chunks that are both speculatable AND have a non-empty
        /// strictness signature — the intersection that Phase B/C will
        /// be able to schedule deterministically instead of speculating.
        speculatable_with_strictness: u32,

        pub fn bucketLabel(index: usize) []const u8 {
            return switch (index) {
                0 => "<16",
                1 => "16-63",
                2 => "64-255",
                3 => "256-1023",
                4 => "1024-4095",
                5 => ">=4096",
                else => "?",
            };
        }
    };

    pub fn stats(self: *const ChunkRegistry) Stats {
        var result: Stats = .{
            .chunks = self.chunks.count(),
            .code_bytes = 0,
            .const_count = 0,
            .source_map_entries = 0,
            .size_buckets = [_]u32{0} ** 6,
            .max_code_bytes = 0,
            .with_strictness = 0,
            .speculatable = 0,
            .speculatable_with_strictness = 0,
        };
        var id: u32 = 0;
        while (id < result.chunks) : (id += 1) {
            const ch = self.chunks.get(id).ptr;
            const len: u32 = @intCast(ch.code.len);
            result.code_bytes += len;
            result.const_count += ch.constants.len;
            result.source_map_entries += ch.source_map.len;
            if (len > result.max_code_bytes) result.max_code_bytes = len;
            const bucket: usize = if (len < 16) 0 else if (len < 64) 1 else if (len < 256) 2 else if (len < 1024) 3 else if (len < 4096) 4 else 5;
            result.size_buckets[bucket] += 1;
            const strict = ch.scheduling.strictness;
            const has_strict = (strict.forced_upvalues | strict.deep_upvalues) != 0;
            if (has_strict) result.with_strictness += 1;
            if (ch.scheduling.body_is_substantial) result.speculatable += 1;
            if (ch.scheduling.body_is_substantial and has_strict) result.speculatable_with_strictness += 1;
        }
        return result;
    }
};

test "chunk builder emits opcodes and operands into the code stream" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .loc_get);
    try builder.writeByte(allocator, 3);
    try builder.writeOp(allocator, .jump);
    try builder.writeU32(allocator, 10);

    var chunk = try builder.finish(allocator, 1);
    defer chunk.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 7), chunk.code.len);
    try std.testing.expectEqual(@intFromEnum(OpCode.loc_get), chunk.code[0]);
    try std.testing.expectEqual(@as(u8, 3), chunk.code[1]);
    try std.testing.expectEqual(@intFromEnum(OpCode.jump), chunk.code[2]);
    try std.testing.expectEqual(@as(u32, 10), readU32Inline(chunk.code, 3));
}

test "chunk builder patches a forward jump offset after emission" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .jump_false);
    const patch_at = builder.code.items.len;
    try builder.writeU32(allocator, 0); // placeholder, patched below
    try builder.writeOp(allocator, .push_null);
    try builder.writeOp(allocator, .ret);

    // Patch the placeholder now that we know how far to jump.
    const target = builder.code.items.len;
    const offset: u32 = @intCast(target - (patch_at + 4));
    std.mem.writeInt(u32, builder.code.items[patch_at..][0..4], offset, .little);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    const decoded = readU32Inline(chunk.code, patch_at);
    try std.testing.expectEqual(offset, decoded);
    // The patched jump should land exactly at the end of the code.
    try std.testing.expectEqual(chunk.code.len, patch_at + 4 + decoded);
}

test "addConstant deduplicates exact values and reset clears its index" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    const first = try builder.addConstant(allocator, Value.int(7));
    const second = try builder.addConstant(allocator, Value.int(7));
    const distinct = try builder.addConstant(allocator, Value.int(8));

    try std.testing.expectEqual(@as(ConstIdx, 0), first);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(ConstIdx, 1), distinct);
    try std.testing.expectEqual(@as(usize, 2), builder.constants.items.len);

    builder.reset();
    const after_reset = try builder.addConstant(allocator, Value.int(7));
    try std.testing.expectEqual(@as(ConstIdx, 0), after_reset);
    try std.testing.expectEqual(@as(usize, 1), builder.constants.items.len);
}

test "emitConstant writes a constant op referencing the new pool index" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.emitConstant(allocator, Value.int(99));
    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try std.testing.expectEqual(@as(i64, 99), chunk.constants[0].asInt());
    try std.testing.expectEqual(@intFromEnum(OpCode.push_const), chunk.code[0]);
    try std.testing.expectEqual(@as(u16, 0), readU16Inline(chunk.code, 1));
}

test "classifyTrivialBody recognizes a up_get_ret-only thunk body" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .up_get_ret);
    try builder.writeU16(allocator, 4);
    try builder.writeOp(allocator, .halt);

    // Thunk bodies have local_count == 0.
    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    switch (chunk.scheduling.trivial) {
        .identity_upvalue => |idx| try std.testing.expectEqual(@as(u16, 4), idx),
        else => return error.TestUnexpectedResult,
    }
}

test "classifyTrivialBody recognizes a push_const_ret-only thunk body" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.emitConstant(allocator, Value.int(5));
    // emitConstant writes a plain `push_const` op; fuse it into
    // `push_const_ret` by hand the way the compiler's emit.zig would,
    // then append halt so the shape matches the classifier's expectation.
    builder.code.items[0] = @intFromEnum(OpCode.push_const_ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    switch (chunk.scheduling.trivial) {
        .literal => |v| try std.testing.expectEqual(@as(i64, 5), v.asInt()),
        else => return error.TestUnexpectedResult,
    }
}

test "classifyTrivialBody classifies a multi-instruction body as non-trivial" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .up_get);
    try builder.writeU16(allocator, 0);
    try builder.writeOp(allocator, .up_get);
    try builder.writeU16(allocator, 1);
    try builder.writeOp(allocator, .int_add);
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    try std.testing.expectEqual(TrivialBody.none, chunk.scheduling.trivial);
}

test "classifyTrivialBody never fires for chunks with locals (lambda bodies)" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .up_get_ret);
    try builder.writeU16(allocator, 0);
    try builder.writeOp(allocator, .halt);

    // local_count == 1 means this is a lambda body, not a thunk body,
    // so the short-circuit must not apply even though the bytes match
    // the up_get_ret shape exactly.
    var chunk = try builder.finish(allocator, 1);
    defer chunk.deinit(allocator);

    try std.testing.expectEqual(TrivialBody.none, chunk.scheduling.trivial);
}

test "chunk registry registers well-known chunks retrievable by id" {
    const allocator = std.testing.allocator;
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();

    const genlist_chunk = registry.get(registry.well_known.genlist_apply);
    try std.testing.expect(genlist_chunk != null);
    const mapattrs_chunk = registry.get(registry.well_known.mapattrs_apply);
    try std.testing.expect(mapattrs_chunk != null);

    // Two distinct well-known chunks must have distinct ids.
    try std.testing.expect(registry.well_known.genlist_apply != registry.well_known.mapattrs_apply);
}

test "chunk registry register/get round-trips a custom chunk" {
    const allocator = std.testing.allocator;
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();

    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);
    try builder.emitConstant(allocator, Value.int(123));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);
    const built = try builder.finish(allocator, 0);

    const id = try registry.register(built);
    const fetched = registry.get(id) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(usize, 1), fetched.constants.len);
    try std.testing.expectEqual(@as(i64, 123), fetched.constants[0].asInt());
}

test "chunk registry get returns null for an out-of-range id" {
    const allocator = std.testing.allocator;
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.get(std.math.maxInt(ChunkId)) == null);
}

/// Small chunk for the dedup tests: `push_const <const_val>; ret; halt` with
/// a body span on `line`, so a test can vary exactly one semantic ingredient
/// (constant bits / span) at a time.
fn buildDedupTestChunk(allocator: std.mem.Allocator, const_val: i64, line: u32) !Chunk {
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);
    try builder.emitConstant(allocator, Value.int(const_val));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);
    builder.body_span = .{ .file = null, .offset = 0, .len = 5, .line = line, .column = 1 };
    return builder.finish(allocator, 0);
}

test "chunk dedup: structurally identical registrations share one id" {
    const allocator = std.testing.allocator;
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();

    const first = try registry.registerDeduped(try buildDedupTestChunk(allocator, 7, 1), name_tree_mod.root_name_id);
    try std.testing.expect(!first.reused);
    try std.testing.expectEqual(first.id, first.new_id.?);

    var copy = try buildDedupTestChunk(allocator, 7, 1);
    const second = try registry.registerDeduped(copy, name_tree_mod.root_name_id);
    try std.testing.expect(second.reused);
    try std.testing.expectEqual(@as(?ChunkId, null), second.new_id);
    try std.testing.expectEqual(first.id, second.id);
    // reused=true ⇒ the registry kept the first registration; the caller
    // still owns (and must free) its own copy.
    copy.deinit(allocator);
}

test "chunk dedup: a differing constant or span is a distinct registration" {
    const allocator = std.testing.allocator;
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();

    const base = try registry.registerDeduped(try buildDedupTestChunk(allocator, 7, 1), name_tree_mod.root_name_id);
    const other_const = try registry.registerDeduped(try buildDedupTestChunk(allocator, 8, 1), name_tree_mod.root_name_id);
    const other_span = try registry.registerDeduped(try buildDedupTestChunk(allocator, 7, 2), name_tree_mod.root_name_id);

    try std.testing.expect(!other_const.reused);
    try std.testing.expect(!other_span.reused);
    try std.testing.expect(base.id != other_const.id);
    try std.testing.expect(base.id != other_span.id);
    try std.testing.expect(other_const.id != other_span.id);
}

test "chunk dedup: concurrent registrations converge (equal) and stay distinct (unique)" {
    const allocator = std.testing.allocator;
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();

    const thread_count = 8;
    const iterations = 64;

    var equal_ids: [thread_count][iterations]ChunkId = undefined;
    var distinct_ids: [thread_count][iterations]ChunkId = undefined;

    const Worker = struct {
        fn run(reg: *ChunkRegistry, alloc: std.mem.Allocator, t_idx: usize, equal_out: []ChunkId, distinct_out: []ChunkId) void {
            for (equal_out, distinct_out, 0..) |*e, *d, i| {
                // Same content on every thread and iteration: every
                // registration must resolve to ONE converged id, whichever
                // thread's shard-map insert won the race (`registerDeduped`
                // returns the winner even for the losing racer).
                var equal = buildDedupTestChunk(alloc, 4242, 1) catch @panic("chunk build failed");
                const re = reg.registerDeduped(equal, name_tree_mod.root_name_id) catch @panic("registerDeduped failed");
                if (re.reused) equal.deinit(alloc);
                e.* = re.id;

                // Per-(thread, iteration) unique constant: never merged.
                var distinct = buildDedupTestChunk(alloc, @intCast(t_idx * 100_000 + i), 1) catch @panic("chunk build failed");
                const rd = reg.registerDeduped(distinct, name_tree_mod.root_name_id) catch @panic("registerDeduped failed");
                if (rd.reused) distinct.deinit(alloc);
                d.* = rd.id;
            }
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &registry, allocator, i, &equal_ids[i], &distinct_ids[i] });
    }
    for (&threads) |t| t.join();

    const converged = equal_ids[0][0];
    for (equal_ids) |row| {
        for (row) |id| try std.testing.expectEqual(converged, id);
    }

    var seen: std.AutoHashMapUnmanaged(ChunkId, void) = .empty;
    defer seen.deinit(allocator);
    for (distinct_ids) |row| {
        for (row) |id| {
            try std.testing.expect(id != converged);
            const gop = try seen.getOrPut(allocator, id);
            try std.testing.expect(!gop.found_existing);
        }
    }
}

test "chunk sidecars support concurrent compiler writers" {
    const allocator = std.testing.allocator;
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();
    registry.capture_names = true;

    const thread_count = 8;
    const iterations = 512;
    const Worker = struct {
        fn run(reg: *ChunkRegistry, t_idx: usize) void {
            for (0..iterations) |i| {
                const id: ChunkId = @intCast(t_idx * iterations + i);
                const file: types.InternId = @intCast(10_000 + id);
                const names = [_]types.InternId{ @intCast(t_idx), @intCast(i) };
                reg.recordFile(id, file) catch @panic("recordFile failed");
                reg.recordUpvalueNames(id, &names) catch @panic("recordUpvalueNames failed");
                reg.recordLocalNames(id, &names) catch @panic("recordLocalNames failed");
            }
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &registry, i });
    }
    for (&threads) |thread| thread.join();

    for (0..thread_count) |t_idx| {
        for (0..iterations) |i| {
            const id: ChunkId = @intCast(t_idx * iterations + i);
            try std.testing.expectEqual(@as(types.InternId, @intCast(10_000 + id)), registry.fileOf(id).?);
            try std.testing.expectEqualSlices(types.InternId, &.{ @intCast(t_idx), @intCast(i) }, registry.upvalueNamesOf(id).?);
            try std.testing.expectEqualSlices(types.InternId, &.{ @intCast(t_idx), @intCast(i) }, registry.localNamesOf(id).?);
        }
    }

    // A deduped registration never invalidates a slice a reader may already
    // hold; the first diagnostic sidecar remains canonical.
    const replacement = [_]types.InternId{999};
    try registry.recordLocalNames(0, &replacement);
    try std.testing.expectEqualSlices(types.InternId, &.{ 0, 0 }, registry.localNamesOf(0).?);
}
