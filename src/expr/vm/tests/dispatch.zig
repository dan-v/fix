//! Opcode-level dispatch tests for `run.zig` and its small vm/ support
//! files (access.zig, equality.zig, stack.zig, strings.zig).
//!
//! These hand-build a `Chunk` via `ChunkBuilder` and run it to
//! completion through the real dispatcher via
//! `closures.runIsolatedFrame` — the same entry point production code
//! uses to run a bytecode thunk/closure body (see `vm/force.zig`,
//! `vm/closures.zig`). This lets us exercise individual opcodes
//! without going through the parser/compiler.

const std = @import("std");
const testing = std.testing;

const eval_mod = @import("../../evaluator.zig");
const Engine = eval_mod.Engine;
const vm_mod = @import("../../vm.zig");
const VM = vm_mod.VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const heap_mod = @import("runtime").heap;
const bytecode = @import("../../bytecode.zig");
const ChunkBuilder = bytecode.ChunkBuilder;
const OpCode = bytecode.OpCode;
const closures = @import("../../vm.zig").closures;
const force = @import("../../vm.zig").force;
const stack = @import("../../vm.zig").stack;
const equality = @import("../../vm.zig").equality;
const FutureState = @import("runtime").future.FutureState;

/// A live Engine plus a bare VM sharing its registry/heap/intern
/// state. `evaluate("null")` on the Engine first drives the normal
/// public API once, which builds the builtins attrset and starts the
/// scheduler — everything a hand-built chunk running through
/// `runIsolatedFrame` needs already in place.
///
/// `ev` is heap-allocated so its address is stable: `vm` holds pointers
/// into it (`&ev.registry`, `&ev.heap`, ...), and returning an
/// `Engine` by value out of a constructor would move it, dangling
/// those pointers.
const Harness = struct {
    ev: *Engine,
    /// VM scratch arena. Heap-allocated for the same address-stability
    /// reason as `ev`: the VM's allocator captures its address.
    scratch: *std.heap.ArenaAllocator,
    vm: VM,

    fn init() !Harness {
        const ev = try testing.allocator.create(Engine);
        errdefer testing.allocator.destroy(ev);
        ev.* = try Engine.init(testing.allocator, .{ .worker_count = 0 });
        errdefer ev.deinit();
        _ = try ev.evaluate("null");

        const scratch = try testing.allocator.create(std.heap.ArenaAllocator);
        errdefer testing.allocator.destroy(scratch);
        scratch.* = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer scratch.deinit();

        const vm = try VM.init(.{
            .driver = &vm_mod.driver,
            .allocator = scratch.allocator(),
            .registry = &ev.registry,
            .intern = &ev.intern,
            .heap = &ev.heap,
            .files = &ev.sources.files,
            .fetchers = &ev.sources.fetchers,
            .realization = &ev.store.realization,
            .workers = @import("../../eval/workers/vm_runtime.zig").Runtime.init(&ev.execution.scheduler),
            .builtins_value = ev.builtins_value.?,
        });
        return .{ .ev = ev, .scratch = scratch, .vm = vm };
    }

    fn deinit(self: *Harness) void {
        self.vm.deinit();
        self.scratch.deinit();
        testing.allocator.destroy(self.scratch);
        self.ev.deinit();
        testing.allocator.destroy(self.ev);
    }
};

/// Build a chunk from a caller-supplied builder callback and run it via
/// `runIsolatedFrame` with no arguments/upvalues. `build` receives the
/// builder and the allocator it was created with.
fn runChunk(h: *Harness, comptime build: fn (*ChunkBuilder, std.mem.Allocator) anyerror!void, local_count: u16) !Value {
    var builder = try ChunkBuilder.init(testing.allocator);
    defer builder.deinit(testing.allocator);
    try build(&builder, testing.allocator);
    const ch = try builder.finish(testing.allocator, local_count);
    // `register` takes ownership of `ch` (stores it by value and frees it
    // from `ChunkRegistry.deinit`) — don't also free it here.
    const chunk_id = try h.ev.registry.register(ch);
    return closures.runIsolatedFrame(&h.vm, h.ev.registry.get(chunk_id).?, chunk_id, 0, null, null, false);
}

// ---- harness round-trip ----

