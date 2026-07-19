//! Evaluator — the top-level orchestration layer.
//!
//! Manages the shared state (chunk registry, intern table, scheduler) and runs
//! the worker threads that execute bytecode.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const store_domain = @import("store");
const fetchers_mod = @import("fetchers");
const types = @import("runtime").types;
const bytecode = @import("bytecode.zig");
const InternTable = @import("runtime").intern.InternTable;
const ChunkRegistry = bytecode.ChunkRegistry;
const ChunkBuilder = bytecode.ChunkBuilder;
const ChunkId = types.ChunkId;
const Scheduler = @import("eval/workers.zig").Scheduler;
const vm_mod = @import("vm.zig");
const execution = @import("eval/workers.zig");
const VM = vm_mod.VM;
const LanguagePolicy = @import("policy.zig").LanguagePolicy;
const vm_force = @import("vm.zig").force;
const vm_builtins = @import("vm.zig").builtins;
const vm_strings = @import("vm.zig").strings;
const ObjectHeap = @import("runtime").heap.ObjectHeap;
const heap_collector = @import("runtime").heap_collector;
const FileCache = store_domain.FileCache;
const FetchCache = fetchers_mod.FetchCache;
const regex_mod = @import("support.zig").regex;
const corepkgs = @import("eval/imports/corepkgs.zig");
const vma_mod = @import("runtime").mem_tag.vma;
const realization = @import("store").realization;
const derivation = @import("store").derivation;
const Value = @import("runtime").value.Value;
const builtins = @import("runtime").builtins;
const parser_mod = @import("syntax").parser;
const diagnostic = @import("syntax").diagnostic;
const eval_trace = @import("observ.zig").trace;
const observ = @import("base").observ;
const ast_mod = @import("syntax").ast;
const deferred_mod = @import("compiler.zig").deferred_table;
const EvaluationReport = @import("eval/evaluation_report.zig").EvaluationReport;
const path_ops = @import("runtime").paths;
const eval_print = @import("eval/print.zig");
const search_path_mod = @import("eval/search_path.zig");
const imports_mod = @import("eval/imports.zig");
const mem_report = @import("eval/mem_report.zig");
const tuning = @import("eval/tuning.zig");
const debugger_state = @import("eval/debugger_state.zig");
const debug_session = @import("eval/debug_session.zig");

const worker_mod = execution.worker;
const gc_controller = @import("eval/gc_controller.zig");
const gc_coordinator = @import("eval/gc_coordinator.zig");
const build_session = @import("build_session.zig");
const store_state = @import("eval/store_state.zig");
const lifecycle = @import("eval/lifecycle.zig");
const tooling_adapter = @import("eval/tooling.zig");
const fiber_mod = @import("base").fiber;
const prof = @import("probe.zig").prof;
const compiler_mod = @import("compiler.zig");
const VmTrace = @import("vm.zig").trace_log.VmTrace;
const ThunkTrace = @import("probe.zig").thunk_trace.ThunkTrace;
const SpinMutex = @import("base").sync.SpinMutex;

const parse_observation: observ.SpanSpec = .{
    .category = "eval",
    .name = "parse",
    .begin_verb = "parsing",
    .finish_verb = "parsed",
    .begin_level = 3,
    .finish_level = 2,
};
const compile_observation: observ.SpanSpec = .{
    .category = "eval",
    .name = "compile",
    .begin_verb = "compiling",
    .finish_verb = "compiled",
    .begin_level = 3,
    .finish_level = 2,
};
const evaluate_observation: observ.SpanSpec = .{
    .category = "eval",
    .name = "evaluate",
    .begin_verb = "evaluating",
    .finish_verb = "evaluated",
    .begin_level = std.math.maxInt(u8),
    .finish_level = std.math.maxInt(u8),
};
const import_observation: observ.SpanSpec = .{
    .category = "eval",
    .name = "import",
    .begin_verb = "importing",
    .finish_verb = "imported",
    .begin_level = std.math.maxInt(u8),
    .finish_level = std.math.maxInt(u8),
};
const render_observation: observ.SpanSpec = .{
    .category = "eval",
    .name = "render",
    .begin_verb = "rendering",
    .finish_verb = "rendered",
    .begin_level = std.math.maxInt(u8),
    .finish_level = std.math.maxInt(u8),
};
const fetch_observation: observ.SpanSpec = .{
    .category = "fetch",
    .name = "fetch",
    .begin_verb = "fetching",
    .finish_verb = "fetched",
};

fn observationDetails(subject: []const u8) observ.Details {
    return .{ .subject = if (std.fs.path.isAbsolute(subject))
        .{ .path = subject }
    else
        .{ .text = subject } };
}

const gc = @import("runtime").gc;
const future_mod = @import("runtime").future;
const thunk_mod = @import("runtime").thunk;
const worker_id_mod = @import("base").worker_id;

pub const Diagnostic = diagnostic.Diagnostic;
pub const EvalTrace = eval_trace.Trace;

pub const ReleaseAction = lifecycle.ReleaseAction;

/// Why the debugger was entered (re-exported from the VM layer so the CLI can
/// switch on it without reaching into `vm`).
pub const BreakReason = vm_mod.BreakReason;

/// A top-level evaluation together with the bytecode entry that produced it.
/// Most callers only need `value`; inspection frontends retain `entry_chunk`
/// so concrete results (which carry no runtime code pointer) still have a
/// useful initial location in the VM explorer.
pub const EvaluationResult = struct {
    value: Value,
    entry_chunk: ChunkId,
};

/// The CLI-supplied debugger console. `run` drives one interactive pause.
pub const DebugUi = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, *DebugSession) anyerror!void,
};

const DebuggerState = debugger_state.State(DebugUi, bytecode.BreakpointTable);

/// One rendered backtrace frame: the running chunk and its source anchor.
/// `line`/`column` are 1-based; `file`/all fields are 0 when unavailable.
pub const DebugFrame = debug_session.DebugFrame;

/// A live handle to a paused evaluation, handed to the debugger UI. It exposes
/// only facade-level operations (backtrace, scope inspection, evaluate-in-place,
/// value rendering) so the `cli` layer never touches raw VM types. All methods
/// run on the paused demand fiber; `eval` re-enters the evaluator, which is
/// safe because forcing already nests VM frames (`runIsolatedFrame`).
pub const DebugSession = struct {
    ev: *Evaluator,
    vm: *VM,
    /// The value passed to `builtins.break` (may be an unforced thunk), or the
    /// value under evaluation at an error. Inspect via `writeValue`/`force`.
    value: Value,
    reason: BreakReason,

    /// Number of active call frames (top of stack last).
    pub fn frameCount(self: *const DebugSession) usize {
        return debug_session.frameCount(self.vm);
    }

    /// Frame `i` (0 = outermost, `frameCount()-1` = innermost/current).
    pub fn frame(self: *const DebugSession, i: usize) DebugFrame {
        return debug_session.frame(debugContext(self), i);
    }

    pub fn frameChunkId(self: *const DebugSession, i: usize) ChunkId {
        return debug_session.frameRef(self.vm, i).frame().chunk_id;
    }

    /// The current (innermost) frame, or null if the stack is empty.
    pub fn currentFrame(self: *const DebugSession) ?DebugFrame {
        const count = self.frameCount();
        if (count == 0) return null;
        return self.frame(count - 1);
    }

    /// The source text for frame `i` — the file it runs (from the FileCache),
    /// or the entry `-E` source. Null if neither is available. The frame's span
    /// (`frame(i).span`) offsets into this text. Used to show a code snippet at
    /// the pause.
    pub fn frameSourceText(self: *DebugSession, i: usize) ?[]const u8 {
        return debug_session.frameSourceText(debugContext(self), i);
    }

    /// Local slots of frame `i` (the values in `vm.stack[base..base+count]`).
    /// Names are not tracked per local, so callers index by slot.
    pub fn localCount(self: *const DebugSession, i: usize) usize {
        return debug_session.frameRef(self.vm, i).frame().local_count;
    }

    pub fn localValue(self: *const DebugSession, i: usize, slot: usize) Value {
        const ref = debug_session.frameRef(self.vm, i);
        const f = ref.frame();
        return ref.vm.stack[f.frame_base + slot];
    }

    /// Write frame `i`'s always-on qualified name (`pkgs.hello`) to `w`, or
    /// nothing if anonymous. Available in every run — no `capture_names` flag.
    pub fn writeFrameName(self: *const DebugSession, w: *std.Io.Writer, i: usize) !void {
        const ref = debug_session.frameRef(self.vm, i);
        try self.ev.registry.writeQualifiedName(w, ref.frame().chunk_id, &self.ev.intern);
    }

    pub fn hasFrameName(self: *const DebugSession, i: usize) bool {
        return self.ev.registry.hasQualifiedName(debug_session.frameRef(self.vm, i).frame().chunk_id);
    }

    /// The source name of local `slot` in frame `i`, if the compiler recorded
    /// one (requires chunk-name capture, which `--debugger` enables). Internal
    /// (`\x00`-prefixed) names are hidden.
    pub fn localName(self: *const DebugSession, i: usize, slot: usize) ?[]const u8 {
        const names = self.ev.registry.localNamesOf(debug_session.frameRef(self.vm, i).frame().chunk_id) orelse return null;
        if (slot >= names.len) return null;
        return debug_session.displayName(self.ev.intern.get(names[slot]));
    }

    /// The source name of upvalue `idx` in frame `i`, if recorded.
    pub fn upvalueName(self: *const DebugSession, i: usize, idx: usize) ?[]const u8 {
        const names = self.ev.registry.upvalueNamesOf(debug_session.frameRef(self.vm, i).frame().chunk_id) orelse return null;
        if (idx >= names.len) return null;
        return debug_session.displayName(self.ev.intern.get(names[idx]));
    }

    pub fn upvalueCount(self: *const DebugSession, i: usize) usize {
        return if (debug_session.frameRef(self.vm, i).frame().upvalues) |ups| ups.len else 0;
    }

    pub fn upvalueValue(self: *const DebugSession, i: usize, idx: usize) Value {
        return debug_session.frameRef(self.vm, i).frame().upvalues.?[idx];
    }

    /// Force `v` (shallow) on the paused fiber and return the result.
    pub fn force(self: *DebugSession, v: Value) !Value {
        return vm_force.forceValue(self.vm, v);
    }

    /// Render `v` for display (forces thunks as needed), same formatting as the
    /// repl. Runs on the paused fiber's VM.
    pub fn writeValue(self: *DebugSession, writer: *std.Io.Writer, v: Value) !void {
        return eval_print.writeValue(valuePrintHost(self.ev), writer, v);
    }

    /// Look up interned text (e.g. a source file id).
    pub fn internText(self: *const DebugSession, id: types.InternId) []const u8 {
        return self.ev.intern.get(id);
    }

    /// Compile and evaluate `source` against `scope` (an ambient attrset whose
    /// members resolve as free identifiers, like the repl's bindings), reusing
    /// the paused evaluator. Returns the resulting (unforced) value.
    pub fn eval(self: *DebugSession, source: []const u8, scope: ?Value) !Value {
        return self.ev.debugEvalScoped(self.vm, source, scope);
    }

    /// Set a source-line breakpoint at `file:line`. Resolves to the nearest
    /// line carrying code, or remains pending until the file is compiled.
    /// Applies to already compiled chunks and any that compile later.
    pub fn setBreakpoint(self: *DebugSession, file: []const u8, line: u32) !bytecode.BreakpointTable.SetResult {
        return self.ev.setBreakpoint(file, line);
    }

    /// All active breakpoint requests (for a `:breakpoints` listing).
    pub fn listBreakpoints(self: *const DebugSession) []const bytecode.BreakpointTable.Request {
        return self.ev.listBreakpoints();
    }

    /// Remove a breakpoint by id; true if it existed.
    pub fn deleteBreakpoint(self: *DebugSession, id: u32) bool {
        return self.ev.deleteBreakpoint(id);
    }

    pub const StepKind = debug_session.StepKind;

    /// Arm a single step. It takes effect once the console resumes; the next
    /// pause is the step's landing point. See `clearStep`.
    pub fn step(self: *DebugSession, kind: StepKind) !void {
        if (kind == .into and !self.vm.debug_import_replay) {
            // `import` is memoized across REPL inputs. Continuing/finishing a
            // debug expression may use that fast path, but step-into promises
            // executable imported code. Give this paused VM chain a fresh,
            // separately rooted memo table so old helpers using the ordinary
            // table remain untouched.
            self.ev.imports.beginReplayQuiescent(self.ev.allocator);
            var cursor: ?*VM = self.vm;
            while (cursor) |vm| : (cursor = vm.debug_parent) vm.debug_import_replay = true;
        }
        return debug_session.step(debugContext(self), kind);
    }

    /// Disarm any in-progress step (called at each pause before prompting).
    pub fn clearStep(self: *DebugSession) void {
        if (self.ev.debugger.breakpoints) |*bp| bp.clearStep(&self.ev.registry);
    }

    /// Build a one-entry scope attrset binding `name` to `self.value` — handy
    /// for the console to expose the break value as an identifier.
    pub fn bindValueScope(self: *DebugSession, name: []const u8) !Value {
        const entries = [_]runtime.heap.AttrEntry{.{
            .name = try self.ev.intern.intern(name),
            .value = self.value,
        }};
        return Value.attrs(try self.ev.heap.addAttrs(&entries));
    }

    /// The lexical scope at the pause: an ambient attrset of the current frame's
    /// named locals and upvalues (locals shadow upvalues), plus `it` = the break
    /// value. Console expressions compile against this, so `let`/`param`
    /// bindings visible at the breakpoint resolve as free identifiers. Requires
    /// recorded names (`--debugger` turns capture on); with no frame or no names
    /// it degrades to just `it`.
    pub fn scopeAttrs(self: *DebugSession) !Value {
        return debug_session.scopeAttrs(debugContext(self));
    }
};

