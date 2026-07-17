const std = @import("std");
const testing = std.testing;
const Evaluator = @import("../../eval.zig").Evaluator;
const disasm = @import("../../tooling/bytecode.zig").disasm;

/// One decoded disassembler line: the opcode name and its 0-based position
/// in the (depth-first, recursive) disassembly of `source`'s compiled
/// chunk graph. Lets tests assert on opcode-sequence ordering (e.g. "the
/// jump falls between the two operand pushes") without hand-decoding the
/// bytecode stream or pinning byte offsets.
const OpLine = struct { name: []const u8, index: usize };

/// Compile `source` with a fresh single-threaded `Evaluator`, recursively
/// disassemble every reachable chunk via the real disassembler, and split
/// the result into per-line opcode names in program order. The caller owns
/// the returned text buffer (`text`) and must free it; `lines` borrows from
/// it.
const Disassembly = struct {
    text: []u8,
    lines: []OpLine,

    fn deinit(self: *Disassembly, allocator: std.mem.Allocator) void {
        allocator.free(self.lines);
        allocator.free(self.text);
    }

    /// First line whose opcode is exactly `name`.
    fn find(self: *const Disassembly, name: []const u8) ?usize {
        for (self.lines) |line| {
            if (std.mem.eql(u8, line.name, name)) return line.index;
        }
        return null;
    }

    fn contains(self: *const Disassembly, name: []const u8) bool {
        return self.find(name) != null;
    }

    fn count(self: *const Disassembly, name: []const u8) usize {
        var total: usize = 0;
        for (self.lines) |line| if (std.mem.eql(u8, line.name, name)) {
            total += 1;
        };
        return total;
    }
};

fn disassemble(ev: *Evaluator, source: []const u8) !Disassembly {
    const chunk_id = try ev.compileSource(source, null);
    const target = ev.getChunk(chunk_id).?;
    const symbols = disasm.Symbols{ .intern = ev.internTable(), .registry = ev.chunkRegistry() };
    const options = disasm.Options{ .recurse = true, .max_depth = 16 };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try disasm.writeChunk(testing.allocator, &out.writer, chunk_id, target, symbols, options);
    const text = try out.toOwnedSlice();
    errdefer testing.allocator.free(text);

    var lines: std.ArrayListUnmanaged(OpLine) = .empty;
    errdefer lines.deinit(testing.allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    var idx: usize = 0;
    while (it.next()) |raw_line| : (idx += 1) {
        // Every body line starts with the chunk left-margin guide "│ "; strip it.
        const line = if (std.mem.startsWith(u8, raw_line, "│ ")) raw_line["│ ".len..] else raw_line;
        // Instruction lines are "  xxxx  opname<spaces...>operands"; every
        // other line (headers, constants, blanks) starts differently.
        if (line.len < 8 or line[0] != ' ' or line[1] != ' ') continue;
        const hex = line[2..6];
        if (!std.mem.eql(u8, line[6..8], "  ")) continue;
        var hex_ok = true;
        for (hex) |c| {
            if (!std.ascii.isHex(c)) hex_ok = false;
        }
        if (!hex_ok) continue;
        const rest = std.mem.trimStart(u8, line[8..], " ");
        const name_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        try lines.append(testing.allocator, .{ .name = rest[0..name_end], .index = idx });
    }
    return .{ .text = text, .lines = try lines.toOwnedSlice(testing.allocator) };
}

test "compileBinary emits the runtime add opcode for non-literal operands" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();
    // Locals (lambda params), not literals, so the `+` can't constant-fold
    // — the runtime `int_add` opcode must actually be emitted.
    var d = try disassemble(&ev, "a: b: a + b");
    defer d.deinit(testing.allocator);
    try testing.expect(d.contains("int_add"));
}

test "compileBinary emits the runtime sub/mul/div opcodes for non-literal operands" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();

    var sub_d = try disassemble(&ev, "a: b: a - b");
    defer sub_d.deinit(testing.allocator);
    try testing.expect(sub_d.contains("int_sub"));

    var mul_d = try disassemble(&ev, "a: b: a * b");
    defer mul_d.deinit(testing.allocator);
    try testing.expect(mul_d.contains("int_mul"));

    var div_d = try disassemble(&ev, "a: b: a / b");
    defer div_d.deinit(testing.allocator);
    try testing.expect(div_d.contains("int_div"));
}

