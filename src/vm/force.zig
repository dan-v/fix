const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../types.zig");
const Value = @import("../value.zig").Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const ObjectId = types.ObjectId;
const bytecode_mod = @import("../bytecode.zig");
const opcode = @import("../opcode.zig");
const OpCode = opcode.OpCode;
const chunk = @import("../chunk.zig");
const Chunk = chunk.Chunk;
const thunk_mod = @import("../thunk.zig");
const Thunk = thunk_mod.Thunk;
const ThunkTarget = thunk_mod.ThunkTarget;
const heap_mod = @import("../heap.zig");
const Closure = heap_mod.Closure;
const numeric = @import("../runtime/numeric.zig");
const source_paths = @import("../runtime/source_path.zig");
const vm_builtins = @import("builtins.zig");
const diagnostic = @import("../diagnostic.zig");

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const opcode_profile_enabled = vm_mod.opcode_profile_enabled;
const readU16 = vm_mod.readU16;
const readU32 = vm_mod.readU32;
const readInternId = vm_mod.readInternId;

// ---- thunk management ----

pub fn forceThunk(self: *VM, thunk_val: Value) !Value {
    return self.forceThunkFallible(thunk_val);
}

pub inline fn forceValue(self: *VM, value: Value) anyerror!Value {
    return switch (value.discriminant) {
        .thunk => try self.forceThunkFallible(value),
        .cell => try self.forceCellValue(value),
        else => value,
    };
}

pub fn forceCellValue(self: *VM, value: Value) anyerror!Value {
    const cell_id = value.asObjectId();
    const raw = try self.heap.getCellValue(cell_id);
    const forced = try self.forceValue(raw);
    if (raw.discriminant == .thunk or raw.discriminant == .cell) {
        try self.heap.setCellValue(cell_id, forced);
    }
    return forced;
}

pub fn forceDeep(self: *VM, value: Value) !void {
    var seen: std.ArrayListUnmanaged(SeenDeepObject) = .empty;
    defer seen.deinit(self.allocator);
    try self.forceDeepInner(value, &seen);
}

pub const SeenDeepKind = enum { list, attrs };

pub const SeenDeepObject = struct {
    kind: SeenDeepKind,
    id: ObjectId,
};

pub fn forceDeepInner(self: *VM, value: Value, seen: *std.ArrayListUnmanaged(SeenDeepObject)) anyerror!void {
    const forced = try self.forceValue(value);
    switch (forced.discriminant) {
        .list => {
            const id = forced.asObjectId();
            if (!try self.enterDeep(.list, id, seen)) return;
            for (try self.heap.getList(id)) |item| try self.forceDeepInner(item, seen);
        },
        .attrs => {
            const id = forced.asObjectId();
            if (!try self.enterDeep(.attrs, id, seen)) return;
            for (try self.heap.getAttrs(id)) |entry| try self.forceDeepInner(entry.value, seen);
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

    const result = self.evalThunkTarget(target) catch |err| {
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
        .closure => |closure| self.evalThunkClosure(closure),
        .bytecode => |bytecode| blk: {
            const ch = self.registry.get(bytecode.chunk_id) orelse return error.InvalidChunk;
            break :blk self.runIsolatedFrame(ch, 0, bytecode.upvalues);
        },
    };
}

pub fn evalThunkClosure(self: *VM, closure_val: Value) anyerror!Value {
    switch (closure_val.discriminant) {
        .closure => {
            const closure_id = closure_val.asObjectId();
            const closure = try self.getClosureById(closure_id);
            const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
            return self.runIsolatedFrame(ch, 0, closure.upvalues);
        },
        .builtin_closure => {
            const closure = try self.heap.getBuiltinClosure(closure_val.asObjectId());
            return self.applyBuiltin(closure.builtin_id, closure.args);
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
