//! Evaluator — the top-level orchestration layer.
//!
//! Manages the shared state (chunk registry, intern table, scheduler) and runs
//! the worker threads that execute bytecode.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("runtime").types;
const bytecode = @import("bytecode.zig");
const opcode = bytecode.opcode;
const InternTable = @import("runtime").intern.InternTable;
const ChunkRegistry = bytecode.ChunkRegistry;
const ChunkBuilder = bytecode.ChunkBuilder;
const ChunkId = types.ChunkId;
const Scheduler = @import("parallel").scheduler.Scheduler;
const vm_mod = @import("vm.zig");
const VM = vm_mod.VM;
const vm_force = @import("vm/force.zig");
const vm_builtins = @import("vm/builtins.zig");
const ObjectHeap = @import("runtime").heap.ObjectHeap;
const heap_gc = @import("runtime").heap.heap_gc;
const FileCache = @import("runtime").file_cache.FileCache;
const FetchCache = @import("runtime").fetch_cache.FetchCache;
const regex_mod = @import("runtime").regex;
const vma_mod = @import("runtime").vma;
const DerivationStore = @import("derivation").DerivationStore;
const derivation = @import("derivation");
const Value = @import("runtime").value.Value;
const builtins = @import("runtime").builtins;
const parser_mod = @import("syntax").parser;
const diagnostic = @import("syntax").diagnostic;
const eval_trace = @import("eval/trace.zig");
const eval_progress = @import("eval/progress.zig");
const timeline = @import("probe/timeline.zig");
const ast_mod = @import("syntax").ast;
const deferred_mod = @import("compiler/deferred_table.zig");
const Run = @import("eval/run.zig").Run;
const path_ops = @import("runtime").paths;
const eval_print = @import("eval/print.zig");
const search_path_mod = @import("eval/search_path.zig");
const imports_mod = @import("eval/imports.zig");
const mem_report = @import("eval/mem_report.zig");
const tuning = @import("eval/tuning.zig");
const eval_diagnostics = @import("eval/diagnostics.zig");

const worker_mod = @import("eval/worker.zig");
const eval_gc = @import("eval/gc.zig");
const fiber_mod = @import("parallel").fiber;
const prof = @import("probe/prof.zig");
const compiler_mod = @import("compiler.zig");
const VmTrace = @import("vm/trace_log.zig").VmTrace;
const ThunkTrace = @import("probe/thunk_trace.zig").ThunkTrace;
const SpinMutex = @import("runtime").stable_segments.SpinMutex;
const gc = @import("runtime").gc;
const thunk_mod = @import("runtime").thunk;
const worker_id_mod = @import("runtime").worker_id;
const tjit_hot = @import("jit/hot.zig");
const tjit_exec = @import("jit/exec.zig");
const tjit_record = @import("jit/record_driver.zig");

