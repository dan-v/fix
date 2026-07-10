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
    /// Print the raw instruction bytes as a hex column (one color per byte
    /// value when `use_color`, so repeated bytes/opcodes stand out).
    show_bytes: bool = false,
    /// Walk closure/thunk operands and recursively disassemble referenced chunks.
    recurse: bool = false,
    /// Colorize headers, mnemonics, operands, and the per-byte hex column.
    use_color: bool = false,
    /// Recursion cap when `recurse` is true; 0 = unlimited (a visited set still
    /// guarantees termination). The trace pretty-printer bounds this.
    max_depth: u8 = 4,
    /// Optional cross-reference graph; when set, each chunk header lists its
    /// incoming and outgoing chunk references.
    refs: ?*const RefGraph = null,
    /// Terminal width, for extending the zebra row background across the whole
    /// line. 0 disables the extension (background stops at the content).
    line_width: u16 = 0,
};

/// Chunk cross-reference graph over the whole registry: for each chunk, which
/// chunks it references (outgoing) and which reference it (incoming). Built once
/// per disassembly; scanning is O(total bytecode). Uses `page_allocator`, to
/// match the rest of the disassembler's scratch allocations.
pub const RefGraph = struct {
    out: []std.ArrayListUnmanaged(ChunkId),
    inc: []std.ArrayListUnmanaged(ChunkId),

    pub fn build(registry: *const ChunkRegistry, symbols: Symbols) !RefGraph {
        const a = std.heap.page_allocator;
        const n = registry.count();
        const out = try a.alloc(std.ArrayListUnmanaged(ChunkId), n);
        const inc = try a.alloc(std.ArrayListUnmanaged(ChunkId), n);
        for (out) |*l| l.* = .empty;
        for (inc) |*l| l.* = .empty;
        var scratch: std.Io.Writer.Allocating = .init(a);
        defer scratch.deinit();
        var id: ChunkId = 0;
        while (id < n) : (id += 1) {
            const chunk = registry.get(id) orelse continue;
            var refs: std.AutoArrayHashMapUnmanaged(ChunkId, void) = .empty;
            defer refs.deinit(a);
            collectRefs(chunk, symbols, &refs, &scratch) catch continue;
            var it = refs.iterator();
            while (it.next()) |e| {
                const t = e.key_ptr.*;
                out[id].append(a, t) catch {};
                if (t < n) inc[t].append(a, id) catch {};
            }
        }
        for (out) |*l| std.mem.sort(ChunkId, l.items, {}, std.sort.asc(ChunkId));
        for (inc) |*l| std.mem.sort(ChunkId, l.items, {}, std.sort.asc(ChunkId));
        return .{ .out = out, .inc = inc };
    }

    pub fn deinit(self: *RefGraph) void {
        const a = std.heap.page_allocator;
        for (self.out) |*l| l.deinit(a);
        for (self.inc) |*l| l.deinit(a);
        a.free(self.out);
        a.free(self.inc);
    }

    fn outgoing(self: *const RefGraph, id: ChunkId) []const ChunkId {
        return if (id < self.out.len) self.out[id].items else &.{};
    }
    fn incoming(self: *const RefGraph, id: ChunkId) []const ChunkId {
        return if (id < self.inc.len) self.inc[id].items else &.{};
    }
};

/// Walk a chunk's bytecode, collecting every chunk id it references. Reuses
/// `writeOperands` (into a throwaway buffer) so the operand-length and
/// chunk-extraction logic lives in exactly one place.
fn collectRefs(chunk: *const Chunk, symbols: Symbols, refs: *std.AutoArrayHashMapUnmanaged(ChunkId, void), scratch: *std.Io.Writer.Allocating) !void {
    var ip: usize = 0;
    while (ip < chunk.code.len) {
        const op_byte = chunk.code[ip];
        if (op_byte >= opcode_mod.count) {
            ip += 1;
            continue;
        }
        const op: OpCode = @enumFromInt(op_byte);
        ip += 1;
        scratch.writer.end = 0;
        ip = try writeOperands(&scratch.writer, chunk, op, ip, symbols, null, refs);
    }
}

/// Bytes shown per row: the hex column is a fixed 4 cells wide (so the opcode
/// byte, operand bytes, mnemonic, and interpretation all align), and longer
/// records wrap onto continuation rows.
const bytes_per_line = 8;

/// Constant string/path snippets are truncated hard: the pool is a reference
/// table, not a value dump, and colored index links tie a `#N` back to its row.
/// Keeping entries short stops one long string from blowing out column widths.
const snippet_max = 20;

/// The constant pool table can afford longer values than inline references —
/// it's the definitive listing, so truncate it only for very long strings.
const table_snippet_max = 48;

const Visited = std.AutoHashMapUnmanaged(ChunkId, void);

pub fn writeChunk(
    writer: *std.Io.Writer,
    chunk_id: ?ChunkId,
    chunk: *const Chunk,
    symbols: Symbols,
    options: Options,
) !void {
    var visited: Visited = .empty;
    defer visited.deinit(std.heap.page_allocator);
    try writeChunkAt(writer, chunk_id, chunk, symbols, options, 0, &visited);
}

