//! Tail-calling bytecode virtual machine.
//!
//! Each worker thread gets its own VM instance. The VM executes bytecode chunks
//! in a loop until they return. Tail calls are optimized by reusing the current
//! frame instead of pushing a new one.
//!
//! Architecture:
//!   - Direct-threaded dispatch via switch statement
//!   - Value stack (growable, contiguous memory)
//!   - Frame stack (call frames with return info)
//!   - Atomic thunk integration for lazy evaluation

const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const bytecode_mod = @import("bytecode");
const opcode = bytecode_mod.opcode;
const build_options = @import("build_options");
const chunk = bytecode_mod.chunk;
const Chunk = chunk.Chunk;
const ChunkRegistry = chunk.ChunkRegistry;
const InternTable = @import("runtime").intern.InternTable;
const Scheduler = @import("scheduler").Scheduler;
const heap_mod = @import("runtime").heap;
const ObjectHeap = heap_mod.ObjectHeap;
const FileCache = @import("runtime").file_cache.FileCache;
const FetchCache = @import("runtime").fetch_cache.FetchCache;
const DerivationStore = @import("derivation").DerivationStore;
const eval_trace = @import("observ").trace;
const eval_progress = @import("observ").progress;
const VmTrace = @import("vm/trace_log.zig").VmTrace;
const worker_id_mod = @import("base").worker_id;
const DeferredTable = @import("compiler").deferred_table.Table;
const ThunkTrace = @import("probe").thunk_trace.ThunkTrace;

pub const exec_context = @import("vm/exec_context.zig");
pub const ExecutionContext = exec_context.ExecutionContext;

pub const builtins = @import("vm/builtins.zig");
pub const run = @import("vm/run.zig");
pub const equality = @import("vm/equality.zig");
pub const force = @import("vm/force.zig");
pub const objects = @import("vm/objects.zig");
pub const strings = @import("vm/strings.zig");
pub const closures = @import("vm/closures.zig");
pub const errors = @import("vm/errors.zig");
pub const access = @import("vm/access.zig");
pub const stack = @import("vm/stack.zig");
pub const trace = @import("vm/trace.zig");
pub const debug = @import("vm/debug.zig");
pub const trace_log = @import("vm/trace_log.zig");
pub const worker = @import("vm/worker.zig");
pub const io_offload = @import("vm/io_offload.zig");

pub const opcode_profile_enabled = build_options.vm_opcode_profile;
pub const thunks_log_enabled = build_options.thunks_log;
pub const OpcodeCounts = [opcode.count]u64;
const OpcodeProfileSink = if (opcode_profile_enabled) *OpcodeCounts else void;
const OpcodeProfileState = if (opcode_profile_enabled) OpcodeCounts else void;
const SpinMutex = @import("base").sync.SpinMutex;
const vma = @import("runtime").mem_tag.vma;
const PatternCache = @import("base").regex.PatternCache;

