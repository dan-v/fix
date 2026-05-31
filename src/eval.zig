//! Evaluator — the top-level orchestration layer.
//!
//! Manages the shared state (chunk registry, intern table, scheduler) and runs
//! the worker threads that execute bytecode.

const std = @import("std");
const types = @import("types.zig");
const InternTable = @import("intern.zig").InternTable;
const ChunkRegistry = @import("chunk.zig").ChunkRegistry;
const ChunkBuilder = @import("chunk.zig").ChunkBuilder;
const Scheduler = @import("scheduler.zig").Scheduler;
const VM = @import("vm.zig").VM;
const ObjectHeap = @import("heap.zig").ObjectHeap;
const Value = @import("value.zig").Value;
const ThunkState = @import("thunk.zig").ThunkState;
const builtins = @import("builtins.zig");
const parser_mod = @import("parser.zig");
const diagnostic = @import("diagnostic.zig");

pub const Diagnostic = diagnostic.Diagnostic;

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    intern: InternTable,
    registry: ChunkRegistry,
    scheduler: Scheduler,
    heap: ObjectHeap,
    runtime_arena: std.heap.ArenaAllocator,
    builtins_value: ?Value,
    base_path: ?[:0]u8,
    worker_count: u8,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),

    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !Evaluator {
        const scheduler = try Scheduler.init(allocator, worker_count);

        return .{
            .allocator = allocator,
            .intern = try InternTable.init(allocator),
            .registry = try ChunkRegistry.init(allocator),
            .scheduler = scheduler,
            .heap = ObjectHeap.init(allocator),
            .runtime_arena = std.heap.ArenaAllocator.init(allocator),
            .builtins_value = null,
            .base_path = null,
            .worker_count = worker_count,
            .diagnostics = .empty,
        };
    }

    pub fn deinit(self: *Evaluator) void {
        if (self.base_path) |path| self.allocator.free(path);
        self.diagnostics.deinit(self.allocator);
        self.heap.deinit();
        self.runtime_arena.deinit();
        self.scheduler.deinit();
        self.registry.deinit();
        self.intern.deinit();
    }

    pub fn getDiagnostics(self: *const Evaluator) []const Diagnostic {
        return self.diagnostics.items;
    }

    pub fn setBasePathFromCurrentPath(self: *Evaluator, io: std.Io) !void {
        if (self.base_path) |path| self.allocator.free(path);
        self.base_path = try std.process.currentPathAlloc(io, self.allocator);
    }

    fn clearDiagnostics(self: *Evaluator) void {
        self.diagnostics.clearRetainingCapacity();
    }

    fn copyDiagnostics(self: *Evaluator, diagnostics: []const Diagnostic) !void {
        self.clearDiagnostics();
        try self.diagnostics.appendSlice(self.allocator, diagnostics);
    }

    /// Compile source text into bytecode and evaluate it.
    /// This is the main public API.
    pub fn evaluate(self: *Evaluator, source: []const u8) !Value {
        self.clearDiagnostics();

        // 1. Parse into AST.
        var arena = @import("ast.zig").AstArena.init(self.allocator);
        defer arena.deinit();

        var parser = parser_mod.Parser.init(self.allocator, &arena, source);
        defer parser.deinit();
        const ast_node = parser.parse() catch {
            try self.copyDiagnostics(parser.diagnostics.items);
            return error.ParseError;
        };

        // 2. Compile AST to bytecode.
        var builder = try ChunkBuilder.init(self.allocator);
        defer builder.deinit(self.allocator);

        var compiler = @import("compiler.zig").Compiler.init(
            self.allocator,
            &builder,
            &self.registry,
            source,
            &self.intern,
        );
        compiler.base_path = self.base_path;
        defer compiler.deinit();

        compiler.compile(ast_node) catch |err| {
            try self.copyDiagnostics(compiler.diagnostics.items);
            if (preserveCompileError(err)) return err;
            return error.CompileError;
        };

        // Add return + halt.
        try builder.writeOp(self.allocator, .ret);
        try builder.writeOp(self.allocator, .halt);

        const chunk = try builder.finish(self.allocator, compiler.slot_count);
        const chunk_id = try self.registry.register(chunk);

        // 3. Evaluate via a VM.
        var vm = try VM.init(
            self.runtime_arena.allocator(),
            &self.registry,
            &self.intern,
            &self.heap,
            &self.scheduler,
            try self.ensureBuiltins(),
            0,
        );
        defer vm.deinit();

        return vm.eval(chunk_id);
    }

    fn ensureBuiltins(self: *Evaluator) !Value {
        if (self.builtins_value) |value| return value;
        const value = try builtins.buildAttrSet(&self.intern, &self.heap);
        self.builtins_value = value;
        return value;
    }

    fn preserveCompileError(err: anyerror) bool {
        return switch (err) {
            error.DuplicateAttribute,
            error.DuplicateBinding,
            error.UndefinedVariable,
            => true,
            else => false,
        };
    }

    pub fn writeValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        var printer = ValuePrinter{
            .ev = self,
            .writer = writer,
            .seen = .empty,
        };
        defer printer.seen.deinit(self.allocator);

        try printer.write(value);
    }

    fn writeQuotedString(self: *Evaluator, writer: *std.Io.Writer, s: []const u8) !void {
        _ = self;
        try writer.writeByte('"');
        for (s) |c| {
            switch (c) {
                '\\' => try writer.writeAll("\\\\"),
                '"' => try writer.writeAll("\\\""),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeByte('"');
    }
};

const ValuePrinter = struct {
    ev: *Evaluator,
    writer: *std.Io.Writer,
    seen: std.ArrayListUnmanaged(SeenObject),

    const SeenKind = enum { list, attrs, thunk, cell };

    const SeenObject = struct {
        kind: SeenKind,
        id: types.ObjectId,
    };

    fn write(self: *ValuePrinter, value: Value) anyerror!void {
        switch (value.discriminant) {
            .null => try self.writer.writeAll("null"),
            .bool_false => try self.writer.writeAll("false"),
            .bool_true => try self.writer.writeAll("true"),
            .int => try self.writer.print("{}", .{value.asInt()}),
            .float => try self.writer.print("{d}", .{value.asFloat()}),
            .string => try self.ev.writeQuotedString(self.writer, self.ev.intern.get(value.asInternId())),
            .path => try self.writer.writeAll(self.ev.intern.get(value.asInternId())),
            .list => try self.writeList(value.asObjectId()),
            .attrs => try self.writeAttrs(value.asObjectId()),
            .closure => try self.writer.writeAll("<closure>"),
            .thunk => try self.writeThunk(value.asObjectId()),
            .cell => try self.writeCell(value.asObjectId()),
            .builtin => try self.writer.writeAll("<builtin>"),
            .builtin_closure => try self.writer.writeAll("<builtin-closure>"),
        }
    }

    fn writeList(self: *ValuePrinter, id: types.ObjectId) !void {
        if (!try self.enter(.list, id)) {
            try self.writer.writeAll("...");
            return;
        }
        defer self.leave();

        const items = try self.ev.heap.getList(id);
        if (items.len == 0) {
            try self.writer.writeAll("[ ]");
            return;
        }

        try self.writer.writeAll("[ ");
        for (items, 0..) |item, i| {
            if (i > 0) try self.writer.writeByte(' ');
            try self.write(item);
        }
        try self.writer.writeAll(" ]");
    }

    fn writeAttrs(self: *ValuePrinter, id: types.ObjectId) !void {
        if (!try self.enter(.attrs, id)) {
            try self.writer.writeAll("...");
            return;
        }
        defer self.leave();

        const entries = try self.ev.heap.getAttrs(id);
        if (entries.len == 0) {
            try self.writer.writeAll("{ }");
            return;
        }

        try self.writer.writeAll("{ ");
        for (entries) |entry| {
            try self.writeAttrName(self.ev.intern.get(entry.name));
            try self.writer.writeAll(" = ");
            try self.write(entry.value);
            try self.writer.writeAll("; ");
        }
        try self.writer.writeByte('}');
    }

    fn writeThunk(self: *ValuePrinter, id: types.ObjectId) !void {
        if (!try self.enter(.thunk, id)) {
            try self.writer.writeAll("...");
            return;
        }
        defer self.leave();

        const thunk = try self.ev.heap.getThunk(id);
        const state: ThunkState = @enumFromInt(thunk.state.load(.acquire));
        if (state != .resolved) {
            try self.writer.writeAll("...");
            return;
        }

        try self.write(thunk.result);
    }

    fn writeCell(self: *ValuePrinter, id: types.ObjectId) !void {
        if (!try self.enter(.cell, id)) {
            try self.writer.writeAll("...");
            return;
        }
        defer self.leave();

        try self.write(try self.ev.heap.getCellValue(id));
    }

    fn writeAttrName(self: *ValuePrinter, name: []const u8) !void {
        if (isBareAttrName(name)) {
            try self.writer.writeAll(name);
        } else {
            try self.ev.writeQuotedString(self.writer, name);
        }
    }

    fn enter(self: *ValuePrinter, kind: SeenKind, id: types.ObjectId) !bool {
        for (self.seen.items) |seen| {
            if (seen.kind == kind and seen.id == id) return false;
        }
        try self.seen.append(self.ev.allocator, .{ .kind = kind, .id = id });
        return true;
    }

    fn leave(self: *ValuePrinter) void {
        _ = self.seen.pop();
    }

    fn isBareAttrName(name: []const u8) bool {
        if (name.len == 0) return false;
        if (!isAttrNameStart(name[0])) return false;
        for (name[1..]) |c| {
            if (!isAttrNameContinue(c)) return false;
        }
        return true;
    }

    fn isAttrNameStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    fn isAttrNameContinue(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '\'';
    }
};

fn renderForTest(source: []const u8) ![]u8 {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate(source);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try ev.writeValue(&out.writer, result);
    return out.toOwnedSlice();
}

test "writeValue prints lazy containers without forcing contents" {
    const list_output = try renderForTest("[ 1 (1 / 0) \"x\" ]");
    defer std.testing.allocator.free(list_output);
    try std.testing.expectEqualStrings("[ ... ... ... ]", list_output);

    const attrs_output = try renderForTest("{ a = 1; b = 1 / 0; c = \"x\"; }");
    defer std.testing.allocator.free(attrs_output);
    try std.testing.expectEqualStrings("{ a = ...; b = ...; c = ...; }", attrs_output);
}

test "writeValue prints recursive attrsets without looping" {
    const output = try renderForTest("rec { a = a; b = 1; }");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("{ a = ...; b = ...; }", output);
}

test "evaluate matches Nix toString bool and null semantics" {
    const true_output = try renderForTest("builtins.toString true");
    defer std.testing.allocator.free(true_output);
    try std.testing.expectEqualStrings("\"1\"", true_output);

    const false_output = try renderForTest("builtins.toString false");
    defer std.testing.allocator.free(false_output);
    try std.testing.expectEqualStrings("\"\"", false_output);

    const null_output = try renderForTest("builtins.toString null");
    defer std.testing.allocator.free(null_output);
    try std.testing.expectEqualStrings("\"\"", null_output);
}

test "evaluate decodes common string escapes" {
    const output = try renderForTest("\"a\\nb\\t\\\"c\"");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("\"a\\nb\\t\\\"c\"", output);
}

test "evaluate compares strings lexically" {
    const output = try renderForTest("let b = \"b\"; a = \"a\"; in b > a");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("true", output);
}

test "evaluate checks attribute paths without forcing final value" {
    const present = try renderForTest("({ a.b = 1 / 0; } ? a.b)");
    defer std.testing.allocator.free(present);
    try std.testing.expectEqualStrings("true", present);

    const missing = try renderForTest("({ a = {}; } ? a.b)");
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("false", missing);
}

test "evaluate simple attrset function parameters" {
    const output = try renderForTest("({ x, y }: x + y) { x = 1; y = 2; }");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("3", output);

    const lazy = try renderForTest("({ x }: 1) { x = 1 / 0; }");
    defer std.testing.allocator.free(lazy);
    try std.testing.expectEqualStrings("1", lazy);
}

test "evaluate attrset function defaults ellipsis and binding" {
    const defaulted = try renderForTest("({ x ? 2 }: x) { }");
    defer std.testing.allocator.free(defaulted);
    try std.testing.expectEqualStrings("2", defaulted);

    const extra = try renderForTest("({ x, ... }: x) { x = 1; y = 2; }");
    defer std.testing.allocator.free(extra);
    try std.testing.expectEqualStrings("1", extra);

    const bound_before = try renderForTest("(args@{ x }: args.x) { x = 3; }");
    defer std.testing.allocator.free(bound_before);
    try std.testing.expectEqualStrings("3", bound_before);

    const bound_after = try renderForTest("({ x }@args: args.x) { x = 4; }");
    defer std.testing.allocator.free(bound_after);
    try std.testing.expectEqualStrings("4", bound_after);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try std.testing.expectError(error.UnexpectedAttribute, ev.evaluate("({ x }: x) { x = 1; y = 2; }"));
}

test "evaluate small unary builtins" {
    const is_float = try renderForTest("builtins.isFloat 1.5");
    defer std.testing.allocator.free(is_float);
    try std.testing.expectEqualStrings("true", is_float);

    const is_function = try renderForTest("builtins.isFunction (x: x)");
    defer std.testing.allocator.free(is_function);
    try std.testing.expectEqualStrings("true", is_function);

    const is_path = try renderForTest("builtins.isPath ./foo");
    defer std.testing.allocator.free(is_path);
    try std.testing.expectEqualStrings("true", is_path);

    const length = try renderForTest("builtins.length [ 1 (1 / 0) 3 ]");
    defer std.testing.allocator.free(length);
    try std.testing.expectEqualStrings("3", length);

    const head = try renderForTest("builtins.head [ 4 5 ]");
    defer std.testing.allocator.free(head);
    try std.testing.expectEqualStrings("4", head);

    const names = try renderForTest("builtins.attrNames { b = 2; a = 1; }");
    defer std.testing.allocator.free(names);
    try std.testing.expectEqualStrings("[ \"a\" \"b\" ]", names);

    const values = try renderForTest("builtins.attrValues { b = 2; a = 1; }");
    defer std.testing.allocator.free(values);
    try std.testing.expectEqualStrings("[ ... ... ]", values);
}

test "evaluate curried binary builtins" {
    const has_attr = try renderForTest("builtins.hasAttr \"a\" { a = 1; }");
    defer std.testing.allocator.free(has_attr);
    try std.testing.expectEqualStrings("true", has_attr);

    const missing_attr = try renderForTest("builtins.hasAttr \"b\" { a = 1; }");
    defer std.testing.allocator.free(missing_attr);
    try std.testing.expectEqualStrings("false", missing_attr);

    const get_attr = try renderForTest("builtins.getAttr \"a\" { a = 3; }");
    defer std.testing.allocator.free(get_attr);
    try std.testing.expectEqualStrings("3", get_attr);

    const elem_at = try renderForTest("builtins.elemAt [ 1 2 3 ] 1");
    defer std.testing.allocator.free(elem_at);
    try std.testing.expectEqualStrings("2", elem_at);

    const partial_is_function = try renderForTest("builtins.isFunction (builtins.elemAt [ 1 ])");
    defer std.testing.allocator.free(partial_is_function);
    try std.testing.expectEqualStrings("true", partial_is_function);
}

test "evaluate builtins.typeOf" {
    const int_type = try renderForTest("builtins.typeOf 1");
    defer std.testing.allocator.free(int_type);
    try std.testing.expectEqualStrings("\"int\"", int_type);

    const set_type = try renderForTest("builtins.typeOf { }");
    defer std.testing.allocator.free(set_type);
    try std.testing.expectEqualStrings("\"set\"", set_type);

    const fn_type = try renderForTest("builtins.typeOf (x: x)");
    defer std.testing.allocator.free(fn_type);
    try std.testing.expectEqualStrings("\"lambda\"", fn_type);
}

test "evaluate concatLists and listToAttrs builtins" {
    const concat = try renderForTest("builtins.concatLists [ [ 1 ] [ (1 / 0) ] [ 3 ] ]");
    defer std.testing.allocator.free(concat);
    try std.testing.expectEqualStrings("[ ... ... ... ]", concat);

    const first_duplicate_wins = try renderForTest("(builtins.listToAttrs [ { name = \"a\"; value = 1; } { name = \"a\"; value = 2; } ]).a");
    defer std.testing.allocator.free(first_duplicate_wins);
    try std.testing.expectEqualStrings("1", first_duplicate_wins);

    const lazy_value = try renderForTest("(builtins.listToAttrs [ { name = \"a\"; value = 1 / 0; } ]) ? a");
    defer std.testing.allocator.free(lazy_value);
    try std.testing.expectEqualStrings("true", lazy_value);
}

test "evaluate removeAttrs and intersectAttrs builtins" {
    const removed = try renderForTest("(builtins.removeAttrs { a = 1; b = 2; } [ \"a\" ]).b");
    defer std.testing.allocator.free(removed);
    try std.testing.expectEqualStrings("2", removed);

    const removed_missing = try renderForTest("(builtins.removeAttrs { a = 1; b = 2; } [ \"a\" ]) ? a");
    defer std.testing.allocator.free(removed_missing);
    try std.testing.expectEqualStrings("false", removed_missing);

    const remove_lazy = try renderForTest("(builtins.removeAttrs { a = 1 / 0; b = 2; } [ \"b\" ]) ? a");
    defer std.testing.allocator.free(remove_lazy);
    try std.testing.expectEqualStrings("true", remove_lazy);

    const intersect = try renderForTest("(builtins.intersectAttrs { a = 1; } { a = 2; b = 3; }).a");
    defer std.testing.allocator.free(intersect);
    try std.testing.expectEqualStrings("2", intersect);

    const intersect_lazy = try renderForTest("(builtins.intersectAttrs { a = 1; } { a = 1 / 0; b = 2; }) ? a");
    defer std.testing.allocator.free(intersect_lazy);
    try std.testing.expectEqualStrings("true", intersect_lazy);
}

test "evaluate exposes parse diagnostics without printing" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("$ $ 1"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqualStrings("Invalid token.", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 0), diagnostics[0].offset);
    try std.testing.expectEqual(@as(u32, 1), diagnostics[0].column);
    try std.testing.expectEqualStrings("Invalid token.", diagnostics[1].message);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].offset);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[1].column);
}