fn writeChunkAt(
    writer: *std.Io.Writer,
    chunk_id: ?ChunkId,
    chunk: *const Chunk,
    symbols: Symbols,
    options: Options,
    // `usize`, not `u8`: `fix disasm` runs with `max_depth == 0` (unlimited,
    // termination guaranteed by `visited`), so a deep reachable-chunk chain
    // (e.g. hundreds of nested lambdas) recurses past 255 — a `u8` counter would
    // overflow and panic.
    depth: usize,
    visited: *Visited,
) anyerror!void {
    if (chunk_id) |id| try visited.put(std.heap.page_allocator, id, {});
    // Each chunk is a top-level group: a colored header and a left-margin guide
    // (in the chunk's own color) down every line of its body.
    const cc: [3]u8 = if (chunk_id) |id| hueColor(id) else .{ 0x9a, 0x9a, 0x9a };
    try writeChunkHeader(writer, chunk_id, chunk, symbols, cc, options.use_color);
    // The chunk's recorded upvalue names (slot order), used by the header table
    // and by upvalue-slot comments throughout the body.
    const up_names: ?[]const InternId = blk: {
        const id = chunk_id orelse break :blk null;
        const reg = symbols.registry orelse break :blk null;
        break :blk reg.upvalueNamesOf(id);
    };

    if (options.show_constants and chunk.constants.len > 0) {
        try writeGuide(writer, cc, null, options.use_color);
        try writer.writeAll("  constants:\n");
        for (chunk.constants, 0..) |c, i| {
            // Table rows sit under their own colored `│` gutter, like operand
            // groups do under their count line; the run closes with `└`.
            try writeGuide(writer, cc, null, options.use_color);
            try writer.writeAll("  ");
            try writeTreeGuide(writer, sec_constants_color, if (i == chunk.constants.len - 1) .corner else .vert, null, options.use_color);
            // `#N` in the slot's identity color — the same hue a `push_const #N`
            // reference carries, so a reference ties back to its row here.
            var ibuf: [8]u8 = undefined;
            const istr = std.fmt.bufPrint(&ibuf, "#{d}", .{i}) catch "#?";
            if (options.use_color) {
                const ic = constColor(i);
                try writer.print("\x1b[38;2;{d};{d};{d}m{s}\x1b[0m", .{ ic[0], ic[1], ic[2], istr });
            } else {
                try writer.writeAll(istr);
            }
            try writer.splatByteAll(' ', 6 -| istr.len);
            try writeValueDigest(writer, c, symbols, table_snippet_max, options.use_color);
            try writer.writeByte('\n');
        }
    }

    // Upvalue table: the best-effort binding name behind each upvalue slot,
    // mirrored by the `upvalue[N] name` comments in the body.
    if (up_names) |ups| {
        try writeGuide(writer, cc, null, options.use_color);
        try writer.writeAll("  upvalues:\n");
        for (ups, 0..) |name_id, i| {
            try writeGuide(writer, cc, null, options.use_color);
            try writer.writeAll("  ");
            try writeTreeGuide(writer, sec_upvalues_color, if (i == ups.len - 1) .corner else .vert, null, options.use_color);
            var ibuf: [8]u8 = undefined;
            const istr = std.fmt.bufPrint(&ibuf, "#{d}", .{i}) catch "#?";
            try writer.writeAll(istr);
            try writer.splatByteAll(' ', 6 -| istr.len);
            if (symbols.internName(name_id)) |name| {
                if (options.use_color) try writer.print("\x1b[38;2;{d};{d};{d}m", .{ name_color[0], name_color[1], name_color[2] });
                try writer.writeAll(name);
                if (options.use_color) try writer.writeAll("\x1b[0m");
            } else {
                try writer.print("0x{x}", .{name_id});
            }
            try writer.writeByte('\n');
        }
    }

    // References section: which chunks reach this one and which it reaches.
    if (chunk_id) |id| if (options.refs) |graph| {
        const inc = graph.incoming(id);
        const out = graph.outgoing(id);
        if (inc.len > 0 or out.len > 0) {
            try writeGuide(writer, cc, null, options.use_color);
            try writer.writeAll("  references:\n");
            try writeRefList(writer, "incoming", sec_incoming_color, inc, out.len == 0, symbols, cc, options.use_color);
            try writeRefList(writer, "outgoing", sec_outgoing_color, out, true, symbols, cc, options.use_color);
        }
    };

    var ip: usize = 0;
    var referenced_chunks: std.AutoArrayHashMapUnmanaged(ChunkId, void) = .empty;
    defer referenced_chunks.deinit(std.heap.page_allocator);

    // Scratch for each instruction's compact operand decode. Growable (reset,
    // capacity retained, per instruction) rather than a fixed buffer: a decode
    // is normally a few dozen bytes, but a pathological attribute name or path
    // (`x."<multi-KB string>"`) is unbounded, and overflowing a fixed buffer
    // would abort the whole disassembly with a write error.
    var op_scratch: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer op_scratch.deinit();

    const env = Env{
        .cc = cc,
        .show_bytes = options.show_bytes,
        .use_color = options.use_color,
        .line_width = options.line_width,
    };
    // Zebra stripe unit counter for the body rows (see takeBg).
    var stripe: usize = 0;

    // Source filenames are hoisted onto their own comment line: one at the top
    // of the chunk (before any bytes) and again only if the file changes
    // mid-chunk. File lines are not striped and don't advance the stripe.
    var last_file: ?InternId = null;
    if (options.show_source) {
        if (chunkPrimaryFile(chunk, chunk_id, symbols)) |f| {
            try writeGuide(writer, cc, null, options.use_color);
            try writeFileLine(writer, f, symbols, options.use_color);
            last_file = f;
        }
    }

    while (ip < chunk.code.len) {
        const start = ip;
        const op_byte = chunk.code[ip];
        // OpCode is a gapless `enum(u8)`, so anything ≥ the tag count is not a
        // valid opcode — a misaligned decode, or (under `--eval`) a registry
        // chunk that isn't plain bytecode. Show the raw byte and resync one byte
        // forward instead of crashing on `@enumFromInt`.
        if (op_byte >= opcode_mod.count) {
            ip += 1;
            const bg = takeBg(&stripe, options.use_color);
            try beginRow(writer, bg, options.use_color);
            try writeGuide(writer, cc, bg, options.use_color);
            try writeOffset(writer, start, bg, options.use_color);
            try writer.writeAll("  ");
            if (options.show_bytes) try writeByteCellColored(writer, op_byte, byteRgb(op_byte), bg, options.use_color);
            if (options.show_bytes) try writer.splatByteAll(' ', (bytes_per_line - 1) * 3 + 1);
            try setCommentFg(writer, options.use_color);
            try writer.print(".byte 0x{x:0>2}", .{op_byte});
            try sgrReset(writer, bg, options.use_color);
            try endRow(writer, bg, env.prefixWidth() + 10, env);
            continue;
        }
        const op: OpCode = @enumFromInt(op_byte);
        ip += 1;

        // Decode the operands into scratch first: we need the full instruction
        // byte-range (to print the raw-byte column ahead of the mnemonic) before
        // writing the line.
        op_scratch.writer.end = 0;
        ip = try writeOperands(&op_scratch.writer, chunk, op, ip, symbols, up_names, &referenced_chunks);
        const operand_text = op_scratch.writer.buffered();
        const insn = chunk.code[start..ip];

        // Find the narrowest source span covering this instruction; hoist its
        // filename onto its own line when it changes from the previous one.
        const span: ?Chunk.SourceSpan = if (options.show_source) bestSpan(chunk, start) else null;
        if (span) |s| {
            if (s.file) |f| {
                if (last_file == null or last_file.? != f) {
                    try writeGuide(writer, cc, null, options.use_color);
                    try writeFileLine(writer, f, symbols, options.use_color);
                    last_file = f;
                }
            }
        }

        const bg = takeBg(&stripe, options.use_color);
        try beginRow(writer, bg, options.use_color);
        try writeGuide(writer, cc, bg, options.use_color);
        try writeOffset(writer, start, bg, options.use_color);
        try writer.writeAll("  ");
        if (isMultiline(op)) {
            // The mnemonic row carries the opcode + head operand (a chunk id, or
            // attrset counts); list operands become indented child rows below,
            // each its own stripe unit.
            var seq: usize = @intFromEnum(op) + 1;
            var head = Line{};
            const head_len = buildHead(&head, op, chunk.code, start, symbols, &seq);
            try emitMnemonicHead(writer, chunk.code, start, op, &head, head_len, &seq, bg, env);
            try writeOperandTail(writer, chunk, op, start + 1 + head_len, ip, operand_text, &seq, symbols, up_names, &stripe, env);
        } else {
            // Zero or one simple operand: keep it all on the mnemonic row. The
            // opcode byte + mnemonic share one color; the operand bytes and its
            // interpretation share another (linked), like the multi-row style.
            // A `push_const` takes its constant's identity color instead, so the
            // reference and the pool row it names share a hue.
            const opcol = switch (op) {
                .push_const, .push_const_ret => if (insn.len >= 3) constColor(readU16(insn, 1)) else hueColor(@intFromEnum(op) + 1),
                else => hueColor(@intFromEnum(op) + 1),
            };
            if (options.show_bytes) {
                var c: usize = 0;
                while (c < bytes_per_line) : (c += 1) {
                    if (c >= insn.len) {
                        try writer.writeAll("   ");
                    } else {
                        try writeByteCellColored(writer, insn[c], if (c == 0) byteRgb(op_byte) else opcol, bg, options.use_color);
                    }
                }
            }
            try writer.writeByte(' '); // gap column between the bytes and the mnemonic
            try writeMnemonic(writer, op, bg, options.use_color);
            var w: u16 = @intCast(@tagName(op).len + 1);
            if (operand_text.len > 0) {
                w = try writeInlineOperand(writer, operand_text, opcol, w, bg, options.use_color);
            }
            try endRow(writer, bg, env.prefixWidth() + w, env);
            // Wrap any remaining instruction bytes onto continuation rows (the
            // same stripe unit as the instruction).
            if (options.show_bytes and insn.len > bytes_per_line) {
                var o: usize = bytes_per_line;
                while (o < insn.len) : (o += bytes_per_line) {
                    try beginRow(writer, bg, options.use_color);
                    try writeGuide(writer, cc, bg, options.use_color);
                    try writer.writeAll("        ");
                    var c: usize = o;
                    while (c < o + bytes_per_line and c < insn.len) : (c += 1) try writeByteCellColored(writer, insn[c], opcol, bg, options.use_color);
                    try endRow(writer, bg, @intCast(10 + 3 * (@min(o + bytes_per_line, insn.len) - o)), env);
                }
            }
        }
    }

    if (options.recurse) {
        const reg = symbols.registry orelse return;
        if (options.max_depth != 0 and depth + 1 >= @as(usize, options.max_depth)) return;
        var it = referenced_chunks.iterator();
        while (it.next()) |entry| {
            const child_id = entry.key_ptr.*;
            if (visited.contains(child_id)) continue;
            const child = reg.get(child_id) orelse continue;
            try writer.writeByte('\n');
            try writeChunkAt(writer, child_id, child, symbols, options, depth + 1, visited);
        }
    }
}

/// One row of the raw-byte column: `bytes` hex cells (color-coded per byte
/// value when `use_color`), padded to a fixed width so what follows aligns.
/// `bytes.len` must be ≤ `bytes_per_row`.
fn writeByteField(writer: *std.Io.Writer, bytes: []const u8, use_color: bool) !void {
    for (bytes) |b| try writeByteCell(writer, b, use_color);
    try writer.splatByteAll(' ', (bytes_per_line - bytes.len) * 3);
}

/// One `xx ` hex cell, color-coded per byte value when `use_color`.
fn writeByteCell(writer: *std.Io.Writer, b: u8, use_color: bool) !void {
    if (use_color) {
        const rgb = byteRgb(b);
        try writer.print("\x1b[38;2;{d};{d};{d}m{x:0>2}\x1b[0m ", .{ rgb[0], rgb[1], rgb[2], b });
    } else {
        try writer.print("{x:0>2} ", .{b});
    }
}

/// Map a byte value to a legible, deterministic RGB color. The golden-angle
/// hue step maximizes separation between nearby byte values, and a high value
/// keeps every color readable on a dark terminal; equal bytes always share a
/// color, so repeats and runs pop visually.
fn byteRgb(b: u8) [3]u8 {
    return hueColor(b);
}

fn hsvToRgb(h: f32, s: f32, v: f32) [3]u8 {
    const c = v * s;
    const hp = h / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    var r: f32 = 0;
    var g: f32 = 0;
    var bl: f32 = 0;
    if (hp < 1.0) {
        r = c;
        g = x;
    } else if (hp < 2.0) {
        r = x;
        g = c;
    } else if (hp < 3.0) {
        g = c;
        bl = x;
    } else if (hp < 4.0) {
        g = x;
        bl = c;
    } else if (hp < 5.0) {
        r = x;
        bl = c;
    } else {
        r = c;
        bl = x;
    }
    const m = v - c;
    return .{
        @intFromFloat(@round((r + m) * 255.0)),
        @intFromFloat(@round((g + m) * 255.0)),
        @intFromFloat(@round((bl + m) * 255.0)),
    };
}

fn writeOffset(writer: *std.Io.Writer, off: usize, bg: ?[3]u8, use_color: bool) !void {
    try writer.writeAll("  ");
    if (use_color) try writer.writeAll("\x1b[2m");
    try writer.print("{x:0>4}", .{off});
    try sgrReset(writer, bg, use_color);
}

