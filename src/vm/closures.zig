const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const tjit_exec = @import("../jit/exec.zig");
const ChunkId = types.ChunkId;
const ObjectId = types.ObjectId;
const chunk = @import("../bytecode.zig").chunk;
const Chunk = chunk.Chunk;
const heap_mod = @import("runtime").heap;
const Closure = heap_mod.Closure;
const BytecodeThunk = @import("runtime").thunk.BytecodeThunk;
const Thunk = @import("runtime").thunk.Thunk;
const deferred_mod = @import("../compiler/deferred_table.zig");

const access = @import("access.zig");
const debug = @import("debug.zig");
const errors = @import("errors.zig");
const stack = @import("stack.zig");
const trace = @import("trace.zig");
const force = @import("force.zig");
const jit_mod = @import("../jit/native.zig");
const trace_log = @import("trace_log.zig");
const prof = @import("../probe/prof.zig");

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const readU16 = vm_mod.readU16;

// ---- closures ----

pub fn getClosureById(self: *VM, closure_id: ObjectId) !Closure {
    return self.heap.getClosure(closure_id);
}

pub fn makeClosure(self: *VM, chunk_id: ChunkId, upvalue_count: u16) !void {
    const start = self.sp - upvalue_count;
    const id = try self.heap.addClosure(chunk_id, self.stack[start..self.sp]);
    self.sp = start;
    try stack.push(self, Value.closure(id));
}

pub fn stageCaptureDescriptors(self: *VM, descriptors: []const u8, frame: *const Frame) !u16 {
    const upvalue_count = descriptors.len / 3;
    const stack_cap: u32 = @intCast(types.VM_STACK_CAP);
    if (upvalue_count > @as(usize, stack_cap - self.sp)) return error.StackOverflow;

    var current_upvalues: ?[]const Value = null;
    var out_index = self.sp;
    var i: usize = 0;
    while (i < descriptors.len) : (i += 3) {
        const capture_index = readU16(descriptors, i + 1);
        const captured = switch (descriptors[i]) {
            0 => self.stack[frame.frame_base + capture_index],
            1 => value: {
                if (current_upvalues == null) {
                    current_upvalues = frame.upvalues orelse return error.MissingClosure;
                }
                break :value current_upvalues.?[capture_index];
            },
            else => return error.InvalidBytecode,
        };
        self.stack[out_index] = captured;
        out_index += 1;
    }

    self.sp = out_index;
    return @intCast(upvalue_count);
}

pub fn fillCaptureValues(self: *VM, descriptors: []const u8, frame: *const Frame, out: []Value) !void {
    std.debug.assert(out.len == descriptors.len / 3);

    var current_upvalues: ?[]const Value = null;
    var out_index: usize = 0;
    var i: usize = 0;
    while (i < descriptors.len) : (i += 3) {
        const capture_index = readU16(descriptors, i + 1);
        out[out_index] = switch (descriptors[i]) {
            0 => self.stack[frame.frame_base + capture_index],
            1 => value: {
                if (current_upvalues == null) {
                    current_upvalues = frame.upvalues orelse return error.MissingClosure;
                }
                break :value current_upvalues.?[capture_index];
            },
            else => return error.InvalidBytecode,
        };
        out_index += 1;
    }
}

pub fn makeClosureFromCaptures(self: *VM, chunk_id: ChunkId, descriptors: []const u8, frame: *const Frame) !void {
    const upvalue_count = try stageCaptureDescriptors(self, descriptors, frame);
    try makeClosure(self, chunk_id, upvalue_count);
}

/// Materialise a `.deferred` thunk (lazy per-attr compilation): gather
/// the enclosing-scope snapshot into the thunk's `env` from the capture
/// descriptors (exactly as a bytecode thunk gathers upvalues), tagged
/// with `deferred_id`. The body is compiled on first force. Not
/// speculatively submitted — deferred thunks are pull-only.
pub fn makeDeferredThunkFromCaptures(self: *VM, deferred_id: u32, descriptors: []const u8, frame: *const Frame) !void {
    const count = descriptors.len / 3;
    if (count > deferred_mod.MAX_SCOPE) return error.InvalidBytecode;
    var buf: [deferred_mod.MAX_SCOPE]Value = undefined;
    try fillCaptureValues(self, descriptors, frame, buf[0..count]);
    const id = try self.heap.addDeferredThunk(deferred_id, buf[0..count]);
    try stack.push(self, Value.thunk(id));
}

