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
const types = @import("types.zig");
const Value = @import("value.zig").Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const ObjectId = types.ObjectId;
const bytecode_mod = @import("bytecode.zig");
const opcode = @import("opcode.zig");
const OpCode = opcode.OpCode;
const build_options = @import("build_options");
const chunk = @import("chunk.zig");
const Chunk = chunk.Chunk;
const ChunkRegistry = chunk.ChunkRegistry;
const InternTable = @import("intern.zig").InternTable;
const thunk_mod = @import("thunk.zig");
const Thunk = thunk_mod.Thunk;
const ThunkTarget = thunk_mod.ThunkTarget;
const Scheduler = @import("scheduler.zig").Scheduler;
const heap_mod = @import("heap.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const Closure = heap_mod.Closure;
const FileCache = @import("file_cache.zig").FileCache;
const FetchCache = @import("fetch_cache.zig").FetchCache;
const DerivationStore = @import("derivation.zig").DerivationStore;
const numeric = @import("runtime/numeric.zig");
const source_paths = @import("runtime/source_path.zig");
const vm_builtins = @import("vm/builtins.zig");
const vm_run = @import("vm/run.zig");
const vm_equality = @import("vm/equality.zig");
const vm_force = @import("vm/force.zig");
const vm_objects = @import("vm/objects.zig");
const vm_strings = @import("vm/strings.zig");
const vm_closures = @import("vm/closures.zig");
const vm_errors = @import("vm/errors.zig");
const vm_access = @import("vm/access.zig");
const eval_trace = @import("eval_trace.zig");
const eval_progress = @import("eval_progress.zig");
const diagnostic = @import("diagnostic.zig");

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
        trace: ?*eval_trace.Trace,
        progress: ?eval_progress.Sink,
        import_host: ?ImportHost,
        builtins: Value,
        worker_id: u8,
        opcode_profile_sink: OpcodeProfileSink,
    ) !VM {
        var stack = try std.ArrayListUnmanaged(Value).initCapacity(allocator, types.VM_STACK_CAP);
        stack.items.len = types.VM_STACK_CAP;
        errdefer stack.deinit(allocator);

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
            .trace = trace,
            .progress = progress,
            .import_host = import_host,
            .builtins = builtins,
            .worker_id = worker_id,
            .stack = stack,
            .sp = 0,
            .frames = frames,
            .opcode_counts = if (opcode_profile_enabled) [_]u64{0} ** opcode.count else {},
            .opcode_profile_sink = opcode_profile_sink,
        };
    }

    pub fn deinit(self: *VM) void {
        if (comptime opcode_profile_enabled) self.flushOpcodeProfile();
        self.stack.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    fn flushOpcodeProfile(self: *VM) void {
        if (comptime opcode_profile_enabled) {
            for (&self.opcode_profile_sink.*, self.opcode_counts) |*total, count| {
                total.* += count;
            }
        }
    }

    // ---- public entry ----

    /// Evaluate a chunk and return its result.
    pub fn eval(self: *VM, chunk_id: ChunkId) !Value {
        const ch = self.registry.get(chunk_id) orelse return error.InvalidChunk;

        // Push initial frame.
        try self.pushFrame(ch, 0, null);
        return self.run() catch |err| {
            self.captureErrorTrace(err) catch {};
            return err;
        };
    }

    pub fn forceListItem(self: *VM, list_val: Value, index: usize) !Value {
        if (list_val.discriminant != .list) return error.TypeError;
        return self.forceValue(try self.heap.getListItem(list_val.asObjectId(), index));
    }

    pub fn writeJsonValue(self: *VM, writer: *std.Io.Writer, value: Value) !void {
        try vm_builtins.writeJsonValue(self, writer, value);
    }

    pub fn writeXmlValue(self: *VM, writer: *std.Io.Writer, value: Value) !void {
        try vm_builtins.writeLazyXmlValue(self, writer, value);
    }

    pub fn setErrorMessage(self: *VM, message: []const u8) !void {
        if (self.trace) |trace| try trace.setMessage(message);
    }

    pub fn pushErrorContext(self: *VM, message: []const u8) !void {
        if (self.trace) |trace| try trace.pushFrame(message);
    }

    pub fn clearErrorTrace(self: *VM) void {
        if (self.trace) |trace| trace.clear();
    }

    pub fn typeErrorExpected(self: *VM, expected: []const u8, got: Value) error{TypeError} {
        if (self.trace) |trace| {
            const message = std.fmt.allocPrint(self.allocator, "expected {s}, got {s}", .{ expected, self.valueTypeName(got) }) catch return error.TypeError;
            defer self.allocator.free(message);
            trace.setMessageIfAbsent(message) catch {};
        }
        return error.TypeError;
    }

    pub fn notCallableError(self: *VM, got: Value) error{NotCallable} {
        if (self.trace) |trace| {
            const message = std.fmt.allocPrint(self.allocator, "expected function, got {s}", .{self.valueTypeName(got)}) catch return error.NotCallable;
            defer self.allocator.free(message);
            trace.setMessageIfAbsent(message) catch {};
        }
        return error.NotCallable;
    }

    pub fn valueTypeName(self: *VM, value: Value) []const u8 {
        _ = self;
        return switch (value.discriminant) {
            .null => "null",
            .bool_false, .bool_true => "bool",
            .int => "int",
            .float => "float",
            .string => "string",
            .path => "path",
            .list => "list",
            .attrs => "attrs",
            .closure, .builtin, .builtin_closure => "function",
            .thunk => "thunk",
            .cell => "cell",
            .string_context => "string",
        };
    }

    // ---- frame management ----

    pub fn pushFrame(self: *VM, ch: *const Chunk, arg_count: u32, upvalues: ?[]const Value) !void {
        if (self.frames.items.len >= types.MAX_FRAMES) return error.FrameOverflow;
        if (arg_count > ch.local_count) return error.InvalidCallFrame;
        const frame_base = self.sp - arg_count;
        const reserved = @as(u32, ch.local_count) - arg_count;

        // Stack and frame buffers are preallocated in init; reserve hot-path
        // slots directly instead of re-entering ArrayList growth checks.
        const stack_cap: u32 = @intCast(types.VM_STACK_CAP);
        if (reserved > stack_cap - self.sp) return error.StackOverflow;
        const start = self.sp;
        const new_sp = start + reserved;
        const start_idx: usize = @intCast(start);
        const new_sp_idx: usize = @intCast(new_sp);
        @memset(self.stack.items[start_idx..new_sp_idx], Value.null_val);
        self.sp = new_sp;

        const frame_index = self.frames.items.len;
        self.frames.items.len = frame_index + 1;
        self.frames.items[frame_index] = .{
            .chunk_ptr = ch,
            .ip = 0,
            .frame_base = frame_base,
            .local_count = ch.local_count,
            .upvalues = upvalues,
        };
    }

    pub fn popFrame(self: *VM) Frame {
        return self.frames.pop().?;
    }

    pub fn currentFrame(self: *VM) *Frame {
        return &self.frames.items[self.frames.items.len - 1];
    }

    // ---- stack ops ----

    pub fn push(self: *VM, val: Value) !void {
        if (@as(usize, self.sp) >= types.VM_STACK_CAP) return error.StackOverflow;
        const index: usize = @intCast(self.sp);
        self.stack.items[index] = val;
        self.sp += 1;
    }

    pub fn pop(self: *VM) Value {
        self.sp -= 1;
        return self.stack.items[self.sp];
    }

    pub fn setStack(self: *VM, idx: u32, val: Value) void {
        self.stack.items[idx] = val;
    }

    // ---- split method groups ----
    // execution
    pub const run = vm_run.run;
    pub const runUntil = vm_run.runUntil;
    pub const expectBool = vm_run.expectBool;

    // equality
    pub const EqualityPair = vm_equality.EqualityPair;
    pub const CompareResult = vm_equality.CompareResult;
    pub const valuesEqual = vm_equality.valuesEqual;
    pub const listContainsValue = vm_equality.listContainsValue;
    pub const valueSliceContainsForcedValue = vm_equality.valueSliceContainsForcedValue;
    pub const valuesEqualSeen = vm_equality.valuesEqualSeen;
    pub const valuesEqualSeenForcedLeft = vm_equality.valuesEqualSeenForcedLeft;
    pub const valuesEqualForced = vm_equality.valuesEqualForced;
    pub const listsEqual = vm_equality.listsEqual;
    pub const attrsEqual = vm_equality.attrsEqual;
    pub const derivationAttrsEqual = vm_equality.derivationAttrsEqual;
    pub const attrsHaveDerivationType = vm_equality.attrsHaveDerivationType;
    pub const equalityPairSeen = vm_equality.equalityPairSeen;
    pub const compareValues = vm_equality.compareValues;

    // forcing
    pub const SeenDeepKind = vm_force.SeenDeepKind;
    pub const SeenDeepObject = vm_force.SeenDeepObject;
    pub const forceThunk = vm_force.forceThunk;
    pub const forceValue = vm_force.forceValue;
    pub const forceCellValue = vm_force.forceCellValue;
    pub const forceDeep = vm_force.forceDeep;
    pub const forceDeepInner = vm_force.forceDeepInner;
    pub const enterDeep = vm_force.enterDeep;
    pub const forceThunkFallible = vm_force.forceThunkFallible;
    pub const evalThunkTarget = vm_force.evalThunkTarget;
    pub const evalThunkClosure = vm_force.evalThunkClosure;
    pub const makeThunk = vm_force.makeThunk;
    pub const makeCell = vm_force.makeCell;

    // objects
    pub const buildAttrs = vm_objects.buildAttrs;
    pub const buildAttrsWithPositions = vm_objects.buildAttrsWithPositions;
    pub const buildList = vm_objects.buildList;
    pub const mergeAttrs = vm_objects.mergeAttrs;
    pub const mergeAttrsStrict = vm_objects.mergeAttrsStrict;
    pub const mergeAttrLiteralObjects = vm_objects.mergeAttrLiteralObjects;
    pub const mergeAttrLiteralValue = vm_objects.mergeAttrLiteralValue;
    pub const concatLists = vm_objects.concatLists;

    // strings
    pub const concatInternedString = vm_strings.concatInternedString;
    pub const stringLikeValue = vm_strings.stringLikeValue;
    pub const stringLikeInternId = vm_strings.stringLikeInternId;
    pub const stringTextInternId = vm_strings.stringTextInternId;
    pub const stringTextInternIdsEqual = vm_strings.stringTextInternIdsEqual;
    pub const attrsStringLikeValue = vm_strings.attrsStringLikeValue;
    pub const concatPathLike = vm_strings.concatPathLike;
    pub const concatStringLike = vm_strings.concatStringLike;
    pub const coerceLanguageStringValue = vm_strings.coerceLanguageStringValue;
    pub const sourcePathStringValue = vm_strings.sourcePathStringValue;
    pub const appendStringContext = vm_strings.appendStringContext;
    pub const hasStorePathContext = vm_strings.hasStorePathContext;
    pub const appendContextEntry = vm_strings.appendContextEntry;
    pub const mergeContextValues = vm_strings.mergeContextValues;
    pub const mergeContextAttrs = vm_strings.mergeContextAttrs;
    pub const mergeContextAttrValue = vm_strings.mergeContextAttrValue;
    pub const mergeContextOutputs = vm_strings.mergeContextOutputs;
    pub const appendUniqueContextOutput = vm_strings.appendUniqueContextOutput;
    pub const pathContextValue = vm_strings.pathContextValue;

    // closures
    pub const getClosureById = vm_closures.getClosureById;
    pub const makeClosure = vm_closures.makeClosure;
    pub const stageCaptureDescriptors = vm_closures.stageCaptureDescriptors;
    pub const fillCaptureValues = vm_closures.fillCaptureValues;
    pub const makeClosureFromCaptures = vm_closures.makeClosureFromCaptures;
    pub const makeBytecodeThunkFromCaptures = vm_closures.makeBytecodeThunkFromCaptures;
    pub const doCall = vm_closures.doCall;
    pub const doTailCall = vm_closures.doTailCall;
    pub const replaceCurrentFrame = vm_closures.replaceCurrentFrame;
    pub const callValue = vm_closures.callValue;
    pub const runIsolatedFrame = vm_closures.runIsolatedFrame;

    // errors
    pub const captureErrorTrace = vm_errors.captureErrorTrace;
    pub const sourceSpanForFrame = vm_errors.sourceSpanForFrame;
    pub const sameSourceSpan = vm_errors.sameSourceSpan;
    pub const defaultErrorMessage = vm_errors.defaultErrorMessage;

    // attribute lookup
    pub const callAttrFunctor = vm_access.callAttrFunctor;
    pub const applyBuiltin = vm_access.applyBuiltin;
    pub const applyBuiltinClosure = vm_access.applyBuiltinClosure;
    pub const getAttrValue = vm_access.getAttrValue;
    pub const getAttrPathOrValue = vm_access.getAttrPathOrValue;
    pub const getAttrPathDynamicOrValue = vm_access.getAttrPathDynamicOrValue;
    pub const getAttrPathMixedOrValue = vm_access.getAttrPathMixedOrValue;
    pub const hasAttrPath = vm_access.hasAttrPath;
    pub const hasAttrPathMixed = vm_access.hasAttrPathMixed;
    pub const validateAttrs = vm_access.validateAttrs;
    pub const lookupWith = vm_access.lookupWith;
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
