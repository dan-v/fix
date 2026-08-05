//! Representative-node tests for the AST → JSON serializer.

const std = @import("std");
const syntax = @import("syntax");
const ast = syntax.ast;
const parser_mod = syntax.parser;
const json = @import("../parse_json.zig");

/// Parse `source` and render its AST as JSON into an owned buffer.
fn render(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = ast.AstArena.init(allocator);
    defer arena.deinit();
    var parser = parser_mod.Parser.init(allocator, &arena, source);
    defer parser.deinit();
    const node = try parser.parse();

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try json.write(&buf.writer, allocator, source, node);
    return allocator.dupe(u8, buf.written());
}

fn expectJson(source: []const u8, expected: []const u8) !void {
    const out = try render(std.testing.allocator, source);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

fn renderWithFailingAllocator(allocator: std.mem.Allocator) !void {
    const source = "{ \"quoted name\" = ''${\"value\"}''; dynamic = \"a${1 + 2}b\"; nested.path = [ true false ]; }";
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();
    var parser = parser_mod.Parser.init(std.testing.allocator, &arena, source);
    defer parser.deinit();
    const node = try parser.parse();

    var output_buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try json.write(&output, allocator, source, node);
}

test "AST JSON serialization propagates every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        renderWithFailingAllocator,
        .{},
    );
}

test "integer literal" {
    try expectJson("42",
        \\{
        \\  "_type": "ExprLiteral",
        \\  "value": 42,
        \\  "valueType": "Int"
        \\}
        \\
    );
}

test "float forces a decimal point" {
    try expectJson("1.0",
        \\{
        \\  "_type": "ExprLiteral",
        \\  "value": 1.0,
        \\  "valueType": "Float"
        \\}
        \\
    );
}

test "true/false/null are ExprVar" {
    try expectJson("true",
        \\{
        \\  "_type": "ExprVar",
        \\  "value": "true"
        \\}
        \\
    );
}

test "select with or-default" {
    try expectJson("foo.bar or baz",
        \\{
        \\  "_type": "ExprSelect",
        \\  "attrs": [
        \\    "bar"
        \\  ],
        \\  "default": {
        \\    "_type": "ExprVar",
        \\    "value": "baz"
        \\  },
        \\  "e": {
        \\    "_type": "ExprVar",
        \\    "value": "foo"
        \\  }
        \\}
        \\
    );
}

test "subtraction lowers to __sub primop call" {
    try expectJson("a - b",
        \\{
        \\  "_type": "ExprCall",
        \\  "args": [
        \\    {
        \\      "_type": "ExprVar",
        \\      "value": "a"
        \\    },
        \\    {
        \\      "_type": "ExprVar",
        \\      "value": "b"
        \\    }
        \\  ],
        \\  "fun": {
        \\    "_type": "ExprVar",
        \\    "value": "__sub"
        \\  }
        \\}
        \\
    );
}

test "addition lowers to ExprConcatStrings" {
    try expectJson("1 + 2",
        \\{
        \\  "_type": "ExprConcatStrings",
        \\  "es": [
        \\    {
        \\      "_type": "ExprLiteral",
        \\      "value": 1,
        \\      "valueType": "Int"
        \\    },
        \\    {
        \\      "_type": "ExprLiteral",
        \\      "value": 2,
        \\      "valueType": "Int"
        \\    }
        \\  ],
        \\  "isInterpolation": false
        \\}
        \\
    );
}

test "curried application flattens into one call" {
    try expectJson("f a b",
        \\{
        \\  "_type": "ExprCall",
        \\  "args": [
        \\    {
        \\      "_type": "ExprVar",
        \\      "value": "a"
        \\    },
        \\    {
        \\      "_type": "ExprVar",
        \\      "value": "b"
        \\    }
        \\  ],
        \\  "fun": {
        \\    "_type": "ExprVar",
        \\    "value": "f"
        \\  }
        \\}
        \\
    );
}