pub fn makeBytecodeThunkFromCaptures(self: *VM, chunk_id: ChunkId, descriptors: []const u8, frame: *const Frame) !void {
    const t = prof.start(.make_bytecode_thunk);
    defer prof.end(.make_bytecode_thunk, t);
    // Pre-fetch the chunk so we can read `body_is_substantial` once
    // instead of a second `registry.get` from `shouldSpeculate`.
    const ch = self.registry.get(chunk_id) orelse return error.InvalidChunk;

    // Trivial-body short-circuit: if the chunk's whole body is
    // `get_upvalue_ret upvalue[N]; halt` or `constant_ret #idx; halt`,
    // we already know what forcing the thunk will produce — the
    // captured value, or the constant. Push it directly instead of
    // allocating a thunk, populating its upvalues, and (later)
    // running a 4-byte chunk through the dispatcher. Saves a heap
    // alloc, a markDemanded, a frame push/pop, and several dispatches
    // per occurrence — the dominant pattern that drives the
    // `thunk_captures` op count (~15% of all ops on NixOS toplevel).
    switch (ch.scheduling.trivial) {
        .identity_upvalue => |idx| {
            return shortCircuitIdentityUpvalue(self, descriptors, frame, idx);
        },
        .constant => |const_idx| {
            return stack.push(self, ch.constants[const_idx]);
        },
        .closure_zero => |cl_id| {
            return makeClosure(self, cl_id, 0);
        },
        .closure_captures => |info| {
            const inner = ch.code[info.inner_descriptors_offset..][0..info.inner_descriptors_len];
            return shortCircuitClosureCaptures(self, info.closure_chunk_id, inner, descriptors, frame);
        },
        .builtins => {
            return stack.push(self, self.builtins);
        },
        .literal => |val| {
            return stack.push(self, val);
        },
        .attr_access => |aa| {
            return shortCircuitAttrAccess(self, descriptors, frame, aa, chunk_id);
        },
        .none => {},
    }

    const id = try captureBytecodeThunk(self, chunk_id, descriptors, frame);
    recordBytecodeThunkCreate(self, id, frame, chunk_id);
    if (ch.scheduling.body_is_substantial) {
        _ = self.scheduler.submit(.{ .force_thunk = id }, self.workerId());
    }
    try stack.push(self, Value.thunk(id));
}

/// Does `callee` force its argument to WHNF? True for a closure whose
/// chunk's body must-forces its parameter (`strict_param`). Conservative
/// (false) for builtins, builtin-closures, and callable attrsets — those
/// keep the lazy thunk. Cheap: one closure load + one chunk lookup, both
/// of which `doCall` performs again immediately after.
pub fn calleeForcesArg(self: *VM, callee: Value) bool {
    if (!callee.isClosure()) return false;
    const cl = self.heap.getClosure(callee.asObjectId()) catch return false;
    const ch = self.registry.get(cl.chunk_id) orelse return false;
    if (ch.scheduling.strict_param) return true;
    // Forwarding `x: f x`: forces x iff the captured `f` (an upvalue we
    // hold here) forces its own argument. One level — enough to catch
    // wrappers around directly-strict functions.
    if (ch.scheduling.strict_via_upvalue) |idx| {
        if (idx < cl.upvalues.len) {
            const f = cl.upvalues[idx];
            if (f.isClosure()) {
                const fcl = self.heap.getClosure(f.asObjectId()) catch return false;
                const fch = self.registry.get(fcl.chunk_id) orelse return false;
                return fch.scheduling.strict_param;
            }
        }
    }
    return false;
}

/// Evaluate an `apply_arg` argument eagerly to a value (used when the
/// callee forces it). Stages the captured upvalues onto the stack below
/// a fresh frame, runs the argument chunk, then replaces the staged
/// upvalues with the resulting value. No thunk is allocated.
pub fn evalArgEager(self: *VM, chunk_id: ChunkId, descriptors: []const u8, frame: *const Frame) !void {
    const ch = self.registry.get(chunk_id) orelse return error.InvalidChunk;
    const base = self.sp;
    const upvalue_count = try stageCaptureDescriptors(self, descriptors, frame);
    const upvalues = self.stack[base .. base + upvalue_count];
    const result = try runIsolatedFrame(self, ch, chunk_id, 0, upvalues);
    self.sp = base; // drop the staged upvalues
    try stack.push(self, result);
}

/// Materialise a bytecode thunk from capture descriptors. Small captures
/// (<= INLINE_CAP) are filled into a stack buffer and stored inline in
/// the thunk (no `values`-store range); wider captures fill the heap's
/// reserved range directly.
fn captureBytecodeThunk(self: *VM, chunk_id: ChunkId, descriptors: []const u8, frame: *const Frame) !types.ObjectId {
    const count = descriptors.len / 3;
    if (count <= BytecodeThunk.INLINE_CAP) {
        var buf: [BytecodeThunk.INLINE_CAP]Value = undefined;
        try fillCaptureValues(self, descriptors, frame, buf[0..count]);
        return self.heap.addBytecodeThunk(chunk_id, buf[0..count]);
    }
    const pending = try self.heap.beginBytecodeThunk(chunk_id, count);
    errdefer self.heap.rollbackBytecodeThunk(pending);
    try fillCaptureValues(self, descriptors, frame, self.heap.pendingBytecodeThunkUpvalues(pending));
    return self.heap.commitBytecodeThunk(pending);
}

