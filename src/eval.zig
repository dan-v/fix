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
const FileCache = @import("file_cache.zig").FileCache;
const Value = @import("value.zig").Value;
const ThunkState = @import("thunk.zig").ThunkState;
const builtins = @import("builtins.zig");
const parser_mod = @import("parser.zig");
const diagnostic = @import("diagnostic.zig");
const path_ops = @import("runtime/paths.zig");

pub const Diagnostic = diagnostic.Diagnostic;

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    intern: InternTable,
    registry: ChunkRegistry,
    scheduler: Scheduler,
    heap: ObjectHeap,
    files: FileCache,
    imports: std.StringHashMapUnmanaged(Value),
    imports_in_progress: std.StringHashMapUnmanaged(void),
    search_paths: []SearchPathEntry,
    runtime_arena: std.heap.ArenaAllocator,
    builtins_value: ?Value,
    base_path: ?[:0]u8,
    worker_count: u8,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),

    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !Evaluator {
        var scheduler = try Scheduler.init(allocator, worker_count);
        errdefer scheduler.deinit();

        var intern = try InternTable.init(allocator);
        errdefer intern.deinit();

        var registry = try ChunkRegistry.init(allocator);
        errdefer registry.deinit();

        return .{
            .allocator = allocator,
            .intern = intern,
            .registry = registry,
            .scheduler = scheduler,
            .heap = ObjectHeap.init(allocator),
            .files = FileCache.init(allocator),
            .imports = .empty,
            .imports_in_progress = .empty,
            .search_paths = &.{},
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
        var imports_iter = self.imports.iterator();
        while (imports_iter.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.imports.deinit(self.allocator);
        var progress_iter = self.imports_in_progress.iterator();
        while (progress_iter.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.imports_in_progress.deinit(self.allocator);
        self.freeSearchPaths();
        self.files.deinit();
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
        self.files.setIo(io);
        if (self.base_path) |path| self.allocator.free(path);
        self.base_path = try std.process.currentPathAlloc(io, self.allocator);
    }

    pub fn setFileIo(self: *Evaluator, io: std.Io) void {
        self.files.setIo(io);
    }

    pub fn setNixPath(self: *Evaluator, nix_path: []const u8) !void {
        self.freeSearchPaths();

        var entries: std.ArrayListUnmanaged(SearchPathEntry) = .empty;
        errdefer {
            for (entries.items) |entry| entry.deinit(self.allocator);
            entries.deinit(self.allocator);
        }

        var parts = std.mem.splitScalar(u8, nix_path, ':');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, part, '=');
            const prefix = if (eq) |i| part[0..i] else "";
            const raw_path = if (eq) |i| part[i + 1 ..] else part;
            if (raw_path.len == 0) continue;

            const resolved = self.resolveHostPath(raw_path) catch |err| switch (err) {
                error.RelativePath => continue,
                else => return err,
            };
            defer if (resolved.owned) self.allocator.free(resolved.text);

            try entries.append(self.allocator, .{
                .prefix = try self.allocator.dupe(u8, prefix),
                .path = try self.allocator.dupe(u8, resolved.text),
            });
        }

        self.search_paths = try entries.toOwnedSlice(self.allocator);
    }

    pub fn readSourceFile(self: *Evaluator, path: []const u8) ![]const u8 {
        const resolved = try self.resolveHostPath(path);
        defer if (resolved.owned) self.allocator.free(resolved.text);
        return self.files.readFile(resolved.text);
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
        return self.evaluateSource(source, self.base_path);
    }

    fn evaluateSource(self: *Evaluator, source: []const u8, base_path: ?[]const u8) !Value {
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
        compiler.base_path = base_path;
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
            &self.files,
            &self.scheduler,
            .{ .context = self, .import_value = importValue, .find_file = findFile },
            try self.ensureBuiltins(),
            0,
        );
        defer vm.deinit();

        return vm.eval(chunk_id);
    }

    fn importValue(context: *anyopaque, path: []const u8) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return self.importPath(path);
    }

    fn findFile(context: *anyopaque, name: []const u8) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return self.findFileInDefaultSearchPath(name);
    }

    fn findFileInDefaultSearchPath(self: *Evaluator, name: []const u8) !Value {
        for (self.search_paths) |entry| {
            if (try self.searchPathCandidate(entry.path, entry.prefix, name)) |candidate| {
                defer self.allocator.free(candidate);
                return Value.path(try self.intern.intern(candidate));
            }
        }
        return error.FileNotFound;
    }

    fn searchPathCandidate(self: *Evaluator, base: []const u8, prefix: []const u8, name: []const u8) !?[]u8 {
        const suffix = path_ops.searchPathSuffix(prefix, name) orelse return null;
        const candidate = try std.fs.path.resolve(self.allocator, &.{ base, suffix });
        errdefer self.allocator.free(candidate);
        if (try self.files.pathExists(candidate)) return candidate;
        self.allocator.free(candidate);
        return null;
    }

    fn importPath(self: *Evaluator, path: []const u8) !Value {
        const resolved = try self.resolveHostPath(path);
        defer if (resolved.owned) self.allocator.free(resolved.text);
        return self.importResolvedPath(resolved.text);
    }

    fn importResolvedPath(self: *Evaluator, path: []const u8) anyerror!Value {
        if (self.imports.get(path)) |value| return value;
        const progress_key = try self.beginImport(path);
        defer self.endImport(progress_key);

        const source = self.files.readFile(path) catch |err| switch (err) {
            error.IsDir => return self.importDirectory(path),
            else => return err,
        };
        const source_base = std.fs.path.dirname(path) orelse "/";
        const value = try self.evaluateSource(source, source_base);
        try self.cacheImportValue(path, value);
        return value;
    }

    fn importDirectory(self: *Evaluator, path: []const u8) anyerror!Value {
        const default_path = try std.fs.path.resolve(self.allocator, &.{ path, "default.nix" });
        defer self.allocator.free(default_path);

        const value = try self.importResolvedPath(default_path);
        try self.cacheImportValue(path, value);
        return value;
    }

    fn cacheImportValue(self: *Evaluator, path: []const u8, value: Value) !void {
        if (self.imports.contains(path)) return;

        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.imports.put(self.allocator, key, value);
    }

    fn beginImport(self: *Evaluator, path: []const u8) ![]u8 {
        if (self.imports_in_progress.contains(path)) return error.ImportCycle;

        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.imports_in_progress.put(self.allocator, key, {});
        return key;
    }

    fn endImport(self: *Evaluator, key: []u8) void {
        _ = self.imports_in_progress.remove(key);
        self.allocator.free(key);
    }

    fn ensureBuiltins(self: *Evaluator) !Value {
        if (self.builtins_value) |value| return value;
        const nix_path = try self.allocator.alloc(builtins.NixPathEntry, self.search_paths.len);
        defer self.allocator.free(nix_path);
        for (self.search_paths, nix_path) |entry, *out| {
            out.* = .{ .prefix = entry.prefix, .path = entry.path };
        }

        const value = try builtins.buildAttrSet(&self.intern, &self.heap, nix_path);
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

    const ResolvedHostPath = struct {
        text: []const u8,
        owned: bool,
    };

    const SearchPathEntry = struct {
        prefix: []u8,
        path: []u8,

        fn deinit(self: SearchPathEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.prefix);
            allocator.free(self.path);
        }
    };

    fn freeSearchPaths(self: *Evaluator) void {
        for (self.search_paths) |entry| entry.deinit(self.allocator);
        self.allocator.free(self.search_paths);
        self.search_paths = &.{};
    }

    fn resolveHostPath(self: *Evaluator, path: []const u8) !ResolvedHostPath {
        if (std.fs.path.isAbsolute(path)) return .{ .text = path, .owned = false };

        const base_path = self.base_path orelse return error.RelativePath;
        return .{
            .text = try std.fs.path.resolve(self.allocator, &.{ base_path, path }),
            .owned = true,
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

test "evaluate primitive arithmetic and bit builtins" {
    const add = try renderForTest("builtins.add 1 2.5");
    defer std.testing.allocator.free(add);
    try std.testing.expectEqualStrings("3.5", add);

    const div = try renderForTest("builtins.div (-7) 2");
    defer std.testing.allocator.free(div);
    try std.testing.expectEqualStrings("-3", div);

    const less_than = try renderForTest("builtins.lessThan \"a\" \"b\"");
    defer std.testing.allocator.free(less_than);
    try std.testing.expectEqualStrings("true", less_than);

    const bit_and = try renderForTest("builtins.bitAnd 6 3");
    defer std.testing.allocator.free(bit_and);
    try std.testing.expectEqualStrings("2", bit_and);

    const bit_or = try renderForTest("builtins.bitOr 4 1");
    defer std.testing.allocator.free(bit_or);
    try std.testing.expectEqualStrings("5", bit_or);

    const bit_xor = try renderForTest("builtins.bitXor 6 3");
    defer std.testing.allocator.free(bit_xor);
    try std.testing.expectEqualStrings("5", bit_xor);

    const floor = try renderForTest("builtins.floor (-1.2)");
    defer std.testing.allocator.free(floor);
    try std.testing.expectEqualStrings("-2", floor);

    const ceil = try renderForTest("builtins.ceil (-1.8)");
    defer std.testing.allocator.free(ceil);
    try std.testing.expectEqualStrings("-1", ceil);
}

test "evaluate primitive path and metadata builtins" {
    const base = try renderForTest("builtins.baseNameOf /foo/bar");
    defer std.testing.allocator.free(base);
    try std.testing.expectEqualStrings("\"bar\"", base);

    const string_dir = try renderForTest("builtins.dirOf \"foo/bar\"");
    defer std.testing.allocator.free(string_dir);
    try std.testing.expectEqualStrings("\"foo\"", string_dir);

    const path_dir = try renderForTest("builtins.dirOf /foo/bar");
    defer std.testing.allocator.free(path_dir);
    try std.testing.expectEqualStrings("/foo", path_dir);

    const true_value = try renderForTest("builtins.true");
    defer std.testing.allocator.free(true_value);
    try std.testing.expectEqualStrings("true", true_value);

    const false_value = try renderForTest("builtins.false");
    defer std.testing.allocator.free(false_value);
    try std.testing.expectEqualStrings("false", false_value);

    const null_value = try renderForTest("builtins.null");
    defer std.testing.allocator.free(null_value);
    try std.testing.expectEqualStrings("null", null_value);

    const lang_version = try renderForTest("builtins.langVersion");
    defer std.testing.allocator.free(lang_version);
    try std.testing.expectEqualStrings("6", lang_version);

    const store_dir = try renderForTest("builtins.storeDir");
    defer std.testing.allocator.free(store_dir);
    try std.testing.expectEqualStrings("\"/nix/store\"", store_dir);
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

test "evaluate elem builtin" {
    const present = try renderForTest("builtins.elem 2 [ 1 2 3 ]");
    defer std.testing.allocator.free(present);
    try std.testing.expectEqualStrings("true", present);

    const missing = try renderForTest("builtins.elem 4 [ 1 2 3 ]");
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("false", missing);

    const short_circuit = try renderForTest("builtins.elem 1 [ 1 (1 / 0) ]");
    defer std.testing.allocator.free(short_circuit);
    try std.testing.expectEqualStrings("true", short_circuit);
}

test "evaluate seq builtin" {
    const value = try renderForTest("builtins.seq 1 2");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("2", value);

    const list_whnf = try renderForTest("builtins.seq [ (1 / 0) ] 2");
    defer std.testing.allocator.free(list_whnf);
    try std.testing.expectEqualStrings("2", list_whnf);

    const unused = try renderForTest("let x = builtins.seq (1 / 0) 2; in 3");
    defer std.testing.allocator.free(unused);
    try std.testing.expectEqualStrings("3", unused);
}

test "evaluate deepSeq builtin" {
    const attrs = try renderForTest("builtins.deepSeq { a = 1; b = [ 2 ]; } 3");
    defer std.testing.allocator.free(attrs);
    try std.testing.expectEqualStrings("3", attrs);

    const unused = try renderForTest("let x = builtins.deepSeq [ (1 / 0) ] 2; in 3");
    defer std.testing.allocator.free(unused);
    try std.testing.expectEqualStrings("3", unused);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try std.testing.expectError(error.DivisionByZero, ev.evaluate("builtins.deepSeq [ (1 / 0) ] 2"));
}

test "evaluate pathExists and readFile builtins through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.txt", .data = "abc\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "input.txt",
    });
    defer std.testing.allocator.free(file_path);

    const exists_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.pathExists \"{s}\"", .{file_path});
    defer std.testing.allocator.free(exists_source);
    const read_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile \"{s}\"", .{file_path});
    defer std.testing.allocator.free(read_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const exists = try ev.evaluate(exists_source);
    try std.testing.expect(exists.asBool());

    const contents = try ev.evaluate(read_source);
    try std.testing.expectEqualStrings("abc\n", ev.intern.get(contents.asInternId()));

    const reread = try ev.evaluate(read_source);
    try std.testing.expectEqual(contents.asInternId(), reread.asInternId());
}

