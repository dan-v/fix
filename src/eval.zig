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
const ThunkState = @import("runtime/thunk.zig").ThunkState;
const builtins = @import("builtins.zig");
const parser_mod = @import("parser.zig");
const diagnostic = @import("diagnostic.zig");
const eval_trace = @import("eval/trace.zig");
const eval_progress = @import("eval/progress.zig");
const Run = @import("eval/run.zig").Run;
const path_ops = @import("runtime/paths.zig");
const eval_print = @import("eval/print.zig");
const stable_segments_mod = @import("runtime/stable_segments.zig");

const worker_id_mod = @import("runtime/worker_id.zig");
const worker_mod = @import("worker.zig");
const fiber_mod = @import("fiber.zig");

/// Per-thread linked list of in-progress *scoped* import paths. Scoped
/// imports are not deduplicated through `ImportEntry` (each call has a
/// distinct scope value), so cycle detection for them remains thread-local.
const ImportFrame = struct {
    path: []const u8,
    next: ?*const ImportFrame,
};
threadlocal var scoped_import_stack_top: ?*const ImportFrame = null;

fn checkScopedImportCycle(path: []const u8) !void {
    var cursor = scoped_import_stack_top;
    while (cursor) |node| {
        if (std.mem.eql(u8, node.path, path)) return error.ImportCycle;
        cursor = node.next;
    }
}

const INVALID_CLAIMER: u8 = 0xFF;