test "compileBinary emits comparison opcodes for non-literal operands" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();

    var lt_d = try disassemble(&ev, "a: b: a < b");
    defer lt_d.deinit(testing.allocator);
    try testing.expect(lt_d.contains("cmp_lt"));

    var eq_d = try disassemble(&ev, "a: b: a == b");
    defer eq_d.deinit(testing.allocator);
    try testing.expect(eq_d.contains("cmp_eq"));
}

test "fully applied operator-equivalent builtins lower to VM opcodes" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();

    const cases = [_]struct { source: []const u8, opcode: []const u8 }{
        .{ .source = "a: b: builtins.sub a b", .opcode = "int_sub" },
        .{ .source = "a: b: builtins.mul a b", .opcode = "int_mul" },
        .{ .source = "a: b: builtins.div a b", .opcode = "int_div" },
        .{ .source = "a: b: builtins.lessThan a b", .opcode = "cmp_lt" },
        .{ .source = "s: builtins.getAttr \"x\" s", .opcode = "loc_get_attr" },
        .{ .source = "s: builtins.hasAttr \"x\" s", .opcode = "attr_has_strict" },
    };
    for (cases) |case| {
        var d = try disassemble(&ev, case.source);
        defer d.deinit(testing.allocator);
        try testing.expect(d.contains(case.opcode));
        try testing.expect(!d.contains("call_n"));
        try testing.expect(!d.contains("call_tail_n"));
        try testing.expect(!d.contains("push_builtins"));
    }
}

test "builtin opcode lowering requires saturation and the global builtins set" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();

    var partial = try disassemble(&ev, "builtins.sub 1");
    defer partial.deinit(testing.allocator);
    try testing.expect(partial.contains("push_builtins"));
    try testing.expect(partial.contains("call") or partial.contains("call_tail"));

    var shadowed = try disassemble(&ev, "let builtins = { sub = a: b: 42; }; in builtins.sub 1 2");
    defer shadowed.deinit(testing.allocator);
    try testing.expect(shadowed.contains("call_n") or shadowed.contains("call_tail_n"));
    try testing.expect(!shadowed.contains("int_sub"));
}

test "inherit-from group compiles one shared source thunk" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();

    var d = try disassemble(&ev, "let inherit (builtins.trace \"once\" { a = 1; b = 2; }) a b; in a + b");
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), d.count("thunk_attr"));
    // The source application exists in one child chunk, not one clone per
    // inherited name.
    try testing.expectEqual(@as(usize, 1), d.count("push_builtins"));
}

test "static literal selection skips attrset construction" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();

    var selected = try disassemble(&ev, "({ a = 1; b = builtins.throw \"unused\"; }).a");
    defer selected.deinit(testing.allocator);
    try testing.expect(!selected.contains("attrs_new"));
    try testing.expect(!selected.contains("attrs_new_srt"));
    try testing.expect(!selected.contains("attrs_new_named_srt"));
    try testing.expect(!selected.contains("attr_get"));
    try testing.expect(!selected.contains("push_builtins"));

    var nested = try disassemble(&ev, "({ a = { b = 2; c = 3; }; x = 4; }).a.b");
    defer nested.deinit(testing.allocator);
    try testing.expect(!nested.contains("attrs_new"));
    try testing.expect(!nested.contains("attr_get"));

    // Dynamic keys and recursive sets keep the general construction path.
    var dynamic = try disassemble(&ev, "name: ({ ${name} = 1; a = 2; }).a");
    defer dynamic.deinit(testing.allocator);
    try testing.expect(dynamic.contains("attrs_new"));
    var recursive = try disassemble(&ev, "(rec { a = 1; }).a");
    defer recursive.deinit(testing.allocator);
    try testing.expect(recursive.contains("attrs_new_named_srt") or recursive.contains("attrs_new_named_pos_srt"));
}

test "static literal membership emits a boolean without member code" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();

    var present = try disassemble(&ev, "({ a = builtins.throw \"unused\"; } ? a)");
    defer present.deinit(testing.allocator);
    try testing.expect(present.contains("push_true"));
    try testing.expect(!present.contains("attr_has_path"));
    try testing.expect(!present.contains("push_builtins"));

    var missing = try disassemble(&ev, "({ a = 1; } ? b)");
    defer missing.deinit(testing.allocator);
    try testing.expect(missing.contains("push_false"));
    try testing.expect(!missing.contains("attr_has_path"));
}