test "evaluate exposes duplicate binding diagnostics" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.DuplicateBinding, ev.evaluate("let x = 1; x = 2; in x"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Severity.err, diagnostics[0].severity);
    try std.testing.expectEqual(Diagnostic.Kind.compile, diagnostics[0].kind);
    try std.testing.expectEqualStrings("duplicate let binding", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 11), diagnostics[0].offset);
    try std.testing.expectEqual(Diagnostic.Severity.note, diagnostics[1].severity);
    try std.testing.expectEqualStrings("first binding defined here", diagnostics[1].message);
    try std.testing.expectEqual(@as(u32, 4), diagnostics[1].offset);
}

test "evaluate exposes duplicate attribute diagnostics" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a = 1; a = 2; }"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Severity.err, diagnostics[0].severity);
    try std.testing.expectEqual(Diagnostic.Kind.compile, diagnostics[0].kind);
    try std.testing.expectEqualStrings("duplicate attribute", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 9), diagnostics[0].offset);
    try std.testing.expectEqual(Diagnostic.Severity.note, diagnostics[1].severity);
    try std.testing.expectEqualStrings("first attribute defined here", diagnostics[1].message);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].offset);
}

test "evaluate exposes undefined variable diagnostics" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.UndefinedVariable, ev.evaluate("let y = x; in y"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Severity.err, diagnostics[0].severity);
    try std.testing.expectEqual(Diagnostic.Kind.compile, diagnostics[0].kind);
    try std.testing.expectEqualStrings("undefined variable", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 8), diagnostics[0].offset);
    try std.testing.expectEqual(@as(u32, 9), diagnostics[0].column);
}