test "read source files through evaluator file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.nix", .data = "1 + 2\n" });

    const relative_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/source.nix", .{tmp.sub_path});
    defer std.testing.allocator.free(relative_path);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try ev.setBasePathFromCurrentPath(std.testing.io);

    const source = try ev.readSourceFile(relative_path);
    try std.testing.expectEqualStrings("1 + 2\n", source);

    const cached_source = try ev.readSourceFile(relative_path);
    try std.testing.expectEqual(@intFromPtr(source.ptr), @intFromPtr(cached_source.ptr));
}

test "evaluate readDir builtin through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "sub", .default_dir);

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(dir_path);

    const file_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.getAttr \"file.txt\" (builtins.readDir {s})", .{dir_path});
    defer std.testing.allocator.free(file_source);
    const dir_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.readDir {s}).sub", .{dir_path});
    defer std.testing.allocator.free(dir_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const file_kind = try ev.evaluate(file_source);
    try std.testing.expectEqualStrings("regular", ev.intern.get(file_kind.asInternId()));

    const dir_kind = try ev.evaluate(dir_source);
    try std.testing.expectEqualStrings("directory", ev.intern.get(dir_kind.asInternId()));
}

test "evaluate readFileType builtin through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "sub", .default_dir);

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(base_path);

    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "file.txt" });
    defer std.testing.allocator.free(file_path);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "sub" });
    defer std.testing.allocator.free(dir_path);

    const file_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFileType {s}", .{file_path});
    defer std.testing.allocator.free(file_source);
    const dir_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFileType {s}", .{dir_path});
    defer std.testing.allocator.free(dir_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const file_kind = try ev.evaluate(file_source);
    try std.testing.expectEqualStrings("regular", ev.intern.get(file_kind.asInternId()));

    const dir_kind = try ev.evaluate(dir_source);
    try std.testing.expectEqualStrings("directory", ev.intern.get(dir_kind.asInternId()));
}

