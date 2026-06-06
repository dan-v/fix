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

const VM = vm_mod.VM;

// ---- thunk management ----

pub fn forceThunk(self: *VM, thunk_val: Value) !Value {
    return forceThunkFallible(self, thunk_val);
}

pub inline fn forceValue(self: *VM, value: Value) anyerror!Value {
    return switch (value.discriminant) {
        .thunk => try forceThunkFallible(self, value),
        .cell => try forceCellValue(self, value),
        else => value,
    };
}

pub fn forceCellValue(self: *VM, value: Value) anyerror!Value {
    const cell_id = value.asObjectId();
    const raw = try self.heap.getCellValue(cell_id);
    const forced = try forceValue(self, raw);
    if (raw.discriminant == .thunk or raw.discriminant == .cell) {
        try self.heap.setCellValue(cell_id, forced);
    }
    return forced;
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
            for (try self.heap.getList(id)) |item| try forceDeepInner(self, item, seen);
        },
        .attrs => {
            const id = forced.asObjectId();
            if (!try enterDeep(self, .attrs, id, seen)) return;
            for (try self.heap.getAttrs(id)) |entry| try forceDeepInner(self, entry.value, seen);
        },
        else => {},
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
    const thunk_id = thunk_val.asObjectId();
    var target: ThunkTarget = undefined;
    const claimed = try self.heap.getThunk(thunk_id);
    switch (claimed.tryClaim()) {
        .already_resolved => return claimed.result,
        .claimed => target = claimed.target,
        .busy => return error.RecursiveThunk,
    }

    const result = evalThunkTarget(self, target) catch |err| {
        const failed = try self.heap.getThunk(thunk_id);
        failed.reset();
        return err;
    };
    const resolved = try self.heap.getThunk(thunk_id);
    resolved.resolve(result);
    return result;
}

pub fn evalThunkTarget(self: *VM, target: ThunkTarget) anyerror!Value {
    return switch (target) {
        .closure => |closure| evalThunkClosure(self, closure),
        .bytecode => |bytecode| blk: {
            const ch = self.registry.get(bytecode.chunk_id) orelse return error.InvalidChunk;
            break :blk closures.runIsolatedFrame(self, ch, 0, bytecode.upvalues);
        },
    };
}

pub fn evalThunkClosure(self: *VM, closure_val: Value) anyerror!Value {
    switch (closure_val.discriminant) {
        .closure => {
            const closure_id = closure_val.asObjectId();
            const closure = try closures.getClosureById(self, closure_id);
            const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
            return closures.runIsolatedFrame(self, ch, 0, closure.upvalues);
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
    return Value.thunk(id);
}

pub fn makeCell(self: *VM, val: Value) !Value {
    const id = try self.heap.addCell(.{ .value = val });
    return Value.cell(id);
}