/// Write the mnemonic followed by a single space. When colored, it takes the
/// same per-value color as its opcode byte, so the mnemonic and its leading hex
/// cell visually match.
fn writeMnemonic(writer: *std.Io.Writer, op: OpCode, bg: ?[3]u8, use_color: bool) !void {
    const name = @tagName(op);
    if (use_color) {
        const rgb = byteRgb(@intFromEnum(op));
        try writer.print("\x1b[38;2;{d};{d};{d}m{s}", .{ rgb[0], rgb[1], rgb[2], name });
        try sgrReset(writer, bg, use_color);
    } else {
        try writer.writeAll(name);
    }
    try writer.writeByte(' ');
}

// ---------------------------------------------------------------------------
// Operand field rendering: one indented line per operand field
// ---------------------------------------------------------------------------

/// A legible color for sequence position `seq`. Consecutive values land a
/// golden angle (~137.5°) apart, so neighbouring groups are always well
/// separated — we care more about telling adjacent parts apart than about a
/// given value always mapping to the same color.
fn hueColor(seq: usize) [3]u8 {
    const hue: f32 = @floatCast(@mod(@as(f64, @floatFromInt(seq)) * 137.508, 360.0));
    return hsvToRgb(hue, 0.62, 0.99);
}

/// Every chunk has an identity color derived from its id — the same hue is used
/// for its header title and for every reference to it, so a `chunk[0xN]` operand
/// visually points at the header it names.
fn objColor(id: anytype) [3]u8 {
    return hueColor(@intCast(id));
}

/// Fixed color for compiler-attributed chunk names, wherever they appear
/// (header title and operand comments), so a name always reads as a name.
const name_color: [3]u8 = .{ 0x83, 0xd6, 0x8f };

/// Subtle background tint for alternating multi-row list records, so each
/// 2-row entry reads as one block.
const row_bg: [3]u8 = .{ 0x28, 0x28, 0x34 };

/// A constant pool slot's identity color, shared by its `#N` references and its
/// row in the pool table. Offset well past typical chunk ids so a `#N` constant
/// and a `chunk[0xN]` never share a hue in the same listing.
fn constColor(i: usize) [3]u8 {
    return hueColor(i + 1000);
}

/// Identity color for an interned string/path id: the same hue everywhere the
/// id appears — as a raw operand, inside a `str[0xN]` comment, and on its
/// constant-pool row — so occurrences of one id link up visually. Offset past
/// the chunk-id and constant-slot seeds.
fn internColor(id: anytype) [3]u8 {
    return hueColor(@as(usize, @intCast(id)) + 5000);
}

/// Identity color for a heap object id (closures/thunks/lists in constant
/// digests). Own seed range, like chunks/constants/interns.
fn heapColor(id: anytype) [3]u8 {
    return hueColor(@as(usize, @intCast(id)) + 9000);
}

/// Fixed keyword color for the store name in a `store[accessor]` reference
/// (`chunk[…]`, `str[…]`, …): the store reads as a keyword, the accessor
/// carries the identity color, and the brackets stay dim.
const store_kw_color: [3]u8 = .{ 0x7f, 0xbf, 0xd8 };

/// Section guide colors (constants / references and its subsections), so each
/// indented table gets its own `│` gutter like operand groups do.
const sec_constants_color: [3]u8 = .{ 0xb8, 0xa6, 0x5c };
const sec_upvalues_color: [3]u8 = .{ 0xb8, 0x5c, 0x74 };
const sec_references_color: [3]u8 = .{ 0x5c, 0xb8, 0xa6 };
const sec_incoming_color: [3]u8 = .{ 0xa6, 0x5c, 0xb8 };
const sec_outgoing_color: [3]u8 = .{ 0x5c, 0x8a, 0xb8 };

/// Column (from the mnemonic's first character) where instruction-line `;`
/// comments start. Field rows compute their pad from this too (minus their
/// guide indentation), so every `;` in a chunk body lands in one column.
const mnem_comment_col = 28;

/// Comment/structural text color — a readable grey, brighter than terminal-dim.
const comment_color: [3]u8 = .{ 0xb2, 0xb2, 0xb2 };

/// Shared rendering environment for the chunk-body emitters.
const Env = struct {
    /// Chunk guide color (the left margin `│`).
    cc: [3]u8,
    show_bytes: bool,
    use_color: bool,
    /// Terminal width the zebra background extends to (0 = no extension).
    line_width: u16,

    /// Width of the fixed row prefix: guide + offset column + byte field + gap.
    fn prefixWidth(self: Env) u16 {
        return if (self.show_bytes) 35 else 11;
    }
};

/// Zebra striping: every other body row gets the background tint, where a
/// multi-row record (position entries) counts as ONE stripe unit. Returns the
/// current unit's background and advances the stripe.
fn takeBg(stripe: *usize, use_color: bool) ?[3]u8 {
    const bg: ?[3]u8 = if (use_color and stripe.* % 2 == 1) row_bg else null;
    stripe.* += 1;
    return bg;
}

/// Start a body row: establish its background (if striped) from column 0, so
/// the tint covers the whole line including the left margin.
fn beginRow(writer: *std.Io.Writer, bg: ?[3]u8, use_color: bool) !void {
    if (use_color) if (bg) |b| try writer.print("\x1b[48;2;{d};{d};{d}m", .{ b[0], b[1], b[2] });
}

/// Finish a body row at absolute column `abs_w`: extend a striped row's tint to
/// the full terminal width, reset, newline.
fn endRow(writer: *std.Io.Writer, bg: ?[3]u8, abs_w: u16, env: Env) !void {
    if (env.use_color and bg != null and env.line_width > abs_w) {
        try writer.splatByteAll(' ', env.line_width - abs_w);
    }
    if (env.use_color) try writer.writeAll("\x1b[0m");
    try writer.writeByte('\n');
}

/// Visible width of UTF-8 text (codepoints; `→`/`…`/`│` count 1).
fn visibleWidth(text: []const u8) u16 {
    var w: u16 = 0;
    for (text) |ch| {
        if ((ch & 0xC0) != 0x80) w += 1;
    }
    return w;
}

/// Set the foreground for comment/structural text — the one grey used for
/// every `;` comment, bracket, and annotation, so nothing reads fainter than
/// the rest regardless of hue or the zebra background underneath.
fn setCommentFg(writer: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try writer.print("\x1b[38;2;{d};{d};{d}m", .{ comment_color[0], comment_color[1], comment_color[2] });
}

/// Render a single instruction's inline operand text: everything before the
/// first ` ; ` is the raw decoded value (in `col`, linked to its bytes); the
/// ` ; …` interpretation that follows takes the shared comment grey and is
/// padded out to the mnemonic-line comment column. `start_w` is the width
/// already written on the line from the mnemonic's first character; returns
/// the width after the operand.
fn writeInlineOperand(writer: *std.Io.Writer, text: []const u8, col: [3]u8, start_w: u16, bg: ?[3]u8, use_color: bool) !u16 {
    const cut = std.mem.indexOf(u8, text, " ; ") orelse text.len;
    if (use_color) try writer.print("\x1b[38;2;{d};{d};{d}m", .{ col[0], col[1], col[2] });
    try writer.writeAll(text[0..cut]);
    var w = start_w + visibleWidth(text[0..cut]);
    if (cut < text.len) {
        try sgrReset(writer, bg, use_color);
        if (w < mnem_comment_col) {
            try writer.splatByteAll(' ', mnem_comment_col - w);
            w = mnem_comment_col;
        }
        try setCommentFg(writer, use_color);
        try writer.writeAll(text[cut..]);
        w += visibleWidth(text[cut..]);
    }
    try sgrReset(writer, bg, use_color);
    return w;
}

/// Reset the foreground (and any attributes), then — inside a background-tinted
/// row (`bg` set) — re-establish that background so the tint survives per-cell
/// resets and stays an unbroken rectangle.
fn sgrReset(writer: *std.Io.Writer, bg: ?[3]u8, use_color: bool) !void {
    if (!use_color) return;
    try writer.writeAll("\x1b[0m");
    if (bg) |b| try writer.print("\x1b[48;2;{d};{d};{d}m", .{ b[0], b[1], b[2] });
}

fn writeByteCellColored(writer: *std.Io.Writer, b: u8, rgb: [3]u8, bg: ?[3]u8, use_color: bool) !void {
    if (use_color) {
        try writer.print("\x1b[38;2;{d};{d};{d}m{x:0>2}", .{ rgb[0], rgb[1], rgb[2], b });
        try sgrReset(writer, bg, use_color);
        try writer.writeByte(' ');
    } else {
        try writer.print("{x:0>2} ", .{b});
    }
}

/// One `--fields` operand line: a run of colored byte-groups (each `len` bytes
/// at `byte_off`, whose interpretation `text` takes that group's color) and dim
/// structural glue (`len == 0`). Groups may be listed in display order even when
/// that differs from byte order — the shared color is the link, not position.
const Tok = struct { byte_off: u16 = 0, len: u16 = 0, text: []const u8, colored: bool = false, pin: bool = false, color: [3]u8 = .{ 0x9a, 0x9a, 0x9a } };