test "evaluate findFile builtin through explicit search path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.nix", .data = "1" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(base_path);
    const expected_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "target.nix" });
    defer std.testing.allocator.free(expected_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.findFile [ {{ prefix = \"pkg\"; path = {s}; }} ] \"pkg/target.nix\"", .{base_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const found = try ev.evaluate(source);
    try std.testing.expectEqualStrings(expected_path, ev.intern.get(found.asInternId()));
}

test "evaluate angle search path literals through cached nix path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.nix", .data = "{ value = 5; }" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(base_path);

    const nix_path = try std.fmt.allocPrint(std.testing.allocator, "pkg={s}", .{base_path});
    defer std.testing.allocator.free(nix_path);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    try ev.setNixPath(nix_path);

    const imported = try ev.evaluate("(import <pkg/target.nix>).value");
    try std.testing.expectEqual(@as(i64, 5), imported.asInt());
}

test "evaluate import through evaluator file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "imported.nix", .data = "{ value = 42; }\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "imported.nix",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "let a = import {s}; b = import {s}; in a.value + b.value", .{ file_path, file_path });
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const imported = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 84), imported.asInt());
    try std.testing.expectEqual(@as(u32, 1), ev.imports.count());
}

test "evaluate directory import through default nix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "pkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/default.nix", .data = "{ value = 9; }\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "pkg",
    });
    defer std.testing.allocator.free(dir_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "(import {s}).value", .{dir_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const imported = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 9), imported.asInt());
}