/// Resolve capture descriptor `idx` to its Value against the current
/// frame. Descriptors are (kind:1, index:2) triples — same resolution
/// `fillCaptureValues` does.
inline fn resolveDescriptorValue(self: *VM, descriptors: []const u8, frame: *const Frame, idx: u16) !Value {
    const offset: usize = @as(usize, idx) * 3;
    if (offset + 3 > descriptors.len) return error.InvalidBytecode;
    const capture_index = readU16(descriptors, offset + 1);
    return switch (descriptors[offset]) {
        0 => self.stack[frame.frame_base + capture_index],
        1 => blk: {
            const upvalues = frame.upvalues orelse return error.MissingClosure;
            break :blk upvalues[capture_index];
        },
        else => error.InvalidBytecode,
    };
}

/// Push the value of capture descriptor `idx` directly without
/// constructing a thunk (`x: x`-shaped trivial bodies).
inline fn shortCircuitIdentityUpvalue(self: *VM, descriptors: []const u8, frame: *const Frame, idx: u16) !void {
    return stack.push(self, try resolveDescriptorValue(self, descriptors, frame, idx));
}

/// Build a frameless `attr_access` thunk for a `someUpvalue.attr` body:
/// resolve the base attrset from the descriptor and bake (base, name).
/// Forcing it later runs `getAttrValue` with no frame/dispatch.
inline fn shortCircuitAttrAccess(self: *VM, descriptors: []const u8, frame: *const Frame, aa: chunk.AttrAccessShape, chunk_id: ChunkId) !void {
    const base = try resolveDescriptorValue(self, descriptors, frame, aa.upvalue_index);
    const id = try self.heap.addThunk(Thunk.initAttrAccess(base, aa.name));
    recordBytecodeThunkCreate(self, id, frame, chunk_id);
    return stack.push(self, Value.thunk(id));
}

/// Compose outer + inner descriptors and build the closure directly,
/// skipping the wrapping bytecode thunk. Inner descriptors are all
/// kind=upvalue (classifier guarantee), so each inner upvalue resolves
/// to `outer_descriptors[inner_idx]` evaluated against the outer frame.
inline fn shortCircuitClosureCaptures(
    self: *VM,
    cl_chunk_id: ChunkId,
    inner_descriptors: []const u8,
    outer_descriptors: []const u8,
    frame: *const Frame,
) !void {
    const k = inner_descriptors.len / 3;
    const stack_cap: u32 = @intCast(types.VM_STACK_CAP);
    if (k > @as(usize, stack_cap - self.sp)) return error.StackOverflow;

    var current_upvalues: ?[]const Value = null;
    var out_index = self.sp;
    var i: usize = 0;
    while (i < inner_descriptors.len) : (i += 3) {
        // Classifier guarantees inner kind == 1 (upvalue); the
        // descriptor's index field selects which outer descriptor to
        // re-evaluate.
        const inner_idx = readU16(inner_descriptors, i + 1);
        const outer_off: usize = @as(usize, inner_idx) * 3;
        if (outer_off + 3 > outer_descriptors.len) return error.InvalidBytecode;
        const outer_kind = outer_descriptors[outer_off];
        const outer_idx = readU16(outer_descriptors, outer_off + 1);
        const value: Value = switch (outer_kind) {
            0 => self.stack[frame.frame_base + outer_idx],
            1 => blk: {
                if (current_upvalues == null) {
                    current_upvalues = frame.upvalues orelse return error.MissingClosure;
                }
                break :blk current_upvalues.?[outer_idx];
            },
            else => return error.InvalidBytecode,
        };
        self.stack[out_index] = value;
        out_index += 1;
    }
    self.sp = out_index;
    return makeClosure(self, cl_chunk_id, @intCast(k));
}



