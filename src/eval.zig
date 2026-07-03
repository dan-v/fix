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
const FileCache = @import("runtime").file_cache.FileCache;
const FetchCache = @import("runtime").fetch_cache.FetchCache;
const DerivationStore = @import("derivation").DerivationStore;
const derivation = @import("derivation");
const Value = @import("runtime").value.Value;
const builtins = @import("runtime").builtins;
const parser_mod = @import("syntax").parser;
const diagnostic = @import("syntax").diagnostic;
const eval_trace = @import("support/trace.zig");
const eval_progress = @import("eval/progress.zig");
const timeline = @import("probe/timeline.zig");
const ast_mod = @import("syntax").ast;
const deferred_mod = @import("compiler/deferred_table.zig");
const Run = @import("eval/run.zig").Run;
const path_ops = @import("runtime").paths;
const eval_print = @import("eval/print.zig");
const search_path_mod = @import("eval/search_path.zig");
const imports_mod = @import("eval/imports.zig");

const worker_mod = @import("eval/worker.zig");
const fiber_mod = @import("parallel").fiber;
const prof = @import("probe/prof.zig");
const compiler_mod = @import("compiler.zig");
const VmTrace = @import("vm/trace_log.zig").VmTrace;
const ThunkTrace = @import("probe/thunk_trace.zig").ThunkTrace;
const SpinMutex = @import("runtime").stable_segments.SpinMutex;
const struct_census = @import("runtime").struct_census;
const gc = @import("runtime").gc;
const thunk_mod = @import("runtime").thunk;
const trace_probe = @import("probe/trace_probe.zig");
const drv_probe = @import("probe/drv_probe.zig");
const ngram_probe = @import("probe/ngram_probe.zig");
const tjit_hot = @import("jit/hot.zig");
const tjit_exec = @import("jit/exec.zig");
const tjit_record = @import("jit/record.zig");

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
    imports: imports_mod.Registry,
    search_paths: search_path_mod.Paths,
    /// One arena per worker. Each VM allocates its stack, frames, and
    /// per-opcode scratch through its worker's arena so workers never share
    /// a non-thread-safe allocator.
    worker_arenas: []std.heap.ArenaAllocator,
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

        const arenas = try allocator.alloc(std.heap.ArenaAllocator, worker_count);
        errdefer allocator.free(arenas);
        for (arenas) |*arena| arena.* = std.heap.ArenaAllocator.init(allocator);

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
            .imports = .{},
            .search_paths = .{},
            .worker_arenas = arenas,
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

    /// `-Dtjit` diagnostic: which chunks went hot enough to anchor a trace.
    /// Resolves each armed/traced chunk to its source location so we can see
    /// the recorder's targets on the real workload.
    fn reportHotAnchors(self: *Evaluator) void {
        if (!tjit_hot.report_enabled) return;
        const h = self.registry.hot orelse return;
        var armed: usize = 0;
        var traced: usize = 0;
        var shown: usize = 0;
        const count = self.registry.count();
        var id: u32 = 0;
        while (id < count and id < h.entries.len) : (id += 1) {
            const st = h.stateOf(id);
            if (st == .cold or st == .blacklisted) continue;
            if (st == .traced) traced += 1 else armed += 1;
            if (shown >= 80) continue;
            shown += 1;
            const ch = self.registry.get(id) orelse continue;
            var line: u32 = 0;
            var file: ?types.InternId = null;
            for (ch.source_map) |e| {
                if (e.start == 0) {
                    line = e.span.line;
                    file = e.span.file;
                    break;
                }
            }
            const path = if (file) |f| std.fs.path.basename(self.intern.get(f)) else "<no-file>";
            std.debug.print("HOT-ANCHOR chunk={d} {s}:{d} {s} entries={d} locals={d}\n", .{
                id, path, line, @tagName(st), h.entries[id].count, ch.local_count,
            });
        }
        std.debug.print("=== tjit hot anchors: {d} armed, {d} traced (threshold={d}, chunks={d}) ===\n", .{ armed, traced, h.hot_threshold, count });
    }

    pub fn deinit(self: *Evaluator) void {
        if (comptime vm_mod.opcode_profile_enabled) printVmOpcodeProfile(&self.vm_opcode_counts);
        trace_probe.report();
        struct_census.report();
        if (comptime gc.enabled) {
            gc.recordFinalTotal(self.heap.totalReservedBytes());
            gc.report();
            self.gc_tracer.deinit();
            self.gc_import_vms.deinit(self.allocator);
            self.allocator.free(self.gc_workers);
        }
        drv_probe.report();
        ngram_probe.report();
        if (comptime tjit_hot.enabled) self.reportHotAnchors();
        if (comptime tjit_exec.enabled) tjit_exec.report();
        if (comptime tjit_record.enabled) tjit_record.report();
        // Helpers hold VMs whose allocations live in `worker_arenas`. Shut
        // them down (which joins on `defer vm.deinit()` inside helperLoop)
        // before freeing the arenas they borrow from.
        self.scheduler.deinit();
        // Now that helpers are guaranteed quiescent, tear down the main
        // worker. Doing this before scheduler shutdown could race with
        // a helper still resuming a stolen main fiber.
        if (self.main_worker) |w| w.deinit();
        if (self.base_path) |path| self.allocator.free(path);
        self.run.deinit();
        self.imports.deinit(self.allocator);
        self.search_paths.deinit(self.allocator);
        self.fetchers.deinit();
        self.derivations.deinit();
        self.files.deinit();
        self.heap.deinit();
        for (self.worker_arenas) |*arena| arena.deinit();
        self.allocator.free(self.worker_arenas);
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

        const ast_node = blk: {
            self.progressBegin(.parse, subject);
            defer self.progressEnd(.parse, subject);
            timeline.begin(.parse, subject, 0);
            defer timeline.end(.parse);
            const pt = prof.start(.parse);
            defer prof.end(.parse, pt);
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
                .line = tok.line,
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
        trace_probe.init(self.allocator);
        struct_census.init(self.allocator);
        // Build the builtins attrset on the main thread before any helpers
        // can race on it. `buildAttrSet` predicts the next ObjectId for
        // the self-reference `builtins.builtins`; that prediction is only
        // safe when no other thread is allocating objects.
        _ = try self.ensureBuiltins();
        try self.scheduler.start(helperLoop, self);
        self.clearDiagnostics();
        self.derivations.clearDebugRecords();
        return self.evaluateSource(source, self.base_path, null, null);
    }

    pub fn evaluateSource(
        self: *Evaluator,
        source: []const u8,
        base_path: ?[]const u8,
        source_path: ?[]const u8,
        scope: ?Value,
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
        var vm = try self.initVm(0);
        defer vm.deinit();
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
        // Depth-transparent import: we got here from inside the
        // `import`/`scopedImport` builtin (which raised native_depth). Drop
        // back to the caller's depth for the imported eval so that a
        // top-level import still collects (depth 0), while an import nested
        // inside another builtin stays gated (that builtin's depth). This is
        // what keeps builtins correct-by-default. See vm/force.zig.
        if (comptime gc.enabled) vm_force.native_depth -= 1;
        defer if (comptime gc.enabled) {
            vm_force.native_depth += 1;
        };
        return vm.eval(chunk_id);
    }

    fn runChunkOnMainWorker(self: *Evaluator, chunk_id: ChunkId) !Value {
        return self.runWithVm(VM.eval, .{chunk_id});
    }

    fn initVm(self: *Evaluator, worker_id: u8) !VM {
        var vm = try VM.init(
            self.worker_arenas[worker_id].allocator(),
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
            const wf: *worker_mod.Fiber = @fieldParentPtr("inner", inner);
            vm.claimer_id = wf.vm.claimer_id;
        }
        vm.lazy_shells_visible = self.lazy_shells_visible;
        vm.deferred_table = &self.deferred_table;
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
        return self.runWithVm(vm_force.forceDeep, .{value});
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
            var vm = try self.initVm(0);
            defer vm.deinit();
            if (comptime gc.enabled) self.gcRegisterVm(&vm);
            defer if (comptime gc.enabled) self.gcUnregisterVm(&vm);
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
                var vm = ctx.ev.initVm(0) catch |e| {
                    ctx.err = e;
                    return;
                };
                defer vm.deinit();
                if (comptime gc.enabled) ctx.ev.gcRegisterVm(&vm);
                defer if (comptime gc.enabled) ctx.ev.gcUnregisterVm(&vm);
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
            // Reclaim is enabled at --workers=1 (byte-identical, -16% RSS).
            // The multi-worker stop-the-world path (barrier + per-worker
            // roots + suspended-fiber conservative scan) is built but the STW
            // barrier still has a back-to-back-collection handshake race, so
            // it stays gated off pending a properly generation-tagged
            // barrier. At --workers>1 the GC is dormant (no collection), so
            // the evaluator behaves exactly as a non-GC build there.
            if (self.worker_count == 1) {
                // FIX_GC_STEP_MB (validation): collect every N MB of fresh
                // allocation so the detector exercises every builtin loop.
                var step_bytes: u64 = 0;
                if (self.env_map) |em| {
                    if (em.get("FIX_GC_STEP_MB")) |s| {
                        if (std.fmt.parseInt(u64, s, 10)) |mb| step_bytes = mb << 20 else |_| {}
                    }
                }
                self.heap.gcEnableCollect(ObjectHeap.GC_MIN_THRESHOLD, step_bytes);
            }
        }
        return w;
    }

    /// GC (`-Dgc`): register a stack-local VM (the top-level entry's VM, a
    /// nested-eval VM, or an import VM) so the collector scans its roots.
    /// These VMs are NOT in any worker's `fibers` list, so without this their
    /// operand stack / frames / force-chain / temp-roots are invisible and
    /// their live objects get swept. Concurrent imports at --workers>1
    /// interleave, hence the mutex + remove-by-value.
    pub fn gcRegisterVm(self: *Evaluator, vm: *VM) void {
        if (comptime !gc.enabled) return;
        self.gc_import_vms_mu.lock();
        defer self.gc_import_vms_mu.unlock();
        self.gc_import_vms.append(self.allocator, vm) catch {};
    }
    pub fn gcUnregisterVm(self: *Evaluator, vm: *VM) void {
        if (comptime !gc.enabled) return;
        self.gc_import_vms_mu.lock();
        defer self.gc_import_vms_mu.unlock();
        for (self.gc_import_vms.items, 0..) |ivm, i| {
            if (ivm == vm) {
                _ = self.gc_import_vms.swapRemove(i);
                break;
            }
        }
    }

    /// Type-erased trampoline for the heap's collect callback.
    fn gcCollectThunk(ctx: *anyopaque) void {
        const self: *Evaluator = @ptrCast(@alignCast(ctx));
        self.gcCollect();
    }

    /// GC (`-Dgc`): one stop-the-world mark-sweep at a safepoint. Mark the
    /// live graph from roots, sweep dead objects/ranges into the free
    /// lists, set the next threshold from the surviving live set. Runs on
    /// the lone mutator at --workers=1; see docs/plans/gc-plan.md for the roots.
    fn gcCollect(self: *Evaluator) void {
        if (comptime !gc.enabled) return;
        const tr = &self.gc_tracer;
        tr.reset(self.heap.objects.count()) catch {
            // Can't size the mark bitmap — skip this collection rather than
            // risk an unmarked sweep. Bump the threshold so we don't spin.
            self.heap.gcAfterCollect(self.heap.totalReservedBytes());
            return;
        };
        const t0 = gcNowNs();
        self.gcMarkRoots(tr);
        tr.drain(&self.heap); // precise transitive closure from the roots
        const t1 = gcNowNs();
        const st = self.heap.sweep(tr.mark_bits);
        const t2 = gcNowNs();
        self.heap.gcAfterCollect(tr.stats.bytes);
        gc.recordCollection(st.objects_freed, tr.stats.bytes, self.heap.totalReservedBytes());
        gc.recordTiming(t1 - t0, t2 - t1);
        gc.recordBreakdown(.{
            .obj_live = tr.stats.objects,
            .obj_reserved = self.heap.objects.count(),
            .val_live = tr.stats.values,
            .val_reserved = self.heap.values.count(),
            .attr_live = tr.stats.attrs,
            .attr_reserved = self.heap.attrs.count(),
        });
    }

    fn gcNowNs() u64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }

    /// Mark all GC roots into `tr` (without draining). See docs/plans/gc-plan.md.
    fn gcMarkRoots(self: *Evaluator, tr: *gc.Tracer) void {
        if (self.builtins_value) |b| tr.markValue(&self.heap, b);
        // Every worker's fibers' VM stack/frames/upvalues. At a stop-the-
        // world every live worker is parked at a safepoint, so its fiber
        // list is stable and its fibers' VMs hold that worker's roots. The
        // registry is published by each worker before it can allocate.
        for (self.gc_workers) |*slot| {
            const w = slot.load(.acquire) orelse continue;
            for (w.fibers.items) |f| {
                // Precise, for every fiber: operand stack + frames + upvalues +
                // in-flight force chain + builtin temp-roots (see force.zig).
                gcMarkVm(tr, &self.heap, &f.vm);
                // A task assigned to a fiber is out of the scheduler queue
                // but still a live reference until the fiber processes it.
                if (f.current_task) |task| switch (task) {
                    .force_thunk => |id| tr.markObject(&self.heap, id),
                    .force_list_range => |r| tr.markObject(&self.heap, r.list_id),
                };
            }
        }
        // Transient import VMs (not in any fiber list).
        self.gc_import_vms_mu.lock();
        for (self.gc_import_vms.items) |ivm| gcMarkVm(tr, &self.heap, ivm);
        self.gc_import_vms_mu.unlock();
        // Pending scheduler tasks reference thunks/lists that will be forced.
        self.scheduler.gcMarkPendingTasks(tr, &self.heap);
        // Thread-local caches hold Values that can be the momentary sole
        // reference to a shared object during forcing — mark them.
        vm_force.gcMarkThunkMemo(tr, &self.heap);
        @import("vm/access.zig").gcMarkAttrCache(tr, &self.heap);
        // Chunk constants can hold heap references (e.g. a scoped-import's
        // ambient-scope attrset baked in via emitConstant). Chunks are never
        // GC'd, so their constants are permanent roots.
        const chunk_count = self.registry.count();
        var cid: ChunkId = 0;
        while (cid < chunk_count) : (cid += 1) {
            const ch = self.registry.get(cid) orelse continue;
            for (ch.constants) |c| tr.markValue(&self.heap, c);
        }
        // Resolved import results.
        var it = self.imports.entries.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (entry.future.state.load(.monotonic) == @intFromEnum(thunk_mod.FutureState.resolved))
                tr.markValue(&self.heap, entry.result);
        }
        // Lazy-derivation cache (Value bits keyed by attrs id). Only current-
        // token entries are live roots; stale ones (pre-GC id, now reused) are
        // dead and will miss on lookup, so don't retain them.
        var dit = self.derivations.lazy_drv_cache.iterator();
        while (dit.next()) |e| if (e.value_ptr.token == self.heap.token)
            tr.markValue(&self.heap, .{ .bits = e.value_ptr.bits });
    }

    fn gcMarkVm(tr: *gc.Tracer, heap: *ObjectHeap, vm: *const VM) void {
        if (comptime !gc.enabled) return;
        tr.markValue(heap, vm.builtins);
        tr.markValue(heap, vm.gc_extra_root); // value in-flight at the safepoint
        for (vm.gc_force_chain.items) |id| tr.markObject(heap, id); // in-flight force chain
        for (vm.gc_temp_roots.items) |v| tr.markValue(heap, v); // native builtin roots
        for (vm.stack[0..vm.sp]) |v| tr.markValue(heap, v);
        for (vm.frames[0..vm.frames_len]) |frame| {
            if (frame.upvalues) |ups| for (ups) |v| tr.markValue(heap, v);
        }
        for (vm.native_upvalues) |v| tr.markValue(heap, v);
    }

    fn importValue(context: *anyopaque, path: []const u8) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return imports_mod.importPath(self, path);
    }

    fn scopedImportValue(context: *anyopaque, scope: Value, path: []const u8) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return imports_mod.scopedImportPath(self, scope, path);
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
    /// fan-out force run on arbitrary worker fibers and reentrantly
    /// interleave begin/end pairs into the one std `Progress` tree, which
    /// deadlocks inside `Io.Threaded.cancel` (`Progress.Node.end`). Every
    /// task fiber forces via `forceValueSpeculative` (so `vm.in_speculation`
    /// is set); only the top demand fiber has it clear and is never
    /// concurrent with itself, so it alone may emit. begin and end share
    /// this gate (the fiber's flag is stable across a single force), so
    /// pairs stay balanced. No current fiber = early single-threaded setup.
    fn progressEligible() bool {
        const inner = fiber_mod.currentFiber() orelse return true;
        const wf: *worker_mod.Fiber = @fieldParentPtr("inner", inner);
        return !wf.vm.in_speculation;
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

fn initVmForWorkerSlot(ctx: *anyopaque, worker_id: u8, _: u32) anyerror!VM {
    const ev: *Evaluator = @ptrCast(@alignCast(ctx));
    return ev.initVm(worker_id);
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

const OpcodeCountEntry = struct {
    op: opcode.OpCode,
    count: u64,
};

fn printVmOpcodeProfile(counts: *const vm_mod.OpcodeCounts) void {
    var total: u64 = 0;
    var entries: [opcode.count]OpcodeCountEntry = undefined;
    for (counts, &entries, 0..) |count, *entry, i| {
        total += count;
        entry.* = .{
            .op = @enumFromInt(i),
            .count = count,
        };
    }

    std.mem.sort(OpcodeCountEntry, &entries, {}, opcodeCountGreaterThan);

    std.debug.print("fix vm opcode profile: total={d}\n", .{total});
    for (entries) |entry| {
        if (entry.count == 0) break;
        const pct = if (total == 0) 0.0 else (@as(f64, @floatFromInt(entry.count)) * 100.0) / @as(f64, @floatFromInt(total));
        std.debug.print("  {s}: {d} ({d:.2}%)\n", .{ @tagName(entry.op), entry.count, pct });
    }
}

fn opcodeCountGreaterThan(_: void, lhs: OpcodeCountEntry, rhs: OpcodeCountEntry) bool {
    return lhs.count > rhs.count;
}

test {
    _ = @import("eval/tests.zig");
}
