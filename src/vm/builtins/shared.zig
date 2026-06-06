const Value = @import("../../value.zig").Value;
const BuiltinId = @import("../../builtins.zig").BuiltinId;

pub fn makeBuiltinClosure(self: anytype, builtin_id: u16, args: []const Value) !Value {
    return Value.builtinClosure(try self.heap.addBuiltinClosure(builtin_id, args));
}

pub fn makeBuiltinThunk(self: anytype, id: BuiltinId, args: []const Value) !Value {
    return self.makeThunk(try makeBuiltinClosure(self, @intFromEnum(id), args));
}