const Line = struct {
    toks: [24]Tok = undefined,
    n: usize = 0,
    buf: [1024]u8 = undefined,
    used: usize = 0,
    /// Token index where the `;` comment starts, if any. The renderer pads the
    /// tokens before it out to `field_comment_col` so comment semicolons align.
    comment_tok: ?usize = null,

    fn store(self: *Line, comptime fmt: []const u8, args: anytype) []const u8 {
        const s = std.fmt.bufPrint(self.buf[self.used..], fmt, args) catch self.buf[self.used..self.used];
        self.used += s.len;
        return s;
    }
    /// Dim structural text (brackets, separators, `chunk `), consumes no bytes.
    fn glue(self: *Line, comptime fmt: []const u8, args: anytype) void {
        const s = self.store(fmt, args);
        if (self.n < self.toks.len) {
            self.toks[self.n] = .{ .text = s };
            self.n += 1;
        }
    }
    /// A decoded value: `len` bytes at `byte_off`, text tinted to match them.
    fn group(self: *Line, byte_off: u16, len: u16, comptime fmt: []const u8, args: anytype) void {
        const s = self.store(fmt, args);
        if (self.n < self.toks.len) {
            self.toks[self.n] = .{ .byte_off = byte_off, .len = len, .text = s, .colored = true };
            self.n += 1;
        }
    }
    /// Like `group`, but with an explicit identity `color` (its bytes take it
    /// too) instead of the running-hue assignment — for a chunk id, whose color
    /// is fixed to the chunk it names.
    fn groupPinned(self: *Line, byte_off: u16, len: u16, color: [3]u8, comptime fmt: []const u8, args: anytype) void {
        const s = self.store(fmt, args);
        if (self.n < self.toks.len) {
            self.toks[self.n] = .{ .byte_off = byte_off, .len = len, .text = s, .colored = true, .pin = true, .color = color };
            self.n += 1;
        }
    }
    /// Colored text that maps to no bytes — an interpretive comment fragment
    /// (`chunk[0xN]`, a name) drawn in a fixed color rather than dim grey.
    fn tint(self: *Line, color: [3]u8, comptime fmt: []const u8, args: anytype) void {
        const s = self.store(fmt, args);
        if (self.n < self.toks.len) {
            self.toks[self.n] = .{ .text = s, .colored = true, .pin = true, .color = color };
            self.n += 1;
        }
    }
    /// Begin the `;` comment: marks the alignment point, then writes ` ; `.
    fn comment(self: *Line) void {
        if (self.comment_tok == null) self.comment_tok = self.n;
        self.glue(" ; ", .{});
    }
    /// A `store[accessor]` reference: keyword in the fixed store color, brackets
    /// dim, accessor in the object's identity color. The uniform shape for every
    /// cross-reference (`chunk[0xN]`, `str[0xN]`, …).
    fn storeRef(self: *Line, kw: []const u8, id_color: [3]u8, comptime id_fmt: []const u8, id_args: anytype) void {
        self.tint(store_kw_color, "{s}", .{kw});
        self.glue("[", .{});
        self.tint(id_color, id_fmt, id_args);
        self.glue("]", .{});
    }
    fn total(self: *const Line) u16 {
        var m: u16 = 0;
        for (self.toks[0..self.n]) |t| {
            if (t.byte_off + t.len > m) m = t.byte_off + t.len;
        }
        return m;
    }
    /// Assign each group the next hue from the running counter, so adjacent
    /// groups differ sharply regardless of their byte values.
    fn paint(self: *Line, seq: *usize) void {
        for (self.toks[0..self.n]) |*t| {
            if (t.colored and t.len > 0 and !t.pin) {
                t.color = hueColor(seq.*);
                seq.* += 1;
            }
        }
    }
    fn colorAt(self: *const Line, pos: u16) [3]u8 {
        for (self.toks[0..self.n]) |t| {
            if (t.len > 0 and pos >= t.byte_off and pos < t.byte_off + t.len) return t.color;
        }
        return .{ 0x9a, 0x9a, 0x9a }; // ungrouped byte
    }
};

/// One hierarchy indent guide, drawn once per ancestor group and colored by
/// that group's title — a background block in color mode, `│` otherwise. This
/// is what nests capture/position lists under their count line.
fn writeGuide(writer: *std.Io.Writer, rgb: [3]u8, bg: ?[3]u8, use_color: bool) !void {
    if (use_color) {
        try writer.print("\x1b[38;2;{d};{d};{d}m│", .{ rgb[0], rgb[1], rgb[2] });
        try sgrReset(writer, bg, use_color);
        try writer.writeByte(' ');
    } else {
        try writer.writeAll("│ ");
    }
}

/// One operand-hierarchy gutter cell: a vertical `│` that descends through the
/// group's members, closing with an L-shaped `└` on the run's last row. A
/// column wider than the thin chunk margin.
const GuideKind = enum { vert, corner, blank };
fn writeTreeGuide(writer: *std.Io.Writer, rgb: [3]u8, kind: GuideKind, bg: ?[3]u8, use_color: bool) !void {
    const glyph: []const u8 = switch (kind) {
        .vert => "│  ",
        .corner => "└  ",
        .blank => "   ",
    };
    if (use_color and kind != .blank) {
        try writer.print("\x1b[38;2;{d};{d};{d}m{s}", .{ rgb[0], rgb[1], rgb[2], glyph });
        try sgrReset(writer, bg, use_color);
    } else {
        try writer.writeAll(glyph); // blank guide: bare spaces (already on `bg`)
    }
}

/// Render one operand line at `off` under `guides` (ancestor colors), then
/// advance `off` past its bytes. Bytes stay in their fixed column (aligned under
/// the opcode byte); the hierarchy guides sit in the mnemonic gutter to the
/// right of the bytes, so the interpretation reads as an indented child of the
/// mnemonic. Long records wrap at `bytes_per_line`, guides repeating on each
/// row (a continuous gutter) but the interpretation only on the first. `seq` is
/// the running per-instruction color counter (shared with the mnemonic).
fn emitLine(writer: *std.Io.Writer, code: []const u8, off: *usize, line: *Line, seq: *usize, guides: []const [3]u8, last_mask: u8, bg: ?[3]u8, env: Env) !void {
    const base = off.*;
    const total = line.total();
    line.paint(seq);
    const depth: u16 = @intCast(guides.len);
    // Field-row comment column, relative to the token area: absolute alignment
    // with the mnemonic-line comments, minus this row's guide indentation.
    const comment_col = mnem_comment_col -| 3 * depth;
    const rows: u16 = if (!env.show_bytes or total == 0) 1 else (total + bytes_per_line - 1) / bytes_per_line;
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        try beginRow(writer, bg, env.use_color);
        try writeGuide(writer, env.cc, bg, env.use_color);
        try writer.writeAll("        "); // blank offset column
        if (env.show_bytes) {
            var c: u16 = 0;
            while (c < bytes_per_line) : (c += 1) {
                const pos = r * bytes_per_line + c;
                if (pos < total) try writeByteCellColored(writer, code[base + pos], line.colorAt(pos), bg, env.use_color) else try writer.writeAll("   ");
            }
        }
        try writer.writeByte(' '); // gap column between the bytes and the gutter
        // Tree gutter: every ancestor level draws a vertical bar `│` down the
        // gutter; a level whose run ends at this line (`last_mask` bit i)
        // closes with `└` on the line's final row.
        for (guides, 0..) |gc, gi| {
            const ends = (last_mask >> @intCast(gi)) & 1 == 1;
            const kind: GuideKind = if (ends and r == rows - 1) .corner else .vert;
            try writeTreeGuide(writer, gc, kind, bg, env.use_color);
        }
        var w: u16 = 0;
        if (r == 0) {
            for (line.toks[0..line.n], 0..) |t, i| {
                // Align the `;` comments down the block: pad the raw-value
                // region out to the shared column before the comment starts.
                if (line.comment_tok != null and i == line.comment_tok.? and w < comment_col) {
                    try sgrReset(writer, bg, env.use_color);
                    try writer.splatByteAll(' ', comment_col - w);
                    w = comment_col;
                }
                if (env.use_color) {
                    if (t.colored) {
                        try writer.print("\x1b[38;2;{d};{d};{d}m", .{ t.color[0], t.color[1], t.color[2] });
                    } else {
                        // Structural / comment text: grey — reset first so it
                        // doesn't inherit the previous token's hue.
                        try sgrReset(writer, bg, env.use_color);
                        try writer.print("\x1b[38;2;{d};{d};{d}m", .{ comment_color[0], comment_color[1], comment_color[2] });
                    }
                }
                try writer.writeAll(t.text);
                w += visibleWidth(t.text);
            }
        }
        try endRow(writer, bg, env.prefixWidth() + 3 * depth + w, env);
    }
    off.* += total;
}

/// Whether a chunk-id-carrying op uses the wide (u32) id form.
fn chunkIdWide(op: OpCode) bool {
    return switch (op) {
        .clos_w, .clos_cap_w, .thk_w, .thk_eag_w, .thk_arg => true,
        else => false,
    };
}