test "detect recursive imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cycle.nix", .data = "import ./cycle.nix\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "cycle.nix",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "import {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    try std.testing.expectError(error.ImportCycle, ev.evaluate(source));
}

test "evaluate all and any builtins" {
    const all_true = try renderForTest("builtins.all (x: x < 3) [ 1 2 ]");
    defer std.testing.allocator.free(all_true);
    try std.testing.expectEqualStrings("true", all_true);

    const all_short_circuit = try renderForTest("builtins.all (x: x < 3) [ 1 4 (1 / 0) ]");
    defer std.testing.allocator.free(all_short_circuit);
    try std.testing.expectEqualStrings("false", all_short_circuit);

    const any_short_circuit = try renderForTest("builtins.any (x: x == 2) [ 1 2 (1 / 0) ]");
    defer std.testing.allocator.free(any_short_circuit);
    try std.testing.expectEqualStrings("true", any_short_circuit);

    const any_false = try renderForTest("builtins.any (x: x == 2) [ 1 3 ]");
    defer std.testing.allocator.free(any_false);
    try std.testing.expectEqualStrings("false", any_false);
}

test "evaluate filter builtin" {
    const filtered = try renderForTest("builtins.filter (x: x < 3) [ 1 4 2 ]");
    defer std.testing.allocator.free(filtered);
    try std.testing.expectEqualStrings("[ 1 2 ]", filtered);

    const length_lazy = try renderForTest("builtins.length (builtins.filter (x: true) [ (1 / 0) ])");
    defer std.testing.allocator.free(length_lazy);
    try std.testing.expectEqualStrings("1", length_lazy);

    const reject_lazy = try renderForTest("builtins.filter (x: false) [ (1 / 0) ]");
    defer std.testing.allocator.free(reject_lazy);
    try std.testing.expectEqualStrings("[ ]", reject_lazy);
}

