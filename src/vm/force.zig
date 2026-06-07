const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;
const ObjectId = types.ObjectId;
const thunk_mod = @import("../runtime/thunk.zig");
const Thunk = thunk_mod.Thunk;
const ThunkTarget = thunk_mod.ThunkTarget;

const access = @import("access.zig");
const closures = @import("closures.zig");
const trace_log = @import("trace_log.zig");

const VM = vm_mod.VM;

// ---- thunk management ----

pub fn forceThunk(self: *VM, thunk_val: Value) !Value {
    return forceThunkImpl(self, thunk_val, true);
}

pub inline fn forceValue(self: *VM, value: Value) anyerror!Value {
    return forceValueImpl(self, value, true);
}

/// Speculative force: evaluate the value (resolving thunks) without
/// marking them as demanded. Used by scheduler helpers — if no real
/// caller later observes the thunk, lazy renderers will still treat it
/// as unevaluated.
pub fn forceValueSpeculative(self: *VM, value: Value) anyerror!Value {
    return forceValueImpl(self, value, false);
}

pub inline fn forceValueImpl(self: *VM, value: Value, demand: bool) anyerror!Value {
    return switch (value.discriminant) {
        .thunk => try forceThunkImpl(self, value, demand),
        else => value,
    };
}

pub fn forceDeep(self: *VM, value: Value) !void {
    var seen: std.ArrayListUnmanaged(SeenDeepObject) = .empty;
    defer seen.deinit(self.allocator);
    try forceDeepInner(self, value, &seen);
}

pub const SeenDeepKind = enum { list, attrs };

pub const SeenDeepObject = struct {
    kind: SeenDeepKind,
    id: ObjectId,
};

pub fn forceDeepInner(self: *VM, value: Value, seen: *std.ArrayListUnmanaged(SeenDeepObject)) anyerror!void {
    const forced = try forceValue(self, value);
    switch (forced.discriminant) {
        .list => {
            const id = forced.asObjectId();
            if (!try enterDeep(self, .list, id, seen)) return;
            const items = try self.heap.getList(id);
            fanOutListShallow(self, items);
            for (items) |item| try forceDeepInner(self, item, seen);
        },
        .attrs => {
            const id = forced.asObjectId();
            if (!try enterDeep(self, .attrs, id, seen)) return;
            const entries = try self.heap.getAttrs(id);
            fanOutAttrsShallow(self, entries);
            for (entries) |entry| try forceDeepInner(self, entry.value, seen);
        },
        else => {},
    }
}

/// Demand-driven fan-out: urgently submit a shallow force_thunk for every
/// thunk-typed item to helpers. The caller is about to walk every item
/// itself, so this is guaranteed work, not speculation — whoever loses
/// the race (helper or main) sees `.already_resolved` and proceeds. We
/// stop submitting once a push fails, since `submitUrgent` only returns
/// false when every helper queue is full and the caller will pick up the
/// remainder inline.
fn fanOutListShallow(self: *VM, items: []const Value) void {
    for (items) |v| {
        if (v.discriminant != .thunk) continue;
        if (!self.scheduler.submitUrgent(.{ .force_thunk = v.asObjectId() })) break;
    }
}

fn fanOutAttrsShallow(self: *VM, entries: []const @import("../runtime/heap.zig").AttrEntry) void {
    for (entries) |entry| {
        if (entry.value.discriminant != .thunk) continue;
        if (!self.scheduler.submitUrgent(.{ .force_thunk = entry.value.asObjectId() })) break;
    }
}

pub fn enterDeep(self: *VM, kind: SeenDeepKind, id: ObjectId, seen: *std.ArrayListUnmanaged(SeenDeepObject)) !bool {
    for (seen.items) |item| {
        if (item.kind == kind and item.id == id) return false;
    }
    try seen.append(self.allocator, .{ .kind = kind, .id = id });
    return true;
}

pub fn forceThunkFallible(self: *VM, thunk_val: Value) anyerror!Value {
    return forceThunkImpl(self, thunk_val, true);
}

pub fn forceThunkImpl(self: *VM, thunk_val: Value, demand: bool) anyerror!Value {
    const thunk_id = thunk_val.asObjectId();
    const thunk = try self.heap.getThunk(thunk_id);

    while (true) {
        switch (thunk.tryForce(self.claimer_id)) {
            .already_resolved => |v| {
                if (demand) thunk.markDemanded();
                return v;
            },
            .blackhole => return error.RecursiveThunk,
            .claimed => {
                trace_log.forceEnter(self.vm_trace, self.worker_id, thunk_id);
                // We own this thunk now; compute and publish (or fail and reset).
                const result = evalThunkTarget(self, thunk.target) catch |err| {
                    thunk.reset();
                    trace_log.forceExit(self.vm_trace, self.worker_id, thunk_id, false);
                    return err;
                };
                thunk.resolve(result);
                trace_log.forceExit(self.vm_trace, self.worker_id, thunk_id, true);
                if (demand) thunk.markDemanded();
                return result;
            },
            .busy => {
                switch (thunk.waitFor()) {
                    .resolved => |v| {
                        if (demand) thunk.markDemanded();
                        return v;
                    },
                    .blackhole => return error.RecursiveThunk,
                    .retry => continue,
                }
            },
        }
    }
}

pub fn evalThunkTarget(self: *VM, target: ThunkTarget) anyerror!Value {
    return switch (target) {
        .closure => |closure| evalThunkClosure(self, closure),
        .bytecode => |bytecode| blk: {
            const ch = self.registry.get(bytecode.chunk_id) orelse return error.InvalidChunk;
            break :blk closures.runIsolatedFrame(self, ch, bytecode.chunk_id, 0, bytecode.upvalues);
        },
        .pass_through => |v| forceValueImpl(self, v, true),
    };
}

pub fn evalThunkClosure(self: *VM, closure_val: Value) anyerror!Value {
    switch (closure_val.discriminant) {
        .closure => {
            const closure_id = closure_val.asObjectId();
            const closure = try closures.getClosureById(self, closure_id);
            const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
            return closures.runIsolatedFrame(self, ch, closure.chunk_id, 0, closure.upvalues);
        },
        .builtin_closure => {
            const closure = try self.heap.getBuiltinClosure(closure_val.asObjectId());
            return access.applyBuiltin(self, closure.builtin_id, closure.args);
        },
        else => return error.NotCallable,
    }
}

pub fn makeThunk(self: *VM, closure: Value) !Value {
    const id = try self.heap.addThunk(Thunk.init(closure));
    if (shouldSpeculateClosure(self, closure)) {
        _ = self.scheduler.submit(.{ .force_thunk = id });
    }
    return Value.thunk(id);
}

const SPECULATION_MIN_CODE_BYTES: usize = 256;

inline fn shouldSpeculateClosure(self: *VM, closure: Value) bool {
    // Only Nix-level closures with a meaningfully-sized body warrant the
    // submit overhead. Builtin / builtin_closure thunks are typically a
    // single dispatched call — main can force them faster than the
    // scheduler dance.
    if (closure.discriminant != .closure) return false;
    const c = self.heap.getClosure(closure.asObjectId()) catch return false;
    const ch = self.registry.get(c.chunk_id) orelse return false;
    return ch.code.len >= SPECULATION_MIN_CODE_BYTES;
}

pub fn makeCell(self: *VM, val: Value) !Value {
    // "Cell" is just a pass-through thunk: the underlying value gets forced
    // and the result memoized in the thunk's resolved slot.
    const id = try self.heap.addThunk(Thunk.initPassThrough(val));
    return Value.thunk(id);
}