const StoreState = store_state.StoreState;
pub const BuildSession = build_session.BuildSession;

fn debugContext(session: *const DebugSession) debug_session.Context {
    return .{
        .allocator = session.ev.allocator,
        .heap = &session.ev.heap,
        .intern = &session.ev.intern,
        .registry = &session.ev.registry,
        .files = &session.ev.files,
        .breakpoints = if (session.ev.debugger.breakpoints) |*bp| bp else null,
        .source = session.ev.debugger.source,
        .vm = session.vm,
        .value = session.value,
    };
}

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    intern: InternTable,
    registry: ChunkRegistry,
    scheduler: Scheduler,
    heap: ObjectHeap,
    files: FileCache,
    fetchers: FetchCache,
    /// Store and daemon state that deliberately outlives language teardown.
    store: StoreState,
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
    /// Propagated to every VM via `initVm`; gates `thunk_shell`.
    /// Default false — the CLI sets it true only for `--xml`.
    lazy_shells_visible: bool = false,
    /// Feature gates and deprecated compatibility behavior shared unchanged by
    /// parsing, every nested compiler, and every VM.
    policy: LanguagePolicy = .{},
    debugger: DebuggerState = .{},
    /// Colorize `writeValue` output (strings/numbers/keywords/attr names). Set
    /// by the CLI from its terminal-color decision; default off (plain text for
    /// pipes, tests, JSON/XML paths). See `eval/print.zig`.
    value_color: bool = false,
    base_path: ?[:0]u8,
    env_map: ?*const std.process.Environ.Map,
    observer: observ.Observer = .{},
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
    /// import error paths serialize on `report.mu`.
    report: EvaluationReport,
    /// Lazy per-attr compilation: deferred attrset value bodies, compiled
    /// on first force. See `compiler/deferred_table.zig`.
    deferred_table: deferred_mod.Table,
    /// AST arenas kept alive because a deferred body retains nodes into
    /// them (force-time compile re-walks the node). Files that defer
    /// nothing free their arena immediately (the common case). Appended
    /// concurrently by helper-thread import compiles, hence the mutex.
    retained_arenas: std.ArrayListUnmanaged(ast_mod.AstArena),
    retained_arenas_mu: SpinMutex,
    /// Reusable live-set marker driven at collection safepoints.
    gc_tracer: gc.Tracer,
    /// Fresh VMs for in-flight imports/scoped-imports. These
    /// run on transient stack-local VMs NOT in a worker's `fibers` list, so
    /// the collector must scan them explicitly or their live values are
    /// missed. Guarded by `gc_import_vms_mu` — imports run concurrently at
    /// --workers>1.
    gc_import_vms: std.ArrayListUnmanaged(*VM),
    gc_import_vms_mu: SpinMutex,
    /// Every live `Worker` by id (0 = main, 1.. = helpers).
    /// The collector walks each worker's fibers for roots. A worker
    /// registers itself before it can allocate user objects and unregisters
    /// after it's quiesced, and during a stop-the-world all live workers are
    /// parked — so the collector reads a stable set.
    gc_workers: []std.atomic.Value(?*worker_mod.Worker),
    /// Chunk-constant root scan is INCREMENTAL across minors. A
    /// chunk constant's referent is promoted to old at the first minor that
    /// scans it and stays old (a later young reference it gains is caught by
    /// the remembered-set barrier, not the constant). So each minor scans only
    /// chunks `[gc_chunks_scanned, registry.count())`; re-scanning all of them
    /// every minor was ~77% of the serial root-scan. A future MAJOR resets this
    /// to 0 (a full mark re-scans every constant).
    gc_chunks_scanned: ChunkId = 0,
    /// `--gc-budget` override for the collector's heap budget, in bytes
    /// (0 = never collect). `null` resolves the RAM-scaled default; see
    /// `eval/gc_controller.zig:memoryBudget`.
    /// Set by the CLI before evaluation.
    gc_budget_bytes: ?u64 = null,
    /// Optional teardown memory report (`"dump"` also lists registered VMAs).
    mem_report_mode: ?[]const u8 = null,
    /// Print the collector summary during teardown.
    gc_report_on: bool = false,
    /// Evaluator-local cap on parallel GC participants. Environment tuning of
    /// one evaluator must not alter another evaluator in the same process.
    gc_parallel_cap: u32 = gc_controller.default_parallel_cap,
    gc_coord: gc_coordinator.Coordinator = .{},
    /// Caller-held root values (the repl's scope bindings and
    /// last results live outside any VM between evaluations). Marked by
    /// `markRoots`; replaced wholesale via `gcSetExternalRoots`.
    gc_extra_roots: std.ArrayListUnmanaged(Value) = .empty,
    /// Speculative import prefetch state (`FIX_IMPORT_PREFETCH`).
    prefetch: Prefetch = .{},
    /// Whether `releaseEvalState` already ran (the build-phase memory
    /// release). Makes the release idempotent so `deinit` can share it.
    eval_released: bool = false,

    /// Speculative import prefetch (`FIX_IMPORT_PREFETCH`): `.nix` path
    /// constants discovered by `ChunkRegistry.register` are submitted as
    /// `import_prefetch` tasks ahead of demand.
    pub const Prefetch = struct {
        /// Dedup so each path is prefetched at most once per eval. Guarded
        /// by `mu` (compiles run on every worker).
        seen: std.AutoHashMapUnmanaged(types.InternId, void) = .empty,
        mu: SpinMutex = .{},
        /// Remaining submission budget — bounds the junk volume.
        budget: u32 = 0,
    };

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

        // Single-worker mode: the evaluator owns these tables and no helper
        // thread will ever exist, so their internal locking (intern shard
        // mutexes, chunk-dedup shard mutexes, the registration CAS) is pure
        // tax — mark them solo before anything runs. See InternTable.solo /
        // ChunkRegistry.solo for the contract.
        if (worker_count == 1) {
            intern.solo = true;
            registry.solo = true;
        }

        const gc_workers = try allocator.alloc(std.atomic.Value(?*worker_mod.Worker), worker_count);
        for (gc_workers) |*w| w.* = .init(null);
        errdefer allocator.free(gc_workers);

        var store = try StoreState.init(allocator);
        errdefer store.deinit();

        const ev: Evaluator = .{
            .allocator = allocator,
            .intern = intern,
            .registry = registry,
            .scheduler = scheduler,
            .heap = try ObjectHeap.init(allocator, worker_count),
            .files = FileCache.init(allocator),
            .fetchers = FetchCache.init(allocator),
            .store = store,
            .regexes = regex_mod.PatternCache.init(allocator),
            .imports = .{},
            .search_paths = .{},
            .vm_buffers = vm_mod.BufferPool.init(allocator),
            .builtins_value = null,
            .base_path = null,
            .env_map = null,
            .observer = .{},
            .vm_trace = null,
            .thunk_trace = if (vm_mod.thunks_log_enabled) null else {},
            .worker_count = worker_count,
            .main_worker = null,
            .report = EvaluationReport.init(allocator),
            .deferred_table = deferred_mod.Table.init(allocator),
            .retained_arenas = .empty,
            .retained_arenas_mu = .{},
            .gc_tracer = gc.Tracer.init(allocator),
            .gc_import_vms = .empty,
            .gc_import_vms_mu = .{},
            .gc_workers = gc_workers,
        };
        return ev;
    }

    pub fn deinit(self: *Evaluator) void {
        self.debugger.deinit();
        self.releaseEvalState();
        if (self.base_path) |path| self.allocator.free(path);
        // Language workers are joined by releaseEvalState, so no fiber remains
        // parked on the store's fast IO lane when it is shut down here.
        self.store.deinit();
    }

    /// Free the language-evaluation half of the evaluator — workers and
    /// their fiber stacks, the object heap (flat store + segment stores),
    /// file/fetch caches, retained AST, bytecode registry, and the intern
    /// table — while keeping the store half (daemon connection + IO thread,
    /// progress session) alive. The build-phase memory release: once `fix
    /// build`/`run`/`shell` has copied the drv/out paths out of the intern
    /// table, the ~2 GB evaluator heap has no further reader, but the
    /// daemon build can run for minutes. Also flushes the process block
    /// cache, whose free stacks would otherwise retain the dead segment
    /// blocks for the build's duration.
    ///
    /// Idempotent; `deinit` runs it too. After this only store-side entry
    /// points are valid (`StoreState`/`BuildSession` and the progress-session
    /// calls) — no evaluation, value
    /// access, or diagnostics rendering.
    pub fn releaseEvalState(self: *Evaluator) void {
        if (self.eval_released) return;
        self.eval_released = true;
        mem_report.report(&self.heap, &self.intern, &self.registry, self.retained_arenas.items, self.mem_report_mode);
        gc.recordFinalTotal(&self.heap.gc_report, self.heap.totalReservedBytes());
        if (self.gc_report_on) gc.report(&self.heap.gc_report, self.heap.gc_budget_bytes);
        // Shut helpers down (which joins on `defer vm.deinit()` inside
        // helperLoop) before tearing down state their VMs borrow.
        self.scheduler.deinit();
        // Now that helpers are guaranteed quiescent, tear down the main
        // worker. Doing this before scheduler shutdown could race with
        // a helper still resuming a stolen main fiber.
        if (self.main_worker) |w| w.deinit();
        self.main_worker = null;
        // Registration effects run directly from compiler workers now. Keep
        // their dedup state alive until every worker that can publish a chunk
        // has joined.
        self.prefetch.seen.deinit(self.allocator);
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
        self.gc_tracer.deinit();
        self.gc_import_vms.deinit(self.allocator);
        self.gc_extra_roots.deinit(self.allocator);
        self.allocator.free(self.gc_workers);
        self.report.deinit();
        self.imports.deinit(self.allocator);
        self.search_paths.deinit(self.allocator);
        self.fetchers.deinit();
        self.regexes.deinit();
        self.store.realization.releaseRecipePayloads();
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
        // Dangling Value into the freed heap; never read again, but don't
        // keep it findable.
        self.builtins_value = null;
    }

    /// Allocator for app-layer values whose ownership is explicitly returned
    /// to the evaluator (source descriptors, diagnostics, debug records).
    pub fn hostAllocator(self: *const Evaluator) std.mem.Allocator {
        return self.allocator;
    }

    pub fn basePath(self: *const Evaluator) ?[]const u8 {
        return self.base_path;
    }

    pub fn configureLanguage(self: *Evaluator, policy: LanguagePolicy) void {
        self.policy = policy;
    }

    pub fn languagePolicy(self: *const Evaluator) LanguagePolicy {
        return self.policy;
    }

    pub fn configureMemory(self: *Evaluator, gc_budget: ?u64, report_mode: ?[]const u8, gc_report: bool) void {
        self.gc_budget_bytes = gc_budget;
        self.mem_report_mode = report_mode;
        self.gc_report_on = gc_report;
    }

    pub fn setLazyShellsVisible(self: *Evaluator, visible: bool) void {
        self.lazy_shells_visible = visible;
    }

    pub fn setTraceFlows(self: *Evaluator, enabled: bool) void {
        self.scheduler.setTraceFlows(enabled);
    }

    pub fn addIndirectRoot(self: *Evaluator, link_path: []const u8, target: []const u8) !void {
        return self.store.addIndirectRoot(link_path, target);
    }

    pub fn getDiagnostics(self: *const Evaluator) []const Diagnostic {
        return self.report.diagnosticsView();
    }

    /// Render recorded parser/compiler diagnostics without exposing the syntax
    /// subsystem through the application facade.
    pub fn writeDiagnostics(self: *const Evaluator, writer: *std.Io.Writer, source: []const u8, use_color: bool) !void {
        try diagnostic.writeAllWithOptions(writer, source, self.getDiagnostics(), .{ .color = use_color });
    }

    /// Render one source-backed evaluation trace frame. Parser/compiler
    /// diagnostics keep their compact `near` excerpt; a trace already shows
    /// the source line and should not repeat it.
    pub fn writeTraceDiagnostic(
        _: *const Evaluator,
        writer: *std.Io.Writer,
        source: []const u8,
        item: Diagnostic,
        use_color: bool,
    ) !void {
        try diagnostic.writeAllWithOptions(writer, source, &.{item}, .{
            .color = use_color,
            .show_near = false,
        });
    }

    pub fn getTrace(self: *const Evaluator) *const EvalTrace {
        return self.report.traceView();
    }

    pub fn setDerivationDebug(self: *Evaluator, enabled: bool) void {
        self.store.realization.setDebugEnabled(enabled);
    }

    /// Cap concurrent fetches (`http-connections`; 0 = unlimited).
    pub fn setFetchConnections(self: *Evaluator, n: u32) !void {
        try self.fetchers.setMaxConnections(n);
    }

    /// `download-attempts`: total tries per download before failing.
    pub fn setDownloadAttempts(self: *Evaluator, n: u32) void {
        self.fetchers.setDownloadAttempts(n);
    }

    pub fn setTarballTtl(self: *Evaluator, seconds: u32) void {
        self.fetchers.setTarballTtl(seconds);
    }

    pub fn setFetchConnectTimeout(self: *Evaluator, seconds: u32) void {
        self.fetchers.setConnectTimeout(seconds);
    }

    pub fn setStalledDownloadTimeout(self: *Evaluator, seconds: u32) void {
        self.fetchers.setStalledDownloadTimeout(seconds);
    }

    pub fn setDownloadSpeed(self: *Evaluator, kib_per_second: u64) void {
        self.fetchers.setDownloadSpeed(kib_per_second);
    }

    pub fn setSslCertFile(self: *Evaluator, path: []const u8) !void {
        try self.fetchers.setSslCertFile(path);
    }

    pub fn setFlakeRegistryUrl(self: *Evaluator, url: ?[]const u8) !void {
        try self.fetchers.setFlakeRegistryUrl(url);
    }

    /// Set the fetcher's `access-tokens` (a raw `nix.conf` value), used to
    /// authenticate downloads to matching hosts. See `setup.configure`.
    pub fn setAccessTokens(self: *Evaluator, raw: []const u8) !void {
        try self.fetchers.setAccessTokens(raw);
    }

    /// Set the fetcher's `netrc` credentials (raw file content) for HTTP
    /// basic-auth on plain downloads. See `setup.configure`.
    pub fn setNetrc(self: *Evaluator, content: []const u8) !void {
        try self.fetchers.setNetrc(content);
    }

    pub fn derivationDebugRecords(self: *const Evaluator) []const derivation.DebugRecord {
        return self.store.realization.debugRecords();
    }

    pub fn setBasePathFromCurrentPath(self: *Evaluator, io: std.Io) !void {
        self.files.setIo(io);
        self.fetchers.setIo(io);
        self.store.realization.setIo(io);
        if (self.base_path) |path| self.allocator.free(path);
        self.base_path = try std.process.currentPathAlloc(io, self.allocator);
    }

    pub fn setFileIo(self: *Evaluator, io: std.Io) void {
        self.files.setIo(io);
        self.fetchers.setIo(io);
        self.store.realization.setIo(io);
    }

    /// Point the base path (used to resolve relative path literals like `./x`)
    /// at the directory containing `file_path`, resolved against the current
    /// base path. This makes a file's relative paths resolve relative to the
    /// file, as Nix does — not the process cwd.
    pub fn setBasePathToFileDir(self: *Evaluator, file_path: []const u8) !void {
        const base = self.base_path orelse ".";
        const abs = try std.fs.path.resolve(self.allocator, &.{ base, file_path });
        defer self.allocator.free(abs);
        const dir = std.fs.path.dirname(abs) orelse abs;
        const owned = try self.allocator.dupeZ(u8, dir);
        if (self.base_path) |old| self.allocator.free(old);
        self.base_path = owned;
    }

    pub fn setEnvironment(self: *Evaluator, env_map: *const std.process.Environ.Map) void {
        self.env_map = env_map;
        self.fetchers.setEnvironment(env_map);
        // Point the fetch download-cache at `$XDG_CACHE_HOME/fix` (default
        // `~/.cache/fix`), mirroring Nix's `~/.cache/nix`. Best-effort; without
        // HOME/XDG the FetchCache keeps its `./.zig-cache/fix` fallback.
        self.setFetchCacheRoot() catch {};
    }

    pub fn environment(self: *const Evaluator) ?*const std.process.Environ.Map {
        return self.env_map;
    }

    fn setFetchCacheRoot(self: *Evaluator) !void {
        const env = self.env_map orelse return;
        const base: []const u8, const sub: []const []const u8 = blk: {
            if (env.get("XDG_CACHE_HOME")) |xdg| {
                if (xdg.len != 0) break :blk .{ xdg, &.{"fix"} };
            }
            if (env.get("HOME")) |home| {
                if (home.len != 0) break :blk .{ home, &.{ ".cache", "fix" } };
            }
            return;
        };
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        defer parts.deinit(self.allocator);
        try parts.append(self.allocator, base);
        try parts.appendSlice(self.allocator, sub);
        const root = try std.fs.path.join(self.allocator, parts.items);
        defer self.allocator.free(root);
        try self.fetchers.setCacheRoot(root);
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

    /// Construct a thunk trace bound to this evaluator's runtime state without
    /// exporting mutable heap/registry pointers to the CLI composition layer.
    pub fn initThunkTrace(self: *Evaluator, writer: *std.Io.Writer) ThunkTrace {
        return ThunkTrace.init(writer, &self.intern, &self.heap, &self.registry);
    }

    pub fn setObserver(self: *Evaluator, observer: observ.Observer) void {
        self.observer = observer;
        self.store.realization.setObserver(observer);
    }

    pub fn setNixPath(self: *Evaluator, nix_path: []const u8) !void {
        try self.search_paths.set(self.allocator, nix_path, self, resolveHostPath);
        for (self.search_paths.entries) |*entry| {
            if (!std.mem.startsWith(u8, entry.path, "http://") and !std.mem.startsWith(u8, entry.path, "https://") and !std.mem.startsWith(u8, entry.path, "file://")) continue;
            const result = try self.fetchTarball(entry.path);
            self.allocator.free(entry.path);
            entry.path = result.path;
            if (result.nar_payload) |payload| self.allocator.free(payload.bytes);
        }
    }

    pub fn readSourceFile(self: *Evaluator, path: []const u8) ![]const u8 {
        const resolved = try self.resolveHostPath(path);
        defer if (resolved.owned) self.allocator.free(resolved.text);
        return self.files.readFile(resolved.text);
    }

    /// Resolve `<name>` through the configured NIX_PATH to an owned host path.
    pub fn resolveLookupPath(self: *Evaluator, name: []const u8) ![]u8 {
        return self.search_paths.resolveName(self.allocator, &self.files, name);
    }

    /// Fetch and unpack a legacy fileish tarball, returning its owned cache path.
    pub fn fetchTarballPath(self: *Evaluator, url: []const u8) ![]u8 {
        const result = try self.fetchTarball(url);
        if (result.nar_payload) |payload| self.allocator.free(payload.bytes);
        return result.path;
    }

    fn fetchTarball(self: *Evaluator, url: []const u8) !@import("fetchers").FetchCache.TarballResult {
        var span = self.observer.begin(&fetch_observation, .{ .subject = .{ .url = url } });
        defer span.cancel();
        const result = try self.fetchers.fetchTarball(&self.files, .{ .url = url, .name = "source" }, null);
        span.finish(.{ .verb = if (result.cached) "cached" else null });
        return result;
    }

    pub fn isSourceDirectory(self: *Evaluator, path: []const u8) !bool {
        const resolved = try self.resolveHostPath(path);
        defer if (resolved.owned) self.allocator.free(resolved.text);
        return self.files.isDirectoryFollowing(resolved.text);
    }

    /// Fetch a flake source without evaluating its outputs. `parseFlakeRef`
    /// performs registry resolution, `fetchTree` materializes the source, and
    /// `dir` selects a nested flake before legacy fileish default.nix loading.
    pub fn fetchFlakeSourcePath(self: *Evaluator, ref: []const u8) ![]u8 {
        if (!self.policy.flakes_enabled) return error.FlakesFeatureRequired;
        var escaped: std.ArrayListUnmanaged(u8) = .empty;
        defer escaped.deinit(self.allocator);
        for (ref) |c| {
            if (c == '\\' or c == '"' or c == '$') try escaped.append(self.allocator, '\\');
            try escaped.append(self.allocator, c);
        }
        const source = try std.fmt.allocPrint(
            self.allocator,
            "let r = builtins.parseFlakeRef \"{s}\"; t = builtins.fetchTree r; in t.outPath + (if r ? dir then \"/\" + r.dir else \"\")",
            .{escaped.items},
        );
        defer self.allocator.free(source);
        const value = try self.forceValue(try self.evaluate(source));
        if (!value.isPath() and !value.isString()) return error.TypeError;
        return self.allocator.dupe(u8, self.intern.get(value.asInternId()));
    }

    fn clearDiagnostics(self: *Evaluator) void {
        self.report.clear();
    }

    fn copyDiagnostics(self: *Evaluator, diagnostics: []const Diagnostic, source: []const u8, source_path: ?[]const u8) !void {
        try self.report.replaceDiagnostics(diagnostics, source, source_path);
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

    pub fn compileSourceAt(self: *Evaluator, source: []const u8, base_path: ?[]const u8, source_path: ?[]const u8) !ChunkId {
        return self.parseAndCompile(source, base_path, source_path, null);
    }

    /// `compileSource` with an ambient scope attrset (see
    /// `evaluateWithScope`). The repl's VM explorer compiles expressions that
    /// reference repl bindings through this.
    pub fn compileSourceScoped(self: *Evaluator, source: []const u8, scope: ?Value) !ChunkId {
        return self.parseAndCompile(source, self.base_path, null, scope);
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
            var observation = self.observer.begin(&parse_observation, observationDetails(subject));
            defer observation.cancel();
            const pt = prof.start(.parse);
            defer prof.end(.parse, pt);
            // RSS attribution: blocks the parse grows (AST arena chunks,
            // parser scratch) belong to the "ast-arena" bucket — the
            // retained ones live as long as the evaluator.
            const prev_tag = vma_mod.setAllocTag(.ast_arena);
            defer _ = vma_mod.setAllocTag(prev_tag);
            const parsed = parser.parse() catch {
                try self.copyDiagnostics(parser.diagnostics.items, source, source_path);
                return error.ParseError;
            };
            observation.finish(.{ .metrics = &.{.{
                .name = "source",
                .value = .{ .unsigned = source.len },
                .unit = .bytes,
            }} });
            break :blk parsed;
        };

        // Compile-time feature gate. Pipe operators always parse (into tagged
        // apply nodes); enabling them is required to compile. Like Nix, we
        // reject on *presence* — the parser records whether any `|>`/`<|`
        // was seen, so a pipe anywhere in the file (even an unused/deferred
        // attr body) fails here, before any compilation runs.
        if (parser.used_pipe_operators and !self.policy.pipe_operators_enabled) {
            const tok = parser.first_pipe_token.?;
            try self.copyDiagnostics(&.{.{
                .severity = .err,
                .kind = .compile,
                .line = parser_mod.Parser.tokenLine(source, tok),
                .column = diagnostic.columnForOffset(source, tok.offset),
                .offset = tok.offset,
                .len = tok.len,
                .token_type = tok.type,
                .message = "pipe operators are disabled; pass --extra-experimental-features pipe-operators to enable them",
            }}, source, source_path);
            return error.PipeOperatorsDisabled;
        }

        // Lix deprecated CR/CRLF line endings: rejected by default, re-permitted
        // by `cr-line-endings`. The scanner records the first structural CR; the
        // parse still succeeds (CR is treated as a line ending) so enabling the
        // feature Just Works.
        if (parser.first_cr_offset) |cr_off| {
            if (!self.policy.allow_cr_line_endings) {
                try self.copyDiagnostics(&.{.{
                    .severity = .err,
                    .kind = .compile,
                    .line = diagnostic.lineForOffset(source, cr_off),
                    .column = diagnostic.columnForOffset(source, cr_off),
                    .offset = cr_off,
                    .len = 1,
                    .token_type = null,
                    .message = "CR (`\\r`) and CRLF (`\\r\\n`) line endings are not supported. Please inspect the file and normalize it to use LF (`\\n`) line endings instead. Use --extra-deprecated-features cr-line-endings to silence this warning.",
                }}, source, source_path);
                return error.CrLineEndingsDisabled;
            }
        }

        // Lix deprecated `tokens-no-whitespace`: a value token stuck to the next
        // token without whitespace is rejected by default. The tokenization
        // still succeeds, so enabling the feature Just Works.
        if (parser.first_tokens_no_ws_offset) |off| {
            if (!self.policy.allow_tokens_no_whitespace) {
                try self.copyDiagnostics(&.{.{
                    .severity = .err,
                    .kind = .compile,
                    .line = diagnostic.lineForOffset(source, off),
                    .column = diagnostic.columnForOffset(source, off),
                    .offset = off,
                    .len = 1,
                    .token_type = null,
                    .message = "whitespace between tokens is required here. Use --extra-deprecated-features tokens-no-whitespace to disable this error.",
                }}, source, source_path);
                return error.TokensNoWhitespaceDisabled;
            }
        }

        // Per-compilation-unit scratch arena: all of the compiler's
        // transient structures (builder buffers, locals/captures, strictness
        // and name-resolution maps, diagnostics) allocate here and are freed
        // wholesale when this returns. Only the emitted chunk is duped onto
        // the long-lived allocator (at `builder.finish`). The AST arena above
        // is separate — it may be retained for deferred bodies; this one never
        // is, since nothing persistent points into it.
        var scratch = @import("base").arena.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const scratch_alloc = scratch.allocator();

        var builder = try ChunkBuilder.init(scratch_alloc);
        defer builder.deinit(scratch_alloc);

        var compiler = compiler_mod.Compiler.init(
            &compiler_mod.driver,
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
        compiler.home_dir = if (self.env_map) |env| env.get("HOME") else null;
        compiler.policy = self.policy;
        compiler.registration_sink = chunkRegistrationSink(self);
        // Set eagerly (not lazily on first position record, see sourceFileId):
        // chunks registered before any position record would otherwise miss
        // their file in the disasm sidecar.
        if (self.registry.capture_names) {
            if (source_path) |p| compiler.source_file_id = try self.intern.intern(p);
        }
        // A scoped import (`builtins.scopedImport`) supplies BOTH an ambient
        // scope and a source path; that attrset replaces the base env, so free
        // identifiers — even ones that name builtins — must bind to it first. A
        // repl/debug overlay also carries a scope but no source_path, and must
        // keep builtins visible; hence the source_path conjunct.
        compiler.scoped_base = scope != null and source_path != null;
        compiler.deferred_table = &self.deferred_table;
        // Elided bodies materialize into the file's AST arena (retained
        // below alongside deferred bodies); this compile is single-threaded,
        // so in-place node replacement is safe and keeps every later
        // consumer's view identical to an eager parse.
        compiler.ast_arena = &arena;
        compiler.elide_mutable = true;
        defer compiler.deinit();

        {
            var observation = self.observer.begin(&compile_observation, observationDetails(subject));
            defer observation.cancel();
            const ct = prof.start(.compile);
            defer prof.end(.compile, ct);
            compiler.compileAndFinish(ast_node, scope) catch |err| {
                try self.copyDiagnostics(compiler.diagnostics.items, source, source_path);
                return err;
            };
            observation.finish(.{});
        }

        const chunk = try builder.finish(self.allocator, compiler.slot_count);
        // The top-level chunk registers outside `registerChunk`; name it after
        // the file (a useful `while evaluating 'configuration.nix'`). A bare
        // `-E` expression stays anonymous so its trace reads plain. disasm adds
        // its own `(top)` tag for pathless chunks.
        const top_name: bytecode.NameId = if (source_path) |p|
            (self.registry.childName(bytecode.root_name_id, try self.intern.intern(std.fs.path.basename(p)), false) catch bytecode.root_name_id)
        else if (self.registry.capture_names)
            (self.registry.childName(bytecode.root_name_id, try self.intern.intern("(top)"), true) catch bytecode.root_name_id)
        else
            bytecode.root_name_id;
        const chunk_id = try self.registry.registerNamed(chunk, top_name);
        self.chunkRegistered(chunk_id);
        if (compiler.source_file_id) |f| try self.registry.recordFile(chunk_id, f);
        // Local binding names for the top chunk (child chunks get theirs in
        // `registerChunk`); lets the debugger and disasm name top-level locals.
        if (self.registry.capture_names) try self.registry.recordLocalNames(chunk_id, compiler.local_names.items);
        if (source_path) |path| {
            if (self.debugger.breakpoints) |*breakpoints| {
                breakpoints.resolvePendingFile(&self.registry, path);
            }
        }
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

    /// The `builtins` attrset, built on first use. Single-threaded callers
    /// only (the repl's completer wants it before the first evaluation).
    pub fn builtinsValue(self: *Evaluator) !Value {
        return self.ensureBuiltins();
    }

    /// Read-only access to the chunk registry for tools.
    pub fn chunkRegistry(self: *const Evaluator) *const ChunkRegistry {
        return &self.registry;
    }

    /// Explicit diagnostic surface for CLI tooling. Runtime representation is
    /// intentionally available here, but ordinary command workflows do not get
    /// direct mutable access to the Evaluator's heap/intern/registry fields.
    pub const Tooling = tooling_adapter.Adapter(Evaluator);

    pub fn tooling(self: *Evaluator) Tooling {
        return .{ .ev = self };
    }

    pub const ScopeBinding = struct { name: []const u8, value: Value };

    /// Replace the REPL's ambient scope and its external GC roots as one
    /// evaluator-owned operation, so the CLI cannot accidentally construct a
    /// heap object without registering the values that keep it alive.
    pub fn replaceExternalScope(self: *Evaluator, bindings: []const ScopeBinding) !Value {
        const entries = try self.allocator.alloc(runtime.heap.AttrEntry, bindings.len);
        defer self.allocator.free(entries);
        const roots = try self.allocator.alloc(Value, bindings.len + 1);
        defer self.allocator.free(roots);
        for (bindings, entries, roots[0..bindings.len]) |binding, *entry, *root| {
            entry.* = .{ .name = try self.intern.intern(binding.name), .value = binding.value };
            root.* = binding.value;
        }
        const scope = Value.attrs(try self.heap.addAttrs(entries));
        roots[bindings.len] = scope;
        try self.gcSetExternalRoots(roots);
        return scope;
    }

    /// Enable best-effort chunk naming: the compiler records the attr/let
    /// binding name behind each lambda/thunk chunk into a registry sidecar, for
    /// `fix disasm` and the REPL explorer to display. Off by default (hot
    /// compiles pay nothing); sidecar writes are synchronized for the REPL's
    /// parallel import compilation. Set before compiling.
    pub fn setCaptureChunkNames(self: *Evaluator, on: bool) void {
        self.registry.capture_names = on;
    }

    /// Install (or clear) the interactive debugger. `run` is called on the
    /// demand fiber each time evaluation pauses (a `builtins.break`, or — with
    /// `enterDebuggerOnError` — an evaluation error); it drives the console and
    /// returns to resume. `ctx` is the UI's opaque self-pointer. The CLI owns
    /// the UI implementation (terminal I/O lives in `cli`); the engine only
    /// upcalls through this seam, so the layering stays down-only.
    pub fn setDebugUi(self: *Evaluator, ctx: *anyopaque, run: *const fn (*anyopaque, *DebugSession) anyerror!void) void {
        self.debugger.setUi(.{ .ctx = ctx, .run = run });
        self.ensureBreakpointTable();
    }

    /// Breakpoint tooling is also available to the VM explorer, before a
    /// debugger UI is attached. A later `:debug`/`--debugger` session reuses
    /// the same requests and patched sites.
    pub fn setBreakpoint(self: *Evaluator, file: []const u8, line: u32) !bytecode.BreakpointTable.SetResult {
        self.ensureBreakpointTable();
        return self.debugger.breakpoints.?.set(&self.registry, file, line);
    }

    pub fn listBreakpoints(self: *const Evaluator) []const bytecode.BreakpointTable.Request {
        if (self.debugger.breakpoints) |*breakpoints| return breakpoints.list();
        return &.{};
    }

    pub fn deleteBreakpoint(self: *Evaluator, id: u32) bool {
        if (self.debugger.breakpoints) |*breakpoints| return breakpoints.remove(&self.registry, id);
        return false;
    }

    fn ensureBreakpointTable(self: *Evaluator) void {
        if (self.debugger.breakpoints == null)
            self.debugger.breakpoints = bytecode.BreakpointTable.init(self.allocator, &self.intern);
    }

    pub fn clearDebugUi(self: *Evaluator) void {
        self.debugger.clearUi();
    }

    pub fn setDebugSource(self: *Evaluator, source: ?[]const u8) void {
        self.debugger.setSource(source);
    }

    pub fn setValueColor(self: *Evaluator, enabled: bool) void {
        self.value_color = enabled;
    }

    /// `vm_mod.BreakSink.fire` trampoline: build a `DebugSession` over the
    /// paused VM and hand it to the installed UI. Runs synchronously on the
    /// current demand fiber, so the console can re-enter the evaluator.
    fn fireBreak(ctx: *anyopaque, vm: *VM, value: Value, reason: vm_mod.BreakReason) anyerror!void {
        const self: *Evaluator = @ptrCast(@alignCast(ctx));
        // A break/throw raised while the console is evaluating an expression
        // must not recurse into a nested debugger.
        const ui = self.debugger.beginSession() orelse return;
        defer self.debugger.endSession();
        var session: DebugSession = .{ .ev = self, .vm = vm, .value = value, .reason = reason };
        try ui.run(ui.ctx, &session);
    }

    /// Console-expression evaluation from a debug pause: compile `source` in an
    /// ambient `scope` and run it on a fresh nested VM (sharing the registry,
    /// heap, and intern table). The nested VM leaves the paused VM's stack and
    /// frames untouched, so inspecting a value can't corrupt the pause point.
    fn debugEvalScoped(self: *Evaluator, paused_vm: *VM, source: []const u8, scope: ?Value) !Value {
        const chunk_id = try self.compileSourceScoped(source, scope);
        return self.runWithVm(debugRunBody, .{ chunk_id, paused_vm.debug_import_replay });
    }

    fn debugRunBody(vm: *VM, chunk_id: ChunkId, import_replay: bool) !Value {
        vm.debug_import_replay = import_replay;
        return vm.eval(chunk_id);
    }

    pub fn heapStats(self: *const Evaluator) ObjectHeap.Stats {
        return self.heap.stats();
    }

    pub fn heapCounts(self: *const Evaluator) ObjectHeap.Counts {
        return self.heap.counts();
    }

    pub fn heapObjectSnapshot(self: *const Evaluator, allocator: std.mem.Allocator) !ObjectHeap.ObjectSnapshot {
        return self.heap.objectSnapshot(allocator);
    }

    pub fn inspectHeapObject(self: *const Evaluator, snapshot: *const ObjectHeap.ObjectSnapshot, id: runtime.types.ObjectId) !runtime.heap.ObjectInfo {
        return self.heap.inspectObject(snapshot, id);
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
        var config = self.scheduler.configuration();
        config.disable_speculation = disable_speculation;
        config.disable_fanout = disable_fanout;
        self.scheduler.configure(config);
    }

    pub fn setDebugSerial(self: *Evaluator, enabled: bool) void {
        self.scheduler.setDebugSerial(enabled);
    }

    /// Compile source text into bytecode and evaluate it.
    /// This is the main public API.
    pub fn evaluate(self: *Evaluator, source: []const u8) !Value {
        return self.evaluateTop(source, self.base_path, null, null);
    }

    /// `evaluate`, attributing the top-level source to `source_path` — source
    /// spans and the disasm file sidecar then carry the entry file's name, the
    /// same way imported files do. Used by `fix disasm --eval`.
    pub fn evaluatePath(self: *Evaluator, source: []const u8, source_path: ?[]const u8) !Value {
        return self.evaluateTop(source, self.base_path, source_path, null);
    }

    /// `evaluatePath` with an explicit relative-path base. Multi-input CLI
    /// builds use this so each file keeps its own directory while sharing one
    /// evaluator.
    pub fn evaluatePathAt(self: *Evaluator, source: []const u8, base_path: ?[]const u8, source_path: ?[]const u8) !Value {
        return self.evaluateTop(source, base_path, source_path, null);
    }

    /// Like `evaluate`, but compiles the source inside an ambient scope
    /// attrset (identifiers not otherwise bound resolve from `scope`, the
    /// same mechanism as `builtins.scopedImport`). The repl uses this to
    /// make its bindings visible. `scope` is baked into the compiled
    /// chunk's constants, which are GC roots.
    pub fn evaluateWithScope(self: *Evaluator, source: []const u8, scope: ?Value) !Value {
        return self.evaluateTop(source, self.base_path, null, scope);
    }

    /// `evaluateWithScope`, retaining the compiled entry chunk for tooling.
    pub fn evaluateWithScopeResult(self: *Evaluator, source: []const u8, scope: ?Value) !EvaluationResult {
        return self.evaluateTopResult(source, self.base_path, null, scope, false);
    }

    /// Evaluate REPL source with a one-shot debugger pause at its first mapped
    /// instruction. The source is compiled unchanged; the UI must already be
    /// installed so the entry trap has somewhere to route.
    pub fn debugWithScopeResult(self: *Evaluator, source: []const u8, scope: ?Value) !EvaluationResult {
        const was_debug_serial = self.scheduler.swapDebugSerial(true);
        defer self.scheduler.setDebugSerial(was_debug_serial);
        return self.evaluateTopResult(source, self.base_path, null, scope, true);
    }

    fn evaluateTop(self: *Evaluator, source: []const u8, base_path: ?[]const u8, source_path: ?[]const u8, scope: ?Value) !Value {
        return (try self.evaluateTopResult(source, base_path, source_path, scope, false)).value;
    }

    fn evaluateTopResult(
        self: *Evaluator,
        source: []const u8,
        base_path: ?[]const u8,
        source_path: ?[]const u8,
        scope: ?Value,
        initial_break: bool,
    ) !EvaluationResult {
        if (initial_break) {
            if (self.debugger.breakpoints) |*breakpoints| breakpoints.clearStep(&self.registry);
        }
        defer if (initial_break) {
            // A finish/step can run directly to the result without another
            // pause at which the UI would normally clear its temporary sites.
            if (self.debugger.breakpoints) |*breakpoints| breakpoints.clearStep(&self.registry);
        };
        try self.prepareEvaluations();
        // Not routed through `evaluateSource`: its top-level detection is
        // `source_path == null`, so passing the path there would send the
        // top-level eval down the nested-import path (wrong fiber). Attribute
        // the source at compile time (and bake `scope` into the chunk's
        // constants, the repl's ambient-scope mechanism), then run on the
        // main worker as usual.
        const chunk_id = try self.parseAndCompile(source, base_path, source_path, scope);
        if (initial_break) {
            if (self.debugger.breakpoints) |*breakpoints| {
                _ = try breakpoints.armEntry(&self.registry, chunk_id);
            }
        }
        const subject = source_path orelse "expression";
        var observation = self.observer.begin(&evaluate_observation, observationDetails(subject));
        defer observation.cancel();
        const value = try self.runChunkOnMainWorker(chunk_id);
        observation.finish(.{});
        return .{ .value = value, .entry_chunk = chunk_id };
    }

    fn prepareEvaluations(self: *Evaluator) !void {
        // Build the builtins attrset on the main thread before any helpers
        // can race on it. `buildAttrSet` predicts the next ObjectId for
        // the self-reference `builtins.builtins`; that prediction is only
        // safe when no other thread is allocating objects.
        _ = try self.ensureBuiltins();
        if (!self.scheduler.isStarted()) {
            self.scheduler.configure(tuning.resolve(self.scheduler.configuration(), self.env_map, self.worker_count));
        }
        // Speculative import prefetch: `.nix` path constants of freshly
        // compiled chunks are parse+compile+evaluated ahead of demand on
        // the spec lane (the braid-window perf decomposition measured
        // ~25-50ms of import parse+compile sitting ON the critical chain
        // at w=8 while every helper parked). The import registry dedups
        // and coordinates, so a prefetch is exactly the import the demand
        // fiber would have run — started earlier. Default ON whenever
        // helpers exist. (The old 2..16 gate mirrored the novel lane's:
        // at w=32 extra spec-lane volume chased junk. Re-measured
        // 2026-07-11 with the bulk-spec drain cap containing that
        // volume — prefetch-on measured -5% median at w=32, so the
        // gate is gone.) FIX_IMPORT_PREFETCH=0/1 overrides,
        // FIX_IMPORT_PREFETCH_MAX bounds submissions per eval.
        {
            var on = self.worker_count >= 2;
            var max: u32 = 8192;
            if (self.env_map) |em| {
                if (em.get("FIX_IMPORT_PREFETCH")) |s| on = !std.mem.eql(u8, s, "0");
                if (em.get("FIX_IMPORT_PREFETCH_MAX")) |s| {
                    if (std.fmt.parseInt(u32, s, 10)) |n| max = n else |_| {}
                }
            }
            self.prefetch.budget = if (on and self.worker_count > 1) max else 0;
        }
        // Speculative readDir-children prefetch: a cold builtins.readDir
        // whose listing is a directory-of-directories fans the children out
        // to helpers, who warm the FileCache ahead of the demand fiber's
        // serial child-readDir walk (pkgs/by-name: 756 shard listings
        // back-to-back on the critical chain, ~19ms at w=8). Same default
        // gate as import prefetch (ON whenever helpers exist; the old
        // w<=16 bound fell with the bulk-spec drain cap, same evidence);
        // FIX_READDIR_PREFETCH=0/1 overrides, FIX_READDIR_PREFETCH_MIN
        // tunes the directory-children threshold,
        // FIX_READDIR_PREFETCH_MAX bounds total child listings per eval.
        {
            var on = self.worker_count >= 2;
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
        self.store.realization.clearDebugRecords();
    }

    pub const ParallelInput = struct {
        source: []const u8,
        base_path: ?[]const u8 = null,
        source_path: ?[]const u8 = null,
    };

    pub const ParallelSink = struct {
        context: *anyopaque,
        complete_fn: *const fn (context: *anyopaque, index: usize, value: ?Value, failure: ?ParallelFailure) void,

        pub fn complete(self: ParallelSink, index: usize, value: ?Value, failure: ?ParallelFailure) void {
            self.complete_fn(self.context, index, value, failure);
        }
    };

    pub const ParallelFailure = struct {
        err: anyerror,
        trace: *const EvalTrace,
        diagnostics: bool = false,
    };

    /// Compile several independent inputs, then evaluate each on its own demand
    /// fiber. `sink` is called exactly once per input, from that demand fiber
    /// for runtime outcomes and from the caller for compile/setup failures.
    pub fn evaluatePathsParallel(self: *Evaluator, inputs: []const ParallelInput, sink: ParallelSink) void {
        if (inputs.len == 0) return;
        self.prepareEvaluations() catch |err| {
            for (inputs, 0..) |_, index| sink.complete(index, null, .{ .err = err, .trace = self.getTrace() });
            return;
        };

        const Context = struct {
            ev: *Evaluator,
            sink: ParallelSink,
            index: usize,
            chunk_id: ChunkId,
            details: observ.Details,
            trace: *EvalTrace,

            fn entry(raw: *anyopaque) void {
                const ctx: *@This() = @ptrCast(@alignCast(raw));
                const inner = fiber_mod.currentFiber().?;
                const fiber: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
                fiber.ctx.error_trace = ctx.trace;
                defer fiber.ctx.error_trace = null;
                var scratch = @import("base").arena.ArenaAllocator.init(ctx.ev.allocator);
                defer scratch.deinit();
                var vm = ctx.ev.initVm(0, scratch.allocator()) catch |err| {
                    ctx.sink.complete(ctx.index, null, .{ .err = err, .trace = ctx.trace });
                    return;
                };
                defer vm.deinit();
                gc_controller.registerVm(gcContext(ctx.ev), &vm);
                defer gc_controller.unregisterVm(gcContext(ctx.ev), &vm);
                var observation = ctx.ev.observer.begin(&evaluate_observation, ctx.details);
                defer observation.cancel();
                const value = vm.eval(ctx.chunk_id) catch |err| {
                    ctx.sink.complete(ctx.index, null, .{ .err = err, .trace = ctx.trace });
                    return;
                };
                observation.finish(.{});
                ctx.sink.complete(ctx.index, value, null);
            }
        };

        const contexts = self.allocator.alloc(Context, inputs.len) catch {
            for (inputs, 0..) |_, index| sink.complete(index, null, .{ .err = error.OutOfMemory, .trace = self.getTrace() });
            return;
        };
        defer self.allocator.free(contexts);
        const traces = self.allocator.alloc(EvalTrace, inputs.len) catch {
            for (inputs, 0..) |_, index| sink.complete(index, null, .{ .err = error.OutOfMemory, .trace = self.getTrace() });
            return;
        };
        defer self.allocator.free(traces);
        for (traces) |*trace| trace.* = EvalTrace.init(self.allocator);
        defer for (traces) |*trace| trace.deinit();
        var entries: std.ArrayListUnmanaged(worker_mod.Worker.TopLevelEntry) = .empty;
        defer entries.deinit(self.allocator);
        entries.ensureTotalCapacity(self.allocator, inputs.len) catch {
            for (inputs, 0..) |_, index| sink.complete(index, null, .{ .err = error.OutOfMemory, .trace = self.getTrace() });
            return;
        };

        for (inputs, 0..) |input, index| {
            const chunk_id = self.parseAndCompile(input.source, input.base_path orelse self.base_path, input.source_path, null) catch |err| {
                sink.complete(index, null, .{ .err = err, .trace = self.getTrace(), .diagnostics = true });
                continue;
            };
            contexts[index] = .{
                .ev = self,
                .sink = sink,
                .index = index,
                .chunk_id = chunk_id,
                .details = observationDetails(input.source_path orelse "expression"),
                .trace = &traces[index],
            };
            entries.appendAssumeCapacity(.{ .entry = Context.entry, .arg = &contexts[index] });
        }

        const worker = self.ensureMainWorker() catch |err| {
            for (entries.items) |entry| {
                const ctx: *Context = @ptrCast(@alignCast(entry.arg));
                sink.complete(ctx.index, null, .{ .err = err, .trace = ctx.trace });
            }
            return;
        };
        worker.runTopLevels(entries.items) catch |err| {
            for (entries.items) |entry| {
                const ctx: *Context = @ptrCast(@alignCast(entry.arg));
                sink.complete(ctx.index, null, .{ .err = err, .trace = ctx.trace });
            }
        };
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
        /// The VM containing the synchronous import call, for debugger stack
        /// traversal. Null for a top-level/non-import evaluation.
        debug_parent: ?*VM,
    ) !Value {
        const chunk_id = try self.parseAndCompile(source, base_path, source_path, scope);
        const subject = source_path orelse "expression";
        var observation = self.observer.begin(&evaluate_observation, observationDetails(subject));
        defer observation.cancel();
        // Only a top-level eval (no source_path — a plain or repl-scoped
        // entry) goes through a main-thread fiber so the main thread can
        // yield on a `.busy` thunk; nested invocations (imports, scoped
        // imports — which always carry the imported file's path) run
        // synchronously on the existing fiber's stack — they share the
        // surrounding fiber's execution identity via the ctx pointer
        // `initVm` copies.
        if (source_path == null) {
            const value = try self.runChunkOnMainWorker(chunk_id);
            observation.finish(.{});
            return value;
        }
        // Per-import scratch arena: the nested VM's run-path allocations
        // (drv hashing, builtin temp buffers) are freed wholesale when the
        // import returns instead of accreting for the evaluator's lifetime.
        var scratch = @import("base").arena.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var vm = try self.initVm(0, scratch.allocator());
        defer vm.deinit();
        vm.debug_parent = debug_parent;
        vm.debug_import_replay = if (debug_parent) |parent| parent.debug_import_replay else false;
        // Depth-transparent import: the fresh nested VM inherits the caller's
        // depth minus 1 (dropping the `import` builtin's own +1), so a
        // top-level import evaluates at depth 0 (collects) while a nested one
        // stays gated at the enclosing builtin's depth. native_depth lives on
        // the VM (fiber-local), so no threadlocal dance is needed.
        vm.native_depth = parent_depth -| 1;
        // This VM isn't in a Worker's fiber list; make its roots visible to GC.
        gc_controller.registerVm(gcContext(self), &vm);
        defer gc_controller.unregisterVm(gcContext(self), &vm);
        const value = try vm.eval(chunk_id);
        observation.finish(.{});
        return value;
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
        var vm = try VM.init(.{
            .driver = &vm_mod.driver,
            .allocator = scratch,
            .buffer_pool = &self.vm_buffers,
            .registry = &self.registry,
            .intern = &self.intern,
            .heap = &self.heap,
            .files = &self.files,
            .fetchers = &self.fetchers,
            .realization = &self.store.realization,
            .scheduler = &self.scheduler,
            // Helpers (worker_id != 0) don't write to the shared trace —
            // it's a side effect of *real* evaluation, so speculative force
            // stays invisible to it.
            .trace_sink = if (worker_id == 0) &self.report.trace else null,
            // The observer is a cheap evaluator-scoped capability. Every VM
            // receives it, including helper VMs, while the sink is responsible
            // for any synchronization needed by the selected outputs.
            .observer = self.observer,
            .executor = execution.fiber_executor,
            .vm_trace = if (worker_id == 0) self.vm_trace else null,
            // The thunk trace IS shared across workers — diagnosing
            // concurrency-shaped wrong-result bugs needs to see every
            // helper's resolves, not just main's. The trace handles
            // its own locking.
            .thunk_trace = self.thunk_trace,
            .import_host = .{ .context = self, .import_value = importValue, .scoped_import = scopedImportValue, .find_file = findFile, .get_env = getEnv },
            .builtins_value = try self.ensureBuiltins(),
            .deferred_table = &self.deferred_table,
            .registration_sink = chunkRegistrationSink(self),
            .regexes = &self.regexes,
            .break_sink = if (self.debugger.ui != null) .{ .ctx = self, .fire = fireBreak } else null,
            .breakpoints = if (self.debugger.breakpoints != null) &self.debugger.breakpoints.? else null,
            .policy = self.policy,
            .lazy_shells_visible = self.lazy_shells_visible,
        });
        // A nested VM runs on the surrounding fiber, so it borrows that
        // fiber's execution identity wholesale: claim id (any thunk it
        // claims is attributed to the fiber, not to a default that would
        // collide with pool fiber #0 and cause spurious blackholes),
        // demand flag, and the demand-only progress handles (stage stack,
        // "waiting on" record). One pointer copy — nested VMs (imports,
        // render/force bodies) CANNOT diverge from their fiber, so
        // stage/count/wait emission stays alive across them on the demand
        // fiber while a helper fiber's nested VMs stay structurally silent.
        // No current fiber (pool-VM construction on the worker thread,
        // single-threaded setup) keeps the neutral static default; the
        // Worker then binds pool VMs to their own fiber's ctx.
        if (fiber_mod.currentFiber()) |inner| {
            const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
            vm.ctx = &wf.ctx;
            if (wf.ctx.parallel_demand) vm.trace = wf.ctx.error_trace;
        }
        return vm;
    }

    pub fn writeJsonValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        var observation = self.observer.begin(&render_observation, .{ .subject = .{ .text = "result" } });
        defer observation.cancel();
        self.report.trace.clear();
        try self.runWithVm(vm_builtins.writeJsonValue, .{ writer, value });
        observation.finish(.{});
    }

    /// Legacy `nix-instantiate --eval --raw` rendering: coerce exactly as a
    /// Nix string interpolation would (strings, paths, `outPath`,
    /// `__toString`; never integers), then emit the bytes verbatim.
    pub fn writeRawValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        var observation = self.observer.begin(&render_observation, .{ .subject = .{ .text = "result" } });
        defer observation.cancel();
        self.report.trace.clear();
        try self.runWithVm(writeRawValueBody, .{ writer, value });
        observation.finish(.{});
    }

    pub fn writeXmlValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        var observation = self.observer.begin(&render_observation, .{ .subject = .{ .text = "result" } });
        defer observation.cancel();
        self.report.trace.clear();
        try self.runWithVm(vm_builtins.writeLazyXmlValue, .{ writer, value });
        observation.finish(.{});
    }

    pub fn forceValue(self: *Evaluator, value: Value) !Value {
        self.report.trace.clear();
        return self.forceValueUntraced(value);
    }

    fn forceValueUntraced(self: *Evaluator, value: Value) !Value {
        return self.runWithVm(vm_force.forceValue, .{value});
    }

    /// Enable writing forced derivations + their sources to the store as they
    /// are forced (`fix instantiate`/`build`). The daemon connects lazily on
    /// first use; plain eval leaves this off and never touches the store.
    pub fn enableStoreWrites(self: *Evaluator) void {
        self.store.realization.enableStoreWrites();
    }

    /// Legacy `nix-instantiate --eval --read-write-mode`: materialize every
    /// derivation actually demanded by evaluation, while the CLI still renders
    /// the evaluated value rather than returning a `.drv` path.
    pub fn enableReadWriteEvaluation(self: *Evaluator) void {
        self.store.realization.enableEagerEvaluationWrites();
    }

    /// The last daemon error message, for surfacing `error.DaemonError`.
    pub fn lastStoreError(self: *Evaluator) ?[]const u8 {
        return self.store.realization.lastStoreError();
    }

    /// If `value` is a derivation (an attrset with a `drvPath`), force it — which
    /// also instantiates its closure when a daemon is attached — and return the
    /// drv path (borrowed from the intern table). Returns null if `value` is not
    /// a derivation-shaped attrset.
    pub fn derivationDrvPath(self: *Evaluator, value: Value) !?[]const u8 {
        self.report.trace.clear();
        return self.derivationAttrPath(value, "drvPath");
    }

    /// The default output path (`outPath`) of a derivation `value`, or null if
    /// it is not a derivation-shaped attrset.
    pub fn derivationOutPath(self: *Evaluator, value: Value) !?[]const u8 {
        self.report.trace.clear();
        return self.derivationAttrPath(value, "outPath");
    }

    fn derivationAttrPath(self: *Evaluator, value: Value, attr_name: []const u8) !?[]const u8 {
        const forced = try self.forceValueUntraced(value);
        if (!forced.isAttrs()) return null;
        return self.forcedStringAttr(forced.asObjectId(), attr_name);
    }

    pub const DerivationBuildPaths = struct {
        drv_path: []const u8,
        out_path: []const u8,
    };

    /// Extract the paths needed by the parallel build pipeline without touching
    /// the evaluator's single-run diagnostic trace.
    pub fn derivationBuildPaths(self: *Evaluator, value: Value) !?DerivationBuildPaths {
        const forced = try self.forceValueUntraced(value);
        if (!forced.isAttrs()) return null;
        const id = forced.asObjectId();
        const drv_path = (try self.forcedStringAttr(id, "drvPath")) orelse return null;
        return .{
            .drv_path = drv_path,
            .out_path = (try self.forcedStringAttr(id, "outPath")) orelse drv_path,
        };
    }

    /// The name of the program `fix run` should exec from a derivation's output:
    /// `meta.mainProgram`, else `pname`, else `name`. Borrowed from intern.
    pub fn derivationProgram(self: *Evaluator, value: Value) !?[]const u8 {
        const forced = try self.forceValue(value);
        if (!forced.isAttrs()) return null;
        const id = forced.asObjectId();
        if (try self.heap.getAttrValueOpt(id, try self.intern.intern("meta"))) |meta| {
            const meta_forced = try self.forceValue(meta);
            if (meta_forced.isAttrs()) {
                if (try self.forcedStringAttr(meta_forced.asObjectId(), "mainProgram")) |main| return main;
            }
        }
        if (try self.forcedStringAttr(id, "pname")) |pname| return pname;
        return self.forcedStringAttr(id, "name");
    }

    /// Force attribute `name` of `id` and return its text (string/path/context),
    /// or null if absent or non-string. Borrowed from the intern table.
    fn forcedStringAttr(self: *Evaluator, id: types.ObjectId, name: []const u8) !?[]const u8 {
        const name_id = try self.intern.intern(name);
        const attr = (try self.heap.getAttrValueOpt(id, name_id)) orelse return null;
        const forced = try self.forceValueUntraced(attr);
        const text_id = switch (forced.kind()) {
            .string, .path => forced.asInternId(),
            .string_context => (try self.heap.getContextString(forced.asObjectId())).text,
            else => return null,
        };
        return self.intern.get(text_id);
    }

    /// Write `drv_path`'s `.drv` closure to the store on demand (deps-first via
    /// the recipe graph). Since forcing only records recipes, this is how a `.drv`
    /// is materialized — for `instantiate`, and before a build. Must run before
    /// eval state is released (it reads the recipe graph).
    pub fn ensureDerivationClosure(self: *Evaluator, drv_path: []const u8) !void {
        return self.store.realization.ensureClosure(drv_path);
    }

    pub const AsyncBuildRequest = StoreState.AsyncBuildRequest;

    /// Submit a fully materialized derivation to the daemon pool without
    /// waiting for its build to finish.
    pub fn submitBuild(self: *Evaluator, request: *AsyncBuildRequest) void {
        self.store.submitBuild(request);
    }

    /// Finish evaluation and return the only state needed by the build phase.
    /// Language teardown overlaps daemon work once the returned session starts
    /// a build; callers must keep the session alive until that work completes.
    pub fn beginBuildPhase(self: *Evaluator, derived_paths: []const []const u8, after_release: ?ReleaseAction) !BuildSession {
        // Writes are demand-driven: materialize each target's `.drv` closure now,
        // BEFORE releasing eval state — `ensureClosure` walks the recipe graph,
        // which `releaseEvalState` frees. (Cheap, and inherently sequential: the
        // daemon can't build a `.drv` whose closure isn't on disk yet.)
        for (derived_paths) |derived| {
            const drv = derived[0..(std.mem.indexOfScalar(u8, derived, '!') orelse derived.len)];
            try self.store.realization.ensureClosure(drv);
        }
        // Now release on a helper thread so the build launches immediately and
        // the ~2 GB heap teardown overlaps it. If the thread can't spawn, fall
        // back to serial release-then-build.
        const releaser = std.Thread.spawn(.{}, releaseForBuild, .{ self, after_release }) catch blk: {
            releaseForBuild(self, after_release);
            break :blk null;
        };
        return BuildSession.init(&self.store, releaser);
    }

    /// Set the per-connection daemon settings (`--cores`/`--max-jobs`/… via
    /// `set_options`) applied when the store connects. See `setup.configure`.
    pub fn setDaemonBuildSettings(self: *Evaluator, settings: store_domain.daemon.BuildSettings) !void {
        return self.store.realization.setBuildSettings(settings);
    }

    /// Override the nix-daemon socket path (`$NIX_DAEMON_SOCKET_PATH`).
    pub fn setDaemonSocket(self: *Evaluator, path: []const u8) !void {
        return self.store.realization.setDaemonSocket(path);
    }

    /// Navigate a dotted attr path (e.g. `python3Packages.requests`) from `value`,
    /// forcing each step. Returns null if any component is missing or non-attrs.
    pub fn attrPathValue(self: *Evaluator, value: Value, path: []const u8) !?Value {
        var current = try self.forceValue(value);
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |component| {
            if (!current.isAttrs()) return null;
            const name_id = try self.intern.intern(component);
            const attr = (try self.heap.getAttrValueOpt(current.asObjectId(), name_id)) orelse return null;
            current = try self.forceValue(attr);
        }
        return current;
    }

    pub fn forceDeep(self: *Evaluator, value: Value) !void {
        var observation = self.observer.begin(&render_observation, .{ .subject = .{ .text = "strict result" } });
        defer observation.cancel();
        self.report.trace.clear();
        try self.runWithVm(vm_force.forceDeepCounted, .{value});
        observation.finish(.{});
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
            var scratch = @import("base").arena.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            var vm = try self.initVm(0, scratch.allocator());
            defer vm.deinit();
            gc_controller.registerVm(gcContext(self), &vm);
            defer gc_controller.unregisterVm(gcContext(self), &vm);
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
                var scratch = @import("base").arena.ArenaAllocator.init(ctx.ev.allocator);
                defer scratch.deinit();
                var vm = ctx.ev.initVm(0, scratch.allocator()) catch |e| {
                    ctx.err = e;
                    return;
                };
                defer vm.deinit();
                gc_controller.registerVm(gcContext(ctx.ev), &vm);
                defer gc_controller.unregisterVm(gcContext(ctx.ev), &vm);
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
        // Register the collect callback now that `self` is at
        // its final address (init returns by value), and enable reclaim. The
        // collect runs at the forceThunk safepoint when allocation crosses
        // the byte threshold; at --workers>1 it stops the world (all workers
        // park at safepoints) before marking. Register worker 0 so the
        // collector can walk its fibers for roots.
        self.gc_workers[0].store(w, .release);
        self.gc_coord.install(&self.heap, &self.scheduler, .{
            .context = self,
            .collect = gcCollect,
            .help_mark = gcHelpMark,
        });
        if (self.env_map) |em|
            if (em.get("FIX_GC_NOREUSE") != null) self.heap.gcSetDisableReuse(true);
        if (self.env_map) |em|
            if (em.get("FIX_GC_PAR_CAP")) |s| {
                if (std.fmt.parseInt(u32, s, 10)) |c| {
                    if (c >= 1) self.gc_parallel_cap = c;
                } else |_| {}
            };
        // FIX_GC_STEP_MB (validation): collect every N MB of fresh
        // allocation so the detector exercises every builtin loop.
        var step_bytes: u64 = 0;
        if (self.env_map) |em| {
            if (em.get("FIX_GC_STEP_MB")) |s| {
                if (std.fmt.parseInt(u64, s, 10)) |mb| step_bytes = mb << 20 else |_| {}
            }
        }
        // Collection line: no collection runs until heap-reserved bytes
        // cross it (automatic `clamp(½·MemTotal, 256MB, 8GB)`, overridable
        // via `--gc-budget`; see `gc_controller.memoryBudget`).
        // On a roomy machine that line dwarfs the eval → never fires: zero
        // pauses AND zero tracking (lazy arming at line/2, see
        // `heap_collector.enableBudget`); on a tight machine it fires before the
        // eval OOMs. Override 0 = never collect (bump-only). FIX_GC_STEP_MB
        // keeps the eager validation path (tracking from the start).
        const budget = gc_controller.memoryBudget(gcContext(self));
        if (step_bytes > 0)
            heap_collector.enableCollect(&self.heap, budget, step_bytes)
        else if (budget > 0)
            heap_collector.enableBudget(&self.heap, budget, gc_controller.constrainedMode(gcContext(self), budget));
        return w;
    }

    fn gcCollect(ctx: *anyopaque, collector_id: u8) void {
        const self: *Evaluator = @ptrCast(@alignCast(ctx));
        gc_controller.collect(gcContext(self), collector_id);
    }

    /// Replace the caller-held external root set (see
    /// `gc_extra_roots`). The repl passes its scope attrset + loose values
    /// here whenever they change; they stay rooted until replaced.
    pub fn gcSetExternalRoots(self: *Evaluator, roots: []const Value) !void {
        self.gc_extra_roots.clearRetainingCapacity();
        try self.gc_extra_roots.appendSlice(self.allocator, roots);
    }

    pub const CollectNowResult = struct {
        /// False when collection is disabled by policy (`--gc-budget=0`)
        /// or nothing has run yet.
        ran: bool,
        /// Number of actual mark/sweep cycles completed by this request. The
        /// first request may only arm lazy tracking.
        collections: u64,
        objects_freed: u64,
        live_bytes: u64,
        /// Append-store high-water retained for reuse; collection does not
        /// shrink these cursors, so presenting it as before/after is misleading.
        capacity_bytes: u64,
    };

    fn collectNowResult(self: *Evaluator) CollectNowResult {
        return .{
            .ran = false,
            .collections = 0,
            .objects_freed = 0,
            .live_bytes = 0,
            .capacity_bytes = self.heap.totalReservedBytes(),
        };
    }

    fn finishCollectNow(self: *Evaluator, result: *CollectNowResult, before: gc.LiveReport) void {
        const after = gc.liveReport(&self.heap.gc_report);
        result.ran = true;
        result.collections = after.collections -| before.collections;
        result.objects_freed = after.freed_objects -| before.freed_objects;
        result.live_bytes = after.live_bytes;
        result.capacity_bytes = self.heap.totalReservedBytes();
    }

    /// GC: run a stop-the-world collection right now, from outside
    /// any evaluation — the repl's between-inputs reclaim. Drives the same
    /// barrier + hook sequence as the in-eval safepoint (vm/force.zig): win
    /// the collector race, park every worker, collect, release. The first
    /// call arms reclaim tracking (`armLazy` — everything already allocated
    /// becomes the untracked old floor); later calls run real minors.
    ///
    /// Callable only between evaluations (no fiber may be mid-flight on the
    /// calling thread); helpers park at their safepoints as in any STW.
    pub fn collectNow(self: *Evaluator) CollectNowResult {
        var result = self.collectNowResult();
        // No hook yet (nothing evaluated) or reclaim disabled by policy
        // (threshold never armed): nothing to do.
        if (self.main_worker == null) return result;
        if (self.heap.gc_threshold_bytes == std.math.maxInt(u64)) return result;
        if (!self.scheduler.gcTryBeginCollection()) return result;
        const before = gc.liveReport(&self.heap.gc_report);
        self.scheduler.gcWaitAllParked(0);
        // Invalidate the token-keyed thread-local caches (thunk memo, attr
        // IC) BEFORE marking: they root the previous evaluation's hottest
        // values (markRoots must treat current-token entries as live), but
        // between evaluations they are semantically dead — without this the
        // last input's whole result graph gets promoted instead of freed.
        // Safe here: the world is stopped. In-eval collections instead bump
        // the token after the sweep (`afterCollect`).
        self.heap.token = runtime.heap.next_heap_token.fetchAdd(1, .monotonic);
        heap_collector.runCollect(&self.heap, 0);
        self.scheduler.gcEndCollection(0);
        self.finishCollectNow(&result, before);
        return result;
    }

    /// Like `collectNow`, but runs a MAJOR (full) collection — reclaims the
    /// tenured old-generation garbage a minor leaves behind. Used by the repl
    /// between inputs so a heavy input's whole result graph is reclaimed (a
    /// minor only reclaims the young survivors, so under parallel workers, where
    /// more objects tenure, repl memory would otherwise ratchet up). Same STW
    /// dance + cache-invalidating token bump as `collectNow`.
    pub fn collectMajorNow(self: *Evaluator) CollectNowResult {
        var result = self.collectNowResult();
        if (self.main_worker == null) return result;
        if (self.heap.gc_threshold_bytes == std.math.maxInt(u64)) return result;
        if (!self.scheduler.gcTryBeginCollection()) return result;
        const before = gc.liveReport(&self.heap.gc_report);
        self.scheduler.gcWaitAllParked(0);
        self.heap.token = runtime.heap.next_heap_token.fetchAdd(1, .monotonic);
        gc_controller.collectMajor(gcContext(self), 0);
        self.scheduler.gcEndCollection(0);
        self.finishCollectNow(&result, before);
        return result;
    }

    fn gcHelpMark(ctx: *anyopaque, worker_id: u8) void {
        const self: *Evaluator = @ptrCast(@alignCast(ctx));
        gc_controller.helpMark(gcContext(self), worker_id);
    }

    fn importValue(context: *anyopaque, caller: *VM, path: []const u8, parent_depth: u32) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return self.importPath(path, parent_depth, caller);
    }

    fn importPath(self: *Evaluator, path: []const u8, parent_depth: u32, debug_parent: *VM) !Value {
        const resolved = try self.resolveHostPath(path);
        defer if (resolved.owned) self.allocator.free(resolved.text);
        return self.importResolvedPath(resolved.text, parent_depth, debug_parent);
    }

    fn importResolvedPath(self: *Evaluator, path: []const u8, parent_depth: u32, debug_parent: *VM) anyerror!Value {
        const entry = try self.imports.lookupOrCreate(self.allocator, path, debug_parent.debug_import_replay);
        return self.forceImportEntry(path, entry, parent_depth, debug_parent);
    }

    fn forceImportEntry(
        self: *Evaluator,
        path: []const u8,
        entry: *imports_mod.ImportEntry,
        parent_depth: u32,
        debug_parent: *VM,
    ) anyerror!Value {
        const me = currentImportClaimer();
        while (true) {
            switch (entry.future.tryClaim(me)) {
                .already_resolved => return entry.result,
                .blackhole => return error.ImportCycle,
                .errored => return entry.error_info.?.err,
                .busy => {
                    const inner = fiber_mod.currentFiber() orelse
                        @panic("import entry became busy outside an evaluator fiber");
                    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
                    if (entry.future.enrollWaiter(&wf.waiter)) {
                        wf.state = .suspended;
                        fiber_mod.Fiber.yield();
                        wf.state = .running;
                    }
                    continue;
                },
                .claimed => {
                    const value = self.compileImportPath(path, parent_depth, debug_parent) catch |err| {
                        self.publishImportFailure(entry, err);
                        return err;
                    };
                    entry.result = value;
                    entry.future.publish();
                    return value;
                },
            }
        }
    }

    fn publishImportFailure(self: *Evaluator, entry: *imports_mod.ImportEntry, err: anyerror) void {
        switch (err) {
            error.OutOfMemory, error.StackOverflow => {
                entry.future.reset();
                return;
            },
            else => {},
        }
        const info = self.allocator.create(thunk_mod.ErrorInfo) catch {
            entry.future.reset();
            return;
        };
        info.* = .{ .err = err, .message = null };
        entry.error_info = info;
        entry.future.publishErrored();
    }

    fn compileImportPath(self: *Evaluator, path: []const u8, parent_depth: u32, debug_parent: *VM) anyerror!Value {
        const stable_path = try self.allocator.dupe(u8, path);
        defer self.allocator.free(stable_path);

        var observation = self.observer.begin(&import_observation, .{ .subject = .{ .path = stable_path } });
        defer observation.cancel();

        const source = if (corepkgs.source(stable_path)) |core_source|
            core_source
        else
            self.files.readFile(stable_path) catch |err| switch (err) {
                error.IsDir => return self.importDirectory(stable_path, parent_depth, debug_parent),
                else => return err,
            };
        const source_base = std.fs.path.dirname(stable_path) orelse "/";
        const value = try self.evaluateSource(source, source_base, stable_path, null, parent_depth, debug_parent);
        observation.finish(.{});
        return value;
    }

    /// Explicit post-registration phase: compiler code reports a newly
    /// published chunk here, after the registry mutation has completed. Import
    /// discovery and debugger patching are evaluator orchestration, not hidden
    /// side effects of `ChunkRegistry.register`.
    fn chunkRegistered(self: *Evaluator, chunk_id: ChunkId) void {
        const chunk = self.registry.get(chunk_id) orelse return;
        for (chunk.constants) |value| {
            if (value.isPath()) prefetchPathConst(self, value.asInternId());
        }
        if (self.debugger.breakpoints) |*breakpoints| {
            breakpoints.placeRegisteredChunk(chunk_id, @constCast(chunk));
        }
    }

    /// Import-path discovery in the evaluator's explicit chunk-registration
    /// phase (`FIX_IMPORT_PREFETCH`):
    /// called for every `.path` constant of every freshly compiled chunk,
    /// from whichever worker ran the compile. Filters to `.nix` files
    /// (directory references — the bulk of e.g. all-packages.nix's ~1.7K
    /// path constants — are mostly never imported in a given eval and
    /// would be junk), dedups per intern id, spends the submission
    /// budget, and hands the path to the spec lane.
    fn prefetchPathConst(self: *Evaluator, path_id: types.InternId) void {
        const text = self.intern.get(path_id);
        if (!std.mem.endsWith(u8, text, ".nix")) return;
        {
            self.prefetch.mu.lock();
            defer self.prefetch.mu.unlock();
            if (self.prefetch.budget == 0) return;
            const gop = self.prefetch.seen.getOrPut(self.allocator, path_id) catch return;
            if (gop.found_existing) return;
            self.prefetch.budget -= 1;
        }
        _ = self.scheduler.submit(.{ .import_prefetch = path_id }, worker_id_mod.current);
    }

    fn scopedImportValue(context: *anyopaque, caller: *VM, scope: Value, path: []const u8, parent_depth: u32) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return self.scopedImportPath(scope, path, parent_depth, caller);
    }

    fn scopedImportPath(self: *Evaluator, scope: Value, path: []const u8, parent_depth: u32, debug_parent: *VM) !Value {
        const resolved = try self.resolveHostPath(path);
        defer if (resolved.owned) self.allocator.free(resolved.text);
        return self.scopedImportResolvedPath(scope, resolved.text, parent_depth, debug_parent);
    }

    fn scopedImportResolvedPath(
        self: *Evaluator,
        scope: Value,
        path: []const u8,
        parent_depth: u32,
        debug_parent: *VM,
    ) anyerror!Value {
        const stable_path = try self.allocator.dupe(u8, path);
        defer self.allocator.free(stable_path);

        var cursor = currentExecutionContext().scoped_import_top;
        while (cursor) |node| {
            if (std.mem.eql(u8, node.path, stable_path)) return error.ImportCycle;
            cursor = node.next;
        }
        var frame: execution.ScopedImportFrame = .{ .path = stable_path, .next = currentExecutionContext().scoped_import_top };
        currentExecutionContext().scoped_import_top = &frame;
        defer currentExecutionContext().scoped_import_top = frame.next;

        var observation = self.observer.begin(&import_observation, .{ .subject = .{ .path = stable_path } });
        defer observation.cancel();

        const source = if (corepkgs.source(stable_path)) |core_source|
            core_source
        else
            self.files.readFile(stable_path) catch |err| switch (err) {
                error.IsDir => return self.scopedImportDirectory(scope, stable_path, parent_depth, debug_parent),
                else => return err,
            };
        const source_base = std.fs.path.dirname(stable_path) orelse "/";
        const value = try self.evaluateSource(source, source_base, stable_path, scope, parent_depth, debug_parent);
        observation.finish(.{});
        return value;
    }

    fn importDirectory(self: *Evaluator, path: []const u8, parent_depth: u32, debug_parent: *VM) anyerror!Value {
        const default_path = try std.fs.path.resolve(self.allocator, &.{ path, "default.nix" });
        defer self.allocator.free(default_path);
        return self.importResolvedPath(default_path, parent_depth, debug_parent);
    }

    fn scopedImportDirectory(
        self: *Evaluator,
        scope: Value,
        path: []const u8,
        parent_depth: u32,
        debug_parent: *VM,
    ) anyerror!Value {
        const default_path = try std.fs.path.resolve(self.allocator, &.{ path, "default.nix" });
        defer self.allocator.free(default_path);
        return self.scopedImportResolvedPath(scope, default_path, parent_depth, debug_parent);
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
        if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://") or std.mem.startsWith(u8, path, "file://"))
            return .{ .text = path, .owned = false };
        if (std.fs.path.isAbsolute(path)) return .{ .text = path, .owned = false };

        const base_path = self.base_path orelse return error.RelativePath;
        return .{
            .text = try std.fs.path.resolve(self.allocator, &.{ base_path, path }),
            .owned = true,
        };
    }

    pub fn writeValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        var observation = self.observer.begin(&render_observation, .{ .subject = .{ .text = "result" } });
        defer observation.cancel();
        try self.runWithVm(writeValueBody, .{ self, writer, value });
        observation.finish(.{});
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
    // GC: register this helper so the collector can walk its fibers
    // for roots. Registration happens before `run()` (before any user-object
    // allocation), and the collector only reads the registry at a stop-the-
    // world where this worker is parked.
    ev.gc_workers[worker_id].store(worker, .release);
    worker.run();
    // Wait until ALL helpers have stopped forcing before destroying any
    // fibers — a still-running helper could resolve a thunk and wake a
    // just-freed enrolled fiber (shutdown UAF). See awaitHelpersQuiescent.
    sched.awaitHelpersQuiescent();
    // Unregister before deinit so a late collection never scans freed fibers.
    // (After awaitHelpersQuiescent no helper is still forcing, so no
    // collection can be triggered past this point, but keep the invariant.)
    ev.gc_workers[worker_id].store(null, .release);
    worker.deinit();
}

