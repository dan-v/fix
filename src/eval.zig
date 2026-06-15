//! Evaluator — the top-level orchestration layer.
//!
//! Manages the shared state (chunk registry, intern table, scheduler) and runs
//! the worker threads that execute bytecode.

const std = @import("std");
const types = @import("runtime/types.zig");
const bytecode = @import("bytecode.zig");
const opcode = bytecode.opcode;
const InternTable = @import("runtime/intern.zig").InternTable;
const ChunkRegistry = bytecode.ChunkRegistry;
const ChunkBuilder = bytecode.ChunkBuilder;
const ChunkId = types.ChunkId;
const Scheduler = @import("scheduler.zig").Scheduler;
const vm_mod = @import("vm.zig");
const VM = vm_mod.VM;
const vm_force = @import("vm/force.zig");
const vm_builtins = @import("vm/builtins.zig");
const ObjectHeap = @import("runtime/heap.zig").ObjectHeap;
const FileCache = @import("file_cache.zig").FileCache;
const FetchCache = @import("fetch_cache.zig").FetchCache;
const DerivationStore = @import("derivation.zig").DerivationStore;
const derivation = @import("derivation.zig");
const Value = @import("runtime/value.zig").Value;
const builtins = @import("builtins.zig");
const parser_mod = @import("parser.zig");
const diagnostic = @import("diagnostic.zig");
const eval_trace = @import("eval/trace.zig");
const eval_progress = @import("eval/progress.zig");
const Run = @import("eval/run.zig").Run;
const path_ops = @import("runtime/paths.zig");
const eval_print = @import("eval/print.zig");
const search_path_mod = @import("eval/search_path.zig");
const imports_mod = @import("eval/imports.zig");

const worker_mod = @import("worker.zig");
const fiber_mod = @import("fiber.zig");

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
    base_path: ?[:0]u8,
    env_map: ?*const std.process.Environ.Map,
    progress: ?eval_progress.Sink,
    vm_trace: ?*@import("vm/trace_log.zig").VmTrace,
    thunk_trace: if (vm_mod.thunks_log_enabled) ?*@import("eval/thunk_trace.zig").ThunkTrace else void,
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
        };
    }

    /// `-Dtjit` diagnostic: which chunks went hot enough to anchor a trace.
    /// Resolves each armed/traced chunk to its source location so we can see
    /// the recorder's targets on the real workload.
    fn reportHotAnchors(self: *Evaluator) void {
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
                id, path, line, @tagName(st), h.entries[id].count.load(.monotonic), ch.local_count,
            });
        }
        std.debug.print("=== tjit hot anchors: {d} armed, {d} traced (threshold={d}, chunks={d}) ===\n", .{ armed, traced, h.hot_threshold, count });
    }

    pub fn deinit(self: *Evaluator) void {
        if (comptime vm_mod.opcode_profile_enabled) printVmOpcodeProfile(&self.vm_opcode_counts);
        @import("vm/trace_probe.zig").report();
        @import("vm/ngram_probe.zig").report();
        if (comptime @import("tjit/hot.zig").enabled) self.reportHotAnchors();
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

    pub fn setVmTrace(self: *Evaluator, vm_trace: ?*@import("vm/trace_log.zig").VmTrace) void {
        self.vm_trace = vm_trace;
    }

    pub fn setThunkTrace(self: *Evaluator, thunk_trace: ?*@import("eval/thunk_trace.zig").ThunkTrace) void {
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

        var arena = @import("ast.zig").AstArena.init(self.allocator);
        defer arena.deinit();

        var parser = parser_mod.Parser.init(self.allocator, &arena, source);
        defer parser.deinit();

        const ast_node = blk: {
            self.progressBegin(.parse, subject);
            defer self.progressEnd(.parse, subject);
            const pt = @import("prof.zig").start(.parse);
            defer @import("prof.zig").end(.parse, pt);
            break :blk parser.parse() catch {
                try self.copyDiagnostics(parser.diagnostics.items, source, source_path);
                return error.ParseError;
            };
        };

        var builder = try ChunkBuilder.init(self.allocator);
        defer builder.deinit(self.allocator);

        var compiler = @import("compiler.zig").Compiler.init(
            self.allocator,
            &builder,
            &self.registry,
            source,
            &self.intern,
            &self.heap,
        );
        compiler.base_path = base_path;
        compiler.source_path = source_path;
        defer compiler.deinit();

        {
            self.progressBegin(.compile, subject);
            defer self.progressEnd(.compile, subject);
            const ct = @import("prof.zig").start(.compile);
            defer @import("prof.zig").end(.compile, ct);
            compiler.compileAndFinish(ast_node, scope) catch |err| {
                try self.copyDiagnostics(compiler.diagnostics.items, source, source_path);
                return err;
            };
        }

        const chunk = try builder.finish(self.allocator, compiler.slot_count);
        return self.registry.register(chunk);
    }

    /// Read-only access to compiled chunks for tools.
    pub fn getChunk(self: *const Evaluator, id: ChunkId) ?*const @import("bytecode.zig").Chunk {
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
        @import("vm/trace_probe.zig").init(self.allocator);
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
        return vm;
    }

    pub fn writeJsonValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        self.progressBegin(.render, "result");
        defer self.progressEnd(.render, "result");
        self.run.trace.clear();
        return self.runWithVm(vm_builtins.writeJsonValue, .{ writer, value });
    }

    pub fn writeXmlValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        self.progressBegin(.render, "result");
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
        return w;
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
        defer self.progressEnd(.render, "result");
        return self.runWithVm(writeValueBody, .{ self, writer, value });
    }

    pub fn progressBegin(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
        if (self.progress) |progress| progress.begin(stage, subject);
    }

    pub fn progressEnd(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
        if (self.progress) |progress| progress.end(stage, subject);
    }

    pub fn progressInstant(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
        if (self.progress) |progress| progress.instant(stage, subject);
    }
};

/// Helper worker loop. Owns a fiber pool of `worker_mod.slots_per_worker`
/// slots; each slot has its own VM and can be parked mid-evaluation when
/// it hits a `.busy` thunk. The Worker drives the slot scheduler — see
/// `worker.zig`. Errors during speculation are swallowed inside the
/// slot's entry; the thunk's own `reset()` on failure surfaces the
/// error to a future genuine caller.
fn helperLoop(worker_id: u8, sched: *Scheduler, ev: *Evaluator) void {
    const worker = worker_mod.Worker.init(
        ev.allocator,
        sched,
        worker_id,
        ev,
        initVmForWorkerSlot,
    ) catch return;
    defer worker.deinit();
    worker.run();
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