test "evaluate map concatMap mapAttrs and genList builtins" {
    const mapped = try renderForTest("builtins.map (x: x + 1) [ 1 2 3 ]");
    defer std.testing.allocator.free(mapped);
    try std.testing.expectEqualStrings("[ 2 3 4 ]", mapped);

    const concat_mapped = try renderForTest("builtins.elemAt (builtins.concatMap (x: [ x (x + 10) ]) [ 1 2 ]) 1");
    defer std.testing.allocator.free(concat_mapped);
    try std.testing.expectEqualStrings("11", concat_mapped);

    const mapped_attrs = try renderForTest("(builtins.mapAttrs (name: value: value + 1) { a = 1; b = 2; }).b");
    defer std.testing.allocator.free(mapped_attrs);
    try std.testing.expectEqualStrings("3", mapped_attrs);

    const map_attrs_lazy_select = try renderForTest("(builtins.mapAttrs (name: value: if name == \"a\" then value else builtins.throw \"bad\") { a = 1; b = 2; }).a");
    defer std.testing.allocator.free(map_attrs_lazy_select);
    try std.testing.expectEqualStrings("1", map_attrs_lazy_select);

    const map_attrs_lazy_has_attr = try renderForTest("(builtins.mapAttrs (name: value: builtins.throw \"bad\") { a = 1; }) ? a");
    defer std.testing.allocator.free(map_attrs_lazy_has_attr);
    try std.testing.expectEqualStrings("true", map_attrs_lazy_has_attr);

    const generated = try renderForTest("builtins.genList (x: x + 1) 3");
    defer std.testing.allocator.free(generated);
    try std.testing.expectEqualStrings("[ 1 2 3 ]", generated);
}

test "evaluate string builtins" {
    const length = try renderForTest("builtins.stringLength \"abcd\"");
    defer std.testing.allocator.free(length);
    try std.testing.expectEqualStrings("4", length);

    const joined = try renderForTest("builtins.concatStringsSep \",\" [ \"a\" \"b\" \"c\" ]");
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("\"a,b,c\"", joined);

    const substring = try renderForTest("builtins.substring 1 2 \"abcd\"");
    defer std.testing.allocator.free(substring);
    try std.testing.expectEqualStrings("\"bc\"", substring);

    const replaced = try renderForTest("builtins.replaceStrings [ \"ab\" \"d\" ] [ \"X\" \"Y\" ] \"abcd\"");
    defer std.testing.allocator.free(replaced);
    try std.testing.expectEqualStrings("\"XcY\"", replaced);
}