pub const Diagnostic = diagnostic.Diagnostic;
pub const EvalTrace = eval_trace.Trace;

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    intern: InternTable,
    registry: ChunkRegistry,
    scheduler: Scheduler,
    heap: ObjectHeap,
    files: FileCache,
    fetchers: FetchCache,
    derivations: DerivationStore,
    /// Compiled-regex cache shared by every VM (`builtins.match`/`split`).
    regexes: regex_mod.PatternCache,
    imports: imports_mod.Registry,
    search_paths: search_path_mod.Paths,
    /// Shared pool of VM stack/frames buffers (see vm.zig BufferPool):
    /// nested import VMs churn ~2.6K times per NixOS eval; reuse bounds
    /// their RSS at the concurrent-VM high-water instead of leaking a
    /// dirty half-MB into the worker arena per import.
    vm_buffers: vm_mod.BufferPool,
    builtins_value: ?Value,
    /// Whether the final render observes lazy shells (only lazy-XML).
    /// Propagated to every VM via `initVm`; gates `make_lazy_shell`.
    /// Default false — the CLI sets it true only for `--xml`.
    lazy_shells_visible: bool = false,
    /// Whether the `|>`/`<|` pipe operators are permitted. They always
    /// parse; when this is false, `parseAndCompile` rejects any source that
    /// used one (matching Nix, which gates the feature on presence). The CLI
    /// sets it true for `--pipe-operators`. Default false.
    pipe_operators_enabled: bool = false,
    base_path: ?[:0]u8,
    env_map: ?*const std.process.Environ.Map,
    progress: ?eval_progress.Sink,
    /// Progress sampler state (active only while `progress != null`). A thread
    /// pushes a counter snapshot to the sink every ~100ms — decoupled from
    /// fiber quanta so `--workers=1` (which can run the whole eval in one
    /// non-yielding quantum) still updates. `progress_wait` is the shared
    /// demand-block subject the sampler surfaces. All three are inert (unset)
    /// in non-interactive runs, so they add nothing to the hot path.
    progress_wait: eval_progress.ProgressWait = .{},
    progress_thread: ?std.Thread = null,
    progress_stop: std.atomic.Value(bool) = .init(false),
    vm_trace: ?*VmTrace,
    thunk_trace: if (vm_mod.thunks_log_enabled) ?*ThunkTrace else void,
    worker_count: u8,
    /// Persistent worker for worker_id 0 (the main / calling thread).
    /// Lazily created on first `runWithVm`, kept alive for the
    /// evaluator's lifetime, and deinit'd *after* the scheduler is
    /// torn down — that ordering guarantees no helper is still running
    /// a stolen main-fiber when its stack gets freed. See [F1.4].
    main_worker: ?*worker_mod.Worker,
    /// Per-evaluation state (diagnostics + trace + string arena). Cleared
    /// at the start of each `evaluate()`; helpers writing diagnostics from
    /// import error paths serialize on `run.mu`.
    run: Run,
    vm_opcode_counts: if (vm_mod.opcode_profile_enabled) vm_mod.OpcodeCounts else void,
    /// Lazy per-attr compilation: deferred attrset value bodies, compiled
    /// on first force. See `compiler/deferred_table.zig`.
    deferred_table: deferred_mod.Table,
    /// AST arenas kept alive because a deferred body retains nodes into
    /// them (force-time compile re-walks the node). Files that defer
    /// nothing free their arena immediately (the common case). Appended
    /// concurrently by helper-thread import compiles, hence the mutex.
    retained_arenas: std.ArrayListUnmanaged(ast_mod.AstArena),
    retained_arenas_mu: SpinMutex,
    /// GC (`-Dgc`): reusable live-set marker driven at collection safepoints.
    /// `void` in normal builds.
    gc_tracer: if (gc.enabled) gc.Tracer else void,
    /// GC (`-Dgc`): fresh VMs for in-flight imports/scoped-imports. These
    /// run on transient stack-local VMs NOT in a worker's `fibers` list, so
    /// the collector must scan them explicitly or their live values are
    /// missed. Guarded by `gc_import_vms_mu` — imports run concurrently at
    /// --workers>1.
    gc_import_vms: if (gc.enabled) std.ArrayListUnmanaged(*VM) else void,
    gc_import_vms_mu: if (gc.enabled) SpinMutex else void,
    /// GC (`-Dgc`): every live `Worker` by id (0 = main, 1.. = helpers).
    /// The collector walks each worker's fibers for roots. A worker
    /// registers itself before it can allocate user objects and unregisters
    /// after it's quiesced, and during a stop-the-world all live workers are
    /// parked — so the collector reads a stable set.
    gc_workers: if (gc.enabled) []std.atomic.Value(?*worker_mod.Worker) else void,
    /// GC (`-Dgc`): chunk-constant root scan is INCREMENTAL across minors. A
    /// chunk constant's referent is promoted to old at the first minor that
    /// scans it and stays old (a later young reference it gains is caught by
    /// the remembered-set barrier, not the constant). So each minor scans only
    /// chunks `[gc_chunks_scanned, registry.count())`; re-scanning all of them
    /// every minor was ~77% of the serial root-scan. A future MAJOR resets this
    /// to 0 (a full mark re-scans every constant).
    gc_chunks_scanned: if (gc.enabled) ChunkId else void = if (gc.enabled) 0 else {},
    /// GC (`-Dgc`): `--max-memory` override for the collector's memory
    /// budget, in bytes (0 = never collect). `null` = resolve the default
    /// (`FIX_MAX_MEMORY`, else half of MemAvailable) — see
    /// `eval/gc.zig:memoryBudget`. Set by the CLI before evaluation;
    /// ignored by non-`-Dgc` builds.
    max_memory_bytes: ?u64 = null,
    /// Speculative import prefetch (`FIX_IMPORT_PREFETCH`): `.nix` path
    /// constants discovered by `ChunkRegistry.register` and already
    /// submitted as `import_prefetch` tasks — dedup so each path is
    /// prefetched at most once per eval. Guarded by `prefetch_mu`
    /// (compiles run on every worker). Remaining submission budget in
    /// `prefetch_budget` bounds the junk volume.
    prefetch_seen: std.AutoHashMapUnmanaged(types.InternId, void) = .empty,
    prefetch_mu: SpinMutex = .{},
    prefetch_budget: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, requested_worker_count: u8) !Evaluator {
        // Always run at least one worker — the main evaluator thread itself
        // owns worker id 0 even when no scheduler helpers are requested.
        const worker_count: u8 = @max(requested_worker_count, 1);

        var scheduler = try Scheduler.init(allocator, worker_count);
        errdefer scheduler.deinit();

        var intern = try InternTable.init(allocator);
        errdefer intern.deinit();

        var registry = try ChunkRegistry.init(allocator);
        errdefer registry.deinit();


        const gc_workers = if (gc.enabled) blk: {
            const ws = try allocator.alloc(std.atomic.Value(?*worker_mod.Worker), worker_count);
            for (ws) |*w| w.* = .init(null);
            break :blk ws;
        } else {};
        errdefer if (gc.enabled) allocator.free(gc_workers);

        return .{
            .allocator = allocator,
            .intern = intern,
            .registry = registry,
            .scheduler = scheduler,
            .heap = try ObjectHeap.init(allocator, worker_count),
            .files = FileCache.init(allocator),
            .fetchers = FetchCache.init(allocator),
            .derivations = DerivationStore.init(allocator),
            .regexes = regex_mod.PatternCache.init(allocator),
            .imports = .{},
            .search_paths = .{},
            .vm_buffers = vm_mod.BufferPool.init(allocator),
            .builtins_value = null,
            .base_path = null,
            .env_map = null,
            .progress = null,
            .vm_trace = null,
            .thunk_trace = if (vm_mod.thunks_log_enabled) null else {},
            .worker_count = worker_count,
            .main_worker = null,
            .run = Run.init(allocator),
            .vm_opcode_counts = if (vm_mod.opcode_profile_enabled) [_]u64{0} ** opcode.count else {},
            .deferred_table = deferred_mod.Table.init(allocator),
            .retained_arenas = .empty,
            .retained_arenas_mu = .{},
            .gc_tracer = if (gc.enabled) gc.Tracer.init(allocator) else {},
            .gc_import_vms = if (gc.enabled) .empty else {},
            .gc_import_vms_mu = if (gc.enabled) .{} else {},
            .gc_workers = gc_workers,
        };
    }

    pub fn deinit(self: *Evaluator) void {
        mem_report.report(self);
        // Detach the import-prefetch sink before teardown (module-level
        // global; only clear it if it still points at THIS evaluator).
        if (ChunkRegistry.path_const_sink) |sink| {
            if (sink.ctx == @as(*anyopaque, @ptrCast(self))) ChunkRegistry.path_const_sink = null;
        }
        self.prefetch_seen.deinit(self.allocator);
        if (comptime vm_mod.opcode_profile_enabled) eval_diagnostics.printVmOpcodeProfile(&self.vm_opcode_counts);
        if (comptime gc.enabled) {
            gc.recordFinalTotal(self.heap.totalReservedBytes());
            // Off by default: the report is a diagnostic, not something every
            // `-Dgc` run should dump to stderr. Gate it like `FIX_MEM_REPORT`.
            const gc_report_on = if (self.env_map) |em| em.get("FIX_GC_REPORT") != null else false;
            if (gc_report_on) gc.report();
        }
        if (comptime tjit_hot.enabled) eval_diagnostics.reportHotAnchors(self);
        if (comptime tjit_exec.enabled) tjit_exec.report();
        if (comptime tjit_record.enabled) tjit_record.report();
        // Shut helpers down (which joins on `defer vm.deinit()` inside
        // helperLoop) before tearing down state their VMs borrow.
        self.scheduler.deinit();
        // Now that helpers are guaranteed quiescent, tear down the main
        // worker. Doing this before scheduler shutdown could race with
        // a helper still resuming a stolen main fiber.
        if (self.main_worker) |w| w.deinit();
        // Every VM (helper fibers, main worker, imports) is dead now —
        // all pooled stack/frames buffers are back on the free list.
        self.vm_buffers.deinit();
        // GC bookkeeping is freed only AFTER the workers above are joined:
        // a helper can still be finishing a speculative import when the
        // main thread enters deinit, and its `evaluateSource` appends the
        // nested VM into `gc_import_vms` (and its registered chunks come
        // from the same allocator pools). Freeing the list before the join
        // leaves a dangling `items.ptr`; the late append then writes a
        // fiber-stack `*VM` into whatever recycled the freed buffer — the
        // observed victim was a freshly registered Chunk whose stomped
        // `code.ptr` detonated at `registry.deinit` (teardown SIGSEGV).
        if (comptime gc.enabled) {
            self.gc_tracer.deinit();
            self.gc_import_vms.deinit(self.allocator);
            self.allocator.free(self.gc_workers);
        }
        if (self.base_path) |path| self.allocator.free(path);
        self.run.deinit();
        self.imports.deinit(self.allocator);
        self.search_paths.deinit(self.allocator);
        self.fetchers.deinit();
        self.derivations.deinit();
        self.regexes.deinit();
        self.files.deinit();
        self.heap.deinit();
        // Free deferred-compile state after the heap (whose thunks
        // referenced entries) and workers (no force-compile can be in
        // flight) are gone. The retained arenas own the AST nodes the
        // entries point at; the registered chunks are self-contained
        // bytecode and don't reference them, so order vs registry is free.
        self.deferred_table.deinit();
        for (self.retained_arenas.items) |*arena| arena.deinit();
        self.retained_arenas.deinit(self.allocator);
        self.registry.deinit();
        self.intern.deinit();
    }

    pub fn getDiagnostics(self: *const Evaluator) []const Diagnostic {
        return self.run.diagnosticsView();
    }

    pub fn getTrace(self: *const Evaluator) *const EvalTrace {
        return self.run.traceView();
    }

    pub fn setDerivationDebug(self: *Evaluator, enabled: bool) void {
        self.derivations.setDebugEnabled(enabled);
    }

    pub fn derivationDebugRecords(self: *const Evaluator) []const derivation.DebugRecord {
        return self.derivations.debugRecords();
    }

    pub fn setBasePathFromCurrentPath(self: *Evaluator, io: std.Io) !void {
        self.files.setIo(io);
        self.fetchers.setIo(io);
        if (self.base_path) |path| self.allocator.free(path);
        self.base_path = try std.process.currentPathAlloc(io, self.allocator);
    }

    pub fn setFileIo(self: *Evaluator, io: std.Io) void {
        self.files.setIo(io);
        self.fetchers.setIo(io);
    }

    pub fn setEnvironment(self: *Evaluator, env_map: *const std.process.Environ.Map) void {
        self.env_map = env_map;
    }

    pub fn setVmTrace(self: *Evaluator, vm_trace: ?*VmTrace) void {
        self.vm_trace = vm_trace;
    }

    pub fn setThunkTrace(self: *Evaluator, thunk_trace: ?*ThunkTrace) void {
        // No-op when the trace is compiled out; callers don't need to
        // comptime-gate. `--thunks-log` users get a heads-up at the CLI
        // layer.
        if (comptime !vm_mod.thunks_log_enabled) return;
        self.thunk_trace = thunk_trace;
    }

    pub fn setProgressSink(self: *Evaluator, progress: ?eval_progress.Sink) void {
        self.progress = progress;
    }

    pub fn setNixPath(self: *Evaluator, nix_path: []const u8) !void {
        try self.search_paths.set(self.allocator, nix_path, self, resolveHostPath);
    }

    pub fn readSourceFile(self: *Evaluator, path: []const u8) ![]const u8 {
        const resolved = try self.resolveHostPath(path);
        defer if (resolved.owned) self.allocator.free(resolved.text);
        return self.files.readFile(resolved.text);
    }

    fn clearDiagnostics(self: *Evaluator) void {
        self.run.clear();
    }

    fn copyDiagnostics(self: *Evaluator, diagnostics: []const Diagnostic, source: []const u8, source_path: ?[]const u8) !void {
        try self.run.replaceDiagnostics(diagnostics, source, source_path);
    }

    /// Parse and compile source text into a registered chunk id. Used by
    /// debugging tools that want to inspect bytecode without running it.
    pub fn compileSource(
        self: *Evaluator,
        source: []const u8,
        source_path: ?[]const u8,
    ) !ChunkId {
        return self.parseAndCompile(source, self.base_path, source_path, null);
    }

    /// Parse + compile + register, returning the compiled chunk id.
    /// Shared by `compileSource` (public, no eval) and `evaluateSource`
    /// (the internal eval entrypoint that runs the chunk afterwards).
    fn parseAndCompile(
        self: *Evaluator,
        source: []const u8,
        base_path: ?[]const u8,
        source_path: ?[]const u8,
        scope: ?Value,
    ) !ChunkId {
        const subject = source_path orelse "expression";

        var arena = ast_mod.AstArena.init(self.allocator);
        // Freed here unless a deferred attr body retains nodes into it
        // (then the arena is moved into `retained_arenas`, below).
        var retain_arena = false;
        defer if (!retain_arena) arena.deinit();

        var parser = parser_mod.Parser.init(self.allocator, &arena, source);
        defer parser.deinit();
        // Body-span elision: skip PARSING large attrset value bodies that
        // lazy per-attr compilation would defer anyway; the compiler
        // sub-parses them on demand (`literals.materializeElided`). File
        // compiles only, mirroring the deferral gate (`shouldDeferSet`).
        parser.elide_bodies = source_path != null;

        const ast_node = blk: {
            self.progressBegin(.parse, subject);
            defer self.progressEnd(.parse, subject);
            timeline.begin(.parse, subject, 0);
            defer timeline.end(.parse);
            const pt = prof.start(.parse);
            defer prof.end(.parse, pt);
            // RSS attribution: blocks the parse grows (AST arena chunks,
            // parser scratch) belong to the "ast-arena" bucket — the
            // retained ones live as long as the evaluator.
            const prev_tag = vma_mod.setAllocTag(.ast_arena);
            defer _ = vma_mod.setAllocTag(prev_tag);
            break :blk parser.parse() catch {
                try self.copyDiagnostics(parser.diagnostics.items, source, source_path);
                return error.ParseError;
            };
        };

        // Compile-time feature gate. Pipe operators always parse (into tagged
        // apply nodes); enabling them is required to compile. Like Nix, we
        // reject on *presence* — the parser records whether any `|>`/`<|`
        // was seen, so a pipe anywhere in the file (even an unused/deferred
        // attr body) fails here, before any compilation runs.
        if (parser.used_pipe_operators and !self.pipe_operators_enabled) {
            const tok = parser.first_pipe_token.?;
            try self.copyDiagnostics(&.{.{
                .severity = .err,
                .kind = .compile,
                .line = parser_mod.Parser.tokenLine(source, tok),
                .column = diagnostic.columnForOffset(source, tok.offset),
                .offset = tok.offset,
                .len = tok.len,
                .token_type = tok.type,
                .message = "pipe operators are disabled; pass --pipe-operators to enable them",
            }}, source, source_path);
            return error.PipeOperatorsDisabled;
        }

        // Per-compilation-unit scratch arena: all of the compiler's
        // transient structures (builder buffers, locals/captures, strictness
        // and name-resolution maps, diagnostics) allocate here and are freed
        // wholesale when this returns. Only the emitted chunk is duped onto
        // the long-lived allocator (at `builder.finish`). The AST arena above
        // is separate — it may be retained for deferred bodies; this one never
        // is, since nothing persistent points into it.
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const scratch_alloc = scratch.allocator();

        var builder = try ChunkBuilder.init(scratch_alloc);
        defer builder.deinit(scratch_alloc);

        var compiler = compiler_mod.Compiler.init(
            scratch_alloc,
            self.allocator,
            &builder,
            &self.registry,
            source,
            &self.intern,
            &self.heap,
        );
        compiler.base_path = base_path;
        compiler.source_path = source_path;
        compiler.deferred_table = &self.deferred_table;
        // Elided bodies materialize into the file's AST arena (retained
        // below alongside deferred bodies); this compile is single-threaded,
        // so in-place node replacement is safe and keeps every later
        // consumer's view identical to an eager parse.
        compiler.ast_arena = &arena;
        compiler.elide_mutable = true;
        defer compiler.deinit();

        {
            self.progressBegin(.compile, subject);
            defer self.progressEnd(.compile, subject);
            timeline.begin(.compile, subject, 0);
            defer timeline.end(.compile);
            const ct = prof.start(.compile);
            defer prof.end(.compile, ct);
            compiler.compileAndFinish(ast_node, scope) catch |err| {
                try self.copyDiagnostics(compiler.diagnostics.items, source, source_path);
                return err;
            };
        }

        const chunk = try builder.finish(self.allocator, compiler.slot_count);
        const chunk_id = try self.registry.register(chunk);
        // `chunk` now owns persistent copies of its bytecode; `scratch`
        // (incl. `builder`'s buffers) is freed by the defers above.

        // If any attr body in this file was deferred, its AST nodes are
        // referenced by `deferred_table` entries and must outlive the
        // compile — keep the arena alive for the evaluator's lifetime.
        if (compiler.deferred_count > 0) {
            retain_arena = true; // nodes are referenced; never free here
            self.retained_arenas_mu.lock();
            defer self.retained_arenas_mu.unlock();
            // Best-effort: on OOM we intentionally leak (don't free AST a
            // deferred entry still points at) rather than risk a dangling node.
            self.retained_arenas.append(self.allocator, arena) catch {};
        }
        return chunk_id;
    }

    /// Read-only access to compiled chunks for tools.
    pub fn getChunk(self: *const Evaluator, id: ChunkId) ?*const bytecode.Chunk {
        return self.registry.get(id);
    }

    /// Read-only access to the intern table for tools.
    pub fn internTable(self: *const Evaluator) *const InternTable {
        return &self.intern;
    }

    /// Read-only access to the chunk registry for tools.
    pub fn chunkRegistry(self: *const Evaluator) *const ChunkRegistry {
        return &self.registry;
    }

    pub fn heapStats(self: *const Evaluator) ObjectHeap.Stats {
        return self.heap.stats();
    }

    pub fn internStats(self: *const Evaluator) InternTable.Stats {
        return self.intern.stats();
    }

    pub fn chunkStats(self: *const Evaluator) ChunkRegistry.Stats {
        return self.registry.stats();
    }

    pub fn schedulerStats(self: *const Evaluator) Scheduler.Stats {
        return self.scheduler.stats();
    }

    pub fn workerCount(self: *const Evaluator) u8 {
        return self.scheduler.worker_count;
    }

    pub fn setParallelismToggles(self: *Evaluator, disable_speculation: bool, disable_fanout: bool) void {
        self.scheduler.disable_speculation = disable_speculation;
        self.scheduler.disable_fanout = disable_fanout;
    }

    /// Compile source text into bytecode and evaluate it.
    /// This is the main public API.
    pub fn evaluate(self: *Evaluator, source: []const u8) !Value {
        // Build the builtins attrset on the main thread before any helpers
        // can race on it. `buildAttrSet` predicts the next ObjectId for
        // the self-reference `builtins.builtins`; that prediction is only
        // safe when no other thread is allocating objects.
        _ = try self.ensureBuiltins();
        tuning.apply(self);
        // Speculative import prefetch: `.nix` path constants of freshly
        // compiled chunks are parse+compile+evaluated ahead of demand on
        // the spec lane (the braid-window perf decomposition measured
        // ~25-50ms of import parse+compile sitting ON the critical chain
        // at w=8 while every helper parked). The import registry dedups
        // and coordinates, so a prefetch is exactly the import the demand
        // fiber would have run — started earlier. Default ON at 2..16
        // workers (same gate as the novel lane: at w=32 extra spec-lane
        // volume chases junk); FIX_IMPORT_PREFETCH=0/1 overrides,
        // FIX_IMPORT_PREFETCH_MAX bounds submissions per eval.
        {
            var on = self.worker_count >= 2 and self.worker_count <= 16;
            var max: u32 = 8192;
            if (self.env_map) |em| {
                if (em.get("FIX_IMPORT_PREFETCH")) |s| on = !std.mem.eql(u8, s, "0");
                if (em.get("FIX_IMPORT_PREFETCH_MAX")) |s| {
                    if (std.fmt.parseInt(u32, s, 10)) |n| max = n else |_| {}
                }
            }
            if (on and self.worker_count > 1) {
                self.prefetch_budget = max;
                ChunkRegistry.path_const_sink = .{ .ctx = self, .call = prefetchPathConst };
            } else {
                self.prefetch_budget = 0;
                ChunkRegistry.path_const_sink = null;
            }
        }
        // Speculative readDir-children prefetch: a cold builtins.readDir
        // whose listing is a directory-of-directories fans the children out
        // to helpers, who warm the FileCache ahead of the demand fiber's
        // serial child-readDir walk (pkgs/by-name: 756 shard listings
        // back-to-back on the critical chain, ~19ms at w=8). Same default
        // gate as import prefetch (ON at 2..16 workers);
        // FIX_READDIR_PREFETCH=0/1 overrides, FIX_READDIR_PREFETCH_MIN
        // tunes the directory-children threshold,
        // FIX_READDIR_PREFETCH_MAX bounds total child listings per eval.
        {
            var on = self.worker_count >= 2 and self.worker_count <= 16;
            var min: u32 = 32;
            var max: u32 = 16384;
            if (self.env_map) |em| {
                if (em.get("FIX_READDIR_PREFETCH")) |s| on = !std.mem.eql(u8, s, "0");
                if (em.get("FIX_READDIR_PREFETCH_MIN")) |s| {
                    if (std.fmt.parseInt(u32, s, 10)) |n| min = n else |_| {}
                }
                if (em.get("FIX_READDIR_PREFETCH_MAX")) |s| {
                    if (std.fmt.parseInt(u32, s, 10)) |n| max = n else |_| {}
                }
            }
            if (on and self.worker_count > 1)
                self.scheduler.setReadDirPrefetch(min, max)
            else
                self.scheduler.setReadDirPrefetch(0, 0);
        }
        try self.scheduler.start(helperLoop, self);
        self.clearDiagnostics();
        self.derivations.clearDebugRecords();
        return self.evaluateSource(source, self.base_path, null, null, 0);
    }

    pub fn evaluateSource(
        self: *Evaluator,
        source: []const u8,
        base_path: ?[]const u8,
        source_path: ?[]const u8,
        scope: ?Value,
        /// The calling VM's `native_depth` (the `import` builtin already +1'd
        /// it). The nested import VM inherits `parent_depth - 1` so imports are
        /// GC-safepoint-transparent (a top-level import collects at depth 0; a
        /// nested one stays gated at the caller's depth). 0 for the top level.
        parent_depth: u32,
    ) !Value {
        const chunk_id = try self.parseAndCompile(source, base_path, source_path, scope);
        const subject = source_path orelse "expression";
        self.progressBegin(.evaluate, subject);
        defer self.progressEnd(.evaluate, subject);
        timeline.instant(.evaluate, subject);
        // Only the top-level eval (no scope, no source_path) goes
        // through a main-thread fiber so the main thread can yield on
        // a `.busy` thunk; nested invocations (imports, scoped
        // imports) run synchronously on the existing fiber's stack —
        // they share the outer VM's claim identity via the default
        // placeholder claimer that `initVm` hands out.
        if (scope == null and source_path == null) {
            return self.runChunkOnMainWorker(chunk_id);
        }
        // Per-import scratch arena: the nested VM's run-path allocations
        // (drv hashing, builtin temp buffers) are freed wholesale when the
        // import returns instead of accreting for the evaluator's lifetime.
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var vm = try self.initVm(0, scratch.allocator());
        defer vm.deinit();
        // Depth-transparent import: the fresh nested VM inherits the caller's
        // depth minus 1 (dropping the `import` builtin's own +1), so a
        // top-level import evaluates at depth 0 (collects) while a nested one
        // stays gated at the enclosing builtin's depth. native_depth lives on
        // the VM (fiber-local), so no threadlocal dance is needed.
        if (comptime gc.enabled) vm.native_depth = parent_depth -| 1;
        // This VM isn't in any worker's `fibers`, so the collector can't find
        // its roots on its own — register it for the duration of the import.
        // Concurrent imports at --workers>1 interleave, so guard the list and
        // remove by value (not LIFO pop).
        if (comptime gc.enabled) {
            self.gc_import_vms_mu.lock();
            self.gc_import_vms.append(self.allocator, &vm) catch {};
            self.gc_import_vms_mu.unlock();
        }
        defer if (comptime gc.enabled) {
            self.gc_import_vms_mu.lock();
            for (self.gc_import_vms.items, 0..) |ivm, i| {
                if (ivm == &vm) {
                    _ = self.gc_import_vms.swapRemove(i);
                    break;
                }
            }
            self.gc_import_vms_mu.unlock();
        };
        return vm.eval(chunk_id);
    }

    fn runChunkOnMainWorker(self: *Evaluator, chunk_id: ChunkId) !Value {
        return self.runWithVm(VM.eval, .{chunk_id});
    }

    /// `scratch` is the VM's allocation arena — per-fiber (reset when the
    /// fiber is recycled) or per-import (freed when the import returns).
    /// It MUST be an arena: VM run paths lean on arena semantics — frees
    /// are best-effort, error/suspend paths may abandon allocations, and
    /// the sweep happens wholesale at reset/deinit. It must NOT live for
    /// the whole evaluator: that retained ~240 MB (w=1) / ~380 MB (w=8)
    /// of dead interleaved scratch pages on a NixOS eval (~490 MB of
    /// transient traffic per run never reclaimed by a never-reset arena).
    fn initVm(self: *Evaluator, worker_id: u8, scratch: std.mem.Allocator) !VM {
        // RSS attribution: the VM's own allocations (gc lists; the
        // stack/frames go through the shared pool) get the worker bucket.
        const prev_tag = vma_mod.setAllocTag(.worker_arena);
        defer _ = vma_mod.setAllocTag(prev_tag);
        var vm = try VM.init(
            scratch,
            &self.vm_buffers,
            &self.registry,
            &self.intern,
            &self.heap,
            &self.files,
            &self.fetchers,
            &self.derivations,
            &self.scheduler,
            // Helpers (worker_id != 0) don't write to the shared trace or
            // emit progress events. Both are observable side effects of
            // *real* evaluation — speculative force must stay invisible to
            // them. `std.Progress.Node.start` in particular asserts a
            // single-writer invariant on the parent slot which speculation
            // would violate.
            if (worker_id == 0) &self.run.trace else null,
            if (worker_id == 0) self.progress else null,
            if (worker_id == 0) self.vm_trace else null,
            // The thunk trace IS shared across workers — diagnosing
            // concurrency-shaped wrong-result bugs needs to see every
            // helper's resolves, not just main's. The trace handles
            // its own locking.
            self.thunk_trace,
            .{ .context = self, .import_value = importValue, .scoped_import = scopedImportValue, .find_file = findFile, .get_env = getEnv },
            try self.ensureBuiltins(),
            if (comptime vm_mod.opcode_profile_enabled) &self.vm_opcode_counts else {},
        );
        // Inherit the surrounding fiber's claim identity if we're inside
        // one. This covers nested VMs that get created mid-evaluation
        // (e.g. import bodies, top-level entry's own VM): they must
        // share the outer fiber's identity so any thunk they claim is
        // attributed to the fiber, not to the default (worker_id, 0)
        // which would collide with pool fiber #0's pre-allocated VM
        // and cause spurious blackholes when fiber #0 runs a task.
        if (fiber_mod.currentFiber()) |inner| {
            const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
            vm.claimer_id = wf.vm.claimer_id;
        }
        vm.lazy_shells_visible = self.lazy_shells_visible;
        vm.deferred_table = &self.deferred_table;
        vm.regexes = &self.regexes;
        // Only worker-0 VMs (the demand path) publish their block subject, and
        // only when progress is drawn — keeps the busy-safepoint write out of
        // helper and non-interactive paths entirely.
        if (worker_id == 0 and self.progress != null) vm.progress_wait = &self.progress_wait;
        return vm;
    }

    pub fn writeJsonValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        self.progressBegin(.render, "result");
        timeline.instant(.render, "result");
        defer self.progressEnd(.render, "result");
        self.run.trace.clear();
        return self.runWithVm(vm_builtins.writeJsonValue, .{ writer, value });
    }

    pub fn writeXmlValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        self.progressBegin(.render, "result");
        timeline.instant(.render, "result");
        defer self.progressEnd(.render, "result");
        self.run.trace.clear();
        return self.runWithVm(vm_builtins.writeLazyXmlValue, .{ writer, value });
    }

    pub fn forceValue(self: *Evaluator, value: Value) !Value {
        self.run.trace.clear();
        return self.runWithVm(vm_force.forceValue, .{value});
    }

    pub fn forceDeep(self: *Evaluator, value: Value) !void {
        self.progressBegin(.render, "strict result");
        defer self.progressEnd(.render, "strict result");
        timeline.instant(.render, "strict result");
        self.run.trace.clear();
        return self.runWithVm(vm_force.forceDeepCounted, .{value});
    }

    /// Run `body(vm, args...)` on this Evaluator's main worker. If we're
    /// already inside a fiber (nested call from inside an evaluation),
    /// reuse the surrounding fiber's claim identity via a fresh VM. If
    /// we're on a bare OS thread, spin up a one-shot main Worker so the
    /// body's `.busy` thunks yield through the standard fiber machinery
    /// instead of blocking the thread. The body's payload type is
    /// inferred from its return signature; void payloads work too.
    fn runWithVm(self: *Evaluator, comptime body: anytype, args: anytype) !ReturnPayload(@TypeOf(body)) {
        if (fiber_mod.currentFiber() != null) {
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            var vm = try self.initVm(0, scratch.allocator());
            defer vm.deinit();
            if (comptime gc.enabled) eval_gc.registerVm(self, &vm);
            defer if (comptime gc.enabled) eval_gc.unregisterVm(self, &vm);
            return @call(.auto, body, .{&vm} ++ args);
        }
        const Args = @TypeOf(args);
        const Ret = ReturnPayload(@TypeOf(body));
        const Ctx = struct {
            ev: *Evaluator,
            body_args: Args,
            result: Ret = undefined,
            err: ?anyerror = null,

            fn entry(arg: *anyopaque) void {
                const ctx: *@This() = @ptrCast(@alignCast(arg));
                var scratch = std.heap.ArenaAllocator.init(ctx.ev.allocator);
                defer scratch.deinit();
                var vm = ctx.ev.initVm(0, scratch.allocator()) catch |e| {
                    ctx.err = e;
                    return;
                };
                defer vm.deinit();
                if (comptime gc.enabled) eval_gc.registerVm(ctx.ev, &vm);
                defer if (comptime gc.enabled) eval_gc.unregisterVm(ctx.ev, &vm);
                const result = @call(.auto, body, .{&vm} ++ ctx.body_args) catch |e| {
                    ctx.err = e;
                    return;
                };
                ctx.result = result;
            }
        };
        var ctx: Ctx = .{ .ev = self, .body_args = args };
        const worker = try self.ensureMainWorker();
        try worker.runTopLevel(Ctx.entry, @ptrCast(&ctx));
        if (ctx.err) |e| return e;
        return ctx.result;
    }

    fn ensureMainWorker(self: *Evaluator) !*worker_mod.Worker {
        if (self.main_worker) |w| return w;
        const w = try worker_mod.Worker.init(
            self.allocator,
            &self.scheduler,
            0,
            self,
            initVmForWorkerSlot,
        );
        self.main_worker = w;
        // GC (`-Dgc`): register the collect callback now that `self` is at
        // its final address (init returns by value), and enable reclaim. The
        // collect runs at the forceThunk safepoint when allocation crosses
        // the byte threshold; at --workers>1 it stops the world (all workers
        // park at safepoints) before marking. Register worker 0 so the
        // collector can walk its fibers for roots.
        if (comptime gc.enabled) {
            self.gc_workers[0].store(w, .release);
            self.heap.setGcHook(.{ .ctx = self, .sample = gcCollectThunk });
            // Parallel STW mark (--workers>1): parked peers call this to help
            // drain the graph. Inert at --workers=1 (no peer ever parks).
            self.scheduler.gcSetMarkHook(.{ .ctx = self, .help = gcHelpMarkThunk });
            // The copying nursery collector runs at ALL worker counts by
            // default: minor pauses are short (~ms) and it bounds RSS. It pairs
            // with speculation being opt-in (default off) — speculation is the
            // dominant source of young garbage, so with it off the nursery sees
            // mostly real work and collects a handful of times. `FIX_GC_OFF`
            // opts out (measurement / bump-only A-B).
            const gc_off = if (self.env_map) |em| em.get("FIX_GC_OFF") != null else false;
            if (self.env_map) |em|
                if (em.get("FIX_GC_NOREUSE") != null) ObjectHeap.gcSetDisableReuse(true);
            if (self.env_map) |em|
                if (em.get("FIX_GC_PAR_CAP")) |s| {
                    if (std.fmt.parseInt(u32, s, 10)) |c| {
                        if (c >= 1) eval_gc.gc_par_cap = c;
                    } else |_| {}
                };
            if (!gc_off) {
                // FIX_GC_STEP_MB (validation): collect every N MB of fresh
                // allocation so the detector exercises every builtin loop.
                var step_bytes: u64 = 0;
                if (self.env_map) |em| {
                    if (em.get("FIX_GC_STEP_MB")) |s| {
                        if (std.fmt.parseInt(u64, s, 10)) |mb| step_bytes = mb << 20 else |_| {}
                    }
                }
                // Memory budget: no collection runs until heap-reserved bytes
                // cross it (`--max-memory` / `FIX_MAX_MEMORY`; default half of
                // MemAvailable). On a big-RAM machine that is never — zero
                // pauses AND zero tracking (lazy arming at budget/2, see
                // `heap_gc.enableBudget`); on a small-RAM device it fires
                // before the eval OOMs. Budget 0 = never collect (reclaim
                // stays disabled entirely — bump-only). FIX_GC_STEP_MB keeps
                // the eager validation path (tracking from the start).
                const budget = eval_gc.memoryBudget(self);
                if (step_bytes > 0)
                    heap_gc.enableCollect(&self.heap, budget, step_bytes)
                else if (budget > 0)
                    heap_gc.enableBudget(&self.heap, budget);
            }
        }
        return w;
    }

    /// Type-erased trampoline for the heap's collect callback. Kept here
    /// (next to `setGcHook`) so the `*const fn(*anyopaque, u8) void` ABI
    /// stays exact; the body lives in `eval/gc.zig`. `collector_id` is the
    /// worker that won the collection (its parallel-mark slot).
    fn gcCollectThunk(ctx: *anyopaque, collector_id: u8) void {
        const self: *Evaluator = @ptrCast(@alignCast(ctx));
        eval_gc.collect(self, collector_id);
    }

    /// Type-erased trampoline for the scheduler's parallel-mark hook: a parked
    /// peer helps drain marker slot `worker_id` to termination. Kept here for
    /// the exact fn-pointer ABI; the body lives in `eval/gc.zig`.
    fn gcHelpMarkThunk(ctx: *anyopaque, worker_id: u8) void {
        const self: *Evaluator = @ptrCast(@alignCast(ctx));
        eval_gc.helpMark(self, worker_id);
    }

    fn importValue(context: *anyopaque, path: []const u8, parent_depth: u32) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return imports_mod.importPath(self, path, parent_depth);
    }

    /// `ChunkRegistry.path_const_sink` target (`FIX_IMPORT_PREFETCH`):
    /// called for every `.path` constant of every freshly compiled chunk,
    /// from whichever worker ran the compile. Filters to `.nix` files
    /// (directory references — the bulk of e.g. all-packages.nix's ~1.7K
    /// path constants — are mostly never imported in a given eval and
    /// would be junk), dedups per intern id, spends the submission
    /// budget, and hands the path to the spec lane.
    fn prefetchPathConst(context: *anyopaque, path_id: types.InternId) void {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        const text = self.intern.get(path_id);
        if (!std.mem.endsWith(u8, text, ".nix")) return;
        {
            self.prefetch_mu.lock();
            defer self.prefetch_mu.unlock();
            if (self.prefetch_budget == 0) return;
            const gop = self.prefetch_seen.getOrPut(self.allocator, path_id) catch return;
            if (gop.found_existing) return;
            self.prefetch_budget -= 1;
        }
        _ = self.scheduler.submit(.{ .import_prefetch = path_id }, worker_id_mod.current);
    }

    fn scopedImportValue(context: *anyopaque, scope: Value, path: []const u8, parent_depth: u32) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return imports_mod.scopedImportPath(self, scope, path, parent_depth);
    }

    fn findFile(context: *anyopaque, name: []const u8) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return self.findFileInDefaultSearchPath(name);
    }

    fn getEnv(context: *anyopaque, name: []const u8) anyerror![]const u8 {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        const env_map = self.env_map orelse return "";
        return env_map.get(name) orelse "";
    }

    fn findFileInDefaultSearchPath(self: *Evaluator, name: []const u8) !Value {
        return self.search_paths.findFile(self.allocator, &self.files, &self.intern, name);
    }

    fn ensureBuiltins(self: *Evaluator) !Value {
        if (self.builtins_value) |value| return value;
        const nix_path = try self.search_paths.toNixPath(self.allocator);
        defer self.allocator.free(nix_path);
        const value = try builtins.buildAttrSet(&self.intern, &self.heap, nix_path);
        self.builtins_value = value;
        return value;
    }

    pub fn resolveHostPath(self: *Evaluator, path: []const u8) !search_path_mod.ResolvedPath {
        if (std.fs.path.isAbsolute(path)) return .{ .text = path, .owned = false };

        const base_path = self.base_path orelse return error.RelativePath;
        return .{
            .text = try std.fs.path.resolve(self.allocator, &.{ base_path, path }),
            .owned = true,
        };
    }

    pub fn writeValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        self.progressBegin(.render, "result");
        timeline.instant(.render, "result");
        defer self.progressEnd(.render, "result");
        return self.runWithVm(writeValueBody, .{ self, writer, value });
    }

    /// Progress is a single-threaded UI concern that must be driven only by
    /// the demand path. Imports/compiles triggered off a speculative or
    /// fan-out force — OR off a background `import_prefetch` task — run on
    /// arbitrary worker fibers and would reentrantly interleave begin/end
    /// pairs into the one std `Progress` tree (whose `active[]` stack is not
    /// thread-safe) → the `Progress.Node.init` "slot reuse" assert / a torn
    /// stack. Gate on the fiber's `is_demand` flag: exactly one fiber carries
    /// it (the top-level entry), it emits sequentially even across a steal, so
    /// it alone may emit. NB: `!in_speculation` is NOT sufficient — a prefetch
    /// task fiber has `in_speculation == false` yet must stay silent. begin
    /// and end share this gate (the flag is stable across a fiber's life), so
    /// pairs stay balanced. No current fiber = early single-threaded setup.
    fn progressEligible() bool {
        const inner = fiber_mod.currentFiber() orelse return true;
        const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
        return wf.is_demand;
    }

    pub fn progressBegin(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
        if (!progressEligible()) return;
        if (self.progress) |progress| progress.begin(stage, subject);
    }

    pub fn progressEnd(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
        if (!progressEligible()) return;
        if (self.progress) |progress| progress.end(stage, subject);
    }

    pub fn progressInstant(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
        if (!progressEligible()) return;
        if (self.progress) |progress| progress.instant(stage, subject);
    }

    /// Build a live counter snapshot for the progress indicator. Cheap — a
    /// handful of plain/atomic loads plus one /proc RSS read. Runs on the
    /// sampler thread; every read here is advisory, so no locking.
    fn readMetrics(self: *Evaluator) eval_progress.Metrics {
        const st = self.scheduler.stats();
        const g = gc.liveReport();
        var m: eval_progress.Metrics = .{
            .objects = self.heap.objects.count(),
            .values = self.heap.values.count(),
            .attrs = self.heap.attrs.count(),
            .reserved_bytes = self.heap.totalReservedBytes(),
            .rss_bytes = gc.currentRssBytes(),
            .pending = self.scheduler.pending_tasks.v.load(.monotonic),
            .forced = st.pops,
            .steals = st.steals,
            .spec_submitted = st.speculative_submitted,
            .spec_rejected = st.speculative_rejected,
            .gc_collections = g.collections,
            .gc_live_bytes = g.live_bytes,
            .gc_freed_objects = g.freed_objects,
        };
        m.wait_len = @intCast(self.progress_wait.read(&m.wait_buf));
        return m;
    }

    fn progressSample(self: *Evaluator) void {
        if (self.progress) |sink| sink.metrics(self.readMetrics());
    }

    /// Sampler thread body: push a snapshot, then sleep ~100ms (waking every
    /// 20ms to observe the stop flag). Decoupled from fiber quanta so the
    /// display advances even during a single long `--workers=1` quantum.
    fn progressSampleLoop(self: *Evaluator) void {
        while (!self.progress_stop.load(.acquire)) {
            self.progressSample();
            var slept: u32 = 0;
            while (slept < 100 and !self.progress_stop.load(.acquire)) : (slept += 20) {
                var req: std.os.linux.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
                _ = std.os.linux.nanosleep(&req, null);
            }
        }
    }

    /// Start the background progress sampler. No-op unless progress is drawn,
    /// so it never spins up in benchmark / piped runs.
    pub fn startProgressSampler(self: *Evaluator) void {
        if (self.progress == null) return;
        self.progress_stop.store(false, .release);
        self.progress_thread = std.Thread.spawn(.{}, progressSampleLoop, .{self}) catch null;
    }

    /// Stop and join the sampler, then push one final snapshot so the last
    /// numbers (final heap / GC tally) land before the bar is torn down.
    pub fn stopProgressSampler(self: *Evaluator) void {
        if (self.progress_thread) |t| {
            self.progress_stop.store(true, .release);
            t.join();
            self.progress_thread = null;
        }
        self.progressSample();
    }

    /// Writer-side `[i/N]` item count. `progressCountBegin` sets the render
    /// node's total (once, per top-level collection) and returns whether
    /// counting is live; `progressStep` advances it per element (cheap — no
    /// per-element eligibility recheck). Demand path only.
    pub fn progressCountBegin(self: *Evaluator, total: usize) bool {
        if (!progressEligible()) return false;
        const sink = self.progress orelse return false;
        sink.count(0, total);
        return true;
    }

    pub fn progressStep(self: *Evaluator, completed: usize, total: usize) void {
        if (self.progress) |sink| sink.count(completed, total);
    }

    pub fn progressSessionBegin(self: *Evaluator, label: []const u8) void {
        if (self.progress) |sink| sink.sessionBegin(label);
    }

    pub fn progressSessionEnd(self: *Evaluator) void {
        self.progress_wait.clear();
        if (self.progress) |sink| sink.sessionEnd();
    }
};