fn releaseForBuild(ev: *Evaluator, after_release: ?ReleaseAction) void {
    ev.releaseEvalState();
    if (after_release) |action| action.run(action.context);
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
    return eval_print.writeValue(valuePrintHost(ev), writer, value);
}

fn writeRawValueBody(vm: *VM, writer: *std.Io.Writer, value: Value) !void {
    const string_value = try vm_strings.coerceLanguageStringValue(vm, value);
    const text_id = try vm_strings.stringTextInternId(vm, string_value);
    try writer.writeAll(vm.intern.get(text_id));
}

fn valuePrintHost(ev: *Evaluator) eval_print.Host {
    return .{
        .allocator = ev.allocator,
        .heap = &ev.heap,
        .intern = &ev.intern,
        .value_color = ev.value_color,
        .context = ev,
        .force_value = printForceValue,
    };
}

fn chunkRegistrationSink(ev: *Evaluator) compiler_mod.ChunkRegistrationSink {
    return .{ .context = ev, .registered = chunkRegisteredThunk };
}

fn chunkRegisteredThunk(context: *anyopaque, chunk_id: ChunkId) void {
    const ev: *Evaluator = @ptrCast(@alignCast(context));
    ev.chunkRegistered(chunk_id);
}

fn printForceValue(context: *anyopaque, value: Value) anyerror!Value {
    const ev: *Evaluator = @ptrCast(@alignCast(context));
    return ev.forceValue(value);
}