test "evaluate hash builtins" {
    const hash_string = try renderForTest("builtins.hashString \"sha256\" \"abc\"");
    defer std.testing.allocator.free(hash_string);
    try std.testing.expectEqualStrings("\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"", hash_string);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.txt", .data = "abc" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "input.txt",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.hashFile \"sha1\" {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const hash_file = try ev.evaluate(source);
    try std.testing.expectEqualStrings("a9993e364706816aba3e25717850c26c9cd0d89d", ev.intern.get(hash_file.asInternId()));
}

test "evaluate JSON builtins" {
    const json = try renderForTest("builtins.toJSON { b = [ 2 false ]; a = \"x\"; }");
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("\"{\\\"a\\\":\\\"x\\\",\\\"b\\\":[2,false]}\"", json);

    const json_forces_values = try renderForTest("builtins.toJSON { a = 1; }");
    defer std.testing.allocator.free(json_forces_values);
    try std.testing.expectEqualStrings("\"{\\\"a\\\":1}\"", json_forces_values);

    const parsed_attr = try renderForTest("(builtins.fromJSON \"{\\\"b\\\":2,\\\"a\\\":[1,true,null]}\").a");
    defer std.testing.allocator.free(parsed_attr);
    try std.testing.expectEqualStrings("[ 1 true null ]", parsed_attr);

    const parsed_float_type = try renderForTest("builtins.typeOf (builtins.fromJSON \"1.5\")");
    defer std.testing.allocator.free(parsed_float_type);
    try std.testing.expectEqualStrings("\"float\"", parsed_float_type);
}

test "evaluate version parsing builtins" {
    const split = try renderForTest("builtins.splitVersion \"1.0-beta2\"");
    defer std.testing.allocator.free(split);
    try std.testing.expectEqualStrings("[ \"1\" \"0\" \"beta\" \"2\" ]", split);

    const equal = try renderForTest("builtins.compareVersions \"1.02\" \"1.2\"");
    defer std.testing.allocator.free(equal);
    try std.testing.expectEqualStrings("0", equal);

    const pre = try renderForTest("builtins.compareVersions \"1.0pre\" \"1.0\"");
    defer std.testing.allocator.free(pre);
    try std.testing.expectEqualStrings("-1", pre);

    const drv = try renderForTest("(builtins.parseDrvName \"foo-bar-1.2pre3\").version");
    defer std.testing.allocator.free(drv);
    try std.testing.expectEqualStrings("\"1.2pre3\"", drv);
}

test "evaluate control and error builtins" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.NixThrow, ev.evaluate("builtins.throw \"nope\""));
    try std.testing.expectError(error.NixAbort, ev.evaluate("builtins.abort \"nope\""));

    const try_success = try renderForTest("(builtins.tryEval (1 + 2)).success");
    defer std.testing.allocator.free(try_success);
    try std.testing.expectEqualStrings("true", try_success);

    const try_value = try renderForTest("(builtins.tryEval (builtins.throw \"nope\")).value");
    defer std.testing.allocator.free(try_value);
    try std.testing.expectEqualStrings("false", try_value);

    const traced = try renderForTest("builtins.trace \"message\" 42");
    defer std.testing.allocator.free(traced);
    try std.testing.expectEqualStrings("42", traced);
}

test "evaluate minimal derivation builtins" {
    const derivation_type = try renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).type");
    defer std.testing.allocator.free(derivation_type);
    try std.testing.expectEqualStrings("\"derivation\"", derivation_type);

    const strict_output = try renderForTest("builtins.head (builtins.derivationStrict { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).outputs");
    defer std.testing.allocator.free(strict_output);
    try std.testing.expectEqualStrings("\"out\"", strict_output);

    const named_output = try renderForTest("(builtins.derivation { name = \"pkg\"; outputs = [ \"out\" \"dev\" ]; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).dev.outputName");
    defer std.testing.allocator.free(named_output);
    try std.testing.expectEqualStrings("\"dev\"", named_output);

    const all_len = try renderForTest("builtins.length (builtins.derivation { name = \"pkg\"; outputs = [ \"out\" \"dev\" ]; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).all");
    defer std.testing.allocator.free(all_len);
    try std.testing.expectEqualStrings("2", all_len);

    const coerced_int = try renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; version = 1; }).version");
    defer std.testing.allocator.free(coerced_int);
    try std.testing.expectEqualStrings("\"1\"", coerced_int);

    const coerced_args = try renderForTest("builtins.head (builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; args = [ 1 ./foo ]; }).args");
    defer std.testing.allocator.free(coerced_args);
    try std.testing.expectEqualStrings("\"1\"", coerced_args);
}

