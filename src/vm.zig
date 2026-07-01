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
const bytecode_mod = @import("bytecode.zig");
const opcode = bytecode_mod.opcode;
const build_options = @import("build_options");
const chunk = bytecode_mod.chunk;
const Chunk = chunk.Chunk;
const ChunkRegistry = chunk.ChunkRegistry;
const InternTable = @import("runtime").intern.InternTable;
const Scheduler = @import("parallel").scheduler.Scheduler;
const heap_mod = @import("runtime").heap;
const ObjectHeap = heap_mod.ObjectHeap;
const FileCache = @import("runtime").file_cache.FileCache;
const FetchCache = @import("runtime").fetch_cache.FetchCache;
const DerivationStore = @import("derivation").DerivationStore;
const eval_trace = @import("support/trace.zig");
const eval_progress = @import("eval/progress.zig");
const VmTrace = @import("vm/trace_log.zig").VmTrace;
const thunk_mod = @import("runtime").thunk;
const worker_id_mod = @import("runtime").worker_id;
const tjit_record = @import("jit/record.zig");
const DeferredTable = @import("compiler/deferred_table.zig").Table;
const ThunkTrace = @import("probe/thunk_trace.zig").ThunkTrace;

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

pub const opcode_profile_enabled = build_options.vm_opcode_profile;
pub const thunks_log_enabled = build_options.thunks_log;
pub const OpcodeCounts = [opcode.count]u64;
const OpcodeProfileSink = if (opcode_profile_enabled) *OpcodeCounts else void;
const OpcodeProfileState = if (opcode_profile_enabled) OpcodeCounts else void;

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
};

pub const ImportHost = struct {
    context: *anyopaque,
    import_value: *const fn (*anyopaque, []const u8) anyerror!Value,
    scoped_import: *const fn (*anyopaque, Value, []const u8) anyerror!Value,
    find_file: *const fn (*anyopaque, []const u8) anyerror!Value,
    get_env: *const fn (*anyopaque, []const u8) anyerror![]const u8,
};

/// Per-thread VM state. Each worker thread has one of these.
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
    /// Tracing-JIT (`-Dtjit`) per-VM recording state, or null when not
    /// recording. Typed `?*anyopaque` (cast in `jit/record.zig`) to avoid a
    /// vm↔tjit import cycle. Untouched in non-tjit builds (hot-path accesses
    /// are comptime-gated).
    tjit_rec: ?*anyopaque = null,
    /// Anchor upvalues of the currently-executing native trace, so a native
    /// `side_exit` (which only gets the upvalues *pointer* via the ABI, not the
    /// length) can reconstruct the anchor frame. Set/restored around each native
    /// call in `jit/exec.zig`; only meaningful mid native-trace.
    native_upvalues: []const Value = &.{},
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
    /// Evaluator-owned progress sink.
    progress: ?eval_progress.Sink,
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
    /// Globally-unique fiber id this VM is bound to. Used as the
    /// `ClaimerId` for thunk forces. Worker patches this when binding
    /// the VM to a fiber.
    claimer_id: thunk_mod.ClaimerId,

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
    /// entry points (see `vm/force.zig`).
    in_speculation: bool,

    /// True only when the result will be rendered as lazy XML, where
    /// eagerly-built shapes (list/attrset/lambda) must appear unevaluated
    /// (`<unevaluated />`) until demanded. The compiler emits
    /// `make_lazy_shell` to wrap such values; when this is false (the
    /// common default/JSON/`.drv`/strict path) the wrap is pure overhead
    /// — millions of throwaway thunks — so the op pushes the value
    /// directly. Set per-eval from `Evaluator.lazy_shells_visible`.
    lazy_shells_visible: bool,

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

    pub fn init(
        allocator: std.mem.Allocator,
        registry: *ChunkRegistry,
        intern: *InternTable,
        heap: *ObjectHeap,
        files: *FileCache,
        fetchers: *FetchCache,
        derivations: *DerivationStore,
        scheduler: *Scheduler,
        trace_sink: ?*eval_trace.Trace,
        progress: ?eval_progress.Sink,
        vm_trace: ?*VmTrace,
        thunk_trace: if (thunks_log_enabled) ?*ThunkTrace else void,
        import_host: ?ImportHost,
        builtins_value: Value,
        opcode_profile_sink: OpcodeProfileSink,
    ) !VM {
        const value_stack = try allocator.alloc(Value, types.VM_STACK_CAP);
        errdefer allocator.free(value_stack);

        const frames = try allocator.alloc(Frame, types.MAX_FRAMES);
        errdefer allocator.free(frames);

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
            .progress = progress,
            .vm_trace = vm_trace,
            .thunk_trace = thunk_trace,
            .import_host = import_host,
            .builtins = builtins_value,
            // Placeholder; overwritten by Worker.allocateFiber with the
            // fiber's globally-allocated id before the VM runs anything.
            .claimer_id = thunk_mod.INVALID_CLAIMER,
            .stack = value_stack,
            .sp = 0,
            .sp_high_water = 0,
            .frames = frames,
            .frames_len = 0,
            .opcode_counts = if (opcode_profile_enabled) [_]u64{0} ** opcode.count else {},
            .opcode_profile_sink = opcode_profile_sink,
            .in_speculation = false,
            .lazy_shells_visible = false,
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

    pub fn deinit(self: *VM) void {
        if (comptime opcode_profile_enabled) flushOpcodeProfile(self);
        if (comptime tjit_record.enabled) tjit_record.cleanup(self);
        if (comptime build_options.gc) self.gc_force_chain.deinit(self.allocator);
        self.allocator.free(self.stack);
        self.allocator.free(self.frames);
    }

    /// Evaluate a chunk and return its result.
    pub fn eval(self: *VM, chunk_id: ChunkId) !Value {
        const ch = self.registry.get(chunk_id) orelse return error.InvalidChunk;

        // Push initial frame.
        try stack.pushFrame(self, ch, chunk_id, 0, null);
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