fn buildReturnConstant(b: *ChunkBuilder, a: std.mem.Allocator) !void {
    try b.emitConstant(a, Value.int(42));
    try b.writeOp(a, .ret);
}

test "runIsolatedFrame round-trips a minimal constant-returning chunk" {
    var h = try Harness.init();
    defer h.deinit();

    const result = try runChunk(&h, buildReturnConstant, 0);
    try testing.expect(result.isInt());
    try testing.expectEqual(@as(i64, 42), result.asInt());
}

// ---- jump / branch opcodes ----

fn buildJumpIfFalseTaken(b: *ChunkBuilder, a: std.mem.Allocator) !void {
    // if (false) 1 else 2  -- compiled by hand:
    //   push_false
    //   jump_false -> else_branch
    //   constant 1
    //   jump -> end
    // else_branch:
    //   constant 2
    // end:
    //   ret
    try b.writeOp(a, .push_false);
    try b.writeOp(a, .jump_false);
    const jif_operand = b.code.items.len;
    try b.writeU32(a, 0); // placeholder
    try b.emitConstant(a, Value.int(1));
    try b.writeOp(a, .jump);
    const jmp_operand = b.code.items.len;
    try b.writeU32(a, 0); // placeholder

    const else_branch = b.code.items.len;
    try b.emitConstant(a, Value.int(2));
    const end = b.code.items.len;
    try b.writeOp(a, .ret);

    patchU32(b, jif_operand, @intCast(else_branch - (jif_operand + 4)));
    patchU32(b, jmp_operand, @intCast(end - (jmp_operand + 4)));
}

fn buildJumpIfFalseNotTaken(b: *ChunkBuilder, a: std.mem.Allocator) !void {
    // if (true) 1 else 2
    try b.writeOp(a, .push_true);
    try b.writeOp(a, .jump_false);
    const jif_operand = b.code.items.len;
    try b.writeU32(a, 0);
    try b.emitConstant(a, Value.int(1));
    try b.writeOp(a, .jump);
    const jmp_operand = b.code.items.len;
    try b.writeU32(a, 0);

    const else_branch = b.code.items.len;
    try b.emitConstant(a, Value.int(2));
    const end = b.code.items.len;
    try b.writeOp(a, .ret);

    patchU32(b, jif_operand, @intCast(else_branch - (jif_operand + 4)));
    patchU32(b, jmp_operand, @intCast(end - (jmp_operand + 4)));
}

fn patchU32(b: *ChunkBuilder, offset: usize, val: u32) void {
    std.mem.writeInt(u32, b.code.items[offset..][0..4], val, .little);
}

test "jump_false takes the branch on a false condition" {
    var h = try Harness.init();
    defer h.deinit();

    const result = try runChunk(&h, buildJumpIfFalseTaken, 0);
    try testing.expect(result.isInt());
    try testing.expectEqual(@as(i64, 2), result.asInt());
}

test "jump_false falls through on a true condition" {
    var h = try Harness.init();
    defer h.deinit();

    const result = try runChunk(&h, buildJumpIfFalseNotTaken, 0);
    try testing.expect(result.isInt());
    try testing.expectEqual(@as(i64, 1), result.asInt());
}

// ---- list / attr index access (access.zig via attr_get) ----

test "attr_get selects an attribute from a hand-built attrset" {
    var h = try Harness.init();
    defer h.deinit();

    // { x = 1; y = 2; }.y
    // attrs_new expects [name1, val1, name2, val2] pairs on the stack,
    // where each name is a string Value carrying the attribute's
    // InternId (see `heap.addAttrsFromStackPairs`).
    const x_id = try h.ev.intern.intern("x");
    const y_id = try h.ev.intern.intern("y");

    var builder = try ChunkBuilder.init(testing.allocator);
    defer builder.deinit(testing.allocator);
    try builder.emitConstant(testing.allocator, Value.string(x_id));
    try builder.emitConstant(testing.allocator, Value.int(1));
    try builder.emitConstant(testing.allocator, Value.string(y_id));
    try builder.emitConstant(testing.allocator, Value.int(2));
    try builder.writeOp(testing.allocator, .attrs_new);
    try builder.writeU16(testing.allocator, 2);
    try builder.writeOp(testing.allocator, .attr_get);
    try builder.writeU16(testing.allocator, @intCast(y_id));
    try builder.writeOp(testing.allocator, .ret);

    const ch = try builder.finish(testing.allocator, 0);
    const chunk_id = try h.ev.registry.register(ch);
    const result = try closures.runIsolatedFrame(&h.vm, h.ev.registry.get(chunk_id).?, chunk_id, 0, null, null, false);

    try testing.expect(result.isInt());
    try testing.expectEqual(@as(i64, 2), result.asInt());
}