/// Build the *head* operand — the scalar accessor(s) the mnemonic line carries
/// (a chunk id, or an attrset's entry/position counts) — as a `Line` whose byte
/// offsets are relative to the opcode byte (byte 0). Returns the number of
/// operand bytes consumed (so the list tail starts at opcode + 1 + head_len).
fn buildHead(l: *Line, op: OpCode, code: []const u8, start: usize, symbols: Symbols, seq: *usize) u16 {
    switch (op) {
        .clos, .clos_w, .clos_cap, .clos_cap_w, .thk, .thk_w, .thk_eag, .thk_eag_w, .thk_arg, .thk_st, .thk_st_cell, .thk_eag_st, .thk_eag_st_cell => {
            const wide = chunkIdWide(op);
            const id_len: u16 = if (wide) 4 else 2;
            const id: ChunkId = if (wide) readU32(code, start + 1) else @intCast(readU16(code, start + 1));
            l.groupPinned(1, id_len, objColor(id), "0x{x}", .{id});
            l.comment();
            l.storeRef("chunk", objColor(id), "0x{x}", .{id});
            if (chunkNameOf(symbols, id)) |name| l.tint(name_color, " {s}", .{name});
            return id_len;
        },
        .attrs_new_pos, .attrs_new_pos_srt => {
            // Each raw count and its mention in the comment share a color.
            const entries = readU16(code, start + 1);
            const positions = readU16(code, start + 3);
            const c_e = hueColor(seq.*);
            const c_p = hueColor(seq.* + 1);
            seq.* += 2;
            l.groupPinned(1, 2, c_e, "#{d}", .{entries});
            l.glue(" ", .{});
            l.groupPinned(3, 2, c_p, "#{d}", .{positions});
            l.comment();
            l.tint(c_e, "{d}", .{entries});
            l.glue(" entries, ", .{});
            l.tint(c_p, "{d}", .{positions});
            l.glue(" positions", .{});
            return 4;
        },
        .thk_defer => {
            const id = readU32(code, start + 1);
            l.group(1, 4, "#{d}", .{id});
            l.comment();
            l.glue("deferred", .{});
            return 4;
        },
        .attr_check, .attr_check_w => {
            const allow = code[start + 1];
            const expected = readU16(code, start + 2);
            const c_a = hueColor(seq.*);
            const c_n = hueColor(seq.* + 1);
            seq.* += 2;
            l.groupPinned(1, 1, c_a, "#{d}", .{allow});
            l.glue(" ", .{});
            l.groupPinned(2, 2, c_n, "#{d}", .{expected});
            l.comment();
            l.tint(c_n, "{d}", .{expected});
            l.glue(" expected, ", .{});
            l.tint(c_a, "extra {s}", .{if (allow != 0) "allowed" else "rejected"});
            return 3;
        },
        else => return 0,
    }
}

/// Render a multiline op's mnemonic row: byte column (opcode + head bytes,
/// colored to match) then the mnemonic and the inline head operand. `head` is
/// from `buildHead`; `head_len` its operand byte count.
fn emitMnemonicHead(writer: *std.Io.Writer, code: []const u8, start: usize, op: OpCode, head: *Line, head_len: u16, seq: *usize, bg: ?[3]u8, env: Env) !void {
    head.paint(seq);
    if (env.show_bytes) {
        var c: u16 = 0;
        while (c < bytes_per_line) : (c += 1) {
            if (c == 0) {
                try writeByteCellColored(writer, code[start], byteRgb(code[start]), bg, env.use_color);
            } else if (c <= head_len) {
                try writeByteCellColored(writer, code[start + c], head.colorAt(c), bg, env.use_color);
            } else {
                try writer.writeAll("   ");
            }
        }
    }
    try writer.writeByte(' '); // gap between bytes and the mnemonic
    try writeMnemonic(writer, op, bg, env.use_color);
    // Width from the mnemonic's first character, for the shared comment column.
    var w: u16 = @intCast(@tagName(op).len + 1);
    for (head.toks[0..head.n], 0..) |t, i| {
        if (head.comment_tok != null and i == head.comment_tok.? and w < mnem_comment_col) {
            try sgrReset(writer, bg, env.use_color);
            try writer.splatByteAll(' ', mnem_comment_col - w);
            w = mnem_comment_col;
        }
        if (env.use_color) {
            if (t.colored) {
                try writer.print("\x1b[38;2;{d};{d};{d}m", .{ t.color[0], t.color[1], t.color[2] });
            } else {
                try sgrReset(writer, bg, env.use_color);
                try writer.print("\x1b[38;2;{d};{d};{d}m", .{ comment_color[0], comment_color[1], comment_color[2] });
            }
        }
        try writer.writeAll(t.text);
        w += visibleWidth(t.text);
    }
    try endRow(writer, bg, env.prefixWidth() + w, env);
}

/// A `#{count} ; {label}` line (count is a u16 at `off`). Fits one row — never
/// wraps — so its guides never blank on a continuation.
fn emitCountLine(writer: *std.Io.Writer, code: []const u8, off: *usize, label: []const u8, seq: *usize, guides: []const [3]u8, last_mask: u8, stripe: *usize, env: Env) !void {
    var l = Line{};
    l.group(0, 2, "#{d}", .{readU16(code, off.*)});
    l.comment();
    l.glue("{s}", .{label});
    try emitLine(writer, code, off, &l, seq, guides, last_mask, takeBg(stripe, env.use_color), env);
}

/// The `n` inline capture descriptors (3 bytes each: kind byte + u16 index),
/// each a child line under `guides`, tinting `local`/`upvalue` with the kind
/// byte and the index with its bytes. Each descriptor fits one row. A kind ==
/// upvalue descriptor reads from the ENCLOSING chunk's upvalues, so its
/// best-effort name (when recorded) becomes the row's comment. `end_mask` is
/// the `last_mask` applied to the list's final row (which guide runs it closes).
fn emitCaptureDescriptors(writer: *std.Io.Writer, code: []const u8, off: *usize, n: u16, seq: *usize, guides: []const [3]u8, end_mask: u8, up_names: ?[]const InternId, symbols: Symbols, stripe: *usize, env: Env) !void {
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const is_upvalue = code[off.*] != 0;
        const idx = readU16(code, off.* + 1);
        var l = Line{};
        l.group(0, 1, "{s}", .{if (is_upvalue) "upvalue" else "local"});
        l.glue("[", .{});
        l.group(1, 2, "{d}", .{idx});
        l.glue("]", .{});
        if (is_upvalue) {
            if (upvalueName(up_names, symbols, idx)) |nm| {
                l.comment();
                l.tint(name_color, "{s}", .{nm});
            }
        }
        const mask: u8 = if (k == n - 1) end_mask else 0;
        try emitLine(writer, code, off, &l, seq, guides, mask, takeBg(stripe, env.use_color), env);
    }
}

/// Resolve upvalue slot `idx`'s best-effort binding name, if recorded.
fn upvalueName(up_names: ?[]const InternId, symbols: Symbols, idx: usize) ?[]const u8 {
    const list = up_names orelse return null;
    if (idx >= list.len) return null;
    return symbols.internName(list[idx]);
}