test "repeated constants share one chunk-pool index" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();

    var d = try disassemble(&ev, "x: x + 7 + 7");
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), d.count("push_const"));
    try testing.expect(std.mem.indexOf(u8, d.text, "push_const #0") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "push_const #1") == null);
}

test "compileBinary folds literal-on-literal arithmetic to a constant instead of emitting an opcode" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();
    var d = try disassemble(&ev, "1 + 2");
    defer d.deinit(testing.allocator);
    try testing.expect(!d.contains("int_add"));
    try testing.expect(d.contains("push_const") or d.contains("push_const_ret"));
}

test "compileAnd emits a jump strictly between the two operand pushes" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();
    // Uncurried two-param lambda: both `a` and `b` compile to `loc_get`
    // reads in one chunk, so the two occurrences bracket the jump.
    var d = try disassemble(&ev, "a: b: a && b");
    defer d.deinit(testing.allocator);

    const jump_line = d.find("jump_false").?;
    var first_local: ?usize = null;
    var second_local: ?usize = null;
    for (d.lines) |line| {
        if (!std.mem.eql(u8, line.name, "loc_get")) continue;
        if (first_local == null) {
            first_local = line.index;
        } else if (second_local == null) {
            second_local = line.index;
        }
    }
    try testing.expect(first_local.? < jump_line);
    try testing.expect(jump_line < second_local.?);
}

test "compileOr emits a jump strictly between the two operand pushes" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();
    var d = try disassemble(&ev, "a: b: a || b");
    defer d.deinit(testing.allocator);

    const false_jump_line = d.find("jump_false").?;
    const end_jump_line = d.find("jump").?;
    try testing.expect(false_jump_line < end_jump_line);

    var first_local: ?usize = null;
    var second_local: ?usize = null;
    for (d.lines) |line| {
        if (!std.mem.eql(u8, line.name, "loc_get")) continue;
        if (first_local == null) {
            first_local = line.index;
        } else if (second_local == null) {
            second_local = line.index;
        }
    }
    // Left operand precedes both jumps; right operand follows both.
    try testing.expect(first_local.? < false_jump_line);
    try testing.expect(end_jump_line < second_local.?);
}

test "&& never evaluates its right-hand side when the left side is false" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();
    // If `1/0` were evaluated, this would raise DivisionByZero.
    const v = try ev.evaluate("false && (1 / 0 == 0)");
    try testing.expect(v.isBool());
    try testing.expect(!v.asBool());
}

test "|| never evaluates its right-hand side when the left side is true" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();
    const v = try ev.evaluate("true || (1 / 0 == 0)");
    try testing.expect(v.isBool());
    try testing.expect(v.asBool());
}

test "&& does evaluate its right-hand side when the left side is true" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();
    try testing.expectError(error.DivisionByZero, ev.evaluate("true && (1 / 0 == 0)"));
}

test "|| does evaluate its right-hand side when the left side is false" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();
    try testing.expectError(error.DivisionByZero, ev.evaluate("false || (1 / 0 == 0)"));
}

test "compileLambda and compileLambdaAttrs produce different chunk shapes" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();

    var value_lambda = try disassemble(&ev, "x: x");
    defer value_lambda.deinit(testing.allocator);
    var attrs_lambda = try disassemble(&ev, "{ x }: x");
    defer attrs_lambda.deinit(testing.allocator);

    // Only the attrset-pattern lambda validates its argument shape.
    try testing.expect(!value_lambda.contains("attr_bind"));
    try testing.expect(attrs_lambda.contains("attr_bind"));

    // Both compile to a top-level closure creation over a nested body chunk.
    try testing.expect(value_lambda.contains("closure"));
    try testing.expect(attrs_lambda.contains("closure"));
}

test "applying a non-callable value raises NotCallable instead of panicking" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();
    try testing.expectError(error.NotCallable, ev.evaluate("(1) 2"));
}

test "duplicate let bindings raise a parse error instead of panicking" {
    var ev = try Evaluator.init(testing.allocator, 0);
    defer ev.deinit();
    try testing.expectError(error.ParseError, ev.evaluate("let x = 1; x = 2; in x"));
}
