const Value = @import("../../runtime/value.zig").Value;
const BuiltinId = @import("../../builtins.zig").BuiltinId;
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const vm_equality = @import("../equality.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");

pub fn makeBuiltinClosure(self: anytype, builtin_id: u16, args: []const Value) !Value {
    return Value.builtinClosure(try self.heap.addBuiltinClosure(builtin_id, args));
}

pub fn makeBuiltinThunk(self: anytype, id: BuiltinId, args: []const Value) !Value {
    return vm_force.makeThunk(self, try makeBuiltinClosure(self, @intFromEnum(id), args));
}