/// Per-path import deduplication entry. The first thread to claim
/// (cmpxchg state from unresolved → evaluating) does the work; others
/// either wait (main thread) or bail (helper threads, to avoid deadlock
/// with the main thread holding a contended thunk).
const ImportEntry = struct {
    const STATE_UNRESOLVED: u32 = 0;
    const STATE_EVALUATING: u32 = 1;
    const STATE_RESOLVED: u32 = 2;
    const STATE_FAILED: u32 = 3;

    state: std.atomic.Value(u32) = .init(STATE_UNRESOLVED),
    claimer: std.atomic.Value(u8) = .init(INVALID_CLAIMER),
    result: Value = Value.null_val,

    fn waitForChange(self: *ImportEntry, from: u32) void {
        switch (@import("builtin").os.tag) {
            .linux => {
                _ = std.os.linux.futex_4arg(
                    @ptrCast(&self.state),
                    .{ .cmd = .WAIT, .private = true },
                    from,
                    null,
                );
            },
            else => std.Thread.yield() catch {},
        }
    }

    fn wakeAll(self: *ImportEntry) void {
        switch (@import("builtin").os.tag) {
            .linux => {
                _ = std.os.linux.futex_3arg(
                    @ptrCast(&self.state),
                    .{ .cmd = .WAKE, .private = true },
                    std.math.maxInt(i32),
                );
            },
            else => {},
        }
    }
};

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
    imports: std.StringHashMapUnmanaged(*ImportEntry),
    imports_mu: stable_segments_mod.SpinMutex,
    search_paths: []SearchPathEntry,
    /// One arena per worker. Each VM allocates its stack, frames, and
    /// per-opcode scratch through its worker's arena so workers never share
    /// a non-thread-safe allocator.
    worker_arenas: []std.heap.ArenaAllocator,
    builtins_value: ?Value,
    base_path: ?[:0]u8,
    env_map: ?*const std.process.Environ.Map,
    progress: ?eval_progress.Sink,
    vm_trace: ?*@import("vm/trace_log.zig").VmTrace,
    thunk_trace: if (vm_mod.thunks_log_enabled) ?*@import("eval/thunk_trace.zig").ThunkTrace else void,
    worker_count: u8,
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
            .imports = .empty,
            .imports_mu = .{},
            .search_paths = &.{},
            .worker_arenas = arenas,
            .builtins_value = null,
            .base_path = null,
            .env_map = null,
            .progress = null,
            .vm_trace = null,
            .thunk_trace = if (vm_mod.thunks_log_enabled) null else {},
            .worker_count = worker_count,
            .run = Run.init(allocator),
            .vm_opcode_counts = if (vm_mod.opcode_profile_enabled) [_]u64{0} ** opcode.count else {},
        };
    }

    pub fn deinit(self: *Evaluator) void {
        if (comptime vm_mod.opcode_profile_enabled) printVmOpcodeProfile(&self.vm_opcode_counts);
        // Helpers hold VMs whose allocations live in `worker_arenas`. Shut
        // them down (which joins on `defer vm.deinit()` inside helperLoop)
        // before freeing the arenas they borrow from.
        self.scheduler.deinit();
        if (self.base_path) |path| self.allocator.free(path);
        self.run.deinit();
        var imports_iter = self.imports.iterator();
        while (imports_iter.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.imports.deinit(self.allocator);
        self.freeSearchPaths();
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
        self.freeSearchPaths();

        var entries: std.ArrayListUnmanaged(SearchPathEntry) = .empty;
        errdefer {
            for (entries.items) |entry| entry.deinit(self.allocator);
            entries.deinit(self.allocator);
        }

        var parts = std.mem.splitScalar(u8, nix_path, ':');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, part, '=');
            const prefix = if (eq) |i| part[0..i] else "";
            const raw_path = if (eq) |i| part[i + 1 ..] else part;
            if (raw_path.len == 0) continue;

            const resolved = self.resolveHostPath(raw_path) catch |err| switch (err) {
                error.RelativePath => continue,
                else => return err,
            };
            defer if (resolved.owned) self.allocator.free(resolved.text);

            try entries.append(self.allocator, .{
                .prefix = try self.allocator.dupe(u8, prefix),
                .path = try self.allocator.dupe(u8, resolved.text),
            });
        }

        self.search_paths = try entries.toOwnedSlice(self.allocator);
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
        const subject = source_path orelse "expression";

        var arena = @import("ast.zig").AstArena.init(self.allocator);
        defer arena.deinit();

        var parser = parser_mod.Parser.init(self.allocator, &arena, source);
        defer parser.deinit();

        const ast_node = blk: {
            self.progressBegin(.parse, subject);
            defer self.progressEnd(.parse, subject);
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
        );
        compiler.base_path = self.base_path;
        compiler.source_path = source_path;
        defer compiler.deinit();

        {
            self.progressBegin(.compile, subject);
            defer self.progressEnd(.compile, subject);
            compiler.compileAndFinish(ast_node, null) catch |err| {
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

    pub fn helperCount(self: *const Evaluator) u8 {
        return self.scheduler.helper_count;
    }

    /// Compile source text into bytecode and evaluate it.
    /// This is the main public API.
    pub fn evaluate(self: *Evaluator, source: []const u8) !Value {
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

    fn evaluateSource(
        self: *Evaluator,
        source: []const u8,
        base_path: ?[]const u8,
        source_path: ?[]const u8,
        scope: ?Value,
    ) !Value {
        const subject = source_path orelse "expression";

        // 1. Parse into AST.
        var arena = @import("ast.zig").AstArena.init(self.allocator);
        defer arena.deinit();

        var parser = parser_mod.Parser.init(self.allocator, &arena, source);
        defer parser.deinit();

        const ast_node = blk: {
            self.progressBegin(.parse, subject);
            defer self.progressEnd(.parse, subject);
            break :blk parser.parse() catch {
                try self.copyDiagnostics(parser.diagnostics.items, source, source_path);
                return error.ParseError;
            };
        };

        // 2. Compile AST to bytecode.
        var builder = try ChunkBuilder.init(self.allocator);
        defer builder.deinit(self.allocator);

        var compiler = @import("compiler.zig").Compiler.init(
            self.allocator,
            &builder,
            &self.registry,
            source,
            &self.intern,
        );
        compiler.base_path = base_path;
        compiler.source_path = source_path;
        defer compiler.deinit();

        {
            self.progressBegin(.compile, subject);
            defer self.progressEnd(.compile, subject);
            compiler.compileAndFinish(ast_node, scope) catch |err| {
                try self.copyDiagnostics(compiler.diagnostics.items, source, source_path);
                return err;
            };
        }

        const chunk = try builder.finish(self.allocator, compiler.slot_count);
        const chunk_id = try self.registry.register(chunk);

        // 3. Evaluate via a VM. Only the *top-level* eval (called from
        // `Evaluator.evaluate`) goes through a main-thread fiber so the
        // main thread can yield on a `.busy` thunk; nested invocations
        // (imports, scoped imports) run synchronously on the existing
        // fiber's stack — they share the outer VM's claim identity via
        // default placeholder claimer that `initVm` hands out.
        if (scope == null and source_path == null) {
            self.progressBegin(.evaluate, subject);
            defer self.progressEnd(.evaluate, subject);
            return self.runChunkOnMainWorker(chunk_id);
        }
        var vm = try self.initVm(0);
        defer vm.deinit();
        self.progressBegin(.evaluate, subject);
        defer self.progressEnd(.evaluate, subject);
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
            worker_id,
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
        const worker = try worker_mod.Worker.init(
            self.allocator,
            &self.scheduler,
            self.scheduler.helper_count,
            0,
            self,
            initVmForWorkerSlot,
        );
        defer worker.deinit();
        try worker.runTopLevel(Ctx.entry, @ptrCast(&ctx));
        if (ctx.err) |e| return e;
        return ctx.result;
    }

    fn importValue(context: *anyopaque, path: []const u8) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return self.importPath(path);
    }

    fn scopedImportValue(context: *anyopaque, scope: Value, path: []const u8) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return self.scopedImportPath(scope, path);
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
        if (std.mem.eql(u8, name, "nix/fetchurl.nix")) {
            return Value.path(try self.intern.intern("/__corepkgs__/fetchurl.nix"));
        }

        for (self.search_paths) |entry| {
            if (try self.searchPathCandidate(entry.path, entry.prefix, name)) |candidate| {
                defer self.allocator.free(candidate);
                return Value.path(try self.intern.intern(candidate));
            }
        }
        return error.FileNotFound;
    }

    fn searchPathCandidate(self: *Evaluator, base: []const u8, prefix: []const u8, name: []const u8) !?[]u8 {
        const suffix = path_ops.searchPathSuffix(prefix, name) orelse return null;
        const candidate = try std.fs.path.resolve(self.allocator, &.{ base, suffix });
        errdefer self.allocator.free(candidate);
        if (try self.files.pathExists(candidate)) return candidate;
        self.allocator.free(candidate);
        return null;
    }

    fn importPath(self: *Evaluator, path: []const u8) !Value {
        const resolved = try self.resolveHostPath(path);
        defer if (resolved.owned) self.allocator.free(resolved.text);
        return self.importResolvedPath(resolved.text);
    }

    fn importResolvedPath(self: *Evaluator, path: []const u8) anyerror!Value {
        const entry = try self.lookupOrCreateImportEntry(path);
        return self.forceImportEntry(path, entry);
    }

    fn forceImportEntry(self: *Evaluator, path: []const u8, entry: *ImportEntry) anyerror!Value {
        const me = worker_id_mod.current;
        while (true) {
            const state = entry.state.load(.acquire);
            switch (state) {
                ImportEntry.STATE_RESOLVED => return entry.result,
                ImportEntry.STATE_FAILED => return error.ImportFailed,
                ImportEntry.STATE_EVALUATING => {
                    const claimer = entry.claimer.load(.acquire);
                    if (claimer == me) return error.ImportCycle;
                    // Helpers don't wait on contended imports. The main thread
                    // may be holding a thunk whose force chain leads back to
                    // us; bailing avoids the cycle and lets a real-demand
                    // force retry later.
                    if (me != 0) return error.ImportContended;
                    entry.waitForChange(ImportEntry.STATE_EVALUATING);
                },
                ImportEntry.STATE_UNRESOLVED => {
                    if (entry.state.cmpxchgWeak(
                        ImportEntry.STATE_UNRESOLVED,
                        ImportEntry.STATE_EVALUATING,
                        .acquire,
                        .monotonic,
                    )) |_| continue;
                    entry.claimer.store(me, .release);
                    const value = self.compileImportPath(path) catch |err| {
                        entry.state.store(ImportEntry.STATE_FAILED, .release);
                        entry.wakeAll();
                        return err;
                    };
                    entry.result = value;
                    entry.state.store(ImportEntry.STATE_RESOLVED, .release);
                    entry.wakeAll();
                    return value;
                },
                else => unreachable,
            }
        }
    }

    /// Internal: do the actual file read + evaluate work for an import.
    /// Caller has already claimed the `ImportEntry` for `path`.
    fn compileImportPath(self: *Evaluator, path: []const u8) anyerror!Value {
        const stable_path = try self.allocator.dupe(u8, path);
        defer self.allocator.free(stable_path);

        self.progressBegin(.import, stable_path);
        defer self.progressEnd(.import, stable_path);

        const source = if (corepkgsSource(stable_path)) |core_source|
            core_source
        else
            self.files.readFile(stable_path) catch |err| switch (err) {
                error.IsDir => return self.importDirectory(stable_path),
                else => return err,
            };
        const source_base = std.fs.path.dirname(stable_path) orelse "/";
        return self.evaluateSource(source, source_base, stable_path, null);
    }

    fn lookupOrCreateImportEntry(self: *Evaluator, path: []const u8) !*ImportEntry {
        self.imports_mu.lock();
        defer self.imports_mu.unlock();

        if (self.imports.get(path)) |entry| return entry;

        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        const entry = try self.allocator.create(ImportEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{};
        try self.imports.put(self.allocator, key, entry);
        return entry;
    }

    fn scopedImportPath(self: *Evaluator, scope: Value, path: []const u8) !Value {
        const resolved = try self.resolveHostPath(path);
        defer if (resolved.owned) self.allocator.free(resolved.text);
        return self.scopedImportResolvedPath(scope, resolved.text);
    }

    fn scopedImportResolvedPath(self: *Evaluator, scope: Value, path: []const u8) anyerror!Value {
        const stable_path = try self.allocator.dupe(u8, path);
        defer self.allocator.free(stable_path);

        try checkScopedImportCycle(stable_path);
        var frame: ImportFrame = .{ .path = stable_path, .next = scoped_import_stack_top };
        scoped_import_stack_top = &frame;
        defer scoped_import_stack_top = frame.next;

        self.progressBegin(.import, stable_path);
        defer self.progressEnd(.import, stable_path);

        const source = if (corepkgsSource(stable_path)) |core_source|
            core_source
        else
            self.files.readFile(stable_path) catch |err| switch (err) {
                error.IsDir => return self.scopedImportDirectory(scope, stable_path),
                else => return err,
            };
        const source_base = std.fs.path.dirname(stable_path) orelse "/";
        return self.evaluateSource(source, source_base, stable_path, scope);
    }

    fn corepkgsSource(path: []const u8) ?[]const u8 {
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

    fn importDirectory(self: *Evaluator, path: []const u8) anyerror!Value {
        const default_path = try std.fs.path.resolve(self.allocator, &.{ path, "default.nix" });
        defer self.allocator.free(default_path);

        return self.importResolvedPath(default_path);
    }

    fn scopedImportDirectory(self: *Evaluator, scope: Value, path: []const u8) anyerror!Value {
        const default_path = try std.fs.path.resolve(self.allocator, &.{ path, "default.nix" });
        defer self.allocator.free(default_path);
        return self.scopedImportResolvedPath(scope, default_path);
    }

    fn ensureBuiltins(self: *Evaluator) !Value {
        if (self.builtins_value) |value| return value;
        const nix_path = try self.allocator.alloc(builtins.NixPathEntry, self.search_paths.len);
        defer self.allocator.free(nix_path);
        for (self.search_paths, nix_path) |entry, *out| {
            out.* = .{ .prefix = entry.prefix, .path = entry.path };
        }

        const value = try builtins.buildAttrSet(&self.intern, &self.heap, nix_path);
        self.builtins_value = value;
        return value;
    }

    const ResolvedHostPath = struct {
        text: []const u8,
        owned: bool,
    };

    const SearchPathEntry = struct {
        prefix: []u8,
        path: []u8,

        fn deinit(self: SearchPathEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.prefix);
            allocator.free(self.path);
        }
    };

    fn freeSearchPaths(self: *Evaluator) void {
        for (self.search_paths) |entry| entry.deinit(self.allocator);
        self.allocator.free(self.search_paths);
        self.search_paths = &.{};
    }

    fn resolveHostPath(self: *Evaluator, path: []const u8) !ResolvedHostPath {
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

    fn progressBegin(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
        if (self.progress) |progress| progress.begin(stage, subject);
    }

    fn progressEnd(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
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
fn helperLoop(helper_idx: u8, sched: *Scheduler, ev: *Evaluator) void {
    const worker = worker_mod.Worker.init(
        ev.allocator,
        sched,
        helper_idx,
        helper_idx + 1,
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