/// Like `makeBytecodeThunkFromCaptures` but submits the thunk to the
/// urgent queue at creation time. Used by `thunk_captures_eager` —
/// the compiler emits that op when strictness analysis confirms the
/// surrounding chunk's body forces this binding.
///
/// `in_speculation` brake: if a helper is currently running a force
/// task (set by `forceValueSpeculative`), we skip the urgent submit
/// — otherwise the cascade is unbounded. The thunk is still created
/// (so subsequent code sees it), it just doesn't fan out further. The
/// helper finishes its current force, then any consumer that forces
/// this thunk gets normal demand-driven handling.
pub fn makeBytecodeThunkFromCapturesEager(self: *VM, chunk_id: ChunkId, descriptors: []const u8, frame: *const Frame) !void {
    const ch = self.registry.get(chunk_id) orelse return error.InvalidChunk;
    switch (ch.scheduling.trivial) {
        .identity_upvalue => |idx| {
            return shortCircuitIdentityUpvalue(self, descriptors, frame, idx);
        },
        .constant => |const_idx| {
            return stack.push(self, ch.constants[const_idx]);
        },
        .closure_zero => |cl_id| {
            return makeClosure(self, cl_id, 0);
        },
        .closure_captures => |info| {
            const inner = ch.code[info.inner_descriptors_offset..][0..info.inner_descriptors_len];
            return shortCircuitClosureCaptures(self, info.closure_chunk_id, inner, descriptors, frame);
        },
        .builtins => {
            return stack.push(self, self.builtins);
        },
        .literal => |val| {
            return stack.push(self, val);
        },
        .attr_access => |aa| {
            return shortCircuitAttrAccess(self, descriptors, frame, aa, chunk_id);
        },
        .none => {},
    }
    const id = try captureBytecodeThunk(self, chunk_id, descriptors, frame);
    recordBytecodeThunkCreate(self, id, frame, chunk_id);
    if (!self.in_speculation) {
        _ = self.scheduler.submitUrgent(.{ .force_thunk = id }, self.workerId());
    }
    try stack.push(self, Value.thunk(id));
}

inline fn recordBytecodeThunkCreate(self: *VM, id: types.ObjectId, frame: *const Frame, chunk_id: ChunkId) void {
    if (comptime !vm_mod.thunks_log_enabled) return;
    if (self.thunk_trace) |tt| {
        const fiber_id = self.claimer_id & 0x00FFFFFF;
        tt.recordCreate(id, self.workerId(), fiber_id, frame.chunk_id, @intCast(frame.ip), .bytecode, chunk_id);
    }
}

// ---- calls ----

/// Per-call-site inline cache. Caches the (chunk_id → Chunk*) lookup
/// at every `call`/`tail_call` site keyed by the caller's
/// (chunk_id, ip). On hit the registry hashtable lookup is skipped,
/// and the cache contents are first-class JIT feedback: at code-gen
/// time the JIT reads the IC to discover whether a site is
/// monomorphic, polymorphic, or megamorphic.
///
/// Heap-token gated: chunk_ids aren't unique across Evaluator
/// instances (each registry starts at 0), and the IC is threadlocal,
/// so a stale `ch_ptr` from a prior eval would point at a freed
/// chunk. Matching `heap_token` invalidates the cache when the
/// evaluator changes — same trick the attr IC uses.
const CallICSlot = struct {
    heap_token: u64 = 0,
    caller_chunk_id: ChunkId = 0,
    caller_ip: u32 = 0,
    callee_chunk_id: ChunkId = 0,
    callee_ch_ptr: ?*const Chunk = null,
};

const call_ic_size: usize = 256;
threadlocal var call_ic: [call_ic_size]CallICSlot = @splat(.{});

inline fn callICIndex(caller_chunk_id: ChunkId, caller_ip: u32) usize {
    const mixed: u64 = (@as(u64, caller_chunk_id) *% 0x9E3779B97F4A7C15) ^ @as(u64, caller_ip);
    return @intCast(mixed % call_ic_size);
}

/// Resolve a closure's Chunk*, consulting the per-call-site IC keyed
/// by the current frame's (chunk_id, ip). On miss the slot is
/// updated to the observed callee. Used by `doCall` / `doTailCall`.
inline fn closureChunkViaIC(self: *VM, callee_chunk_id: ChunkId) !*const Chunk {
    const caller = stack.currentFrame(self);
    const token = self.heap.token;
    const idx = callICIndex(caller.chunk_id, @intCast(caller.ip));
    const slot = &call_ic[idx];
    if (slot.heap_token == token and
        slot.caller_chunk_id == caller.chunk_id and
        slot.caller_ip == caller.ip and
        slot.callee_chunk_id == callee_chunk_id)
    {
        return slot.callee_ch_ptr orelse return error.InvalidChunk;
    }
    const ch = self.registry.get(callee_chunk_id) orelse return error.InvalidChunk;
    slot.* = .{
        .heap_token = token,
        .caller_chunk_id = caller.chunk_id,
        .caller_ip = @intCast(caller.ip),
        .callee_chunk_id = callee_chunk_id,
        .callee_ch_ptr = ch,
    };
    return ch;
}

/// Hard cap on merged-chain arity; see `types.MAX_UNCURRY_ARITY`. Used
/// to size the on-stack arg buffers in the PAP machinery below.
const MAX_UNCURRY_ARITY: u16 = types.MAX_UNCURRY_ARITY;