/// Render an instruction's operands as one line per field. `ip` is the byte
/// offset just past the opcode; `end_ip` is the authoritative instruction end
/// (from `writeOperands`), and `operand_text` its compact decode — used both as
/// the fallback comment for opcodes without a bespoke breakdown and as a guard:
/// any bytes a bespoke arm fails to consume are dumped as a trailing field so a
/// miscount can never bleed into the next instruction.
fn writeOperandTail(
    writer: *std.Io.Writer,
    chunk: *const Chunk,
    op: OpCode,
    ip: usize,
    end_ip: usize,
    operand_text: []const u8,
    seq: *usize,
    symbols: Symbols,
    up_names: ?[]const InternId,
    stripe: *usize,
    env: Env,
) !void {
    const code = chunk.code;
    var off = ip;
    // Guide colors: level 0 is the mnemonic (byteRgb of the opcode); list
    // members hang a level deeper under a count line whose color is g[1].
    var g: [3][3]u8 = undefined;
    g[0] = byteRgb(@intFromEnum(op));
    switch (op) {
        .clos, .clos_w => {
            // The chunk id rode the mnemonic line; only the upvalue count
            // remains — the block's only (and thus last) row.
            try emitCountLine(writer, code, &off, "upvalues (from stack)", seq, g[0..1], 0b01, stripe, env);
        },
        .thk, .thk_eag, .thk_w, .thk_eag_w, .thk_arg, .clos_cap, .clos_cap_w => {
            const n = readU16(code, off);
            g[1] = hueColor(seq.*); // the "captures" count line's color
            try emitCountLine(writer, code, &off, "captures", seq, g[0..1], if (n == 0) 0b01 else 0, stripe, env);
            // The last descriptor closes both the list (level 1) and the block.
            try emitCaptureDescriptors(writer, code, &off, n, seq, g[0..2], 0b11, up_names, symbols, stripe, env);
        },
        .thk_st, .thk_st_cell, .thk_eag_st, .thk_eag_st_cell => {
            const n = readU16(code, off);
            g[1] = hueColor(seq.*);
            try emitCountLine(writer, code, &off, "captures", seq, g[0..1], 0, stripe, env);
            // The list (level 1) closes at the last descriptor; the block
            // (level 0) continues to the store-target row below.
            try emitCaptureDescriptors(writer, code, &off, n, seq, g[0..2], 0b10, up_names, symbols, stripe, env);
            // The trailing slot byte: raw accessor in the value zone, the
            // store-target interpretation (same color) as its comment.
            const c_slot = hueColor(seq.*);
            seq.* += 1;
            var l = Line{};
            l.groupPinned(0, 1, c_slot, "#{d}", .{code[off]});
            l.comment();
            l.glue("→ local[", .{});
            l.tint(c_slot, "{d}", .{code[off]});
            l.glue("]", .{});
            try emitLine(writer, code, &off, &l, seq, g[0..1], 0b01, takeBg(stripe, env.use_color), env);
        },
        .attrs_new_pos, .attrs_new_pos_srt => {
            // Entry/position counts rode the mnemonic line; the positions count
            // is the last 2 head bytes (`off - 2`). Each record hangs at level 1.
            const pos_count = readU16(code, off - 2);
            var k: usize = 0;
            while (k < pos_count) : (k += 1) {
                // 16-byte record: name id, file id, line, col (u32 LE each).
                // Bytes split 8+8 across the two rows, but the text puts the
                // name id alone on row 1 (with its `str[…] → "text"` chain) and
                // the file/line/col trio on row 2 — pinned colors keep every
                // value tied to its bytes even across the row split.
                const nm: InternId = readU32(code, off);
                const fl: InternId = readU32(code, off + 4);
                const ln = readU32(code, off + 8);
                const cl = readU32(code, off + 12);
                const c_nm = internColor(nm);
                const c_fl = internColor(fl);
                const c_ln = hueColor(seq.*);
                const c_cl = hueColor(seq.* + 1);
                seq.* += 2;
                // Row 1 — name id; its bytes and the `str[…]` chain share the
                // intern id's identity color. The file id's bytes (this row's
                // second half) take the file color via a text-less group.
                var esc: [128]u8 = undefined;
                var ew: std.Io.Writer = .fixed(&esc);
                if (symbols.internName(nm)) |s| writeEscapedSnippet(&ew, s, 24) catch {};
                var l1 = Line{};
                l1.groupPinned(0, 4, c_nm, "0x{x}", .{nm});
                l1.groupPinned(4, 4, c_fl, "", .{}); // file id bytes; value shown on row 2
                l1.comment();
                l1.storeRef("str", c_nm, "0x{x}", .{nm});
                l1.glue(" → ", .{});
                // The resolved text is the name id's value — same identity color.
                l1.tint(c_nm, "\"{s}\"", .{esc[0..ew.end]});
                // Row 2 — file, line, col; the location comment's parts reuse
                // their raw values' colors (filename ← file id, line, col).
                var l2 = Line{};
                l2.tint(c_fl, "0x{x}", .{fl}); // value for row 1's second half
                l2.glue(" ", .{});
                l2.groupPinned(0, 4, c_ln, "0x{x}", .{ln});
                l2.glue(" ", .{});
                l2.groupPinned(4, 4, c_cl, "0x{x}", .{cl});
                l2.comment();
                l2.glue("@ ", .{});
                if (symbols.internName(fl)) |f| {
                    l2.tint(c_fl, "{s}", .{std.fs.path.basename(f)});
                } else {
                    l2.storeRef("file", c_fl, "0x{x}", .{fl});
                }
                l2.glue(":", .{});
                l2.tint(c_ln, "{d}", .{ln});
                l2.glue(":", .{});
                l2.tint(c_cl, "{d}", .{cl});
                // The whole 2-row record is ONE stripe unit, so the zebra
                // alternates per entry, not per line.
                const bg = takeBg(stripe, env.use_color);
                try emitLine(writer, code, &off, &l1, seq, g[0..1], 0, bg, env);
                try emitLine(writer, code, &off, &l2, seq, g[0..1], if (k == pos_count - 1) 0b01 else 0, bg, env);
            }
        },
        .thk_defer => {
            const n = readU16(code, off);
            g[1] = hueColor(seq.*);
            try emitCountLine(writer, code, &off, "env", seq, g[0..1], if (n == 0) 0b01 else 0, stripe, env);
            try emitCaptureDescriptors(writer, code, &off, n, seq, g[0..2], 0b11, up_names, symbols, stripe, env);
        },
        .attr_check, .attr_check_w => {
            // The flag + count rode the mnemonic line (count = its last 2 head
            // bytes); one row per expected attribute name, each with its
            // `str[…] → "name"` chain in the intern id's identity color.
            const wide = op == .attr_check_w;
            const id_len: u16 = if (wide) 4 else 2;
            const expected = readU16(code, off - 2);
            var k: usize = 0;
            while (k < expected) : (k += 1) {
                const id: InternId = if (wide) readU32(code, off) else @intCast(readU16(code, off));
                const c = internColor(id);
                var esc: [128]u8 = undefined;
                var ew: std.Io.Writer = .fixed(&esc);
                if (symbols.internName(id)) |s| writeEscapedSnippet(&ew, s, 24) catch {};
                var l = Line{};
                l.groupPinned(0, id_len, c, "0x{x}", .{id});
                l.comment();
                l.storeRef("str", c, "0x{x}", .{id});
                if (ew.end > 0) {
                    l.glue(" → ", .{});
                    l.tint(c, "\"{s}\"", .{esc[0..ew.end]});
                }
                try emitLine(writer, code, &off, &l, seq, g[0..1], if (k == expected - 1) 0b01 else 0, takeBg(stripe, env.use_color), env);
            }
        },
        else => {
            // No bespoke breakdown: dump the whole tail as one group.
            if (end_ip > off) {
                var l = Line{};
                l.group(0, @intCast(end_ip - off), "{s}", .{operand_text});
                try emitLine(writer, code, &off, &l, seq, g[0..1], 0b01, takeBg(stripe, env.use_color), env);
            }
        },
    }
    // Guard: dump any bytes a bespoke arm under-counted as a trailing field.
    if (off < end_ip) {
        var l = Line{};
        l.group(0, @intCast(end_ip - off), "{s}", .{"…"});
        try emitLine(writer, code, &off, &l, seq, g[0..1], 0b01, takeBg(stripe, env.use_color), env);
    }
}

/// Instructions with a list of sub-fields (captures / positions) are drawn
/// across multiple indented rows; everything else fits on one line.
fn isMultiline(op: OpCode) bool {
    return switch (op) {
        .clos,
        .clos_w,
        .thk,
        .thk_eag,
        .thk_w,
        .thk_eag_w,
        .thk_arg,
        .clos_cap,
        .clos_cap_w,
        .thk_st,
        .thk_st_cell,
        .thk_eag_st,
        .thk_eag_st_cell,
        .attrs_new_pos,
        .attrs_new_pos_srt,
        .thk_defer,
        .attr_check,
        .attr_check_w,
        => true,
        else => false,
    };
}