/// Helper worker loop. Owns an on-demand fiber pool (no fixed size);
/// each fiber has its own VM and can be parked mid-evaluation when it
/// hits a `.busy` thunk. The Worker drives the fiber drain loop — see
/// `worker.zig`. Errors during speculation are swallowed inside the
/// fiber's entry; the thunk's own `reset()` on failure surfaces the
/// error to a future genuine caller.
fn helperLoop(worker_id: u8, sched: *Scheduler, ev: *Evaluator) void {
    const worker = worker_mod.Worker.init(
        ev.allocator,
        sched,
        worker_id,
        ev,
        initVmForWorkerSlot,
    ) catch {
        // Still pass the quiescence barrier so peers don't wait forever.
        sched.awaitHelpersQuiescent();
        return;
    };
    // GC (`-Dgc`): register this helper so the collector can walk its fibers
    // for roots. Registration happens before `run()` (before any user-object
    // allocation), and the collector only reads the registry at a stop-the-
    // world where this worker is parked.
    if (comptime gc.enabled) ev.gc_workers[worker_id].store(worker, .release);
    worker.run();
    // Wait until ALL helpers have stopped forcing before destroying any
    // fibers — a still-running helper could resolve a thunk and wake a
    // just-freed enrolled fiber (shutdown UAF). See awaitHelpersQuiescent.
    sched.awaitHelpersQuiescent();
    // Unregister before deinit so a late collection never scans freed fibers.
    // (After awaitHelpersQuiescent no helper is still forcing, so no
    // collection can be triggered past this point, but keep the invariant.)
    if (comptime gc.enabled) ev.gc_workers[worker_id].store(null, .release);
    worker.deinit();
}

fn initVmForWorkerSlot(ctx: *anyopaque, worker_id: u8, _: u32, scratch: std.mem.Allocator) anyerror!VM {
    const ev: *Evaluator = @ptrCast(@alignCast(ctx));
    return ev.initVm(worker_id, scratch);
}

fn ReturnPayload(comptime F: type) type {
    const ret = @typeInfo(F).@"fn".return_type.?;
    return switch (@typeInfo(ret)) {
        .error_union => |eu| eu.payload,
        else => ret,
    };
}

/// Shim that lets `Evaluator.writeValue` reuse the same `runWithVm`
/// machinery as the VM-bodied entries. The output formatter walks
/// values via `Evaluator.forceValue` for nested thunks; the surrounding
/// fiber's identity threads through via initVm, so we don't need a
/// fresh VM here ourselves.
fn writeValueBody(_: *VM, ev: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
    return eval_print.writeValue(ev, writer, value);
}

test {
    _ = @import("eval/tests.zig");
}