/// Eagerly force the must-force arg positions (`ch.strict_params`) of a
/// saturated uncurried call, in place on the stack at `args_base..+n`.
/// The body forces these regardless (sound must-force analysis), so this
/// is value-preserving; doing it before the body runs recovers the
/// single-param eager-arg optimization for the multi-param case and stops
/// lazy-thunk chains from accumulating in accumulator-style recursion.
inline fn forceStrictArgs(self: *VM, ch: *const Chunk, args_base: u32, n: u16) !void {
    var mask = ch.strict_params;
    while (mask != 0) {
        const i = @ctz(mask);
        mask &= mask - 1;
        if (i >= n) break;
        const idx = args_base + i;
        self.stack[idx] = try force.forceValue(self, self.stack[idx]);
    }
}

pub fn doCall(self: *VM, callee: Value, arg: Value) !void {
    const t = prof.start(.do_call);
    defer prof.end(.do_call, t);
    // GC (`-Dgc`): root callee+arg for the call — they were popped off the
    // operand stack into Zig locals, so a force inside the call must not sweep
    // them. See callValue / force.RootScope. Compiles away w/o -Dgc.
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    force.rootKeep(self, callee);
    force.rootKeep(self, arg);
    if (callee.isClosure()) {
        const closure_id = callee.asObjectId();
        const closure = try getClosureById(self, closure_id);
        const ch = try closureChunkViaIC(self, closure.chunk_id);
        if (ch.arity != 1) {
            // Uncurried closure, one arg supplied → under-applied PAP.
            // (arity == 1 is the overwhelmingly common path and stays
            // branch-cheap below; jit_lambda_code is only attached to
            // arity-1 chunks.)
            const id = try self.heap.addPartialApp(callee, &.{arg});
            return stack.push(self, Value.partialApp(id));
        }
        if (comptime jit_mod.enabled) {
            if (ch.jit_lambda_code) |jit_fn| {
                const result = jit_fn(@ptrCast(self), closure.upvalues.ptr, arg);
                if (result.error_code != 0) {
                    return @errorFromInt(@as(std.meta.Int(.unsigned, @bitSizeOf(anyerror)), @intCast(result.error_code)));
                }
                return stack.push(self, result.value);
            }
        }
        // Tracing-JIT: run an installed trace for this lambda body instead of
        // pushing a frame. A guard side-exit returns null → fall through.
        if (comptime tjit_exec.enabled) {
            if (try tjit_exec.tryRun(self, closure.chunk_id, closure.upvalues, arg)) |result| {
                return stack.push(self, result);
            }
        }
        try stack.push(self, arg); // arg is first local
        try stack.pushFrame(self, ch, closure.chunk_id, 1, closure.upvalues);
    } else if (callee.isPartialApp()) {
        try applyToPartial(self, callee, arg);
    } else if (callee.isBuiltin()) {
        try stack.push(self, try access.applyBuiltin(self, callee.asBuiltinId(), &.{arg}));
    } else if (callee.isBuiltinClosure()) {
        try stack.push(self, try access.applyBuiltinClosure(self, callee, arg));
    } else if (callee.isAttrs()) {
        const callable = try access.callAttrFunctor(self, callee);
        try doCall(self, callable, arg);
    } else return trace.notCallableError(self, callee);
}

/// Apply one argument to a partial-application value (control-transfer
/// flavor, used by `doCall`/`call_n` fold). Extends the PAP if still
/// under-applied, otherwise stages all args and pushes a frame so the
/// underlying body runs (its result lands on the caller's stack exactly
/// as a normal `call` would).
fn applyToPartial(self: *VM, pap: Value, arg: Value) !void {
    const pa = try self.heap.getPartialApp(pap.asObjectId());
    const closure = try getClosureById(self, pa.func.asObjectId());
    const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
    const have: u16 = @intCast(pa.args.len);
    if (have + 1 < ch.arity) {
        var buf: [MAX_UNCURRY_ARITY]Value = undefined;
        @memcpy(buf[0..pa.args.len], pa.args);
        buf[pa.args.len] = arg;
        const id = try self.heap.addPartialApp(pa.func, buf[0 .. pa.args.len + 1]);
        return stack.push(self, Value.partialApp(id));
    }
    // Saturated: stage args + the final one, run the body in a fresh frame.
    const args_base = self.sp;
    for (pa.args) |a| try stack.push(self, a);
    try stack.push(self, arg);
    try forceStrictArgs(self, ch, args_base, ch.arity);
    try stack.pushFrame(self, ch, closure.chunk_id, ch.arity, closure.upvalues);
}

