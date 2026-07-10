//! Pretty-print a bytecode chunk with operand decoding and source-map
//! annotations. Used by `fix disasm` and by the trace pretty-printer.
//!
//! The disassembler never needs an evaluator: it only takes a chunk plus
//! an optional intern table for resolving InternIds to their source
//! strings, and an optional registry for resolving ChunkIds when walking
//! closure/thunk opcodes.

const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const ChunkRegistry = @import("chunk.zig").ChunkRegistry;
const opcode_mod = @import("opcode.zig");
const OpCode = opcode_mod.OpCode;
const encoding = @import("encoding.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const intern_mod = @import("runtime").intern;
const InternTable = intern_mod.InternTable;

const InternId = types.InternId;
const ChunkId = types.ChunkId;

pub const Symbols = struct {
    intern: ?*const InternTable = null,
    registry: ?*const ChunkRegistry = null,

    fn internName(self: Symbols, id: InternId) ?[]const u8 {
        const tab = self.intern orelse return null;
        return tab.get(id);
    }
};

pub const Options = struct {
    /// Print constant pool before the code.
    show_constants: bool = true,
    /// Print source-map column on the right.
    show_source: bool = true,
    /// Walk closure/thunk operands and recursively disassemble referenced chunks.
    recurse: bool = false,
    /// Maximum recursion depth when `recurse` is true.
    max_depth: u8 = 4,
};

pub fn writeChunk(
    writer: *std.Io.Writer,
    chunk_id: ?ChunkId,
    chunk: *const Chunk,
    symbols: Symbols,
    options: Options,
) !void {
    try writeChunkAt(writer, chunk_id, chunk, symbols, options, 0);
}

/// Collect the chunk ids this chunk references (closure/thunk/apply
/// operands), in first-appearance order, deduplicated. Reuses the operand
/// decoder with a discarding writer so the decode logic exists once. Used
/// by the repl's disasm browser to build the reference graph.
pub fn collectRefs(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    out: *std.ArrayListUnmanaged(ChunkId),
) !void {
    var discard_buffer: [64]u8 = undefined;
    var discard = std.Io.Writer.Discarding.init(&discard_buffer);
    var referenced: std.AutoArrayHashMapUnmanaged(ChunkId, void) = .empty;
    defer referenced.deinit(std.heap.page_allocator);

    var ip: usize = 0;
    while (ip < chunk.code.len) {
        const op: OpCode = @enumFromInt(chunk.code[ip]);
        ip += 1;
        ip = try writeOperands(&discard.writer, chunk, op, ip, .{}, &referenced);
    }
    var it = referenced.iterator();
    while (it.next()) |entry| try out.append(allocator, entry.key_ptr.*);
}

fn writeChunkAt(
    writer: *std.Io.Writer,
    chunk_id: ?ChunkId,
    chunk: *const Chunk,
    symbols: Symbols,
    options: Options,
    depth: u8,
) anyerror!void {
    try writeChunkHeader(writer, chunk_id, chunk);
    if (options.show_constants and chunk.constants.len > 0) {
        try writer.print("  constants ({d}):\n", .{chunk.constants.len});
        for (chunk.constants, 0..) |c, i| {
            try writer.print("    #{d:0>4}  ", .{i});
            try writeValueDigest(writer, c, symbols);
            try writer.writeByte('\n');
        }
    }

    var ip: usize = 0;
    var referenced_chunks: std.AutoArrayHashMapUnmanaged(ChunkId, void) = .empty;
    defer referenced_chunks.deinit(std.heap.page_allocator);

    while (ip < chunk.code.len) {
        const start = ip;
        const op_byte = chunk.code[ip];
        const op: OpCode = @enumFromInt(op_byte);
        ip += 1;

        try writer.print("  {x:0>4}  {s:<28}", .{ start, @tagName(op) });
        ip = try writeOperands(writer, chunk, op, ip, symbols, &referenced_chunks);

        if (options.show_source) try writeSourceColumn(writer, chunk, start, symbols);
        try writer.writeByte('\n');
    }

    if (options.recurse and depth + 1 < options.max_depth) {
        const reg = symbols.registry orelse return;
        var it = referenced_chunks.iterator();
        while (it.next()) |entry| {
            const child_id = entry.key_ptr.*;
            const child = reg.get(child_id) orelse continue;
            try writer.writeByte('\n');
            try writeChunkAt(writer, child_id, child, symbols, options, depth + 1);
        }
    }
}

fn writeChunkHeader(writer: *std.Io.Writer, chunk_id: ?ChunkId, chunk: *const Chunk) !void {
    if (chunk_id) |id| {
        try writer.print("chunk #{d} ({d} bytes, {d} consts, {d} locals", .{
            id,
            chunk.code.len,
            chunk.constants.len,
            chunk.local_count,
        });
    } else {
        try writer.print("chunk ({d} bytes, {d} consts, {d} locals", .{
            chunk.code.len,
            chunk.constants.len,
            chunk.local_count,
        });
    }
    if (chunk.source_map.len > 0) {
        try writer.print(", {d} source spans", .{chunk.source_map.len});
    }
    if (chunk.arity != 1) {
        try writer.print(", arity {d}", .{chunk.arity});
    }
    try writer.writeAll(")\n");
    if (chunk.scheduling.strictness.forced_upvalues != 0) {
        try writer.writeAll("  strict upvalues:");
        var mask = chunk.scheduling.strictness.forced_upvalues;
        while (mask != 0) {
            const slot = @ctz(mask);
            try writer.print(" {d}", .{slot});
            mask &= mask - 1;
        }
        try writer.writeByte('\n');
    }
    const deep_extra = chunk.scheduling.strictness.deep_upvalues & ~chunk.scheduling.strictness.forced_upvalues;
    if (deep_extra != 0) {
        try writer.writeAll("  deep upvalues:");
        var mask = deep_extra;
        while (mask != 0) {
            const slot = @ctz(mask);
            try writer.print(" {d}", .{slot});
            mask &= mask - 1;
        }
        try writer.writeByte('\n');
    }
}

fn writeOperands(
    writer: *std.Io.Writer,
    chunk: *const Chunk,
    op: OpCode,
    ip_in: usize,
    symbols: Symbols,
    referenced_chunks: *std.AutoArrayHashMapUnmanaged(ChunkId, void),
) !usize {
    var ip = ip_in;
    const code = chunk.code;
    switch (op) {
        .constant, .constant_ret => {
            const idx = readU16(code, ip);
            ip += 2;
            try writer.print("#{d}", .{idx});
            if (idx < chunk.constants.len) {
                try writer.writeAll("  // ");
                try writeValueDigest(writer, chunk.constants[idx], symbols);
            }
        },
        .push_null, .push_true, .push_false, .pop => {},

        .get_local, .set_local, .capture_local, .init_cell_slot, .get_local_ret => {
            const slot = code[ip];
            ip += 1;
            try writer.print("local[{d}]", .{slot});
        },
        .get_local_long, .set_local_long, .capture_local_long, .set_cell_local_long, .init_cell_slot_long, .get_local_ret_long => {
            const slot = readU16(code, ip);
            ip += 2;
            try writer.print("local[{d}]", .{slot});
        },
        .set_cell_local => {
            const slot = code[ip];
            ip += 1;
            try writer.print("local[{d}]", .{slot});
        },
        .capture_upvalue, .get_upvalue, .get_upvalue_ret => {
            const slot = readU16(code, ip);
            ip += 2;
            try writer.print("upvalue[{d}]", .{slot});
        },

        .add_int, .sub_int, .mul_int, .div_int, .negate_int, .add_float, .sub_float, .mul_float, .div_float, .eq, .neq, .eq_null, .neq_null, .lt, .lte, .gt, .gte, .not, .fail_assertion, .push_builtins, .merge_attrs, .merge_attrs_strict, .concat_lists, .get_attr_dynamic, .call, .tail_call, .make_cell, .make_lazy_shell, .ret, .halt => {},

        .call_n, .tail_call_n => {
            const n = code[ip];
            ip += 1;
            try writer.print("{d} args", .{n});
        },

        .jump => {
            const off = readU32(code, ip);
            ip += 4;
            try writer.print("+{d}  // -> {x:0>4}", .{ off, ip + off });
        },
        .jump_if_false => {
            const off = readU32(code, ip);
            ip += 4;
            try writer.print("+{d}  // -> {x:0>4}", .{ off, ip + off });
        },

        .build_attrs, .build_attrs_sorted => {
            const n = readU16(code, ip);
            ip += 2;
            try writer.print("{d} entries", .{n});
        },
        .build_attrs_with_pos, .build_attrs_with_pos_sorted => {
            const n = readU16(code, ip);
            ip += 2;
            const pos_count = readU16(code, ip);
            ip += 2;
            try writer.print("{d} entries, {d} positions", .{ n, pos_count });
            ip += @as(usize, pos_count) * 16;
        },
        .build_list => {
            const n = readU16(code, ip);
            ip += 2;
            try writer.print("{d} items", .{n});
        },
        .concat_strings => {
            const n = readU16(code, ip);
            ip += 2;
            try writer.print("{d} parts", .{n});
        },

        .find_file => {
            const id: InternId = @intCast(readU16(code, ip));
            ip += 2;
            try writeInternRef(writer, id, symbols);
        },
        .find_file_long => {
            const id: InternId = readU32(code, ip);
            ip += 4;
            try writeInternRef(writer, id, symbols);
        },

        .closure, .thunk_captures, .thunk_captures_eager => {
            const id: ChunkId = @intCast(readU16(code, ip));
            ip += 2;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writer.print("chunk #{d}, {d} upvalues", .{ id, upvalues });
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .thunk_captures_store_local, .thunk_captures_store_cell_local, .thunk_captures_eager_store_local, .thunk_captures_eager_store_cell_local => {
            const id: ChunkId = @intCast(readU16(code, ip));
            ip += 2;
            const upvalues = readU16(code, ip);
            ip += 2;
            const desc_len = @as(usize, upvalues) * 3;
            ip += desc_len;
            const slot = code[ip];
            ip += 1;
            try writer.print("chunk #{d}, {d} captures → local[{d}]", .{ id, upvalues, slot });
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .closure_long, .thunk_captures_long, .thunk_captures_eager_long, .apply_arg => {
            const id: ChunkId = readU32(code, ip);
            ip += 4;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writer.print("chunk #{d}, {d} upvalues", .{ id, upvalues });
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .closure_captures => {
            const id: ChunkId = @intCast(readU16(code, ip));
            ip += 2;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writer.print("chunk #{d}, {d} captures", .{ id, upvalues });
            ip += @as(usize, upvalues) * 3;
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .closure_captures_long => {
            const id: ChunkId = readU32(code, ip);
            ip += 4;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writer.print("chunk #{d}, {d} captures", .{ id, upvalues });
            ip += @as(usize, upvalues) * 3;
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .defer_attr_value => {
            // Operand: 4-byte deferred-table id, 2-byte env count, then
            // env_count capture descriptors. No chunk id (compiled lazily).
            const id: u32 = readU32(code, ip);
            ip += 4;
            const env_count = readU16(code, ip);
            ip += 2;
            try writer.print("deferred #{d}, {d} env", .{ id, env_count });
            ip += @as(usize, env_count) * 3;
        },

        .get_attr => {
            const id: InternId = @intCast(readU16(code, ip));
            ip += 2;
            try writeInternRef(writer, id, symbols);
        },
        .get_attr_long => {
            const id: InternId = readU32(code, ip);
            ip += 4;
            try writeInternRef(writer, id, symbols);
        },
        .get_upvalue_attr => {
            const slot = readU16(code, ip);
            const id: InternId = @intCast(readU16(code, ip + 2));
            ip += 4;
            try writer.print("upvalue[{d}].", .{slot});
            try writeInternRef(writer, id, symbols);
        },
        .get_local_attr => {
            const slot = code[ip];
            const id: InternId = @intCast(readU16(code, ip + 1));
            ip += 3;
            try writer.print("local[{d}].", .{slot});
            try writeInternRef(writer, id, symbols);
        },
        .get_local_attr_long => {
            const slot = readU16(code, ip);
            const id: InternId = @intCast(readU16(code, ip + 2));
            ip += 4;
            try writer.print("local[{d}].", .{slot});
            try writeInternRef(writer, id, symbols);
        },
        .get_attr_dynamic_or => {
            try writer.writeAll("(dynamic, with default)");
        },
        .get_attr_path_or, .get_attr_path_dynamic_or, .has_attr_path => {
            const segments = code[ip];
            ip += 1;
            ip += @as(usize, segments) * 2;
            try writeAttrPath(writer, code, ip - @as(usize, segments) * 2, segments, false, symbols);
        },
        .get_attr_path_or_long, .get_attr_path_dynamic_or_long, .has_attr_path_long => {
            const segments = code[ip];
            ip += 1;
            ip += @as(usize, segments) * 4;
            try writeAttrPath(writer, code, ip - @as(usize, segments) * 4, segments, true, symbols);
        },
        .get_attr_path_mixed_or, .has_attr_path_mixed => {
            const segments = code[ip];
            ip += 1;
            const dynamic = code[ip];
            ip += 1;
            try writer.print("{d} segments ({d} dynamic)", .{ segments, dynamic });
            for (0..segments) |_| {
                const tag = code[ip];
                ip += 1;
                if (tag == 0) ip += 4;
            }
        },
        .validate_attrs => {
            const allow = code[ip];
            ip += 1;
            const expected = readU16(code, ip);
            ip += 2;
            try writer.print("{d} expected (allow_extra={s})", .{ expected, if (allow != 0) "true" else "false" });
            ip += @as(usize, expected) * 2;
        },
        .validate_attrs_long => {
            const allow = code[ip];
            ip += 1;
            const expected = readU16(code, ip);
            ip += 2;
            try writer.print("{d} expected (allow_extra={s})", .{ expected, if (allow != 0) "true" else "false" });
            ip += @as(usize, expected) * 4;
        },
        .lookup_with => {
            const id: InternId = @intCast(readU16(code, ip));
            ip += 2;
            const scopes = code[ip];
            ip += 1;
            try writeInternRef(writer, id, symbols);
            try writer.print(" ({d} scopes)", .{scopes});
        },
        .lookup_with_long => {
            const id: InternId = readU32(code, ip);
            ip += 4;
            const scopes = code[ip];
            ip += 1;
            try writeInternRef(writer, id, symbols);
            try writer.print(" ({d} scopes)", .{scopes});
        },
    }
    return ip;
}

fn writeAttrPath(
    writer: *std.Io.Writer,
    code: []const u8,
    start: usize,
    segments: u8,
    wide: bool,
    symbols: Symbols,
) !void {
    try writer.writeByte('"');
    var ip = start;
    for (0..segments) |i| {
        if (i > 0) try writer.writeByte('.');
        const id: InternId = if (wide) blk: {
            const v = readU32(code, ip);
            ip += 4;
            break :blk v;
        } else blk: {
            const v: InternId = @intCast(readU16(code, ip));
            ip += 2;
            break :blk v;
        };
        if (symbols.internName(id)) |name| {
            try writer.writeAll(name);
        } else {
            try writer.print("#{d}", .{id});
        }
    }
    try writer.writeByte('"');
}

fn writeInternRef(writer: *std.Io.Writer, id: InternId, symbols: Symbols) !void {
    if (symbols.internName(id)) |name| {
        try writer.writeByte('"');
        try writer.writeAll(name);
        try writer.print("\" (#{d})", .{id});
    } else {
        try writer.print("#{d}", .{id});
    }
}

fn writeSourceColumn(writer: *std.Io.Writer, chunk: *const Chunk, ip: usize, symbols: Symbols) !void {
    var best: ?Chunk.SourceMapEntry = null;
    for (chunk.source_map) |entry| {
        if (ip < entry.start or ip >= entry.end) continue;
        if (best == null or entry.end - entry.start <= best.?.end - best.?.start) {
            best = entry;
        }
    }
    const entry = best orelse return;
    try writer.writeAll("   ; ");
    if (entry.span.file) |file| {
        if (symbols.internName(file)) |name| {
            try writer.print("{s}:", .{name});
        } else {
            try writer.print("file#{d}:", .{file});
        }
    }
    try writer.print("{d}:{d}+{d}", .{ entry.span.line, entry.span.column, entry.span.len });
}

fn writeValueDigest(writer: *std.Io.Writer, value: Value, symbols: Symbols) !void {
    switch (value.kind()) {
        .null => try writer.writeAll("null"),
        .bool_true => try writer.writeAll("true"),
        .bool_false => try writer.writeAll("false"),
        .int => try writer.print("{d}", .{value.asInt()}),
        .float => try writer.print("{d}", .{value.asFloat()}),
        .string => try writeStringRef(writer, "str", value.asInternId(), symbols),
        .path => try writeStringRef(writer, "path", value.asInternId(), symbols),
        .list => try writer.print("list #{d}", .{value.asObjectId()}),
        .attrs => try writer.print("attrs #{d}", .{value.asObjectId()}),
        .closure => try writer.print("closure #{d}", .{value.asObjectId()}),
        .thunk => try writer.print("thunk #{d}", .{value.asObjectId()}),
        .builtin => try writer.print("builtin #{d}", .{value.asBuiltinId()}),
        .builtin_closure => try writer.print("builtin_closure #{d}", .{value.asObjectId()}),
        .string_context => try writer.print("string_ctx #{d}", .{value.asObjectId()}),
        .boxed_int => try writer.print("boxed_int #{d}", .{value.asObjectId()}),
        .partial_app => try writer.print("partial_app #{d}", .{value.asObjectId()}),
    }
}

fn writeStringRef(writer: *std.Io.Writer, kind: []const u8, id: InternId, symbols: Symbols) !void {
    if (symbols.internName(id)) |text| {
        try writer.print("{s} \"", .{kind});
        try writeEscapedSnippet(writer, text, 40);
        try writer.print("\" (#{d})", .{id});
    } else {
        try writer.print("{s} #{d}", .{ kind, id });
    }
}

fn writeEscapedSnippet(writer: *std.Io.Writer, text: []const u8, max_len: usize) !void {
    const len = @min(text.len, max_len);
    for (text[0..len]) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    if (text.len > max_len) try writer.writeAll("...");
}

fn readU16(code: []const u8, ip: usize) u16 {
    return encoding.readU16(code, ip);
}

fn readU32(code: []const u8, ip: usize) u32 {
    return encoding.readU32(code, ip);
}

const ChunkBuilder = @import("chunk.zig").ChunkBuilder;

test "disassembling a chunk prints arithmetic opcode names and jump targets" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    // get_local 0; get_local 1; add_int; jump +0; ret; halt
    try builder.writeOp(allocator, .get_local);
    try builder.writeByte(allocator, 0);
    try builder.writeOp(allocator, .get_local);
    try builder.writeByte(allocator, 1);
    try builder.writeOp(allocator, .add_int);
    try builder.writeOp(allocator, .jump);
    try builder.writeU32(allocator, 0);
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 2);
    defer chunk.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeChunk(&out.writer, 7, &chunk, .{}, .{});
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "chunk #7") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "get_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "add_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "local[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "local[1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "jump") != null);
    // jump operand is a relative +0 offset; disasm annotates the
    // resolved absolute target after the operand.
    try std.testing.expect(std.mem.indexOf(u8, text, "+0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ret") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "halt") != null);
}

test "disassembling prints the constant pool with resolved values" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.emitConstant(allocator, Value.int(42));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeChunk(&out.writer, null, &chunk, .{}, .{});
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "constants (1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "constant") != null);
}

test "disassembling resolves an interned attribute name via Symbols" {
    const allocator = std.testing.allocator;
    var intern = try InternTable.init(allocator);
    defer intern.deinit();
    const name_id = try intern.intern("myAttr");

    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .get_attr);
    try builder.writeU16(allocator, @intCast(name_id));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeChunk(&out.writer, null, &chunk, .{ .intern = &intern }, .{});
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "get_attr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"myAttr\"") != null);
}

test "disassembling omits the constant pool section when show_constants is false" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.emitConstant(allocator, Value.int(1));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeChunk(&out.writer, null, &chunk, .{}, .{ .show_constants = false });
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "constants (") == null);
}