fn buildListIndexViaBuiltin(b: *ChunkBuilder, a: std.mem.Allocator) !void {
    try b.emitConstant(a, Value.int(10));
    try b.emitConstant(a, Value.int(20));
    try b.emitConstant(a, Value.int(30));
    try b.writeOp(a, .list_new);
    try b.writeU16(a, 3);
    try b.writeOp(a, .ret);
}

test "list_new constructs a list value from stack items" {
    var h = try Harness.init();
    defer h.deinit();

    const result = try runChunk(&h, buildListIndexViaBuiltin, 0);
    try testing.expect(result.isList());
    const items = try h.vm.heap.getList(result.asObjectId());
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(@as(i64, 10), items[0].asInt());
    try testing.expectEqual(@as(i64, 20), items[1].asInt());
    try testing.expectEqual(@as(i64, 30), items[2].asInt());
}

// ---- attrset/list merge opcodes (objects.zig) ----

const objects_mod = @import("../../vm.zig").objects;

test "merge_attrs lets the right-hand side override a colliding key" {
    var h = try Harness.init();
    defer h.deinit();

    const x_id = try h.ev.intern.intern("x");
    const y_id = try h.ev.intern.intern("y");
    const left_entries = [_]heap_mod.AttrEntry{
        .{ .name = x_id, .value = Value.int(1) },
    };
    const right_entries = [_]heap_mod.AttrEntry{
        .{ .name = x_id, .value = Value.int(2) },
        .{ .name = y_id, .value = Value.int(3) },
    };
    const left = Value.attrs(try h.vm.heap.addAttrs(&left_entries));
    const right = Value.attrs(try h.vm.heap.addAttrs(&right_entries));

    const merged = try objects_mod.mergeAttrs(&h.vm, left, right);

    try testing.expect(merged.kind() == .attrs);
    const x_val = try h.vm.heap.getAttrValue(merged.asObjectId(), x_id);
    const y_val = try h.vm.heap.getAttrValue(merged.asObjectId(), y_id);
    try testing.expectEqual(@as(i64, 2), x_val.asInt());
    try testing.expectEqual(@as(i64, 3), y_val.asInt());
}

test "attrs_merge_strict rejects a colliding non-attrs key" {
    var h = try Harness.init();
    defer h.deinit();

    const x_id = try h.ev.intern.intern("x");
    const left_entries = [_]heap_mod.AttrEntry{.{ .name = x_id, .value = Value.int(1) }};
    const right_entries = [_]heap_mod.AttrEntry{.{ .name = x_id, .value = Value.int(2) }};
    const left = Value.attrs(try h.vm.heap.addAttrs(&left_entries));
    const right = Value.attrs(try h.vm.heap.addAttrs(&right_entries));

    try testing.expectError(error.DuplicateAttribute, objects_mod.mergeAttrsStrict(&h.vm, left, right));
}

test "list_cat concatenates two lists in order" {
    var h = try Harness.init();
    defer h.deinit();

    const left_items = [_]Value{ Value.int(1), Value.int(2) };
    const right_items = [_]Value{ Value.int(3), Value.int(4) };
    const left = Value.list(try h.vm.heap.addList(&left_items));
    const right = Value.list(try h.vm.heap.addList(&right_items));

    const result = try objects_mod.concatLists(&h.vm, left, right);
    try testing.expect(result.isList());
    const items = try h.vm.heap.getList(result.asObjectId());
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqual(@as(i64, 1), items[0].asInt());
    try testing.expectEqual(@as(i64, 2), items[1].asInt());
    try testing.expectEqual(@as(i64, 3), items[2].asInt());
    try testing.expectEqual(@as(i64, 4), items[3].asInt());
}