pub fn doTailCall(self: *VM, callee: Value, arg: Value) !void {
    const t = prof.start(.do_tail_call);
    defer prof.end(.do_tail_call, t);
    // GC (`-Dgc`): `arg` and the walked `current` are held in Zig locals across
    // forcing calls (applyToPartial/applyBuiltin*/callAttrFunctor) — none are on
    // the operand stack here — so root them. `current` is re-rooted after each
    // functor hop. Compiles away w/o -Dgc.
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    force.rootKeep(self, arg);
    var current = callee;
    force.rootKeep(self, current);
    while (true) {
        switch (current.kind()) {
            .closure => {
                const closure_id = current.asObjectId();
                const closure = try getClosureById(self, closure_id);
                const ch = try closureChunkViaIC(self, closure.chunk_id);
                if (ch.arity != 1) {
                    // Uncurried closure, one arg → under-applied PAP value.
                    // The following `ret` returns it (mirrors the builtin
                    // tail-call case below).
                    const id = try self.heap.addPartialApp(current, &.{arg});
                    return stack.push(self, Value.partialApp(id));
                }
                if (comptime jit_mod.enabled) {
                    if (ch.jit_lambda_code) |jit_fn| {
                        const result = jit_fn(@ptrCast(self), closure.upvalues.ptr, arg);
                        if (result.error_code != 0) {
                            return @errorFromInt(@as(std.meta.Int(.unsigned, @bitSizeOf(anyerror)), @intCast(result.error_code)));
                        }
                        // Mirror the builtin tail-call case: push the
                        // result on the current frame's stack. The
                        // surrounding op (`opTailCall`) then resumes
                        // dispatch on the next op, which is `ret`.
                        return stack.push(self, result.value);
                    }
                }
                try replaceCurrentFrame(self, ch, closure.chunk_id, arg, closure.upvalues);
                return;
            },
            .partial_app => {
                // Saturation here pushes a fresh frame (non-tail) rather
                // than reusing the current one — rare (a PAP saturating in
                // tail position via a single arg); direct multi-arg tail
                // spines go through `tail_call_n`, which DOES reuse the
                // frame. Correctness preserved; depth grows by 1 here.
                try applyToPartial(self, current, arg);
                return;
            },
            .builtin => {
                try stack.push(self, try access.applyBuiltin(self, current.asBuiltinId(), &.{arg}));
                return;
            },
            .builtin_closure => {
                try stack.push(self, try access.applyBuiltinClosure(self, current, arg));
                return;
            },
            .attrs => {
                current = try access.callAttrFunctor(self, current);
                force.rootKeep(self, current);
            },
            else => return trace.notCallableError(self, current),
        }
    }
}

pub fn replaceCurrentFrame(self: *VM, ch: *const Chunk, chunk_id: types.ChunkId, arg: Value, upvalues: []const Value) !void {
    if (ch.local_count == 0) return error.InvalidCallFrame;

    const stack_cap: u32 = @intCast(types.VM_STACK_CAP);
    const frame = stack.currentFrame(self);
    const frame_base = frame.frame_base;
    const arg_end = frame_base + 1;
    if (arg_end > stack_cap) return error.StackOverflow;
    self.stack[frame_base] = arg;

    const reserved = @as(u32, ch.local_count) - 1;
    if (reserved > stack_cap - arg_end) return error.StackOverflow;
    const new_sp = arg_end + reserved;
    const arg_end_idx: usize = @intCast(arg_end);
    const new_sp_idx: usize = @intCast(new_sp);
    @memset(self.stack[arg_end_idx..new_sp_idx], Value.null_val);
    self.sp = new_sp;

    frame.* = .{
        .chunk_ptr = ch,
        .chunk_id = chunk_id,
        .ip = 0,
        .frame_base = frame_base,
        .local_count = ch.local_count,
        .upvalues = upvalues,
    };
    debug.checkFrameSync(self, frame, ch.code, "replaceCurrentFrame");
    trace_log.framePush(self.vm_trace, self.workerId(), self.frames_len, chunk_id, frame_base);
}

/// Like `replaceCurrentFrame` but for an uncurried (arity>1) callee:
/// `args` (length == ch.arity) are the new frame's first locals. The
/// args currently live at the top of the stack at `args_base..args_base+n`
/// (the caller has already removed the callee). They're copied down to the
/// reused frame's base and the frame is re-pointed at `ch` with ip=0.
fn replaceCurrentFrameMulti(self: *VM, ch: *const Chunk, chunk_id: types.ChunkId, args_base: u32, n: u16, upvalues: []const Value) !void {
    if (ch.local_count < n) return error.InvalidCallFrame;
    const stack_cap: u32 = @intCast(types.VM_STACK_CAP);
    const frame = stack.currentFrame(self);
    const frame_base = frame.frame_base;
    // Copy the n args down to the frame base. dst (frame_base) <= src
    // (args_base) and we copy ascending, so any overlap is safe.
    var j: u32 = 0;
    while (j < n) : (j += 1) self.stack[frame_base + j] = self.stack[args_base + j];

    const arg_end = frame_base + n;
    const reserved = @as(u32, ch.local_count) - n;
    if (reserved > stack_cap - arg_end) return error.StackOverflow;
    const new_sp = arg_end + reserved;
    @memset(self.stack[@intCast(arg_end)..@intCast(new_sp)], Value.null_val);
    self.sp = new_sp;

    frame.* = .{
        .chunk_ptr = ch,
        .chunk_id = chunk_id,
        .ip = 0,
        .frame_base = frame_base,
        .local_count = ch.local_count,
        .upvalues = upvalues,
    };
    debug.checkFrameSync(self, frame, ch.code, "replaceCurrentFrameMulti");
    trace_log.framePush(self.vm_trace, self.workerId(), self.frames_len, chunk_id, frame_base);
}

