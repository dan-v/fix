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
const types = @import("runtime/types.zig");
const Value = @import("runtime/value.zig").Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const bytecode_mod = @import("bytecode.zig");
const opcode = bytecode_mod.opcode;
const build_options = @import("build_options");
const chunk = bytecode_mod.chunk;
const Chunk = chunk.Chunk;
const ChunkRegistry = chunk.ChunkRegistry;
const InternTable = @import("runtime/intern.zig").InternTable;
const Scheduler = @import("scheduler.zig").Scheduler;
const heap_mod = @import("runtime/heap.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const FileCache = @import("file_cache.zig").FileCache;
const FetchCache = @import("fetch_cache.zig").FetchCache;
const DerivationStore = @import("derivation.zig").DerivationStore;
const eval_trace = @import("eval/trace.zig");
const eval_progress = @import("eval/progress.zig");

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

pub const opcode_profile_enabled = build_options.vm_opcode_profile;
pub const OpcodeCounts = [opcode.count]u64;
const OpcodeProfileSink = if (opcode_profile_enabled) *OpcodeCounts else void;
const OpcodeProfileState = if (opcode_profile_enabled) OpcodeCounts else void;

/// A single call frame.
pub const Frame = struct {
    /// The chunk being executed.
    chunk_ptr: *const Chunk,
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
    /// Global chunk registry (shared across all VMs).
    registry: *const ChunkRegistry,
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
    import_host: ?ImportHost,
    /// Cached evaluator-owned builtins attrset.
    builtins: Value,
    /// This VM's worker index.
    worker_id: u8,

    /// The value stack.
    stack: std.ArrayListUnmanaged(Value),
    /// Stack pointer (index into stack.items for next push).
    sp: u32,
    /// Call frames.
    frames: std.ArrayListUnmanaged(Frame),
    opcode_counts: OpcodeProfileState,
    opcode_profile_sink: OpcodeProfileSink,

    pub fn init(
        allocator: std.mem.Allocator,
        registry: *const ChunkRegistry,
        intern: *InternTable,
        heap: *ObjectHeap,
        files: *FileCache,
        fetchers: *FetchCache,
        derivations: *DerivationStore,
        scheduler: *Scheduler,
        trace_sink: ?*eval_trace.Trace,
        progress: ?eval_progress.Sink,
        import_host: ?ImportHost,
        builtins_value: Value,
        worker_id: u8,
        opcode_profile_sink: OpcodeProfileSink,
    ) !VM {
        var value_stack = try std.ArrayListUnmanaged(Value).initCapacity(allocator, types.VM_STACK_CAP);
        value_stack.items.len = types.VM_STACK_CAP;
        errdefer value_stack.deinit(allocator);

        var frames = try std.ArrayListUnmanaged(Frame).initCapacity(allocator, types.MAX_FRAMES);
        errdefer frames.deinit(allocator);

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
            .import_host = import_host,
            .builtins = builtins_value,
            .worker_id = worker_id,
            .stack = value_stack,
            .sp = 0,
            .frames = frames,
            .opcode_counts = if (opcode_profile_enabled) [_]u64{0} ** opcode.count else {},
            .opcode_profile_sink = opcode_profile_sink,
        };
    }

    pub fn deinit(self: *VM) void {
        if (comptime opcode_profile_enabled) flushOpcodeProfile(self);
        self.stack.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    /// Evaluate a chunk and return its result.
    pub fn eval(self: *VM, chunk_id: ChunkId) !Value {
        const ch = self.registry.get(chunk_id) orelse return error.InvalidChunk;

        // Push initial frame.
        try stack.pushFrame(self, ch, 0, null);
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