test "list_cat_n concatenates stack lists once and preserves order" {
    var h = try Harness.init();
    defer h.deinit();

    const a = Value.list(try h.vm.heap.addList(&.{Value.int(1)}));
    const empty = Value.list(try h.vm.heap.addList(&.{}));
    const c = Value.list(try h.vm.heap.addList(&.{ Value.int(2), Value.int(3) }));
    try stack.push(&h.vm, a);
    try stack.push(&h.vm, empty);
    try stack.push(&h.vm, c);

    const result = try objects_mod.concatStackLists(&h.vm, 3);
    const items = try h.vm.heap.getList(result.asObjectId());
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(@as(i64, 1), items[0].asInt());
    try testing.expectEqual(@as(i64, 2), items[1].asInt());
    try testing.expectEqual(@as(i64, 3), items[2].asInt());
}

// ---- equality semantics (equality.zig) ----

test "NaN is never equal to itself" {
    var h = try Harness.init();
    defer h.deinit();

    const nan_val = Value.float(std.math.nan(f64));
    const is_eq = try equality.valuesEqual(&h.vm, nan_val, nan_val);
    try testing.expect(!is_eq);
}

test "lists compare structurally by element equality" {
    var h = try Harness.init();
    defer h.deinit();

    const a_items = [_]Value{ Value.int(1), Value.int(2) };
    const b_items = [_]Value{ Value.int(1), Value.int(2) };
    const c_items = [_]Value{ Value.int(1), Value.int(3) };

    const list_a = Value.list(try h.vm.heap.addList(&a_items));
    const list_b = Value.list(try h.vm.heap.addList(&b_items));
    const list_c = Value.list(try h.vm.heap.addList(&c_items));

    try testing.expect(try equality.valuesEqual(&h.vm, list_a, list_b));
    try testing.expect(!try equality.valuesEqual(&h.vm, list_a, list_c));
}

test "attrsets compare structurally by name and value equality" {
    var h = try Harness.init();
    defer h.deinit();

    const x_id = try h.ev.intern.intern("x");
    const entries_a = [_]heap_mod.AttrEntry{.{ .name = x_id, .value = Value.int(1) }};
    const entries_b = [_]heap_mod.AttrEntry{.{ .name = x_id, .value = Value.int(1) }};
    const entries_c = [_]heap_mod.AttrEntry{.{ .name = x_id, .value = Value.int(2) }};

    const attrs_a = Value.attrs(try h.vm.heap.addAttrs(&entries_a));
    const attrs_b = Value.attrs(try h.vm.heap.addAttrs(&entries_b));
    const attrs_c = Value.attrs(try h.vm.heap.addAttrs(&entries_c));

    try testing.expect(try equality.valuesEqual(&h.vm, attrs_a, attrs_b));
    try testing.expect(!try equality.valuesEqual(&h.vm, attrs_a, attrs_c));
}

test "function values are never equal even when structurally identical" {
    var h = try Harness.init();
    defer h.deinit();

    var builder = try ChunkBuilder.init(testing.allocator);
    defer builder.deinit(testing.allocator);
    try builder.emitConstant(testing.allocator, Value.int(1));
    try builder.writeOp(testing.allocator, .ret);
    const ch = try builder.finish(testing.allocator, 0);
    const chunk_id = try h.ev.registry.register(ch);

    const closure_a = try h.vm.heap.addClosure(chunk_id, &.{});
    const closure_b = try h.vm.heap.addClosure(chunk_id, &.{});

    const fn_a = Value.closure(closure_a);
    const fn_b = Value.closure(closure_b);

    // Same chunk, same (empty) upvalues, but distinct closure objects:
    // never equal.
    try testing.expect(!try equality.valuesEqual(&h.vm, fn_a, fn_b));
    // A closure is only equal to itself (identity).
    try testing.expect(try equality.valuesEqual(&h.vm, fn_a, fn_a));
}

// ---- stack.zig: push/pop/peek primitives ----

test "stack push and pop round-trip a value" {
    var h = try Harness.init();
    defer h.deinit();

    try stack.push(&h.vm, Value.int(7));
    try testing.expectEqual(@as(u32, 1), h.vm.sp);
    const popped = stack.pop(&h.vm);
    try testing.expectEqual(@as(i64, 7), popped.asInt());
    try testing.expectEqual(@as(u32, 0), h.vm.sp);
}