/// Reusable VM buffers — the value stack + frame stack, the two large
/// per-VM allocations (~0.5 MB together). Pooled by the evaluator:
/// nested import VMs are created ~2.6K times per NixOS eval, and each
/// used to bump-allocate a fresh stack out of the worker arena that was
/// then "freed" into the void (arena free is a no-op) — ~245 MB of
/// once-touched, never-reused pages at w=1. Reuse keeps the working set
/// at the max-concurrent-VM high-water instead, and stops the re-fault
/// churn. Buffers come back dirty; that's fine — every consumer is
/// bounded by `sp`/`frames_len`, including the GC's stack scan
/// (eval/gc.zig marks `stack[0..sp]`).
pub const BufferPool = struct {
    allocator: std.mem.Allocator,
    mu: SpinMutex = .{},
    list: std.ArrayListUnmanaged(Buffers) = .empty,

    pub const Buffers = struct { stack: []Value, frames: []Frame };

    pub fn init(allocator: std.mem.Allocator) BufferPool {
        return .{ .allocator = allocator };
    }

    /// All VMs must be dead (buffers released or freed) before this.
    pub fn deinit(self: *BufferPool) void {
        for (self.list.items) |bufs| {
            self.allocator.free(bufs.stack);
            self.allocator.free(bufs.frames);
        }
        self.list.deinit(self.allocator);
    }

    pub fn acquire(self: *BufferPool) !Buffers {
        self.mu.lock();
        if (self.list.pop()) |bufs| {
            self.mu.unlock();
            return bufs;
        }
        self.mu.unlock();
        // RSS attribution (runtime/vma.zig): VM buffers get their own
        // bucket so the report separates them from transient blocks.
        const prev_tag = vma.setAllocTag(.worker_arena);
        defer _ = vma.setAllocTag(prev_tag);
        const value_stack = try self.allocator.alloc(Value, types.VM_STACK_CAP);
        errdefer self.allocator.free(value_stack);
        const frames = try self.allocator.alloc(Frame, types.MAX_FRAMES);
        return .{ .stack = value_stack, .frames = frames };
    }

    pub fn release(self: *BufferPool, bufs: Buffers) void {
        self.mu.lock();
        const appended = blk: {
            self.list.append(self.allocator, bufs) catch break :blk false;
            break :blk true;
        };
        self.mu.unlock();
        if (!appended) {
            self.allocator.free(bufs.stack);
            self.allocator.free(bufs.frames);
        }
    }
};

/// A single call frame.
pub const Frame = struct {
    /// The chunk being executed.
    chunk_ptr: *const Chunk,
    /// Id of the chunk being executed.
    chunk_id: ChunkId,
    /// Instruction pointer (byte offset into chunk.code).
    ip: usize,
    /// Base index into the VM stack for local variables.
    frame_base: u32,
    /// Number of locals in this frame (for cleanup).
    local_count: u32,
    /// Upvalues for the closure or direct thunk currently executing.
    upvalues: ?[]const Value,
    /// Logical call depth of this frame — the length of the function-
    /// application chain that reached it, matching Nix's `max-call-depth`
    /// accounting. A function-application frame is one deeper than the
    /// frame that called it; a passthrough frame (top-level entry, a
    /// thunk-force isolated frame, an eager argument evaluation) inherits
    /// its parent's depth unchanged. Tail calls (`replaceCurrentFrame`)
    /// bump this in place, so a tail-recursion loop grows the logical
    /// depth without growing the physical frame stack — exactly how Nix
    /// bounds otherwise-unbounded tail recursion.
    call_depth: u32 = 0,
};

pub const ImportHost = struct {
    context: *anyopaque,
    // `parent_depth` = the calling VM's `native_depth` (the import builtin has
    // already +1'd it): the nested import VM inherits `parent_depth - 1` so
    // imports stay depth-transparent for GC safepoints.
    import_value: *const fn (*anyopaque, []const u8, u32) anyerror!Value,
    scoped_import: *const fn (*anyopaque, Value, []const u8, u32) anyerror!Value,
    find_file: *const fn (*anyopaque, []const u8) anyerror!Value,
    get_env: *const fn (*anyopaque, []const u8) anyerror![]const u8,
};

/// Why evaluation paused into the debugger. `break_builtin` is a
/// `builtins.break x` call; `line_breakpoint` is a patched source-line
/// breakpoint; `step` is a completed single-step; `eval_error` is an
/// evaluation error caught with `--debugger`.
pub const BreakReason = enum { break_builtin, line_breakpoint, step, eval_error };