test "lambda pattern with default and ellipsis" {
    try expectJson("{ a, b ? 1, ... }: a",
        \\{
        \\  "_type": "ExprLambda",
        \\  "body": {
        \\    "_type": "ExprVar",
        \\    "value": "a"
        \\  },
        \\  "formals": {
        \\    "a": null,
        \\    "b": {
        \\      "_type": "ExprLiteral",
        \\      "value": 1,
        \\      "valueType": "Int"
        \\    }
        \\  },
        \\  "formalsEllipsis": true
        \\}
        \\
    );
}

test "attr paths nest and merge" {
    try expectJson("{ a.b = 1; a.c = 2; }",
        \\{
        \\  "_type": "ExprSet",
        \\  "attrs": {
        \\    "a": {
        \\      "_type": "ExprSet",
        \\      "attrs": {
        \\        "b": {
        \\          "_type": "ExprLiteral",
        \\          "value": 1,
        \\          "valueType": "Int"
        \\        },
        \\        "c": {
        \\          "_type": "ExprLiteral",
        \\          "value": 2,
        \\          "valueType": "Int"
        \\        }
        \\      },
        \\      "recursive": false
        \\    }
        \\  },
        \\  "recursive": false
        \\}
        \\
    );
}

test "string interpolation becomes ExprConcatStrings" {
    try expectJson(
        \\"Foo ${x}"
    ,
        \\{
        \\  "_type": "ExprConcatStrings",
        \\  "es": [
        \\    {
        \\      "_type": "ExprLiteral",
        \\      "value": "Foo ",
        \\      "valueType": "String"
        \\    },
        \\    {
        \\      "_type": "ExprVar",
        \\      "value": "x"
        \\    }
        \\  ],
        \\  "isInterpolation": true
        \\}
        \\
    );
}

test "constant dynamic key folds into static attrs" {
    try expectJson(
        \\{ ${"k"} = 1; }
    ,
        \\{
        \\  "_type": "ExprSet",
        \\  "attrs": {
        \\    "k": {
        \\      "_type": "ExprLiteral",
        \\      "value": 1,
        \\      "valueType": "Int"
        \\    }
        \\  },
        \\  "recursive": false
        \\}
        \\
    );
}

test "inherit and inherit-from regroup" {
    try expectJson("{ inherit a; inherit (s) b c; }",
        \\{
        \\  "_type": "ExprSet",
        \\  "inherit": {
        \\    "a": {
        \\      "_type": "ExprVar",
        \\      "value": "a"
        \\    }
        \\  },
        \\  "inheritFrom": [
        \\    {
        \\      "attrs": [
        \\        "b",
        \\        "c"
        \\      ],
        \\      "from": {
        \\        "_type": "ExprVar",
        \\        "value": "s"
        \\      }
        \\    }
        \\  ],
        \\  "recursive": false
        \\}
        \\
    );
}

const PeakAllocator = struct {
    child: std.mem.Allocator,
    active: usize = 0,
    peak: usize = 0,
    allocations: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *PeakAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn add(self: *PeakAllocator, len: usize) void {
        self.active += len;
        self.peak = @max(self.peak, self.active);
    }

    fn adjust(self: *PeakAllocator, old_len: usize, new_len: usize) void {
        self.active -= old_len;
        self.add(new_len);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.add(len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.adjust(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.adjust(memory.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.active -= memory.len;
    }
};

test "wide lists stream through reused bounded scratch" {
    var source_buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source_buffer.deinit();
    try source_buffer.writer.writeByte('[');
    for (0..4096) |_| try source_buffer.writer.writeAll(" 1");
    try source_buffer.writer.writeAll(" ]");
    const source = source_buffer.written();

    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();
    var parser = parser_mod.Parser.init(std.testing.allocator, &arena, source);
    defer parser.deinit();
    const node = try parser.parse();

    var measured: PeakAllocator = .{ .child = std.testing.allocator };
    var discard_buffer: [1024]u8 = undefined;
    var output: std.Io.Writer.Discarding = .init(&discard_buffer);
    try json.write(&output.writer, measured.allocator(), source, node);

    try std.testing.expect(output.fullCount() > 256 * 1024);
    try std.testing.expect(measured.peak < 64 * 1024);
    try std.testing.expect(measured.allocations < 64);
    try std.testing.expectEqual(@as(usize, 0), measured.active);
}