test "stack push surfaces StackOverflow at capacity" {
    var h = try Harness.init();
    defer h.deinit();

    h.vm.sp = @intCast(types.vm_stack_capacity);
    try testing.expectError(error.StackOverflow, stack.push(&h.vm, Value.int(1)));
}

test "pushFrame surfaces StackOverflow when locals exceed remaining capacity" {
    var h = try Harness.init();
    defer h.deinit();

    var builder = try ChunkBuilder.init(testing.allocator);
    defer builder.deinit(testing.allocator);
    try builder.writeOp(testing.allocator, .push_null);
    try builder.writeOp(testing.allocator, .ret);
    // A chunk that reserves more locals than remain on the stack.
    const ch = try builder.finish(testing.allocator, 4);
    const chunk_id = try h.ev.registry.register(ch);

    h.vm.sp = @intCast(types.vm_stack_capacity - 1);
    try testing.expectError(error.StackOverflow, stack.pushFrame(&h.vm, h.ev.registry.get(chunk_id).?, chunk_id, 0, null, null, false));
}

// ---- fused thunk+store super-ops (thunkStoreOp) ----
//
// The compiler only reaches the wide (`thunk_w_*`) forms past 65,536
// registered chunks, so eval-level tests can't exercise them; hand-built
// bytecode can — the wide encoding is legal for any chunk id.

test "thunk_w_st creates a thunk from a wide chunk id and stores it into a local slot" {
    var h = try Harness.init();
    defer h.deinit();

    // Body: upvalue[0] + 2 — deliberately NOT a trivial shape, so a real
    // thunk is created and the fused op exercises the wide-id decode, the
    // capture-descriptor walk, and the local store.
    var body = try ChunkBuilder.init(testing.allocator);
    defer body.deinit(testing.allocator);
    try body.writeOp(testing.allocator, .up_get);
    try body.writeU16(testing.allocator, 0);
    try body.emitConstant(testing.allocator, Value.int(2));
    try body.writeOp(testing.allocator, .int_add);
    try body.writeOp(testing.allocator, .ret);
    try body.writeOp(testing.allocator, .halt);
    const body_id = try h.ev.registry.register(try body.finish(testing.allocator, 0));

    // Main (locals: [thunk_dst, captured_int]):
    //   push_const 40; loc_set 1
    //   thunk_w_st body_id:4 K=1 (kind=local, idx=1) slot=0
    //   loc_get 0   -- forces the stored thunk
    //   ret
    var main_b = try ChunkBuilder.init(testing.allocator);
    defer main_b.deinit(testing.allocator);
    try main_b.emitConstant(testing.allocator, Value.int(40));
    try main_b.writeOp(testing.allocator, .loc_set);
    try main_b.writeByte(testing.allocator, 1);
    try main_b.writeOp(testing.allocator, .thunk_w_st);
    try main_b.writeU32(testing.allocator, body_id);
    try main_b.writeU16(testing.allocator, 1);
    try main_b.writeByte(testing.allocator, 0); // descriptor kind: local
    try main_b.writeU16(testing.allocator, 1); // descriptor index
    try main_b.writeByte(testing.allocator, 0); // destination slot (trailing byte)
    try main_b.writeOp(testing.allocator, .loc_get);
    try main_b.writeByte(testing.allocator, 0);
    try main_b.writeOp(testing.allocator, .ret);
    const ch = try main_b.finish(testing.allocator, 2);
    const chunk_id = try h.ev.registry.register(ch);

    const result = try closures.runIsolatedFrame(&h.vm, h.ev.registry.get(chunk_id).?, chunk_id, 0, null, null, false);
    try testing.expect(result.isInt());
    try testing.expectEqual(@as(i64, 42), result.asInt());
}