/// `call_n`: apply `callee` to `n` args, all already on the stack as
/// `[callee, arg1, ..., argN]` (sp just past argN). Semantically identical
/// to `n` sequential `call`s; the win is the saturated fast path
/// (closure arity == n) which runs the body in ONE frame with no
/// intermediate closure/PAP allocation. Either pushes a frame (control
/// transfer) or pushes a result value — the caller (`opCallN`) dispatches
/// `currentFrame` afterward, which handles both, exactly like `opCall`.
pub fn doCallN(self: *VM, n: u16) !void {
    const base = self.sp - n;
    const callee = self.stack[base - 1];
    if (callee.isClosure()) {
        const closure = try getClosureById(self, callee.asObjectId());
        const ch = try closureChunkViaIC(self, closure.chunk_id);
        if (ch.arity == n) {
            // Saturated: drop the callee from below the args (shift the
            // args down one slot), then push one frame over the n args.
            // GC (`-Dgc`): the shift overwrites the callee's stack slot at
            // `base-1`, so once `sp` drops it is no longer a stack root — yet
            // `closure.upvalues` (a raw slice owned by that closure object) is
            // read by `pushFrame` AFTER `forceStrictArgs` forces. Root the
            // callee across the force so the closure (and its upvalue range)
            // survives. Compiles away w/o -Dgc.
            const gc_roots = force.rootsBegin(self);
            defer force.rootsEnd(self, gc_roots);
            force.rootKeep(self, callee);
            var j: u32 = 0;
            while (j < n) : (j += 1) self.stack[base - 1 + j] = self.stack[base + j];
            self.sp -= 1;
            try forceStrictArgs(self, ch, base - 1, n);
            return stack.pushFrame(self, ch, closure.chunk_id, n, closure.upvalues);
        }
    }
    // General fold: reduce one arg at a time to a value (run-to-completion),
    // then replace [callee, args] with the result. `callValue` is
    // stack-neutral, so the not-yet-consumed args stay put at `base+i`.
    // Keep `acc` on the stack (the consumed-callee slot at base-1) so it is
    // a precise GC root across each `callValue` (which forces).
    var acc = callee;
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        acc = try callValue(self, acc, self.stack[base + i]);
        self.stack[base - 1] = acc;
    }
    self.sp = base - 1;
    try stack.push(self, acc);
}

/// `tail_call_n`: tail-position `call_n`. The saturated closure case
/// reuses the current frame (so deep multi-arg tail recursion doesn't
/// grow the stack); everything else folds to a value (the following
/// `ret` returns it).
pub fn doTailCallN(self: *VM, n: u16) !void {
    const base = self.sp - n;
    const callee = self.stack[base - 1];
    if (callee.isClosure()) {
        const closure = try getClosureById(self, callee.asObjectId());
        const ch = try closureChunkViaIC(self, closure.chunk_id);
        if (ch.arity == n) {
            try forceStrictArgs(self, ch, base, n);
            return replaceCurrentFrameMulti(self, ch, closure.chunk_id, base, n, closure.upvalues);
        }
    }
    var acc = callee;
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        acc = try callValue(self, acc, self.stack[base + i]);
        self.stack[base - 1] = acc;
    }
    self.sp = base - 1;
    try stack.push(self, acc);
}

pub fn callValue(self: *VM, callee: Value, arg: Value) !Value {
    const t = prof.start(.call_value);
    defer prof.end(.call_value, t);
    // GC (`-Dgc`): root callee+arg for the call's duration — they arrive in Zig
    // locals, so a force inside the call would otherwise sweep them. This is
    // what lets a builtin pass a freshly-produced value (e.g. a partial
    // application, or a user-fn result) into callValue without rooting it
    // itself. Precise; compiles away w/o -Dgc.
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    force.rootKeep(self, callee);
    force.rootKeep(self, arg);
    if (callee.isClosure()) {
        const closure_id = callee.asObjectId();
        const closure = try getClosureById(self, closure_id);
        const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
        if (ch.arity != 1) {
            // Uncurried closure, one arg → under-applied PAP value.
            const id = try self.heap.addPartialApp(callee, &.{arg});
            return Value.partialApp(id);
        }
        if (comptime jit_mod.enabled) {
            if (ch.jit_lambda_code) |jit_fn| {
                const result = jit_fn(@ptrCast(self), closure.upvalues.ptr, arg);
                if (result.error_code != 0) {
                    return @errorFromInt(@as(std.meta.Int(.unsigned, @bitSizeOf(anyerror)), @intCast(result.error_code)));
                }
                return result.value;
            }
        }
        try stack.push(self, arg);
        return runIsolatedFrame(self, ch, closure.chunk_id, 1, closure.upvalues);
    }
    if (callee.isPartialApp()) {
        return callValuePartial(self, callee, arg);
    }
    if (callee.isBuiltin()) {
        return access.applyBuiltin(self, callee.asBuiltinId(), &.{arg});
    }
    if (callee.isBuiltinClosure()) {
        return access.applyBuiltinClosure(self, callee, arg);
    }
    if (callee.isAttrs()) {
        const callable = try access.callAttrFunctor(self, callee);
        return callValue(self, callable, arg);
    }
    return trace.notCallableError(self, callee);
}