test "evaluate path construction builtins" {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const store_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.isString (builtins.storePath \"{s}\")", .{cwd});
    defer std.testing.allocator.free(store_source);
    const path_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.isString (builtins.path {{ path = \"{s}\"; name = \"cwd\"; }})", .{cwd});
    defer std.testing.allocator.free(path_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const store_path = try ev.evaluate(store_source);
    try std.testing.expect(store_path.asBool());

    const path = try ev.evaluate(path_source);
    try std.testing.expect(path.asBool());
}

test "evaluate nixpkgs-heavy collection builtins" {
    const sorted = try renderForTest("builtins.sort (a: b: a < b) [ 3 1 2 ]");
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("[ 1 2 3 ]", sorted);

    const partitioned = try renderForTest("(builtins.partition (x: x < 3) [ 1 3 2 ]).right");
    defer std.testing.allocator.free(partitioned);
    try std.testing.expectEqualStrings("[ 1 2 ]", partitioned);

    const grouped = try renderForTest("(builtins.groupBy (x: if x < 3 then \"small\" else \"big\") [ 1 3 2 ]).small");
    defer std.testing.allocator.free(grouped);
    try std.testing.expectEqualStrings("[ 1 2 ]", grouped);

    const closure_len = try renderForTest("builtins.length (builtins.genericClosure { startSet = [ { key = 1; } ]; operator = item: if item.key < 3 then [ { key = item.key + 1; } ] else [ ]; })");
    defer std.testing.allocator.free(closure_len);
    try std.testing.expectEqualStrings("3", closure_len);

    const cat_attrs = try renderForTest("builtins.elemAt (builtins.catAttrs \"a\" [ { a = 1; } { b = 2; } { a = 3; } ]) 1");
    defer std.testing.allocator.free(cat_attrs);
    try std.testing.expectEqualStrings("3", cat_attrs);

    const cat_attrs_lazy = try renderForTest("builtins.length (builtins.catAttrs \"a\" [ { a = 1 / 0; } ])");
    defer std.testing.allocator.free(cat_attrs_lazy);
    try std.testing.expectEqualStrings("1", cat_attrs_lazy);

    const zipped_len = try renderForTest("(builtins.zipAttrsWith (name: values: builtins.length values) [ { a = 1; } { a = 2; b = 3; } ]).a");
    defer std.testing.allocator.free(zipped_len);
    try std.testing.expectEqualStrings("2", zipped_len);

    const zipped_first = try renderForTest("(builtins.zipAttrsWith (name: values: builtins.head values) [ { a = 1; } { a = 2; } ]).a");
    defer std.testing.allocator.free(zipped_first);
    try std.testing.expectEqualStrings("1", zipped_first);

    const zipped_lazy_select = try renderForTest("(builtins.zipAttrsWith (name: values: if name == \"a\" then 1 else builtins.throw \"bad\") [ { a = 1; b = 2; } ]).a");
    defer std.testing.allocator.free(zipped_lazy_select);
    try std.testing.expectEqualStrings("1", zipped_lazy_select);

    const zipped_lazy_has_attr = try renderForTest("(builtins.zipAttrsWith (name: values: builtins.throw \"bad\") [ { a = 1; } ]) ? a");
    defer std.testing.allocator.free(zipped_lazy_has_attr);
    try std.testing.expectEqualStrings("true", zipped_lazy_has_attr);
}

test "evaluate function metadata builtins" {
    const args = try renderForTest("(builtins.functionArgs ({ a, b ? 1 }: a)).b");
    defer std.testing.allocator.free(args);
    try std.testing.expectEqualStrings("true", args);

    const pos = try renderForTest("builtins.unsafeGetAttrPos \"a\" { a = 1; }");
    defer std.testing.allocator.free(pos);
    try std.testing.expectEqualStrings("null", pos);
}

test "evaluate foldl' builtin" {
    const sum = try renderForTest("builtins.foldl' (a: b: a + b) 0 [ 1 2 3 ]");
    defer std.testing.allocator.free(sum);
    try std.testing.expectEqualStrings("6", sum);

    const ignores_item = try renderForTest("builtins.foldl' (a: b: a) 1 [ (1 / 0) ]");
    defer std.testing.allocator.free(ignores_item);
    try std.testing.expectEqualStrings("1", ignores_item);

    const returns_item = try renderForTest("builtins.foldl' (a: b: b) 0 [ 1 2 ]");
    defer std.testing.allocator.free(returns_item);
    try std.testing.expectEqualStrings("2", returns_item);
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