test "thunk_w_st_cell publishes the thunk into a cell-initialized slot" {
    var h = try Harness.init();
    defer h.deinit();

    // Body: 21 * 2 — non-trivial, no captures.
    var body = try ChunkBuilder.init(testing.allocator);
    defer body.deinit(testing.allocator);
    try body.emitConstant(testing.allocator, Value.int(21));
    try body.emitConstant(testing.allocator, Value.int(2));
    try body.writeOp(testing.allocator, .int_mul);
    try body.writeOp(testing.allocator, .ret);
    try body.writeOp(testing.allocator, .halt);
    const body_id = try h.ev.registry.register(try body.finish(testing.allocator, 0));

    // Main: cell_init 0; thunk_w_st_cell body_id:4 K=0 slot=0; loc_get 0; ret
    // — the fused op must publish through the cell binding (publishCellBinding),
    // and forcing the cell must yield the body's value.
    var main_b = try ChunkBuilder.init(testing.allocator);
    defer main_b.deinit(testing.allocator);
    try main_b.writeOp(testing.allocator, .cell_init);
    try main_b.writeByte(testing.allocator, 0);
    try main_b.writeOp(testing.allocator, .thunk_w_st_cell);
    try main_b.writeU32(testing.allocator, body_id);
    try main_b.writeU16(testing.allocator, 0);
    try main_b.writeByte(testing.allocator, 0); // destination slot (trailing byte)
    try main_b.writeOp(testing.allocator, .loc_get);
    try main_b.writeByte(testing.allocator, 0);
    try main_b.writeOp(testing.allocator, .ret);
    const ch = try main_b.finish(testing.allocator, 1);
    const chunk_id = try h.ev.registry.register(ch);

    const result = try closures.runIsolatedFrame(&h.vm, h.ev.registry.get(chunk_id).?, chunk_id, 0, null, null, false);
    try testing.expect(result.isInt());
    try testing.expectEqual(@as(i64, 42), result.asInt());
}

test "resolved forwarding thunk forces an unresolved binding cell to WHNF" {
    var h = try Harness.init();
    defer h.deinit();

    const binding = try force.makeBindingCell(&h.vm);
    const outer_id = try h.vm.heap.addLazyShell(binding);
    h.vm.heap.getThunkAssumeValid(binding.asObjectId()).publishCellBindingSolo(Value.int(42));

    const result = try force.forceValue(&h.vm, Value.thunk(outer_id));
    try testing.expect(result.isInt());
    try testing.expectEqual(@as(i64, 42), result.asInt());
}

test "forwarding failure completes the outer thunk" {
    var h = try Harness.init();
    defer h.deinit();

    // Return an upvalue without forcing it so the outer bytecode thunk must
    // normalize the forwarding result itself.
    var body = try ChunkBuilder.init(testing.allocator);
    defer body.deinit(testing.allocator);
    try body.writeOp(testing.allocator, .up_grab);
    try body.writeU16(testing.allocator, 0);
    try body.writeOp(testing.allocator, .ret);
    try body.writeOp(testing.allocator, .halt);
    const body_id = try h.ev.registry.register(try body.finish(testing.allocator, 0));

    const binding = try force.makeBindingCell(&h.vm);
    h.vm.heap.getThunkAssumeValid(binding.asObjectId()).publishCellBindingSolo(binding);
    const outer_id = try h.vm.heap.addBytecodeThunk(body_id, &.{binding});
    const outer = Value.thunk(outer_id);

    try testing.expectError(error.RecursiveThunk, force.forceValue(&h.vm, outer));
    try testing.expectEqual(
        @intFromEnum(FutureState.errored),
        h.vm.heap.getThunkAssumeValid(outer_id).future.state.load(.acquire),
    );
    try testing.expectError(error.RecursiveThunk, force.forceValue(&h.vm, outer));
}

// ---- strings.zig: real logic (interned-string concatenation) ----

const strings_mod = @import("../../vm.zig").strings;

test "concatInternedString interns the concatenation of two interned strings" {
    var h = try Harness.init();
    defer h.deinit();

    const a_id = try h.ev.intern.intern("foo");
    const b_id = try h.ev.intern.intern("bar");
    const result_id = try strings_mod.concatInternedString(&h.vm, a_id, b_id);
    try testing.expectEqualStrings("foobar", h.ev.intern.get(result_id));
}

test "stringTextInternIdsEqual compares plain strings by interned id" {
    var h = try Harness.init();
    defer h.deinit();

    const a_id = try h.ev.intern.intern("same");
    const b_id = try h.ev.intern.intern("same");
    const c_id = try h.ev.intern.intern("different");

    try testing.expect(try strings_mod.stringTextInternIdsEqual(&h.vm, Value.string(a_id), Value.string(b_id)));
    try testing.expect(!try strings_mod.stringTextInternIdsEqual(&h.vm, Value.string(a_id), Value.string(c_id)));
}
