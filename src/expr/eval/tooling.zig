//! Explicit read-mostly evaluator adapter for debugger/CLI tooling.

const runtime = @import("runtime");
const types = runtime.types;
const Value = runtime.value.Value;

pub fn Adapter(comptime Evaluator: type) type {
    return struct {
        ev: *Evaluator,

        const Self = @This();

        pub fn attrs(self: Self, value: Value) ![]const runtime.heap.AttrEntry {
            return self.ev.heap.getAttrs(value.asObjectId());
        }

        pub fn listLen(self: Self, value: Value) !usize {
            return self.ev.heap.getListLen(value.asObjectId());
        }

        pub fn internText(self: Self, id: types.InternId) []const u8 {
            return self.ev.intern.get(id);
        }

        pub fn intern(self: Self, text: []const u8) !types.InternId {
            return self.ev.intern.intern(text);
        }

        pub fn attrValueOpt(self: Self, value: Value, name: types.InternId) !?Value {
            return self.ev.heap.getAttrValueOpt(value.asObjectId(), name);
        }

        pub fn thunk(self: Self, value: Value) !*runtime.thunk.Thunk {
            return self.ev.heap.getThunk(value.asObjectId());
        }

        pub fn closure(self: Self, value: Value) !runtime.heap.Closure {
            return self.ev.heap.getClosure(value.asObjectId());
        }

        pub fn reportCreationCensus(self: Self) void {
            self.ev.heap.profCreationCensus();
            self.ev.heap.profSiblingCensus();
        }
    };
}
