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
const bytecode_mod = @import("../bytecode.zig");
const build_options = @import("build_options");
const chunk = bytecode_mod.chunk;
const Chunk = chunk.Chunk;
const ChunkRegistry = chunk.ChunkRegistry;
const InternTable = @import("runtime").intern.InternTable;
const Scheduler = @import("../eval/workers/scheduler.zig").Scheduler;
const heap_mod = @import("runtime").heap;
const ObjectHeap = heap_mod.ObjectHeap;
const FileCache = @import("store").FileCache;
const FetchCache = @import("fetchers").FetchCache;
const RealizationStore = @import("store").RealizationStore;
const eval_trace = @import("../observ.zig").trace;
const observ = @import("base").observ;
const VmTrace = @import("trace_log.zig").VmTrace;
const worker_id_mod = @import("base").worker_id;
const DeferredTable = @import("../compiler/deferred_table.zig").Table;
const ChunkRegistrationSink = @import("../compiler/context.zig").ChunkRegistrationSink;
const ThunkTrace = @import("../probe.zig").thunk_trace.ThunkTrace;
const LanguagePolicy = @import("../policy.zig").LanguagePolicy;

pub const exec_context = @import("../eval/workers/context.zig");
pub const ExecutionContext = exec_context.ExecutionContext;

pub const thunks_log_enabled = build_options.thunks_log;
const SpinMutex = @import("base").sync.SpinMutex;
const vma = @import("runtime").mem_tag.vma;
const PatternCache = @import("../support.zig").regex.PatternCache;
const FiberExecutor = @import("../eval/workers/port.zig").FiberExecutor;

pub const Driver = struct {
    eval: *const fn (*VM, ChunkId) anyerror!Value,
};

/// Reusable VM buffers — the value stack + frame stack, the two large
/// per-VM allocations (~0.5 MB together). Pooled by the evaluator:
/// nested import VMs are created ~2.6K times per NixOS eval, and each
/// used to bump-allocate a fresh stack out of the worker arena that was
/// then "freed" into the void (arena free is a no-op) — ~245 MB of
/// once-touched, never-reused pages at w=1. Reuse keeps the working set
/// at the max-concurrent-VM high-water instead, and stops the re-fault
/// churn. Buffers come back dirty; that's fine — every consumer is
/// bounded by `sp`/`frames_len`, including the GC's stack scan
/// (eval/gc_controller.zig marks `stack[0..sp]`).
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
        const value_stack = try self.allocator.alloc(Value, types.vm_stack_capacity);
        errdefer self.allocator.free(value_stack);
        const frames = try self.allocator.alloc(Frame, types.max_frames);
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
    import_value: *const fn (*anyopaque, *VM, []const u8, u32) anyerror!Value,
    scoped_import: *const fn (*anyopaque, *VM, Value, []const u8, u32) anyerror!Value,
    find_file: *const fn (*anyopaque, []const u8) anyerror!Value,
    get_env: *const fn (*anyopaque, []const u8) anyerror![]const u8,
};

/// Why evaluation paused into the debugger. `entry` is the one-shot stop at
/// the start of a `:debug` expression; `break_builtin` is a `builtins.break x`
/// call; `line_breakpoint` is a patched source-line breakpoint; `step` is a
/// completed single-step; `return_step` is the virtual stop after a stepped
/// frame has returned to its caller; `eval_error` is an evaluation error caught
/// with `--debugger`.
pub const BreakReason = enum { entry, break_builtin, line_breakpoint, step, return_step, eval_error };

/// A debugger attachment. Installed on every VM by `Evaluator.initVm` when a
/// debugger is active; null (the default) means "no debugger" and ordinary
/// return paths pay only one unlikely null check.
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
pub const no_spec_budget: u64 = std.math.maxInt(u64);