fn currentImportClaimer() future_mod.ClaimerId {
    const inner = fiber_mod.currentFiber() orelse return future_mod.invalid_claimer;
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
    return wf.ctx.claimer_id;
}

fn currentExecutionContext() *execution.ExecutionContext {
    const inner = fiber_mod.currentFiber() orelse
        @panic("scoped import ran outside an evaluator fiber");
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
    return &wf.ctx;
}

fn gcContext(ev: *Evaluator) gc_controller.Context {
    return .{
        .allocator = ev.allocator,
        .heap = &ev.heap,
        .registry = &ev.registry,
        .scheduler = &ev.scheduler,
        .realization = &ev.store.realization,
        .imports = &ev.imports,
        .builtins_value = &ev.builtins_value,
        .env_map = ev.env_map,
        .worker_count = ev.worker_count,
        .gc_budget_bytes = ev.gc_budget_bytes,
        .tracer = &ev.gc_tracer,
        .import_vms = &ev.gc_import_vms,
        .import_vms_mu = &ev.gc_import_vms_mu,
        .workers = ev.gc_workers,
        .chunks_scanned = &ev.gc_chunks_scanned,
        .extra_roots = &ev.gc_extra_roots,
        .parallel_cap = ev.gc_parallel_cap,
        .observer = ev.observer,
    };
}

test {
    _ = @import("eval/tests.zig");
}