/// A debugger attachment. Installed on every VM by `Evaluator.initVm` when a
/// debugger is active; null (the default) means "no debugger" and the break
/// path is a plain identity — so this costs nothing in normal evaluation.
///
/// `fire` is an upcall into the owning layer (the `fix` Evaluator, then the
/// `cli` debug console): it runs the interactive session synchronously on the
/// *current* demand fiber, then returns so evaluation continues. `ctx` is the
/// owner's opaque self-pointer. The callback may re-enter the evaluator to
/// force/render `value` and to evaluate console expressions — that nesting is
/// safe because forcing already re-enters the VM (`runIsolatedFrame`).
pub const BreakSink = struct {
    ctx: *anyopaque,
    fire: *const fn (ctx: *anyopaque, vm: *VM, value: Value, reason: BreakReason) anyerror!void,
};

/// Per-thread VM state. Each worker thread has one of these.
/// Sentinel for `VM.spec_budget`: no bound on speculative work. (Never
/// reachable by decrement — 2^64 claimed forces don't happen.)
pub const NO_SPEC_BUDGET: u64 = std.math.maxInt(u64);

pub const VM = struct {
    allocator: std.mem.Allocator,
    /// Global chunk registry (shared across all VMs). Mutable: the
    /// deferred-attr force path registers freshly-compiled chunks at
    /// runtime (`register` is internally thread-safe).
    registry: *ChunkRegistry,
    /// Lazy per-attr compilation: deferred bodies + their compile cache.
    /// Set post-init by `Evaluator.initVm`; null in standalone test VMs
    /// (which never create `.deferred` thunks). See
    /// `compiler/deferred_table.zig`.
    deferred_table: ?*DeferredTable = null,
    /// Evaluator-owned compiled-regex cache for `builtins.match`/`split`
    /// (see `runtime.regex.PatternCache`). Set post-init by
    /// `Evaluator.initVm`; null in standalone test VMs, which fall back
    /// to compiling per call.
    regexes: ?*PatternCache = null,
    /// Optional debugger attachment. Set post-init by `Evaluator.initVm` only
    /// when a debugger is active; null (the default, in every normal run)
    /// makes `builtins.break` a plain identity. See `BreakSink`.
    break_sink: ?BreakSink = null,
    /// Nesting depth of `builtins.tryEval` forces on this fiber. The debugger's
    /// error-entry (throw/abort/assert) suppresses itself while `> 0`, so a
    /// caught error doesn't spuriously pause. Only touched on the debug path.
    tryeval_depth: u32 = 0,
    /// Source-line breakpoint table (patched-byte → original). Set post-init by
    /// `Evaluator.initVm` when a debugger is active; read only by the
    /// `breakpoint` opcode handler, which is unreachable without a patch.
    breakpoints: ?*bytecode_mod.BreakpointTable = null,
    /// Global intern table (shared).
    intern: *InternTable,
    /// Runtime object heap.
    heap: *ObjectHeap,
    /// Evaluator-owned filesystem cache.
    files: *FileCache,
    /// Evaluator-owned network/source fetch cache.
    fetchers: *FetchCache,
    /// Evaluator-owned normalized derivation graph/cache.
    derivations: *DerivationStore,
    /// Global scheduler (for spawning work).
    scheduler: *Scheduler,
    /// Evaluator-owned error trace collector.
    trace: ?*eval_trace.Trace,
    /// The thread-safe concurrent-span half of the progress protocol
    /// (fetches, store writes, source copies). Installed on EVERY VM — it is
    /// the only progress channel available off the demand fiber. Null when
    /// progress isn't drawn.
    progress_spans: ?eval_progress.SpanSink,
    /// Fiber-scoped execution identity: claim id, demand role, and the
    /// demand-only progress handles (stage stack + "waiting on" record).
    /// Points at the owning `WorkerFiber`'s context; nested VMs created on
    /// that fiber share the pointer (see `Evaluator.initVm`), so they cannot
    /// diverge from their fiber's identity. Standalone test VMs (no fiber)
    /// point at the static neutral default. Read-only from the VM's side —
    /// only the fiber's driving worker dresses/resets it, between resumes.
    /// See `vm/exec_context.zig`.
    ctx: *const ExecutionContext = &ExecutionContext.default_instance,
    /// Optional VM execution tracer.
    vm_trace: ?*VmTrace,
    /// Optional per-thunk lifecycle event log (see `probe/thunk_trace.zig`).
    /// Recording is disabled when null. All workers share a single
    /// trace; writes serialize on its internal mutex. The field is
    /// compiled out entirely unless `-Dthunks-log` is set so the
    /// per-thunk null-check overhead doesn't burden default builds.
    thunk_trace: if (thunks_log_enabled) ?*ThunkTrace else void,
    import_host: ?ImportHost,
    /// Cached evaluator-owned builtins attrset.
    builtins: Value,
    /// GC native-builtin call depth (`-Dgc`): incremented
    /// around each native builtin, so `native_depth == 0` marks a clean
    /// safepoint where no builtin holds un-rooted Zig locals. On the VM (not a
    /// threadlocal) so it's fiber-local — a yielded fiber resuming on another
    /// thread keeps its own count. A nested import's fresh VM inherits the
    /// caller's depth (see `Evaluator.evaluateSource`).
    native_depth: u32 = 0,

    /// Where `stack`/`frames` came from and where `deinit` returns them:
    /// the evaluator's shared pool, or (null — tests, tools) `allocator`.
    buffer_pool: ?*BufferPool,
    /// The value stack. Fixed capacity = VM_STACK_CAP; `sp` is the
    /// logical length.
    stack: []Value,
    /// Stack pointer — index of the next push slot.
    sp: u32,
    /// Max value of `sp` ever observed on this VM since construction.
    /// Updated on every push/pushFrame so we can report stack
    /// high-water for sizing future VM_STACK_CAP defaults. Not reset
    /// when sp is reset between tasks (so the peak is across all tasks
    /// this VM has executed).
    sp_high_water: u32,
    /// Call frames. Fixed capacity = MAX_FRAMES; `frames_len` is the
    /// logical count.
    frames: []Frame,
    frames_len: u32,
    opcode_counts: OpcodeProfileState,
    opcode_profile_sink: OpcodeProfileSink,

    /// Demand-carrier: when this VM is currently running speculative work
    /// (a helper forcing a thunk on its own initiative), new thunks
    /// created during that run should NOT submit themselves for further
    /// speculation. That single rule bounds the cascade: a helper that
    /// picks up a speculative task does at most one layer of work before
    /// its descendants fall back to lazy. Set/cleared around speculative
    /// entry points (see `vm/force.zig`). Deliberately NOT on `ctx`:
    /// `forceValueSpeculative` flips it save/restore-style for a sub-scope
    /// of one VM's execution, so it is per-VM mutable state, not
    /// fiber-lifetime identity.
    in_speculation: bool,

    /// Demand priority inheritance (`FIX_RESCUE`): set on a SPECULATIVE
    /// fiber's VM when a demand (or already-rescued) fiber blocks waiting on
    /// a thunk THIS fiber is computing (see `Scheduler.promoteFiber`, driven
    /// from the `.busy` wait in `forceThunkImpl`). While set, this fiber's
    /// sub-forces route to the URGENT lane (so the awaited subtree spreads
    /// across idle workers instead of competing with junk in the spec lane)
    /// and it never `SpeculativeBail`s (a bail would strand the demand
    /// waiter). Cleared at each task boundary (`slotEntry`). Written from a
    /// peer thread, read here — hence atomic; advisory (a stale set only
    /// over-prioritises one task).
    demand_rescue: std.atomic.Value(u8) = .init(0),

    /// Single-worker mode (`Scheduler.worker_count == 1`, captured at VM
    /// construction — before any helper thread can exist). When set, the
    /// thunk force protocol takes the plain-load/store claim + publish
    /// variants (`Thunk.tryForceSolo`/`resolveSolo`) instead of the CAS +
    /// waiter-mutex ones: with one OS thread, fibers interleave only at
    /// yield points, so the atomic RMWs are pure tax (~1% of w=1 cycles).
    /// One predictable branch on the claim path at w>1.
    solo: bool,

    /// Bounded speculation (`FIX_SIBLING`): remaining claimed-force budget
    /// for the current speculative task. `NO_SPEC_BUDGET` (the default)
    /// disables the bound; a sibling-sweep task arms it per member force
    /// so a wrongly-predicted member cascading into a huge evaluation
    /// (`warnings`, `vmVariant`, ...) is abandoned via
    /// `error.SpeculativeBail` after at most this many claimed forces —
    /// while its already-resolved sub-thunks stay resolved (a later real
    /// demand reuses them). Decremented only on the speculative path (see
    /// `forceThunkImpl`'s claimed arm); zero cost on the demand path.
    /// Fiber-local by construction (lives on the VM, travels with the
    /// fiber across yields/steals).
    spec_budget: u64,

    /// Bounded speculation, creation side (`FIX_SIBLING` /
    /// `FIX_SPEC_CREATE_BUDGET`): REMAINING thunk-creation budget for the
    /// current speculative task. The claimed-force budget above cannot
    /// bound creation-heavy builtins (one claimed force through
    /// zipAttrsWith/mapAttrs can materialize 100Ks of thunks); this
    /// catches those on the next speculative force. `NO_SPEC_BUDGET`
    /// disables. Fiber-accurate accounting: creations are metered as
    /// deltas of the per-worker `HeapLocal.thunks_created` counter,
    /// settled lazily at each budget check (`force.specCreateExhausted`)
    /// and RE-BASED on every fiber resume (`Worker.runFiber`), so
    /// unrelated fibers interleaving on the same worker — or a migration
    /// to another worker — never burn this task's budget. (The previous
    /// absolute-limit scheme charged the task for every creation on its
    /// worker while it was parked, and treated migration as instant
    /// exhaustion: with budgets armed on all spec tasks that mass
    /// false-bailed useful speculation, measured +15-20% w=8 wall
    /// regardless of budget size.) Creations between the task's last
    /// check and a yield are dropped by the resume re-base — a small,
    /// benign undercount (checks run at every `forceValueImpl`).
    spec_create_left: u64,
    /// `HeapLocal.thunks_created` value on `spec_create_worker` at the
    /// last settle/re-base. Only meaningful while `spec_create_left !=
    /// NO_SPEC_BUDGET`.
    spec_create_snapshot: u64,
    /// Worker the creation snapshot was taken on. If a check runs on a
    /// different worker before the resume re-base has happened
    /// (defensive; runFiber re-bases first in practice), the check
    /// re-bases instead of bailing.
    spec_create_worker: u8,

    /// True only when the result will be rendered as lazy XML, where
    /// eagerly-built shapes (list/attrset/lambda) must appear unevaluated
    /// (`<unevaluated />`) until demanded. The compiler emits
    /// `thunk_shell` to wrap such values; when this is false (the
    /// common default/JSON/`.drv`/strict path) the wrap is pure overhead
    /// — millions of throwaway thunks — so the op pushes the value
    /// directly. Set per-eval from `Evaluator.lazy_shells_visible`.
    lazy_shells_visible: bool,

    /// Whether a direct `builtins.fetchTree` call is permitted (Nix's
    /// `fetch-tree` experimental feature). Set per-eval from
    /// `Evaluator.fetch_tree_enabled`; checked in the builtin dispatch.
    fetch_tree_enabled: bool,

    /// Whether the flake builtins (`getFlake`, `parseFlakeRef`,
    /// `flakeRefToString`) are permitted (Nix's `flakes` experimental
    /// feature). Set per-eval from `Evaluator.flakes_enabled`; checked in the
    /// builtin dispatch.
    flakes_enabled: bool,

    /// Logical call-depth cap (Nix's `max-call-depth`, default 10000). See
    /// `Frame.call_depth`. Set per-eval from `Evaluator.max_call_depth`.
    max_call_depth: u32,
    /// `coerce-integers` experimental feature — allow int/bool→string coercion.
    coerce_integers_enabled: bool = false,
    /// `floor-ceil-corrupt-integers` deprecated feature — `floor`/`ceil` of a
    /// precision-losing integer returns the corrupted value instead of erroring.
    allow_floor_ceil_corrupt: bool = false,
    allow_nix_path_shadow: bool = false,

    /// GC (`-Dgc`): the value currently being forced, rooted across a
    /// safepoint collection because it may be off the VM stack. `null_val`
    /// outside a collection; `void` in normal builds.
    gc_extra_root: if (build_options.gc) Value else void = if (build_options.gc) Value.null_val else {},

    /// GC (`-Dgc`): the chain of thunks currently being forced on this
    /// fiber (A forces B forces C …). Each is claimed/`.evaluating` and off
    /// the operand stack while its body runs, so without this a collection
    /// triggered by a nested force would sweep the outer in-flight thunks
    /// (and their target closures). Marked as roots. `void` in normal builds.
    gc_force_chain: if (build_options.gc) std.ArrayListUnmanaged(types.ObjectId) else void = if (build_options.gc) .empty else {},

    /// GC (`-Dgc`): heap containers a native builtin holds as a raw store
    /// slice across a force (e.g. `heap.getList(id)` after the list `Value`
    /// goes dead). The conservative running-fiber scan sees `Value`-shaped
    /// locals but cannot recover an object from a raw interior pointer, so an
    /// iterating builtin pushes the container here for its loop's duration —
    /// keeping it, and thus its not-yet-visited elements, alive across a
    /// collection triggered mid-loop. Marked as roots; scoped via
    /// `force.gcRootsMark`/`gcRootsRestore`. `void` in normal builds.
    gc_temp_roots: if (build_options.gc) std.ArrayListUnmanaged(Value) else void = if (build_options.gc) .empty else {},

    pub fn init(
        allocator: std.mem.Allocator,
        buffer_pool: ?*BufferPool,
        registry: *ChunkRegistry,
        intern: *InternTable,
        heap: *ObjectHeap,
        files: *FileCache,
        fetchers: *FetchCache,
        derivations: *DerivationStore,
        scheduler: *Scheduler,
        trace_sink: ?*eval_trace.Trace,
        progress_spans: ?eval_progress.SpanSink,
        vm_trace: ?*VmTrace,
        thunk_trace: if (thunks_log_enabled) ?*ThunkTrace else void,
        import_host: ?ImportHost,
        builtins_value: Value,
        opcode_profile_sink: OpcodeProfileSink,
    ) !VM {
        const bufs: BufferPool.Buffers = if (buffer_pool) |bp| try bp.acquire() else blk: {
            const value_stack = try allocator.alloc(Value, types.VM_STACK_CAP);
            errdefer allocator.free(value_stack);
            const frames = try allocator.alloc(Frame, types.MAX_FRAMES);
            break :blk .{ .stack = value_stack, .frames = frames };
        };
        const value_stack = bufs.stack;
        const frames = bufs.frames;

        return .{
            .allocator = allocator,
            .registry = registry,
            .intern = intern,
            .heap = heap,
            .files = files,
            .fetchers = fetchers,
            .derivations = derivations,
            .scheduler = scheduler,
            .trace = trace_sink,
            .progress_spans = progress_spans,
            .vm_trace = vm_trace,
            .thunk_trace = thunk_trace,
            .import_host = import_host,
            .builtins = builtins_value,
            // `ctx` keeps its neutral default here; Worker.allocateFiber
            // repoints it at the fiber's own context (with the fiber's
            // claim id baked in) before the VM runs anything, and
            // Evaluator.initVm repoints nested VMs at the surrounding
            // fiber's context.
            .buffer_pool = buffer_pool,
            .stack = value_stack,
            .sp = 0,
            .sp_high_water = 0,
            .frames = frames,
            .frames_len = 0,
            .opcode_counts = if (opcode_profile_enabled) [_]u64{0} ** opcode.count else {},
            .opcode_profile_sink = opcode_profile_sink,
            .in_speculation = false,
            .solo = scheduler.worker_count == 1,
            .spec_budget = NO_SPEC_BUDGET,
            .spec_create_left = NO_SPEC_BUDGET,
            .spec_create_snapshot = 0,
            .spec_create_worker = 0,
            .lazy_shells_visible = false,
            .fetch_tree_enabled = false,
            .flakes_enabled = false,
            .max_call_depth = types.DEFAULT_MAX_CALL_DEPTH,
        };
    }

    /// The OS-thread-current worker id. Reads the threadlocal set by
    /// `Worker.run` / `Worker.runTopLevel`. Use this anywhere code
    /// needs to know "who is executing right now" — not a stored field
    /// because fibers migrate across workers (F1.4).
    pub inline fn workerId(self: *const VM) u8 {
        _ = self;
        return worker_id_mod.current;
    }

    /// The owner is about to reset the arena backing `allocator` (fiber
    /// recycle — see WorkerFiber.recycleScratch): drop any capacity this
    /// VM retains there. The lists are logically empty between tasks
    /// (roots/chains are scoped to a force); only their capacity lives on.
    pub fn onScratchReset(self: *VM) void {
        if (comptime build_options.gc) {
            std.debug.assert(self.gc_force_chain.items.len == 0);
            std.debug.assert(self.gc_temp_roots.items.len == 0);
            self.gc_force_chain = .empty;
            self.gc_temp_roots = .empty;
        }
    }

    /// Report `[completed/total]` on the current render/stage node. Demand
    /// path only by construction: `progress_stage` exists solely on the
    /// demand fiber's ExecutionContext (helper fibers hold null), so
    /// speculative walks stay invisible and this is free unless progress is
    /// drawn. Cheap: a field check + one atomic store in the sink → node.
    /// See `vm/force.zig` `forceDeepCounted`.
    pub fn progressCount(self: *VM, completed: usize, total: usize) void {
        if (self.ctx.progress_stage) |stage| stage.count(completed, total);
    }

    pub fn deinit(self: *VM) void {
        if (comptime opcode_profile_enabled) flushOpcodeProfile(self);
        if (comptime build_options.gc) self.gc_force_chain.deinit(self.allocator);
        if (comptime build_options.gc) self.gc_temp_roots.deinit(self.allocator);
        if (self.buffer_pool) |bp| {
            bp.release(.{ .stack = self.stack, .frames = self.frames });
        } else {
            self.allocator.free(self.stack);
            self.allocator.free(self.frames);
        }
    }

    /// Evaluate a chunk and return its result.
    pub fn eval(self: *VM, chunk_id: ChunkId) !Value {
        const ch = self.registry.get(chunk_id) orelse return error.InvalidChunk;

        // Push initial frame (passthrough: the top-level expression is not
        // itself a function application, so it starts the call chain at 0).
        try stack.pushFrame(self, ch, chunk_id, 0, null, false);
        return run.run(self) catch |err| {
            errors.captureErrorTrace(self, err) catch {};
            return err;
        };
    }
};

fn flushOpcodeProfile(self: *VM) void {
    if (comptime opcode_profile_enabled) {
        for (&self.opcode_profile_sink.*, self.opcode_counts) |*total, count| {
            total.* += count;
        }
    }
}

// ---- free functions (don't take self) ----

pub fn readU16(code: []const u8, ip: usize) u16 {
    return bytecode_mod.readU16(code, ip);
}

pub fn readU32(code: []const u8, ip: usize) u32 {
    return bytecode_mod.readU32(code, ip);
}

pub fn readInternId(code: []const u8, ip: usize, wide: bool) InternId {
    return bytecode_mod.readInternId(code, ip, wide);
}