pub const VM = struct {
    driver: *const Driver,
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
    registration_sink: ?ChunkRegistrationSink = null,
    /// Evaluator-owned compiled-regex cache for `builtins.match`/`split`
    /// (see `support/regex.zig`). Set post-init by
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
    /// Synchronous import VMs form a debugger-only parent chain back to the
    /// VM containing the `import` call. The parent outlives this nested VM;
    /// normal execution never reads the link.
    debug_parent: ?*VM = null,
    /// Select the debugger's fresh import memo table. This is carried by the
    /// VM rather than the Evaluator so older helper VMs can safely finish a
    /// normal evaluation while a serial debugger replay begins.
    debug_import_replay: bool = false,
    /// Global intern table (shared).
    intern: *InternTable,
    /// Runtime object heap.
    heap: *ObjectHeap,
    /// Evaluator-owned filesystem cache.
    files: *FileCache,
    /// Evaluator-owned network/source fetch cache.
    fetchers: *FetchCache,
    /// Evaluator-owned realization service for recipes, store I/O, and builds.
    realization: *RealizationStore,
    /// Global scheduler (for spawning work).
    scheduler: *Scheduler,
    /// Evaluator-owned error trace collector.
    trace: ?*eval_trace.Trace,
    /// Evaluator-scoped structured observation capability. Disabled handles
    /// are cheap values and all workers may use an enabled handle safely.
    observer: observ.Observer,
    /// Fiber-aware blocking capability supplied by the evaluator. Standalone
    /// VMs leave this null and execute blocking work inline.
    executor: ?FiberExecutor,
    /// Fiber-scoped execution identity: claim id and demand role.
    /// Points at the owning `WorkerFiber`'s context; nested VMs created on
    /// that fiber share the pointer (see `Evaluator.initVm`), so they cannot
    /// diverge from their fiber's identity. Standalone test VMs (no fiber)
    /// point at the static neutral default. Read-only from the VM's side —
    /// only the fiber's driving worker dresses/resets it, between resumes.
    /// See `eval/workers/context.zig`.
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
    /// GC native-builtin call depth: incremented
    /// around each native builtin, so `native_depth == 0` marks a clean
    /// safepoint where no builtin holds un-rooted Zig locals. On the VM (not a
    /// threadlocal) so it's fiber-local — a yielded fiber resuming on another
    /// thread keeps its own count. A nested import's fresh VM inherits the
    /// caller's depth (see `Evaluator.evaluateSource`).
    native_depth: u32 = 0,

    /// Where `stack`/`frames` came from and where `deinit` returns them:
    /// the evaluator's shared pool, or (null — tests, tools) `allocator`.
    buffer_pool: ?*BufferPool,
    /// The value stack. Fixed capacity = vm_stack_capacity; `sp` is the
    /// logical length.
    stack: []Value,
    /// Stack pointer — index of the next push slot.
    sp: u32,
    /// Max value of `sp` ever observed on this VM since construction.
    /// Updated on every push/pushFrame so we can report stack
    /// high-water for sizing future vm_stack_capacity defaults. Not reset
    /// when sp is reset between tasks (so the peak is across all tasks
    /// this VM has executed).
    sp_high_water: u32,
    /// Call frames. Fixed capacity = max_frames; `frames_len` is the
    /// logical count.
    frames: []Frame,
    frames_len: u32,
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
    /// for the current speculative task. `no_spec_budget` (the default)
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

    /// Bounded speculation, creation side (`FIX_SIBLING` / band budget):
    /// REMAINING thunk-creation budget for the
    /// current speculative task. The claimed-force budget above cannot
    /// bound creation-heavy builtins (one claimed force through
    /// zipAttrsWith/mapAttrs can materialize 100Ks of thunks); this
    /// catches those on the next speculative force. `no_spec_budget`
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
    /// no_spec_budget`.
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

    /// The same compatibility policy used to parse and compile this code.
    policy: LanguagePolicy,

    /// GC: the value currently being forced, rooted across a
    /// safepoint collection because it may be off the VM stack. `null_val`
    /// outside a collection.
    gc_extra_root: Value = Value.null_val,

    /// GC: the chain of thunks currently being forced on this
    /// fiber (A forces B forces C …). Each is claimed/`.evaluating` and off
    /// the operand stack while its body runs, so without this a collection
    /// triggered by a nested force would sweep the outer in-flight thunks
    /// (and their target closures). Marked as roots.
    gc_force_chain: std.ArrayListUnmanaged(types.ObjectId) = .empty,

    /// GC: heap containers a native builtin holds as a raw store
    /// slice across a force (e.g. `heap.getList(id)` after the list `Value`
    /// goes dead). The conservative running-fiber scan sees `Value`-shaped
    /// locals but cannot recover an object from a raw interior pointer, so an
    /// iterating builtin pushes the container here for its loop's duration —
    /// keeping it, and thus its not-yet-visited elements, alive across a
    /// collection triggered mid-loop. Marked as roots; scoped via
    /// `force.gcRootsMark`/`gcRootsRestore`.
    gc_temp_roots: std.ArrayListUnmanaged(Value) = .empty,

    pub const Init = struct {
        driver: *const Driver,
        allocator: std.mem.Allocator,
        buffer_pool: ?*BufferPool = null,
        registry: *ChunkRegistry,
        intern: *InternTable,
        heap: *ObjectHeap,
        files: *FileCache,
        fetchers: *FetchCache,
        realization: *RealizationStore,
        scheduler: *Scheduler,
        trace_sink: ?*eval_trace.Trace = null,
        observer: observ.Observer = .{},
        executor: ?FiberExecutor = null,
        vm_trace: ?*VmTrace = null,
        thunk_trace: if (thunks_log_enabled) ?*ThunkTrace else void = if (thunks_log_enabled) null else {},
        import_host: ?ImportHost = null,
        builtins_value: Value = Value.null_val,
        deferred_table: ?*DeferredTable = null,
        registration_sink: ?ChunkRegistrationSink = null,
        regexes: ?*PatternCache = null,
        break_sink: ?BreakSink = null,
        breakpoints: ?*bytecode_mod.BreakpointTable = null,
        policy: LanguagePolicy = .{},
        lazy_shells_visible: bool = false,
    };

    pub fn init(options: Init) !VM {
        const bufs: BufferPool.Buffers = if (options.buffer_pool) |bp| try bp.acquire() else blk: {
            const value_stack = try options.allocator.alloc(Value, types.vm_stack_capacity);
            errdefer options.allocator.free(value_stack);
            const frames = try options.allocator.alloc(Frame, types.max_frames);
            break :blk .{ .stack = value_stack, .frames = frames };
        };
        const value_stack = bufs.stack;
        const frames = bufs.frames;

        return .{
            .driver = options.driver,
            .allocator = options.allocator,
            .registry = options.registry,
            .deferred_table = options.deferred_table,
            .registration_sink = options.registration_sink,
            .regexes = options.regexes,
            .break_sink = options.break_sink,
            .breakpoints = options.breakpoints,
            .intern = options.intern,
            .heap = options.heap,
            .files = options.files,
            .fetchers = options.fetchers,
            .realization = options.realization,
            .scheduler = options.scheduler,
            .trace = options.trace_sink,
            .observer = options.observer,
            .executor = options.executor,
            .vm_trace = options.vm_trace,
            .thunk_trace = options.thunk_trace,
            .import_host = options.import_host,
            .builtins = options.builtins_value,
            // `ctx` keeps its neutral default here; Worker.allocateFiber
            // repoints it at the fiber's own context (with the fiber's
            // claim id baked in) before the VM runs anything, and
            // Evaluator.initVm repoints nested VMs at the surrounding
            // fiber's context.
            .buffer_pool = options.buffer_pool,
            .stack = value_stack,
            .sp = 0,
            .sp_high_water = 0,
            .frames = frames,
            .frames_len = 0,
            .in_speculation = false,
            .solo = options.scheduler.worker_count == 1,
            .spec_budget = no_spec_budget,
            .spec_create_left = no_spec_budget,
            .spec_create_snapshot = 0,
            .spec_create_worker = 0,
            .lazy_shells_visible = options.lazy_shells_visible,
            .policy = options.policy,
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

    /// Physical frames across the synchronous import-parent chain. Used only
    /// by patched debugger traps, so normal dispatch does not pay for it.
    pub fn debugFrameDepth(self: *const VM) u32 {
        var total = self.frames_len;
        var cursor = self.debug_parent;
        while (cursor) |parent| : (cursor = parent.debug_parent) total += parent.frames_len;
        return total;
    }

    /// The owner is about to reset the arena backing `allocator` (fiber
    /// recycle — see WorkerFiber.recycleScratch): drop any capacity this
    /// VM retains there. The lists are logically empty between tasks
    /// (roots/chains are scoped to a force); only their capacity lives on.
    pub fn onScratchReset(self: *VM) void {
        std.debug.assert(self.gc_force_chain.items.len == 0);
        std.debug.assert(self.gc_temp_roots.items.len == 0);
        self.gc_force_chain = .empty;
        self.gc_temp_roots = .empty;
    }

    pub fn deinit(self: *VM) void {
        self.gc_force_chain.deinit(self.allocator);
        self.gc_temp_roots.deinit(self.allocator);
        if (self.buffer_pool) |bp| {
            bp.release(.{ .stack = self.stack, .frames = self.frames });
        } else {
            self.allocator.free(self.stack);
            self.allocator.free(self.frames);
        }
    }

    /// Evaluate a chunk and return its result.
    pub fn eval(self: *VM, chunk_id: ChunkId) !Value {
        return self.driver.eval(self, chunk_id);
    }
};

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
