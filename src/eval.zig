//! Evaluator — the top-level orchestration layer.
//!
//! Manages the shared state (chunk registry, intern table, memo cache,
//! scheduler) and runs the worker threads that execute bytecode.
//!
//! This is where aggressive normalization happens: before evaluating a chunk,
//! we check the memo cache. If the chunk+environment pair has been evaluated
//! before, we return the cached result immediately.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const InternTable = @import("intern.zig").InternTable;
const ChunkRegistry = @import("chunk.zig").ChunkRegistry;
const ChunkBuilder = @import("chunk.zig").ChunkBuilder;
const Chunk = @import("chunk.zig").Chunk;
const MemoCache = @import("cache.zig").MemoCache;
const Scheduler = @import("scheduler.zig").Scheduler;
const VM = @import("vm.zig").VM;
const Thunk = @import("thunk.zig").Thunk;
const Value = @import("value.zig").Value;
const ChunkId = types.ChunkId;

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    intern: InternTable,
    registry: ChunkRegistry,
    cache: MemoCache,
    scheduler: Scheduler,
    runtime_arena: std.heap.ArenaAllocator,
    worker_count: u8,

    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !Evaluator {
        const cache = try MemoCache.init(allocator, types.CACHE_INITIAL_CAP);
        const scheduler = try Scheduler.init(allocator, worker_count);

        return .{
            .allocator = allocator,
            .intern = try InternTable.init(allocator),
            .registry = try ChunkRegistry.init(allocator),
            .cache = cache,
            .scheduler = scheduler,
            .runtime_arena = std.heap.ArenaAllocator.init(allocator),
            .worker_count = worker_count,
        };
    }

    pub fn deinit(self: *Evaluator) void {
        self.runtime_arena.deinit();
        self.scheduler.deinit();
        self.registry.deinit();
        self.cache.deinit();
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
            std.debug.print("Compile error: {}\n", .{err});
            return error.CompileError;
        };

        // Add return + halt.
        try builder.writeOp(self.allocator, .ret);
        try builder.writeOp(self.allocator, .halt);

        const chunk = try builder.finish(self.allocator);
        const chunk_id = try self.registry.register(chunk);

        // 3. Evaluate via a VM.
        var vm = try VM.init(
            self.runtime_arena.allocator(),
            &self.registry,
            &self.intern,
            &self.cache,
            &self.scheduler,
            0,
        );
        defer vm.deinit();

        return vm.eval(chunk_id);
    }
};