/// `callValue` for a partial-application callee: extend if still
/// under-applied, else run the underlying body to completion with all
/// args and return its value.
fn callValuePartial(self: *VM, pap: Value, arg: Value) anyerror!Value {
    const pa = try self.heap.getPartialApp(pap.asObjectId());
    const closure = try getClosureById(self, pa.func.asObjectId());
    const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
    var buf: [MAX_UNCURRY_ARITY]Value = undefined;
    @memcpy(buf[0..pa.args.len], pa.args);
    buf[pa.args.len] = arg;
    const total: u16 = @intCast(pa.args.len + 1);
    if (total < ch.arity) {
        const id = try self.heap.addPartialApp(pa.func, buf[0..total]);
        return Value.partialApp(id);
    }
    const args_base = self.sp;
    for (buf[0..total]) |a| try stack.push(self, a);
    try forceStrictArgs(self, ch, args_base, ch.arity);
    return runIsolatedFrame(self, ch, closure.chunk_id, ch.arity, closure.upvalues);
}

/// A live local to restore when resuming a truncated trace.
pub const TraceLocal = struct { slot: u16, value: Value };

/// One reconstructed VM frame for a tracing-JIT side-exit.
pub const TraceFrame = struct {
    chunk: *const Chunk,
    chunk_id: types.ChunkId,
    upvalues: ?[]const Value,
    resume_ip: u32,
    locals: []const TraceLocal,
    operands: []const Value,
};

/// Resume interpretation of a tracing-JIT trace mid-body (`-Dtjit` side-exit),
/// reconstructing the WHOLE inlined call stack. `frames` are ordered anchor →
/// deepest; each becomes a real VM frame (locals written into their slots,
/// operands pushed above, ip set to its resume point). The interpreter then
/// unwinds naturally: the deepest frame runs, its `ret` pushes its result to the
/// parent (resuming at the parent's call-return ip), … until the anchor `ret`
/// yields the trace result. Mirrors `runIsolatedFrame`'s teardown on error.
pub fn resumeTraceMulti(self: *VM, frames: []const TraceFrame) anyerror!Value {
    const run_mod = @import("run.zig");
    const stop_depth = self.frames_len;
    const base0 = self.sp;
    for (frames) |fr| {
        const fb = self.sp; // pushFrame(arg_count=0) sets frame_base = sp = fb
        stack.pushFrame(self, fr.chunk, fr.chunk_id, 0, fr.upvalues) catch |err| {
            self.frames_len = stop_depth;
            self.sp = base0;
            return err;
        };
        for (fr.locals) |l| self.stack[fb + l.slot] = l.value;
        if (self.sp + fr.operands.len > types.VM_STACK_CAP) {
            self.frames_len = stop_depth;
            self.sp = base0;
            return error.StackOverflow;
        }
        for (fr.operands) |v| {
            self.stack[self.sp] = v;
            self.sp += 1;
        }
        self.frames[self.frames_len - 1].ip = fr.resume_ip;
    }
    if (self.sp > self.sp_high_water) self.sp_high_water = self.sp;
    return run_mod.runUntil(self, stop_depth) catch |err| {
        errors.captureErrorTrace(self, err) catch {};
        self.frames_len = stop_depth;
        self.sp = base0;
        return err;
    };
}

pub fn runIsolatedFrame(self: *VM, ch: *const Chunk, chunk_id: types.ChunkId, arg_count: u32, upvalues: ?[]const Value) anyerror!Value {
    const t = prof.start(.run_isolated_frame);
    defer prof.end(.run_isolated_frame, t);
    const run_mod = @import("run.zig");
    const stop_depth = self.frames_len;
    const base_sp = self.sp - arg_count;
    stack.pushFrame(self, ch, chunk_id, arg_count, upvalues) catch |err| {
        self.sp = base_sp;
        return err;
    };
    return run_mod.runUntil(self, stop_depth) catch |err| {
        errors.captureErrorTrace(self, err) catch {};
        self.frames_len = stop_depth;
        self.sp = base_sp;
        return err;
    };
}
