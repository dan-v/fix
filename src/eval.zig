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
const builtins = @import("builtins.zig");

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    intern: InternTable,
    registry: ChunkRegistry,
    scheduler: Scheduler,
    heap: ObjectHeap,
    runtime_arena: std.heap.ArenaAllocator,
    builtins_value: ?Value,
    worker_count: u8,

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
            .worker_count = worker_count,
        };
    }

    pub fn deinit(self: *Evaluator) void {
        self.heap.deinit();
        self.runtime_arena.deinit();
        self.scheduler.deinit();
        self.registry.deinit();
        self.intern.deinit();
    }

    /// Compile source text into bytecode and evaluate it.
    /// This is the main public API.
    pub fn evaluate(self: *Evaluator, source: []const u8) !Value {
        // 1. Parse into AST.
        var arena = @import("ast.zig").AstArena.init(self.allocator);
        defer arena.deinit();

        var parser = @import("parser.zig").Parser.init(self.allocator, &arena, source);
        const ast_node = parser.parse() catch |err| {
            std.debug.print("Parse error: {}\n", .{err});
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
        defer compiler.deinit();

        compiler.compile(ast_node) catch |err| {
            if (err == error.DuplicateAttribute) return err;
            std.debug.print("Compile error: {}\n", .{err});
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

    pub fn writeValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        switch (value.discriminant) {
            .null => try writer.writeAll("null"),
            .bool_false => try writer.writeAll("false"),
            .bool_true => try writer.writeAll("true"),
            .int => try writer.print("{}", .{value.asInt()}),
            .float => try writer.print("{d}", .{value.asFloat()}),
            .string => try self.writeQuotedString(writer, self.intern.get(value.asInternId())),
            .path => try writer.print("<path:{s}>", .{self.intern.get(value.asInternId())}),
            .list => try writer.writeAll("[...]"),
            .attrs => try writer.writeAll("{...}"),
            .closure => try writer.writeAll("<closure>"),
            .thunk => try writer.writeAll("<thunk>"),
            .cell => try writer.writeAll("<cell>"),
            .builtin => try writer.writeAll("<builtin>"),
        }
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