fn writeChunkHeader(writer: *std.Io.Writer, chunk_id: ?ChunkId, chunk: *const Chunk, symbols: Symbols, cc: [3]u8, use_color: bool) !void {
    if (chunk_id) |id| {
        // Same `store[accessor]` coloring as every reference to this chunk —
        // keyword, dim brackets, id in the chunk's identity color (bold: this
        // is the definition the references point at).
        if (use_color) try writer.print("\x1b[1;38;2;{d};{d};{d}m", .{ store_kw_color[0], store_kw_color[1], store_kw_color[2] });
        try writer.writeAll("chunk");
        if (use_color) try writer.writeAll("\x1b[0m");
        try setCommentFg(writer, use_color);
        try writer.writeByte('[');
        if (use_color) try writer.print("\x1b[0;1;38;2;{d};{d};{d}m", .{ cc[0], cc[1], cc[2] });
        try writer.print("0x{x}", .{id});
        if (use_color) try writer.writeAll("\x1b[0m");
        try setCommentFg(writer, use_color);
        try writer.writeByte(']');
        if (use_color) try writer.writeAll("\x1b[0m");
    } else {
        if (use_color) try writer.print("\x1b[1;38;2;{d};{d};{d}m", .{ store_kw_color[0], store_kw_color[1], store_kw_color[2] });
        try writer.writeAll("chunk");
        if (use_color) try writer.writeAll("\x1b[0m");
    }
    // Best-effort compiler-attributed name (the binding a lambda/thunk was
    // compiled for), when name capture was on. See ChunkRegistry.recordName.
    if (chunk_id) |id| {
        if (chunkNameOf(symbols, id)) |name| {
            if (use_color) try writer.print("\x1b[1;38;2;{d};{d};{d}m", .{ name_color[0], name_color[1], name_color[2] });
            try writer.print(" {s}", .{name});
            if (use_color) try writer.writeAll("\x1b[0m");
        }
    }
    try writer.print(" ({d} bytes, {d} consts, {d} locals", .{
        chunk.code.len,
        chunk.constants.len,
        chunk.local_count,
    });
    if (chunk.source_map.len > 0) {
        try writer.print(", {d} source spans", .{chunk.source_map.len});
    }
    if (chunk.arity != 1) {
        try writer.print(", arity {d}", .{chunk.arity});
    }
    try writer.writeAll(")\n");
    if (chunk.scheduling.strictness.forced_upvalues != 0) {
        try writeGuide(writer, cc, null, use_color);
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
        try writeGuide(writer, cc, null, use_color);
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

/// A `references:` sub-section (`incoming`/`outgoing`): one `chunk[0xN] name`
/// per referenced chunk, each in that chunk's identity color. No-op when empty.
fn writeRefList(writer: *std.Io.Writer, label: []const u8, sub_color: [3]u8, ids: []const ChunkId, outer_last: bool, symbols: Symbols, cc: [3]u8, use_color: bool) !void {
    if (ids.len == 0) return;
    // Sub-section header under the references gutter, then one row per chunk
    // under the sub-section's own gutter; each vertical run closes with `└`.
    try writeGuide(writer, cc, null, use_color);
    try writer.writeAll("  ");
    try writeTreeGuide(writer, sec_references_color, .vert, null, use_color);
    try writer.print("{s}:\n", .{label});
    for (ids, 0..) |id, i| {
        const sub_last = i == ids.len - 1;
        try writeGuide(writer, cc, null, use_color);
        try writer.writeAll("  ");
        try writeTreeGuide(writer, sec_references_color, if (outer_last and sub_last) .corner else .vert, null, use_color);
        try writeTreeGuide(writer, sub_color, if (sub_last) .corner else .vert, null, use_color);
        try writeStoreRefText(writer, "chunk", id, objColor(id), use_color);
        if (chunkNameOf(symbols, id)) |name| {
            if (use_color) try writer.print("\x1b[38;2;{d};{d};{d}m", .{ name_color[0], name_color[1], name_color[2] });
            try writer.print(" {s}", .{name});
            if (use_color) try writer.writeAll("\x1b[0m");
        }
        try writer.writeByte('\n');
    }
}

/// The best-effort name attributed to chunk `id`, resolved to text.
fn chunkNameOf(symbols: Symbols, id: ChunkId) ?[]const u8 {
    const reg = symbols.registry orelse return null;
    const name_id = reg.nameOf(id) orelse return null;
    return symbols.internName(name_id);
}

/// `chunk[0x{id}]` followed by its best-effort name when known, so a reference
/// reads `chunk[0x62] fetchGit` rather than a bare id.
fn writeChunkRef(writer: *std.Io.Writer, id: ChunkId, symbols: Symbols) !void {
    try writer.print("chunk[0x{x}]", .{id});
    if (chunkNameOf(symbols, id)) |name| try writer.print(" {s}", .{name});
}

fn writeOperands(
    writer: *std.Io.Writer,
    chunk: *const Chunk,
    op: OpCode,
    ip_in: usize,
    symbols: Symbols,
    up_names: ?[]const InternId,
    referenced_chunks: *std.AutoArrayHashMapUnmanaged(ChunkId, void),
) !usize {
    var ip = ip_in;
    const code = chunk.code;
    switch (op) {
        .push_const, .push_const_ret => {
            const idx = readU16(code, ip);
            ip += 2;
            try writer.print("#{d}", .{idx});
            if (idx < chunk.constants.len) {
                try writer.writeAll(" ; ");
                // Plain text: the inline path colors the whole comment dim.
                try writeValueDigest(writer, chunk.constants[idx], symbols, snippet_max, false);
            }
        },
        .push_null, .push_true, .push_false, .pop => {},

        .loc_get, .loc_set, .loc_grab, .cell_init, .loc_get_ret => {
            const slot = code[ip];
            ip += 1;
            try writer.print("#{d} ; local[{d}]", .{ slot, slot });
        },
        .loc_get_w, .loc_set_w, .loc_grab_w, .cell_set_w, .cell_init_w, .loc_get_ret_w => {
            const slot = readU16(code, ip);
            ip += 2;
            try writer.print("#{d} ; local[{d}]", .{ slot, slot });
        },
        .cell_set => {
            const slot = code[ip];
            ip += 1;
            try writer.print("#{d} ; local[{d}]", .{ slot, slot });
        },
        .up_grab, .up_get, .up_get_ret => {
            const slot = readU16(code, ip);
            ip += 2;
            try writer.print("#{d} ; upvalue[{d}]", .{ slot, slot });
            if (upvalueName(up_names, symbols, slot)) |nm| try writer.print(" {s}", .{nm});
        },

        .int_add, .int_sub, .int_mul, .int_div, .int_neg,
        .flt_add, .flt_sub, .flt_mul, .flt_div,
        .cmp_eq, .cmp_ne, .cmp_eq_null, .cmp_ne_null, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge, .bool_not,
        .fail, .push_builtins,
        .attrs_merge, .attrs_merge_strict, .list_cat,
        .attr_get_dyn,
        .call, .call_tail, .cell_new, .thk_shell, .ret, .halt => {},

        .call_n, .call_tail_n => {
            const n = code[ip];
            ip += 1;
            try writer.print("#{d} ; {d} args", .{ n, n });
        },

        .jump => {
            const off = readU32(code, ip);
            ip += 4;
            try writer.print("+{d} ; → {x:0>4}", .{ off, ip + off });
        },
        .jump_false => {
            const off = readU32(code, ip);
            ip += 4;
            try writer.print("+{d} ; → {x:0>4}", .{ off, ip + off });
        },

        .attrs_new, .attrs_new_srt => {
            const n = readU16(code, ip);
            ip += 2;
            try writer.print("#{d} ; {d} entries", .{ n, n });
        },
        .attrs_new_pos, .attrs_new_pos_srt => {
            const n = readU16(code, ip);
            ip += 2;
            const pos_count = readU16(code, ip);
            ip += 2;
            try writer.print("{d} entries, {d} positions", .{ n, pos_count });
            ip += @as(usize, pos_count) * 16;
        },
        .list_new => {
            const n = readU16(code, ip);
            ip += 2;
            try writer.print("#{d} ; {d} items", .{ n, n });
        },
        .str_cat => {
            const n = readU16(code, ip);
            ip += 2;
            try writer.print("#{d} ; {d} parts", .{ n, n });
        },

        .file_find => {
            const id: InternId = @intCast(readU16(code, ip));
            ip += 2;
            try writeInternRef(writer, id, symbols);
        },
        .file_find_w => {
            const id: InternId = readU32(code, ip);
            ip += 4;
            try writeInternRef(writer, id, symbols);
        },

        .clos => {
            // `.clos` carries no inline capture descriptors (captures come
            // off the stack); `.clos_cap`/`.thk*` do.
            const id: ChunkId = @intCast(readU16(code, ip));
            ip += 2;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} upvalues", .{upvalues});
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .thk, .thk_eag => {
            const id: ChunkId = @intCast(readU16(code, ip));
            ip += 2;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} captures", .{upvalues});
            ip += @as(usize, upvalues) * 3; // inline capture descriptors
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .thk_st, .thk_st_cell, .thk_eag_st, .thk_eag_st_cell => {
            const id: ChunkId = @intCast(readU16(code, ip));
            ip += 2;
            const upvalues = readU16(code, ip);
            ip += 2;
            const desc_len = @as(usize, upvalues) * 3;
            ip += desc_len;
            const slot = code[ip];
            ip += 1;
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} captures → local[{d}]", .{ upvalues, slot });
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .clos_w => {
            const id: ChunkId = readU32(code, ip);
            ip += 4;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} upvalues", .{upvalues});
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .thk_w, .thk_eag_w, .thk_arg => {
            const id: ChunkId = readU32(code, ip);
            ip += 4;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} captures", .{upvalues});
            ip += @as(usize, upvalues) * 3; // inline capture descriptors
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .clos_cap => {
            const id: ChunkId = @intCast(readU16(code, ip));
            ip += 2;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} captures", .{upvalues});
            ip += @as(usize, upvalues) * 3;
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .clos_cap_w => {
            const id: ChunkId = readU32(code, ip);
            ip += 4;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} captures", .{upvalues});
            ip += @as(usize, upvalues) * 3;
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .thk_defer => {
            // Operand: 4-byte deferred-table id, 2-byte env count, then
            // env_count capture descriptors. No chunk id (compiled lazily).
            const id: u32 = readU32(code, ip);
            ip += 4;
            const env_count = readU16(code, ip);
            ip += 2;
            try writer.print("deferred #{d}, {d} env", .{ id, env_count });
            ip += @as(usize, env_count) * 3;
        },

        .attr_get => {
            const id: InternId = @intCast(readU16(code, ip));
            ip += 2;
            try writeInternRef(writer, id, symbols);
        },
        .attr_get_w => {
            const id: InternId = readU32(code, ip);
            ip += 4;
            try writeInternRef(writer, id, symbols);
        },
        .up_get_attr => {
            const slot = readU16(code, ip);
            const id: InternId = @intCast(readU16(code, ip + 2));
            ip += 4;
            try writeSlotAttr(writer, "upvalue", slot, id, symbols);
            if (upvalueName(up_names, symbols, slot)) |nm| try writer.print(" ({s})", .{nm});
        },
        .loc_get_attr => {
            const slot = code[ip];
            const id: InternId = @intCast(readU16(code, ip + 1));
            ip += 3;
            try writeSlotAttr(writer, "local", slot, id, symbols);
        },
        .loc_get_attr_w => {
            const slot = readU16(code, ip);
            const id: InternId = @intCast(readU16(code, ip + 2));
            ip += 4;
            try writeSlotAttr(writer, "local", slot, id, symbols);
        },
        .attr_get_dyn_or => {
            try writer.writeAll("(dynamic, with default)");
        },
        .attr_get_path_or, .attr_get_path_dyn_or, .attr_has_path => {
            const segments = code[ip];
            ip += 1;
            ip += @as(usize, segments) * 2;
            try writeAttrPath(writer, code, ip - @as(usize, segments) * 2, segments, false, symbols);
        },
        .attr_get_path_or_w, .attr_get_path_dyn_or_w, .attr_has_path_w => {
            const segments = code[ip];
            ip += 1;
            ip += @as(usize, segments) * 4;
            try writeAttrPath(writer, code, ip - @as(usize, segments) * 4, segments, true, symbols);
        },
        .attr_get_path_mix_or, .attr_has_path_mix => {
            const segments = code[ip];
            ip += 1;
            const dynamic = code[ip];
            ip += 1;
            try writer.print("#{d} #{d} ; {d} segments ({d} dynamic)", .{ segments, dynamic, segments, dynamic });
            for (0..segments) |_| {
                const tag = code[ip];
                ip += 1;
                if (tag == 0) ip += 4;
            }
        },
        .attr_check => {
            const allow = code[ip];
            ip += 1;
            const expected = readU16(code, ip);
            ip += 2;
            try writer.print("#{d} ; {d} expected (allow_extra={s})", .{ expected, expected, if (allow != 0) "true" else "false" });
            ip += @as(usize, expected) * 2;
        },
        .attr_check_w => {
            const allow = code[ip];
            ip += 1;
            const expected = readU16(code, ip);
            ip += 2;
            try writer.print("#{d} ; {d} expected (allow_extra={s})", .{ expected, expected, if (allow != 0) "true" else "false" });
            ip += @as(usize, expected) * 4;
        },
        .with_lookup => {
            const id: InternId = @intCast(readU16(code, ip));
            ip += 2;
            const scopes = code[ip];
            ip += 1;
            try writeInternRef(writer, id, symbols);
            try writer.print(" ({d} scopes)", .{scopes});
        },
        .with_lookup_w => {
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
            try writer.print("0x{x}", .{id});
        }
    }
    try writer.writeByte('"');
}

/// A fused slot-plus-attribute operand (`loc_get_attr`/`up_get_attr`): the two
/// raw values (slot index, name id) as the value, with `role[slot]."name"` as
/// the dimmed interpretation.
fn writeSlotAttr(writer: *std.Io.Writer, role: []const u8, slot: u16, id: InternId, symbols: Symbols) !void {
    if (symbols.internName(id)) |name| {
        try writer.print("#{d} 0x{x} ; {s}[{d}].\"{s}\"", .{ slot, id, role, slot, name });
    } else {
        try writer.print("#{d} 0x{x} ; {s}[{d}]", .{ slot, id, role, slot });
    }
}

/// An interned-name operand: the raw id as the value, then the full lookup
/// chain — `str[0xN] → "text"` — as the interpretation, so the intern id is
/// explicit in the comment and matches the constant-pool rendering.
fn writeInternRef(writer: *std.Io.Writer, id: InternId, symbols: Symbols) !void {
    if (symbols.internName(id)) |name| {
        try writer.print("0x{x} ; str[0x{x}] → \"", .{ id, id });
        try writeEscapedSnippet(writer, name, snippet_max);
        try writer.writeByte('"');
    } else {
        try writer.print("0x{x} ; str[0x{x}]", .{ id, id });
    }
}

/// The chunk's file, from the first source-map entry that carries one. Used to
/// print a filename header before the chunk's bytes.
fn chunkPrimaryFile(chunk: *const Chunk, chunk_id: ?ChunkId, symbols: Symbols) ?InternId {
    for (chunk.source_map) |entry| {
        if (entry.span.file) |f| return f;
    }
    // Wrapper thunks (attrset bodies) have no per-op source map but do carry a
    // representative body span — use its file so they still get a header.
    if (chunk.body_span) |bs| if (bs.file) |f| return f;
    // Last resort: the file the chunk was compiled from (registry sidecar),
    // which covers chunks that carry no source span at all.
    if (chunk_id) |id| if (symbols.registry) |reg| if (reg.fileOf(id)) |f| return f;
    return null;
}

/// The narrowest source span covering `ip`, or null if none. Narrowest wins so
/// the annotation points at the tightest sub-expression, not an enclosing one.
fn bestSpan(chunk: *const Chunk, ip: usize) ?Chunk.SourceSpan {
    var best: ?Chunk.SourceMapEntry = null;
    for (chunk.source_map) |entry| {
        if (ip < entry.start or ip >= entry.end) continue;
        if (best == null or entry.end - entry.start <= best.?.end - best.?.start) {
            best = entry;
        }
    }
    return if (best) |e| e.span else null;
}

/// A standalone `; <filename>` comment line marking that subsequent instructions
/// come from this file (emitted only when the file changes).
fn writeFileLine(writer: *std.Io.Writer, file: InternId, symbols: Symbols, use_color: bool) !void {
    try setCommentFg(writer, use_color);
    try writer.writeAll("  ; ");
    if (symbols.internName(file)) |name| {
        try writer.writeAll(name);
    } else {
        try writer.print("file 0x{x}", .{file});
    }
    if (use_color) try writer.writeAll("\x1b[0m");
    try writer.writeByte('\n');
}

/// The right-hand `; line:col+len` position annotation — the position within the
/// current file (whose name is on its own hoisted line).
/// A `store[accessor]` reference written directly (outside the `Line` token
/// model): keyword in the store color, brackets comment-grey, accessor in `id_color`.
fn writeStoreRefText(writer: *std.Io.Writer, kw: []const u8, id: u64, id_color: [3]u8, use_color: bool) !void {
    if (use_color) try writer.print("\x1b[38;2;{d};{d};{d}m", .{ store_kw_color[0], store_kw_color[1], store_kw_color[2] });
    try writer.writeAll(kw);
    if (use_color) try writer.writeAll("\x1b[0m");
    try setCommentFg(writer, use_color);
    try writer.writeByte('[');
    if (use_color) try writer.print("\x1b[0;38;2;{d};{d};{d}m", .{ id_color[0], id_color[1], id_color[2] });
    try writer.print("0x{x}", .{id});
    if (use_color) try writer.writeAll("\x1b[0m");
    try setCommentFg(writer, use_color);
    try writer.writeByte(']');
    if (use_color) try writer.writeAll("\x1b[0m");
}

/// `type[accessor] → value` digest of a constant. Interned strings/paths render
/// the full lookup chain — `str[0xN] → "text"` — with the intern id in its
/// identity color (matching every other occurrence of that id) when `use_color`.
/// `max` caps string length.
fn writeValueDigest(writer: *std.Io.Writer, value: Value, symbols: Symbols, max: usize, use_color: bool) !void {
    switch (value.kind()) {
        .null => try writer.writeAll("null"),
        .bool_true => try writer.writeAll("true"),
        .bool_false => try writer.writeAll("false"),
        .int => try writer.print("int {d}", .{value.asInt()}),
        .float => try writer.print("float {d}", .{value.asFloat()}),
        .string => try writeStringRef(writer, "str", value.asInternId(), symbols, max, use_color),
        .path => try writeStringRef(writer, "path", value.asInternId(), symbols, max, use_color),
        .list => try writeStoreRefText(writer, "list", value.asObjectId(), heapColor(value.asObjectId()), use_color),
        .attrs => try writeStoreRefText(writer, "attrs", value.asObjectId(), heapColor(value.asObjectId()), use_color),
        .closure => try writeStoreRefText(writer, "closure", value.asObjectId(), heapColor(value.asObjectId()), use_color),
        .thunk => try writeStoreRefText(writer, "thunk", value.asObjectId(), heapColor(value.asObjectId()), use_color),
        .builtin => try writeStoreRefText(writer, "builtin", value.asBuiltinId(), heapColor(value.asBuiltinId()), use_color),
        .builtin_closure => try writeStoreRefText(writer, "builtin_closure", value.asObjectId(), heapColor(value.asObjectId()), use_color),
        .string_context => try writeStoreRefText(writer, "string_ctx", value.asObjectId(), heapColor(value.asObjectId()), use_color),
        .boxed_int => try writeStoreRefText(writer, "boxed_int", value.asObjectId(), heapColor(value.asObjectId()), use_color),
        .partial_app => try writeStoreRefText(writer, "partial_app", value.asObjectId(), heapColor(value.asObjectId()), use_color),
    }
}

fn writeStringRef(writer: *std.Io.Writer, kind: []const u8, id: InternId, symbols: Symbols, max: usize, use_color: bool) !void {
    try writeStoreRefText(writer, kind, id, internColor(id), use_color);
    if (symbols.internName(id)) |text| {
        try setCommentFg(writer, use_color);
        try writer.writeAll(" → \"");
        try writeEscapedSnippet(writer, text, max);
        try writer.writeByte('"');
        if (use_color) try writer.writeAll("\x1b[0m");
    }
}

/// Escape a string for display, truncating in the MIDDLE (`head…tail`) when
/// over `max_len` — a path or store key's ends are the informative parts, so
/// keeping both beats a trailing `...`.
fn writeEscapedSnippet(writer: *std.Io.Writer, text: []const u8, max_len: usize) !void {
    if (text.len <= max_len) {
        try escapeRun(writer, text);
        return;
    }
    const keep = if (max_len > 1) max_len - 1 else 1;
    const head = (keep + 1) / 2;
    const tail = keep - head;
    try escapeRun(writer, text[0..head]);
    try writer.writeAll("…");
    if (tail > 0) try escapeRun(writer, text[text.len - tail ..]);
}

fn escapeRun(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
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

    // loc_get 0; loc_get 1; int_add; jump +0; ret; halt
    try builder.writeOp(allocator, .loc_get);
    try builder.writeByte(allocator, 0);
    try builder.writeOp(allocator, .loc_get);
    try builder.writeByte(allocator, 1);
    try builder.writeOp(allocator, .int_add);
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

    try std.testing.expect(std.mem.indexOf(u8, text, "chunk[0x7]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "loc_get") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "int_add") != null);
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

    try builder.writeOp(allocator, .attr_get);
    try builder.writeU16(allocator, @intCast(name_id));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeChunk(&out.writer, null, &chunk, .{ .intern = &intern }, .{});
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "attr_get") != null);
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
