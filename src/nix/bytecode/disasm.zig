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
/// per disassembly; scanning is O(total bytecode). All allocations use the
/// caller's allocator (stored so `deinit` frees with the same one).
pub const RefGraph = struct {
    out: []std.ArrayListUnmanaged(ChunkId),
    inc: []std.ArrayListUnmanaged(ChunkId),
    allocator: std.mem.Allocator,

    pub fn build(allocator: std.mem.Allocator, registry: *const ChunkRegistry, symbols: Symbols) !RefGraph {
        const a = allocator;
        const n = registry.count();
        const out = try a.alloc(std.ArrayListUnmanaged(ChunkId), n);
        const inc = try a.alloc(std.ArrayListUnmanaged(ChunkId), n);
        for (out) |*l| l.* = .empty;
        for (inc) |*l| l.* = .empty;
        var scratch: std.Io.Writer.Allocating = .init(a);
        defer scratch.deinit();
        // One refs set reused across all chunks (cleared, capacity retained):
        // a fresh map per chunk is an alloc+free pair per chunk, pure overhead.
        var refs: std.AutoArrayHashMapUnmanaged(ChunkId, void) = .empty;
        defer refs.deinit(a);
        var id: ChunkId = 0;
        while (id < n) : (id += 1) {
            const chunk = registry.get(id) orelse continue;
            refs.clearRetainingCapacity();
            collectRefsInto(chunk, symbols, .{ .map = &refs, .allocator = a }, &scratch) catch continue;
            var it = refs.iterator();
            while (it.next()) |e| {
                const t = e.key_ptr.*;
                out[id].append(a, t) catch {};
                if (t < n) inc[t].append(a, id) catch {};
            }
        }
        for (out) |*l| std.mem.sort(ChunkId, l.items, {}, std.sort.asc(ChunkId));
        for (inc) |*l| std.mem.sort(ChunkId, l.items, {}, std.sort.asc(ChunkId));
        return .{ .out = out, .inc = inc, .allocator = a };
    }

    pub fn deinit(self: *RefGraph) void {
        const a = self.allocator;
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
fn collectRefsInto(chunk: *const Chunk, symbols: Symbols, sink: RefSink, scratch: *std.Io.Writer.Allocating) !void {
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
        ip = try writeOperands(&scratch.writer, chunk, op, ip, symbols, null, sink);
    }
}

/// Per-chunk capture-list census: the inline `[count][3×count descriptors]`
/// list that `thunk`/`closure_cap`/`thunk_defer`/… carry is often identical
/// across an attrset's values (they capture the same environment). Measures how
/// many of those bytes are exact duplicates *within one chunk* — i.e. what a
/// per-chunk capture-list interning table would reclaim.
pub const CaptureCensus = struct {
    total: usize = 0,
    duplicated: usize = 0,
    ops: usize = 0,
    dup_defer: usize = 0,
    dup_thunk: usize = 0,
    dup_closure: usize = 0,
    /// Lists with >= 2 captures: the ones where a fixed 6-byte side-table ref
    /// beats the `2 + 3*M` inline encoding (a dual inline/ref op would ref
    /// these and leave single-capture lists inline on the hot path).
    total_ge2: usize = 0,
    ops_ge2: usize = 0,
    dup_ge2: usize = 0,
};

pub fn captureCensus(allocator: std.mem.Allocator, chunk: *const Chunk, symbols: Symbols) !CaptureCensus {
    var scratch: std.Io.Writer.Allocating = .init(allocator);
    defer scratch.deinit();
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(allocator);

    var out: CaptureCensus = .{};
    var ip: usize = 0;
    while (ip < chunk.code.len) {
        const op_byte = chunk.code[ip];
        if (op_byte >= opcode_mod.count) {
            ip += 1;
            continue;
        }
        const op: OpCode = @enumFromInt(op_byte);
        ip += 1;
        // Byte offset of the INLINE capture list (past the op's chunk id).
        // `thunk_defer` is excluded — its captures are now interned in the side
        // table, so it carries no inline list to measure.
        const list_start: ?usize = switch (op) {
            .thunk, .thunk_eag, .closure_cap => ip + 2, // u16 id
            .thunk_w, .thunk_eag_w, .closure_cap_w, .thunk_arg => ip + 4, // u32 id
            else => null,
        };
        scratch.writer.end = 0;
        const next = try writeOperands(&scratch.writer, chunk, op, ip, symbols, null, null);
        if (list_start) |ls| {
            if (ls < next) {
                const region = chunk.code[ls..next];
                out.total += region.len;
                out.ops += 1;
                // region = [count:u16][descriptors:3*M]; M = (len - 2) / 3.
                const m: usize = if (region.len >= 2) (region.len - 2) / 3 else 0;
                const ge2 = m >= 2;
                if (ge2) {
                    out.total_ge2 += region.len;
                    out.ops_ge2 += 1;
                }
                const h = std.hash.Wyhash.hash(0, region);
                if ((try seen.getOrPut(allocator, h)).found_existing) {
                    out.duplicated += region.len;
                    if (ge2) out.dup_ge2 += region.len;
                    switch (op) {
                        .thunk_defer => out.dup_defer += region.len,
                        .closure_cap, .closure_cap_w => out.dup_closure += region.len,
                        else => out.dup_thunk += region.len,
                    }
                }
            }
        }
        ip = next;
    }
    return out;
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
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    chunk_id: ?ChunkId,
    chunk: *const Chunk,
    symbols: Symbols,
    options: Options,
) !void {
    var visited: Visited = .empty;
    defer visited.deinit(allocator);
    try writeChunkAt(allocator, writer, chunk_id, chunk, symbols, options, 0, &visited);
}

/// Collect the chunk ids this chunk references (closure/thunk/apply
/// operands), in first-appearance order, deduplicated. Thin adapter over
/// `collectRefsInto` (the operand decoder run with a throwaway buffer) so
/// the decode logic exists once. Used by the repl's disasm browser to build
/// the reference graph.
pub fn collectRefs(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    out: *std.ArrayListUnmanaged(ChunkId),
) !void {
    var referenced: std.AutoArrayHashMapUnmanaged(ChunkId, void) = .empty;
    defer referenced.deinit(allocator);
    var scratch: std.Io.Writer.Allocating = .init(allocator);
    defer scratch.deinit();
    try collectRefsInto(chunk, .{}, .{ .map = &referenced, .allocator = allocator }, &scratch);
    try out.ensureUnusedCapacity(allocator, referenced.count());
    for (referenced.keys()) |id| out.appendAssumeCapacity(id);
}

fn writeChunkAt(
    allocator: std.mem.Allocator,
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
    // The visited set only matters when recursing (`dumpAll`'s registry walk
    // passes recurse=false and visits each chunk exactly once) — skip the
    // per-call hashmap allocation entirely otherwise.
    if (options.recurse) if (chunk_id) |id| try visited.put(allocator, id, {});
    // Each chunk is a top-level group: a colored header and a left-margin guide
    // (in the chunk's own color) down every line of its body.
    const cc: [3]u8 = if (chunk_id) |id| hueColor(id) else .{ 0x9a, 0x9a, 0x9a };
    // The chunk's recorded upvalue names (slot order), used by the header table
    // and by upvalue-slot comments throughout the body.
    const up_names: ?[]const InternId = blk: {
        const id = chunk_id orelse break :blk null;
        const reg = symbols.registry orelse break :blk null;
        break :blk reg.upvalueNamesOf(id);
    };
    // The chunk's recorded local names (slot order), used to annotate
    // `local[N]` operand comments with the source binding name.
    const local_names: ?[]const InternId = blk: {
        const id = chunk_id orelse break :blk null;
        const reg = symbols.registry orelse break :blk null;
        break :blk reg.localNamesOf(id);
    };
    // The strict/deep flags fold into the upvalues table when it renders;
    // otherwise the header prints its fallback flag lines.
    try writeChunkHeader(writer, chunk_id, chunk, symbols, cc, up_names != null, options.use_color);

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

    // Attr-name / attr-position side tables: the names and source positions the
    // `attrs_new_named*` ops pull out of the code stream. Each op carries only a
    // `names[start..]` / `positions[start..]` reference into these tables — the
    // resolved contents live here, once, like the constant pool. Gated with the
    // constants flag: they are compile-time data of the same family.
    if (options.show_constants and chunk.attr_names.len > 0) {
        try writeGuide(writer, cc, null, options.use_color);
        try writer.writeAll("  attr names:\n");
        for (chunk.attr_names, 0..) |nm, i| {
            try writeTableRowHead(writer, cc, sec_attr_names_color, i, i == chunk.attr_names.len - 1, attrNameColor(i), options.use_color);
            try writeStringRef(writer, "str", nm, symbols, table_snippet_max, options.use_color);
            try writer.writeByte('\n');
        }
    }
    if (options.show_constants and chunk.attr_pos.len > 0) {
        try writeGuide(writer, cc, null, options.use_color);
        try writer.writeAll("  attr positions:\n");
        for (chunk.attr_pos, 0..) |rec, i| {
            try writeTableRowHead(writer, cc, sec_attr_pos_color, i, i == chunk.attr_pos.len - 1, attrPosColor(i), options.use_color);
            try writeAttrPosRow(writer, rec, symbols, options.use_color);
            try writer.writeByte('\n');
        }
    }

    // Upvalue table: the best-effort binding name behind each upvalue slot
    // (mirrored by the `upvalue[N] name` comments in the body), with the
    // chunk's strictness flags folded in per slot. `#N` takes the slot's
    // identity color — the same hue every `up_get #N` operand carries.
    if (up_names) |ups| {
        const strict = chunk.scheduling.strictness.forced_upvalues;
        const deep = chunk.scheduling.strictness.deep_upvalues & ~strict;
        try writeGuide(writer, cc, null, options.use_color);
        try writer.writeAll("  upvalues:\n");
        for (ups, 0..) |name_id, i| {
            try writeGuide(writer, cc, null, options.use_color);
            try writer.writeAll("  ");
            try writeTreeGuide(writer, sec_upvalues_color, if (i == ups.len - 1) .corner else .vert, null, options.use_color);
            var ibuf: [8]u8 = undefined;
            const istr = std.fmt.bufPrint(&ibuf, "#{d}", .{i}) catch "#?";
            if (options.use_color) {
                const uc = upvColor(i);
                try writer.print("\x1b[38;2;{d};{d};{d}m{s}\x1b[0m", .{ uc[0], uc[1], uc[2], istr });
            } else {
                try writer.writeAll(istr);
            }
            try writer.splatByteAll(' ', 6 -| istr.len);
            if (symbols.internName(name_id)) |raw| {
                // Strip the leading NUL off compiler-internal names.
                const name = if (raw.len > 0 and raw[0] == 0) raw[1..] else raw;
                if (options.use_color) try writer.print("\x1b[38;2;{d};{d};{d}m", .{ name_color[0], name_color[1], name_color[2] });
                try writer.writeAll(name);
                if (options.use_color) try writer.writeAll("\x1b[0m");
            } else {
                try writer.print("0x{x}", .{name_id});
            }
            const is_strict = i < 64 and (strict >> @intCast(i)) & 1 == 1;
            const is_deep = i < 64 and (deep >> @intCast(i)) & 1 == 1;
            if (is_strict or is_deep) {
                try setCommentFg(writer, options.use_color);
                try writer.print(" ; {s}", .{if (is_strict) "strict" else "deep"});
                if (options.use_color) try writer.writeAll("\x1b[0m");
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
    defer referenced_chunks.deinit(allocator);
    const ref_sink: RefSink = .{ .map = &referenced_chunks, .allocator = allocator };

    // Scratch for each instruction's compact operand decode. Growable (reset,
    // capacity retained, per instruction) rather than a fixed buffer: a decode
    // is normally a few dozen bytes, but a pathological attribute name or path
    // (`x."<multi-KB string>"`) is unbounded, and overflowing a fixed buffer
    // would abort the whole disassembly with a write error.
    var op_scratch: std.Io.Writer.Allocating = .init(allocator);
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
        ip = try writeOperands(&op_scratch.writer, chunk, op, ip, symbols, up_names, ref_sink);
        const operand_text = op_scratch.writer.buffered();

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

        // Every instruction renders through the same head/tail token model:
        // the mnemonic row carries the head operand (raw accessors, byte-linked,
        // with a colored token comment); multiline ops add indented child rows.
        const bg = takeBg(&stripe, options.use_color);
        try beginRow(writer, bg, options.use_color);
        try writeGuide(writer, cc, bg, options.use_color);
        try writeOffset(writer, start, bg, options.use_color);
        try writer.writeAll("  ");
        var seq: usize = @intFromEnum(op) + 1;
        var head: Line = undefined;
        head.reset();
        const head_len = buildHead(&head, op, chunk, start, symbols, up_names, local_names, operand_text, ip, &seq);
        try emitMnemonicHead(writer, chunk.code, start, op, &head, head_len, &seq, bg, env);
        if (isMultiline(op)) {
            try writeOperandTail(writer, chunk, op, start + 1 + head_len, ip, operand_text, &seq, symbols, up_names, local_names, &stripe, env);
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
            try writeChunkAt(allocator, writer, child_id, child, symbols, options, depth + 1, visited);
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

/// Identity color for an upvalue slot (chunk-local): the upvalues table row,
/// every `up_get #N` operand, and capture-descriptor indexes referencing the
/// slot all share it — like constants' `#N`.
fn upvColor(slot: anytype) [3]u8 {
    return hueColor(@as(usize, @intCast(slot)) + 1500);
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
const sec_attr_names_color: [3]u8 = .{ 0x8a, 0xb8, 0x5c };
const sec_attr_pos_color: [3]u8 = .{ 0xb8, 0x8a, 0x5c };

/// Identity color for an `attr_names` side-table row: the same hue on the row
/// `#i` and on the `names[i..]` reference that points at it, so a reference ties
/// back to its section row (like a constant's `#N`). Own seed range.
fn attrNameColor(i: anytype) [3]u8 {
    return hueColor(@as(usize, @intCast(i)) + 13000);
}

/// Identity color for an `attr_pos` side-table row — like `attrNameColor`, its
/// own seed so a `positions[i..]` reference links to its row.
fn attrPosColor(i: anytype) [3]u8 {
    return hueColor(@as(usize, @intCast(i)) + 17000);
}

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

    /// Reset without touching `toks`/`buf`: the `Line{}` literal lowers to a
    /// ~2KB memset of the undefined arrays, which at one Line per rendered row
    /// (millions per `--eval` dump) dominates the render loop. Declare the Line
    /// `undefined` and reset the three live scalars instead.
    inline fn reset(self: *Line) void {
        self.n = 0;
        self.used = 0;
        self.comment_tok = null;
    }

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
    /// groups differ sharply regardless of their byte values. The HSV math is
    /// skipped when not coloring (nothing reads the colors then), but `seq`
    /// still advances so hue assignment is identical either way.
    fn paint(self: *Line, seq: *usize, use_color: bool) void {
        for (self.toks[0..self.n]) |*t| {
            if (t.colored and t.len > 0 and !t.pin) {
                if (use_color) t.color = hueColor(seq.*);
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
    line.paint(seq, env.use_color);
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
        .closure_w, .closure_cap_w, .thunk_w, .thunk_eag_w, .thunk_arg, .thunk_w_st, .thunk_w_st_cell, .thunk_eag_w_st, .thunk_eag_w_st_cell => true,
        else => false,
    };
}

/// The builtin's Nix-visible name for a raw builtin id, if the id is valid.
fn builtinName(id: u64) ?[]const u8 {
    const BuiltinId = @import("runtime").builtins.BuiltinId;
    inline for (@typeInfo(BuiltinId).@"enum".fields) |f| {
        if (f.value == id) return f.name;
    }
    return null;
}

/// Escape `text` (middle-truncated at `max`) into `buf`, returning the slice.
fn escSnippet(buf: []u8, text: []const u8, max: usize) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeEscapedSnippet(&w, text, max) catch {};
    return w.buffered();
}

/// Token form of `writeStringRef`: `str[0xN] → "text"`, the id and the
/// resolved text in the intern id's identity color.
fn lineStringRef(l: *Line, kind: []const u8, id: InternId, symbols: Symbols, max: usize) void {
    const c = internColor(id);
    l.storeRef(kind, c, "0x{x}", .{id});
    if (symbols.internName(id)) |text| {
        var buf: [128]u8 = undefined;
        l.glue(" → ", .{});
        l.tint(c, "\"{s}\"", .{escSnippet(&buf, text, max)});
    }
}

/// Token form of `writeValueDigest`: `type[accessor] → value` with identity
/// colors, for mnemonic-line comments.
fn lineValueDigest(l: *Line, value: Value, symbols: Symbols, max: usize) void {
    switch (value.kind()) {
        .null => l.glue("null", .{}),
        .bool_true => l.glue("true", .{}),
        .bool_false => l.glue("false", .{}),
        .int => l.glue("int {d}", .{value.asInt()}),
        .float => l.glue("float {d}", .{value.asFloat()}),
        .string => lineStringRef(l, "str", value.asInternId(), symbols, max),
        .path => lineStringRef(l, "path", value.asInternId(), symbols, max),
        .list => l.storeRef("list", heapColor(value.asObjectId()), "0x{x}", .{value.asObjectId()}),
        .attrs => l.storeRef("attrs", heapColor(value.asObjectId()), "0x{x}", .{value.asObjectId()}),
        .closure => l.storeRef("closure", heapColor(value.asObjectId()), "0x{x}", .{value.asObjectId()}),
        .thunk => l.storeRef("thunk", heapColor(value.asObjectId()), "0x{x}", .{value.asObjectId()}),
        .builtin => {
            const bid = value.asBuiltinId();
            l.storeRef("builtin", heapColor(bid), "0x{x}", .{bid});
            if (builtinName(bid)) |nm| {
                l.glue(" → ", .{});
                l.tint(heapColor(bid), "{s}", .{nm});
            }
        },
        .builtin_closure => l.storeRef("builtin_closure", heapColor(value.asObjectId()), "0x{x}", .{value.asObjectId()}),
        .string_context => l.storeRef("string_ctx", heapColor(value.asObjectId()), "0x{x}", .{value.asObjectId()}),
        .boxed_int => l.storeRef("boxed_int", heapColor(value.asObjectId()), "0x{x}", .{value.asObjectId()}),
        .partial_app => l.storeRef("partial_app", heapColor(value.asObjectId()), "0x{x}", .{value.asObjectId()}),
    }
}

/// Build the *head* operand — the accessor(s) the mnemonic line carries — as a
/// `Line` whose byte offsets are relative to the opcode byte (byte 0). For
/// multiline ops this is the leading scalar (chunk id / counts) and the list
/// tail follows on child rows; for single-line ops it is the WHOLE operand,
/// with the interpretation as a colored token comment. Ops without a bespoke
/// arm fall back to the compact `operand_text` decode. Returns the number of
/// operand bytes the head covers.
/// Mnemonic-row head. Three ops keep a bespoke arm (their head/body split or
/// format isn't a plain scalar sequence); everything else is rendered from the
/// operand-layout table by `buildHeadGeneric`.
fn buildHead(l: *Line, op: OpCode, chunk: *const Chunk, start: usize, symbols: Symbols, up_names: ?[]const InternId, local_names: ?[]const InternId, operand_text: []const u8, end_ip: usize, seq: *usize) u16 {
    const code = chunk.code;
    switch (op) {
        .thunk_defer => {
            // deferred id (4) + capture-list start (4) + env count (2). Captures
            // are interned in the chunk side table, not inline — single line.
            const id = readU32(code, start + 1);
            const cap_start = readU32(code, start + 5);
            const cap_count = readU16(code, start + 9);
            l.group(1, 10, "#{d}", .{id});
            l.comment();
            l.glue("deferred #{d}, {d} env @cap[{d}]", .{ id, cap_count, cap_start });
            return 10;
        },
        .attrs_new_named_srt, .attrs_new_named_pos_srt => {
            const entries = readU16(code, start + 1);
            const c_e = hueColor(seq.*);
            seq.* += 1;
            l.groupPinned(1, 2, c_e, "#{d}", .{entries});
            l.comment();
            l.tint(c_e, "{d}", .{entries});
            l.glue(" entries (named)", .{});
            return 2;
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
        .attr_get_path_or, .attr_get_path_dyn_or, .attr_has_path => return buildAttrPathHead(l, code, start, false, symbols, seq),
        .attr_get_path_or_w, .attr_get_path_dyn_or_w, .attr_has_path_w => return buildAttrPathHead(l, code, start, true, symbols, seq),
        .attr_get_path_mix_or, .attr_has_path_mix => return buildMixPathHead(l, code, start, symbols, seq),
        else => return buildHeadGeneric(l, op, chunk, start, symbols, up_names, local_names, operand_text, end_ip, seq),
    }
}

/// A path segment's name group in the `; "a.b.c"` comment: `escSnippet` copies
/// the source name into the line buffer, so its stack scratch need not outlive
/// this call. `off` is the byte offset (from the opcode) of the segment's id
/// run and `len` its width — pinning the name's color to those exact bytes so
/// the id run in the hex column reads as the same color as the name it decodes.
fn appendPathSegment(l: *Line, id: InternId, off: u16, len: u16, symbols: Symbols) void {
    const c = internColor(id);
    if (symbols.internName(id)) |name| {
        var buf: [128]u8 = undefined;
        l.groupPinned(off, len, c, "{s}", .{escSnippet(&buf, name, snippet_max)});
    } else {
        l.groupPinned(off, len, c, "0x{x}", .{id});
    }
}

/// Single-line head for a static attribute path (`attr_get_path_or` &c.): the
/// leading segment-count byte in its own hue, then the dotted path as the
/// comment with EACH segment byte-linked to — and tinted to — its own id run,
/// so every id run in the hex column maps by color to the name it resolves to
/// (rather than the whole operand reading as one count-colored block).
fn buildAttrPathHead(l: *Line, code: []const u8, start: usize, wide: bool, symbols: Symbols, seq: *usize) u16 {
    const w: u16 = if (wide) 4 else 2;
    const segments = code[start + 1];
    const c_cnt = hueColor(seq.*);
    seq.* += 1;
    l.groupPinned(1, 1, c_cnt, "#{d}", .{segments});
    l.comment();
    l.glue("\"", .{});
    var off: u16 = 2; // first segment id, as a byte offset from the opcode
    var i: u8 = 0;
    while (i < segments) : (i += 1) {
        if (i > 0) l.glue(".", .{});
        const id: InternId = @intCast(readWidth(if (wide) .b4 else .b2, code, start + off));
        appendPathSegment(l, id, off, w, symbols);
        off += w;
    }
    l.glue("\"", .{});
    return off - 1; // count byte + segments * w
}

/// Single-line head for a mixed static/dynamic attribute path
/// (`attr_get_path_mix_or` / `attr_has_path_mix`): segment count and dynamic
/// count each get a hue, then the path renders in the comment with static
/// segments byte-linked to their name and dynamic segments shown as `${…}`
/// (their key comes from the stack), each tinted to its own byte run.
fn buildMixPathHead(l: *Line, code: []const u8, start: usize, symbols: Symbols, seq: *usize) u16 {
    const segments = code[start + 1];
    const dyn = code[start + 2];
    const c_cnt = hueColor(seq.*);
    seq.* += 1;
    const c_dyn = hueColor(seq.*);
    seq.* += 1;
    l.groupPinned(1, 1, c_cnt, "#{d}", .{segments});
    l.glue(" ", .{});
    l.groupPinned(2, 1, c_dyn, "#{d}", .{dyn});
    l.comment();
    l.glue("\"", .{});
    var off: u16 = 3; // first segment tag, as a byte offset from the opcode
    var i: u8 = 0;
    while (i < segments) : (i += 1) {
        if (i > 0) l.glue(".", .{});
        if (code[start + off] == 0) { // static: tag byte + 4-byte id
            const id: InternId = @intCast(readU32(code, start + off + 1));
            appendPathSegment(l, id, off, 5, symbols); // whole tag+id run
            off += 5;
        } else { // dynamic: tag byte only, key popped from the stack
            const c = hueColor(seq.*);
            seq.* += 1;
            l.groupPinned(off, 1, c, "${{…}}", .{});
            off += 1;
        }
    }
    l.glue("\"", .{});
    return off - 1;
}

/// Whether a field's contents are drawn as multiline child rows (by
/// `writeOperandTail`) rather than on the mnemonic row.
fn fieldIsList(f: Operand) bool {
    return switch (f) {
        .captures, .captures_slot, .attr_path, .check, .mix => true,
        else => false,
    };
}

/// Table-driven head: render an op's leading SCALAR operand fields as byte-
/// pinned colored groups plus their grey interpretation — the flag-rendering of
/// what used to be ~11 near-identical per-op arms. Multiline ops keep only their
/// leading scalar here (chunk id); the list body is drawn by `writeOperandTail`.
/// Ops whose head is a list (attr paths, mix) or empty fall back to the compact
/// decode.
fn buildHeadGeneric(l: *Line, op: OpCode, chunk: *const Chunk, start: usize, symbols: Symbols, up_names: ?[]const InternId, local_names: ?[]const InternId, operand_text: []const u8, end_ip: usize, seq: *usize) u16 {
    const code = chunk.code;
    const fields = opcode_mod.layout(op);
    const n_head: usize = if (isMultiline(op)) 1 else fields.len;
    if (n_head == 0 or fieldIsList(fields[0])) return buildHeadCompact(l, operand_text, start, end_ip);

    // Colors are computed in pass 1 and reused in pass 2 — a seq-based hue must
    // not advance twice for one field.
    var colors: [4][3]u8 = undefined;
    var byte: u16 = 0;
    var i: usize = 0;
    while (i < n_head) : (i += 1) {
        const f = fields[i];
        const off = start + 1 + byte;
        const flen: u16 = @intCast(opcode_mod.fieldLen(f, code, off));
        colors[i] = headColor(f, code, off, seq);
        if (i > 0) l.glue(" ", .{});
        headRaw(l, f, code, off, 1 + byte, flen, colors[i]);
        byte += flen;
    }
    l.comment();
    byte = 0;
    i = 0;
    while (i < n_head) : (i += 1) {
        if (i > 0) l.glue(", ", .{});
        headInterp(l, fields[i], chunk, code, start + 1 + byte, colors[i], symbols, up_names, local_names);
        byte += @intCast(opcode_mod.fieldLen(fields[i], code, start + 1 + byte));
    }
    return byte;
}

/// Fallback head for ops with no bespoke breakdown: the compact `writeOperands`
/// text, split into a byte-linked raw group and a grey ` ; ` interpretation.
fn buildHeadCompact(l: *Line, operand_text: []const u8, start: usize, end_ip: usize) u16 {
    const oplen: u16 = @intCast(end_ip - (start + 1));
    const cut = std.mem.indexOf(u8, operand_text, " ; ") orelse operand_text.len;
    if (oplen > 0 and cut > 0) l.group(1, oplen, "{s}", .{operand_text[0..cut]});
    if (cut < operand_text.len) {
        l.comment();
        l.glue("{s}", .{operand_text[cut + 3 ..]});
    } else if (oplen == 0 and operand_text.len > 0) {
        l.comment();
        l.glue("{s}", .{operand_text});
    }
    return oplen;
}

/// The identity color for a head field's byte group: value-derived for the
/// ref-like fields (chunk/intern/const/upvalue), a fresh sequential hue for the
/// positional ones (local slot / count / jump).
fn headColor(f: Operand, code: []const u8, off: usize, seq: *usize) [3]u8 {
    switch (f) {
        .const_idx => return constColor(readU16(code, off)),
        .slot => |s| if (s.role == .upvalue) return upvColor(readWidth(s.w, code, off)),
        .chunk_id, .intern => |w| return objInternColor(f, readWidth(w, code, off)),
        else => {},
    }
    const c = hueColor(seq.*);
    seq.* += 1;
    return c;
}

fn objInternColor(f: Operand, id: u32) [3]u8 {
    return switch (f) {
        .chunk_id => objColor(id),
        else => internColor(id),
    };
}

fn headRaw(l: *Line, f: Operand, code: []const u8, off: usize, col_byte: u16, flen: u16, color: [3]u8) void {
    switch (f) {
        .chunk_id, .intern => |w| l.groupPinned(col_byte, flen, color, "0x{x}", .{readWidth(w, code, off)}),
        .jump => l.groupPinned(col_byte, flen, color, "+{d}", .{readU32(code, off)}),
        .cap1 => l.groupPinned(col_byte, flen, color, "#{d}", .{readU16(code, off + 1)}),
        .const_idx => l.groupPinned(col_byte, flen, color, "#{d}", .{readU16(code, off)}),
        .slot => |s| l.groupPinned(col_byte, flen, color, "#{d}", .{readWidth(s.w, code, off)}),
        .count => |c| l.groupPinned(col_byte, flen, color, "#{d}", .{readWidth(c.w, code, off)}),
        .raw => |w| l.groupPinned(col_byte, flen, color, "#{d}", .{readWidth(w, code, off)}),
        else => {},
    }
}

fn headInterp(l: *Line, f: Operand, chunk: *const Chunk, code: []const u8, off: usize, color: [3]u8, symbols: Symbols, up_names: ?[]const InternId, local_names: ?[]const InternId) void {
    switch (f) {
        .const_idx => {
            const idx = readU16(code, off);
            if (idx < chunk.constants.len) lineValueDigest(l, chunk.constants[idx], symbols, snippet_max);
        },
        .slot => |s| {
            const v = readWidth(s.w, code, off);
            const role = if (s.role == .upvalue) "upvalue" else "local";
            l.glue("{s}[", .{role});
            l.tint(color, "{d}", .{v});
            l.glue("]", .{});
            const nm = if (s.role == .upvalue) upvalueName(up_names, symbols, v) else localName(local_names, symbols, v);
            if (nm) |name| l.tint(name_color, " {s}", .{name});
        },
        .cap1 => {
            const kind = code[off];
            const idx = readU16(code, off + 1);
            l.glue("{s}[", .{if (kind == 0) "local" else "upvalue"});
            l.tint(color, "{d}", .{idx});
            l.glue("]", .{});
        },
        .chunk_id => |w| {
            const id: ChunkId = readWidth(w, code, off);
            l.storeRef("chunk", color, "0x{x}", .{id});
            if (chunkNameOf(symbols, id)) |nm| l.tint(name_color, " {s}", .{nm});
        },
        .intern => |w| {
            const id: InternId = readWidth(w, code, off);
            lineStringRef(l, "str", id, symbols, snippet_max);
        },
        .count => |c| {
            l.tint(color, "{d}", .{readWidth(c.w, code, off)});
            l.glue(" {s}", .{c.noun});
        },
        .jump => {
            const target = off + 4 + readU32(code, off);
            l.glue("→ ", .{});
            l.tint(color, "{x:0>4}", .{target});
        },
        else => {},
    }
}

/// Render a multiline op's mnemonic row: byte column (opcode + head bytes,
/// colored to match) then the mnemonic and the inline head operand. `head` is
/// from `buildHead`; `head_len` its operand byte count.
fn emitMnemonicHead(writer: *std.Io.Writer, code: []const u8, start: usize, op: OpCode, head: *Line, head_len: u16, seq: *usize, bg: ?[3]u8, env: Env) !void {
    head.paint(seq, env.use_color);
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
    // Heads longer than the byte column (attr paths etc.) wrap their remaining
    // bytes onto continuation rows — same stripe unit as the instruction.
    if (env.show_bytes and head_len + 1 > bytes_per_line) {
        var o: usize = bytes_per_line;
        while (o < head_len + 1) : (o += bytes_per_line) {
            try beginRow(writer, bg, env.use_color);
            try writeGuide(writer, env.cc, bg, env.use_color);
            try writer.writeAll("        ");
            var c: usize = o;
            var cnt: u16 = 0;
            while (c < o + bytes_per_line and c < head_len + 1) : (c += 1) {
                try writeByteCellColored(writer, code[start + c], head.colorAt(@intCast(c)), bg, env.use_color);
                cnt += 1;
            }
            try endRow(writer, bg, 10 + 3 * cnt, env);
        }
    }
}

/// A `#{count} ; {label}` line (count is a u16 at `off`). Fits one row — never
/// wraps — so its guides never blank on a continuation.
fn emitCountLine(writer: *std.Io.Writer, code: []const u8, off: *usize, label: []const u8, seq: *usize, guides: []const [3]u8, last_mask: u8, stripe: *usize, env: Env) !void {
    var l: Line = undefined;
    l.reset();
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
        var l: Line = undefined;
        l.reset();
        l.group(0, 1, "{s}", .{if (is_upvalue) "upvalue" else "local"});
        l.glue("[", .{});
        // An upvalue index reads the enclosing chunk's slot — give it that
        // slot's identity color (matching the upvalues table and up_get ops).
        if (is_upvalue) l.groupPinned(1, 2, upvColor(idx), "{d}", .{idx}) else l.group(1, 2, "{d}", .{idx});
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
/// Compiler-internal names carry a leading NUL (e.g. the attrset-pattern
/// argument holder `\x00args`) — strip it so no NUL reaches the output.
fn upvalueName(up_names: ?[]const InternId, symbols: Symbols, idx: usize) ?[]const u8 {
    const list = up_names orelse return null;
    if (idx >= list.len) return null;
    const name = symbols.internName(list[idx]) orelse return null;
    return if (name.len > 0 and name[0] == 0) name[1..] else name;
}

/// The source name of local `slot` (from the chunk's `local_names` sidecar),
/// or null. Internal (`\x00`-prefixed) names are hidden.
fn localName(local_names: ?[]const InternId, symbols: Symbols, slot: usize) ?[]const u8 {
    const list = local_names orelse return null;
    if (slot >= list.len) return null;
    const name = symbols.internName(list[slot]) orelse return null;
    if (name.len == 0 or name[0] == 0) return null;
    return name;
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
    local_names: ?[]const InternId,
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
        .closure, .closure_w => {
            // The chunk id rode the mnemonic line; only the upvalue count
            // remains — the block's only (and thus last) row.
            try emitCountLine(writer, code, &off, "upvalues (from stack)", seq, g[0..1], 0b01, stripe, env);
        },
        .thunk, .thunk_eag, .thunk_w, .thunk_eag_w, .thunk_arg, .closure_cap, .closure_cap_w => {
            const n = readU16(code, off);
            g[1] = hueColor(seq.*); // the "captures" count line's color
            try emitCountLine(writer, code, &off, "captures", seq, g[0..1], if (n == 0) 0b01 else 0, stripe, env);
            // The last descriptor closes both the list (level 1) and the block.
            try emitCaptureDescriptors(writer, code, &off, n, seq, g[0..2], 0b11, up_names, symbols, stripe, env);
        },
        .thunk_st, .thunk_st_cell, .thunk_eag_st, .thunk_eag_st_cell, .thunk_w_st, .thunk_w_st_cell, .thunk_eag_w_st, .thunk_eag_w_st_cell => {
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
            var l: Line = undefined;
            l.reset();
            l.groupPinned(0, 1, c_slot, "#{d}", .{code[off]});
            l.comment();
            l.glue("→ local[", .{});
            l.tint(c_slot, "{d}", .{code[off]});
            l.glue("]", .{});
            if (localName(local_names, symbols, code[off])) |nm| l.tint(name_color, " {s}", .{nm});
            try emitLine(writer, code, &off, &l, seq, g[0..1], 0b01, takeBg(stripe, env.use_color), env);
        },
        .attrs_new_named_srt, .attrs_new_named_pos_srt => {
            // Head took the count; remaining operands are the names start
            // (u32) and, for the pos variant, pos_count:u16 + pos_start:u32.
            const count = readU16(code, off - 2);
            const names_start = readU32(code, off);
            const has_pos = op == .attrs_new_named_pos_srt;
            // The resolved names/positions live in the chunk `attr names:` /
            // `attr positions:` sections; the op carries only the reference into
            // them. Tint the reference to its start row's identity color so it
            // links back to the section (like a constant's `#N`).
            {
                const c = attrNameColor(names_start);
                var l: Line = undefined;
                l.reset();
                l.groupPinned(0, 4, c, "#{d}", .{names_start});
                l.comment();
                l.glue("names[", .{});
                l.tint(c, "{d}..{d}", .{ names_start, names_start + count });
                l.glue("]", .{});
                try emitLine(writer, code, &off, &l, seq, g[0..1], if (has_pos) 0 else 0b01, takeBg(stripe, env.use_color), env);
            }
            if (has_pos) {
                const pos_count = readU16(code, off);
                const pos_start = readU32(code, off + 2);
                const c = attrPosColor(pos_start);
                var l: Line = undefined;
                l.reset();
                l.group(0, 2, "#{d}", .{pos_count});
                l.glue(" ", .{});
                l.groupPinned(2, 4, c, "#{d}", .{pos_start});
                l.comment();
                l.glue("positions[", .{});
                l.tint(c, "{d}..{d}", .{ pos_start, pos_start + pos_count });
                l.glue("]", .{});
                try emitLine(writer, code, &off, &l, seq, g[0..1], 0b01, takeBg(stripe, env.use_color), env);
            }
        },
        .thunk_defer => {
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
                var l: Line = undefined;
                l.reset();
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
                var l: Line = undefined;
                l.reset();
                l.group(0, @intCast(end_ip - off), "{s}", .{operand_text});
                try emitLine(writer, code, &off, &l, seq, g[0..1], 0b01, takeBg(stripe, env.use_color), env);
            }
        },
    }
    // Guard: dump any bytes a bespoke arm under-counted as a trailing field.
    if (off < end_ip) {
        var l: Line = undefined;
        l.reset();
        l.group(0, @intCast(end_ip - off), "{s}", .{"…"});
        try emitLine(writer, code, &off, &l, seq, g[0..1], 0b01, takeBg(stripe, env.use_color), env);
    }
}

/// Instructions with a list of sub-fields (captures / positions) are drawn
/// across multiple indented rows; everything else fits on one line.
fn isMultiline(op: OpCode) bool {
    return switch (op) {
        .closure,
        .closure_w,
        .thunk,
        .thunk_eag,
        .thunk_w,
        .thunk_eag_w,
        .thunk_arg,
        .closure_cap,
        .closure_cap_w,
        .thunk_st,
        .thunk_st_cell,
        .thunk_eag_st,
        .thunk_eag_st_cell,
        .thunk_w_st,
        .thunk_w_st_cell,
        .thunk_eag_w_st,
        .thunk_eag_w_st_cell,
        .attrs_new_named_srt,
        .attrs_new_named_pos_srt,
        // .thunk_defer is now single-line: its captures are interned in the
        // chunk side table, no inline descriptor child rows.
        .attr_check,
        .attr_check_w,
        => true,
        else => false,
    };
}

fn writeChunkHeader(writer: *std.Io.Writer, chunk_id: ?ChunkId, chunk: *const Chunk, symbols: Symbols, cc: [3]u8, has_upvalue_table: bool, use_color: bool) !void {
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
    // Strictness flags fold into the upvalues table when one renders; these
    // lines are the fallback for chunks with no recorded upvalue names.
    if (has_upvalue_table) return;
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
/// The chunk's qualified name, rendered from the always-on name tree into a
/// scratch buffer. Disasm is single-threaded (name capture forces `--eval`
/// single-worker), and callers use the slice immediately, so the shared buffer
/// is safe.
var chunk_name_buf: [1024]u8 = undefined;
fn chunkNameOf(symbols: Symbols, id: ChunkId) ?[]const u8 {
    const reg = symbols.registry orelse return null;
    // The two registry-synthesized apply trampolines register before any
    // compiler names them — name them statically.
    if (id == reg.well_known.genlist_apply) return "builtin·genlist_apply";
    if (id == reg.well_known.mapattrs_apply) return "builtin·mapattrs_apply";
    const intern = symbols.intern orelse return null;
    if (!reg.hasQualifiedName(id)) return null;
    var w: std.Io.Writer = .fixed(&chunk_name_buf);
    reg.writeQualifiedName(&w, id, intern) catch return null;
    return chunk_name_buf[0..w.end];
}

/// `chunk[0x{id}]` followed by its best-effort name when known, so a reference
/// reads `chunk[0x62] fetchGit` rather than a bare id.
fn writeChunkRef(writer: *std.Io.Writer, id: ChunkId, symbols: Symbols) !void {
    try writer.print("chunk[0x{x}]", .{id});
    if (chunkNameOf(symbols, id)) |name| try writer.print(" {s}", .{name});
}

/// A place to record the chunk ids an instruction references, bundled with the
/// allocator that owns the map — so `writeOperands` never reaches for a global
/// allocator to grow a caller's container. `null` means "don't collect refs",
/// which the length-only walkers (`captureCensus`, `--stats`) use to skip the
/// allocation entirely.
const RefSink = struct {
    map: *std.AutoArrayHashMapUnmanaged(ChunkId, void),
    allocator: std.mem.Allocator,
};

fn addRef(sink: ?RefSink, id: ChunkId) !void {
    if (sink) |s| try s.map.put(s.allocator, id, {});
}

fn writeOperands(
    writer: *std.Io.Writer,
    chunk: *const Chunk,
    op: OpCode,
    ip_in: usize,
    symbols: Symbols,
    up_names: ?[]const InternId,
    referenced_chunks: ?RefSink,
) !usize {
    // Uniform, table-driven operand rendering. Two passes over the op's operand
    // layout (`opcode.layout`): pass 1 prints raw operand tokens, pass 2 their
    // interpretation, joined as "raw ; interp" (the form the multiline view
    // splits on). Every per-op case that used to live here is now one entry in
    // that table plus the per-field-type renderers below.
    const code = chunk.code;
    const fields = opcode_mod.layout(op);

    var ip = ip_in;
    var wrote_raw = false;
    for (fields) |f| {
        if (fieldHasRaw(f)) {
            if (wrote_raw) try writer.writeByte(' ');
            try writeFieldRaw(writer, f, code, ip);
            wrote_raw = true;
        }
        ip += opcode_mod.fieldLen(f, code, ip);
    }

    var wrote_int = false;
    ip = ip_in;
    for (fields) |f| {
        if (fieldHasInterp(f)) {
            try writer.writeAll(if (wrote_int) ", " else if (wrote_raw) " ; " else "");
            try writeFieldInterp(writer, f, chunk, code, ip, symbols, up_names, referenced_chunks);
            wrote_int = true;
        }
        ip += opcode_mod.fieldLen(f, code, ip);
    }

    std.debug.assert(ip == ip_in + opcode_mod.operandLen(op, code, ip_in));
    return ip;
}

const Operand = opcode_mod.Operand;

fn readWidth(w: opcode_mod.Width, code: []const u8, ip: usize) u32 {
    return switch (w) {
        .b1 => code[ip],
        .b2 => readU16(code, ip),
        .b4 => readU32(code, ip),
    };
}

/// Every field but `.skip` (an internal side-table offset) shows a raw token.
fn fieldHasRaw(f: Operand) bool {
    return switch (f) {
        .skip => false,
        else => true,
    };
}

/// Every field but `.skip` and `.raw` (a bare scalar) has an interpretation.
fn fieldHasInterp(f: Operand) bool {
    return switch (f) {
        .skip, .raw => false,
        else => true,
    };
}

fn writeFieldRaw(writer: *std.Io.Writer, f: Operand, code: []const u8, ip: usize) !void {
    switch (f) {
        .raw, .skip => |w| try writer.print("#{d}", .{readWidth(w, code, ip)}),
        .const_idx => try writer.print("#{d}", .{readU16(code, ip)}),
        .slot => |s| try writer.print("#{d}", .{readWidth(s.w, code, ip)}),
        .cap1 => try writer.print("#{d}", .{readU16(code, ip + 1)}),
        .chunk_id => |w| try writer.print("0x{x}", .{readWidth(w, code, ip)}),
        .intern => |w| try writer.print("#{d}", .{readWidth(w, code, ip)}),
        .count => |c| try writer.print("#{d}", .{readWidth(c.w, code, ip)}),
        .jump => try writer.print("+{d}", .{readU32(code, ip)}),
        .captures, .captures_slot => try writer.print("#{d}", .{readU16(code, ip)}),
        .attr_path => try writer.print("#{d}", .{code[ip]}),
        .check => try writer.print("#{d}", .{readU16(code, ip + 1)}),
        .mix => try writer.print("#{d} #{d}", .{ code[ip], code[ip + 1] }),
    }
}

fn writeFieldInterp(
    writer: *std.Io.Writer,
    f: Operand,
    chunk: *const Chunk,
    code: []const u8,
    ip: usize,
    symbols: Symbols,
    up_names: ?[]const InternId,
    referenced_chunks: ?RefSink,
) !void {
    switch (f) {
        .raw, .skip => {},
        .const_idx => {
            const idx = readU16(code, ip);
            if (idx < chunk.constants.len)
                try writeValueDigest(writer, chunk.constants[idx], symbols, snippet_max, false)
            else
                try writer.print("const #{d}", .{idx});
        },
        .slot => |s| {
            const v = readWidth(s.w, code, ip);
            try writer.print("{s}[{d}]", .{ @tagName(s.role), v });
            if (s.role == .upvalue) {
                if (upvalueName(up_names, symbols, v)) |nm| try writer.print(" {s}", .{nm});
            }
        },
        .cap1 => {
            const kind = code[ip];
            const idx = readU16(code, ip + 1);
            try writer.print("{s}[{d}]", .{ if (kind == 0) "local" else "upvalue", idx });
        },
        .chunk_id => |w| {
            const id: ChunkId = readWidth(w, code, ip);
            try writeChunkRef(writer, id, symbols);
            try addRef(referenced_chunks, id);
        },
        .intern => |w| {
            const id: InternId = readWidth(w, code, ip);
            try writeInternRef(writer, id, symbols);
        },
        .count => |c| try writer.print("{d} {s}", .{ readWidth(c.w, code, ip), c.noun }),
        .jump => {
            const off = readU32(code, ip);
            try writer.print("→ {x:0>4}", .{ip + 4 + off});
        },
        .captures => try writer.print("{d} captures", .{readU16(code, ip)}),
        .captures_slot => {
            const n = readU16(code, ip);
            const slot_b = code[ip + 2 + @as(usize, n) * 3];
            try writer.print("{d} captures → local[{d}]", .{ n, slot_b });
        },
        .attr_path => |w| {
            const segments = code[ip];
            try writeAttrPath(writer, code, ip + 1, segments, w == .b4, symbols);
        },
        .check => {
            const allow = code[ip];
            const expected = readU16(code, ip + 1);
            try writer.print("{d} expected (allow_extra={s})", .{ expected, if (allow != 0) "true" else "false" });
        },
        .mix => try writer.print("{d} segments ({d} dynamic)", .{ code[ip], code[ip + 1] }),
    }
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
pub fn chunkPrimaryFile(chunk: *const Chunk, chunk_id: ?ChunkId, symbols: Symbols) ?InternId {
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
pub fn bestSpan(chunk: *const Chunk, ip: usize) ?Chunk.SourceSpan {
    var best: ?Chunk.SourceMapEntry = null;
    for (chunk.source_map) |entry| {
        if (ip < entry.start or ip >= entry.end) continue;
        if (best == null or entry.end - entry.start <= best.?.end - best.?.start) {
            best = entry;
        }
    }
    return if (best) |e| e.span else null;
}

/// Source span for a live call frame's `ip`. Like `bestSpan` but with an
/// **inclusive** end, because a caller frame's `ip` points *past* the call it's
/// suspended on — i.e. exactly at the covering span's exclusive end — so
/// `bestSpan` would miss it and the frame would show no location. Falls back to
/// the chunk's representative `body_span` when no entry covers `ip` (thunk
/// bodies with a sparse map). This is the backtrace/step location function.
pub fn frameSpan(chunk: *const Chunk, ip: usize) ?Chunk.SourceSpan {
    var best: ?Chunk.SourceMapEntry = null;
    for (chunk.source_map) |entry| {
        if (ip < entry.start or ip > entry.end) continue;
        if (best == null or entry.end - entry.start <= best.?.end - best.?.start) {
            best = entry;
        }
    }
    if (best) |e| return e.span;
    return chunk.body_span;
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
        .builtin => {
            const bid = value.asBuiltinId();
            try writeStoreRefText(writer, "builtin", bid, heapColor(bid), use_color);
            if (builtinName(bid)) |nm| {
                try setCommentFg(writer, use_color);
                try writer.writeAll(" → ");
                if (use_color) {
                    const c = heapColor(bid);
                    try writer.print("\x1b[38;2;{d};{d};{d}m", .{ c[0], c[1], c[2] });
                }
                try writer.writeAll(nm);
                if (use_color) try writer.writeAll("\x1b[0m");
            }
        },
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

/// Set the foreground to `rgb` (no-op when not coloring).
fn setFg(writer: *std.Io.Writer, rgb: [3]u8, use_color: bool) !void {
    if (use_color) try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
}

/// One `attr positions:` row body: `"name" @ file:line:col`, the name and the
/// filename each in their intern identity color, structural glue comment-grey.
fn writeAttrPosRow(writer: *std.Io.Writer, rec: @import("runtime").heap.AttrPosEntry, symbols: Symbols, use_color: bool) !void {
    if (symbols.internName(rec.name)) |s| {
        try setFg(writer, internColor(rec.name), use_color);
        try writer.writeByte('"');
        try writeEscapedSnippet(writer, s, table_snippet_max);
        try writer.writeByte('"');
        if (use_color) try writer.writeAll("\x1b[0m");
    } else {
        try writeStoreRefText(writer, "str", rec.name, internColor(rec.name), use_color);
    }
    try setCommentFg(writer, use_color);
    try writer.writeAll(" @ ");
    if (symbols.internName(rec.pos.file)) |f| {
        try setFg(writer, internColor(rec.pos.file), use_color);
        try writer.writeAll(std.fs.path.basename(f));
        if (use_color) try writer.writeAll("\x1b[0m");
    } else {
        try writeStoreRefText(writer, "file", rec.pos.file, internColor(rec.pos.file), use_color);
    }
    try setCommentFg(writer, use_color);
    try writer.print(":{d}:{d}", .{ rec.pos.line, rec.pos.column });
    if (use_color) try writer.writeAll("\x1b[0m");
}

/// The `│  └ #idx` prefix of one `name:` section-table row: chunk gutter, the
/// section's tree guide (`└` on the last row, else `│`), then the row index in
/// its identity color padded to the value column. The shared row opener for the
/// attr-name/position tables.
fn writeTableRowHead(writer: *std.Io.Writer, cc: [3]u8, sec_color: [3]u8, idx: usize, last: bool, idx_color: [3]u8, use_color: bool) !void {
    try writeGuide(writer, cc, null, use_color);
    try writer.writeAll("  ");
    try writeTreeGuide(writer, sec_color, if (last) .corner else .vert, null, use_color);
    var ibuf: [16]u8 = undefined;
    const istr = std.fmt.bufPrint(&ibuf, "#{d}", .{idx}) catch "#?";
    if (use_color) {
        try writer.print("\x1b[38;2;{d};{d};{d}m{s}\x1b[0m", .{ idx_color[0], idx_color[1], idx_color[2], istr });
    } else {
        try writer.writeAll(istr);
    }
    try writer.splatByteAll(' ', 6 -| istr.len);
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

// ---------------------------------------------------------------------------
// `--stats` mode: corpus-level codegen statistics
// ---------------------------------------------------------------------------

/// One row of counts + code bytes.
const StatRow = struct {
    count: u64 = 0,
    bytes: u64 = 0,
    fn add(self: *StatRow, b: u64) void {
        self.count += 1;
        self.bytes += b;
    }
};

/// Primary category of a chunk body, first match wins.
const ChunkCategory = enum {
    trivial_attr_access,
    trivial_identity,
    trivial_literal,
    trivial_closure0,
    trivial_closure_caps,
    trivial_builtins,
    const_builder, // only constant pushes + aggregate build + ret/halt
    const_scalar, // only constant pushes + ret/halt (no aggregate)
    shell, // builds an aggregate wired with thunks/closures
    general,
};

/// Whether `op` only pushes compile-time-known data (for the const_* buckets).
fn isConstOp(op: OpCode) bool {
    return switch (op) {
        .push_const, .push_const_ret, .push_true, .push_false, .push_null, .ret, .halt => true,
        else => false,
    };
}

fn isAggregateOp(op: OpCode) bool {
    return switch (op) {
        .attrs_new, .attrs_new_srt, .attrs_new_named_srt, .attrs_new_named_pos_srt, .list_new => true,
        else => false,
    };
}

fn isThunkFamilyOp(op: OpCode) bool {
    return switch (op) {
        .thunk, .thunk_w, .thunk_eag, .thunk_eag_w, .thunk_arg, .thunk_shell, .thunk_defer, .thunk_attr, .thunk_st, .thunk_st_cell, .thunk_eag_st, .thunk_eag_st_cell, .thunk_w_st, .thunk_w_st_cell, .thunk_eag_w_st, .thunk_eag_w_st_cell, .closure, .closure_w, .closure_cap, .closure_cap_w => true,
        else => false,
    };
}

/// Corpus statistics over every chunk in the registry: size and category
/// breakdowns, mnemonic histogram, position-table share, duplicate-body reuse,
/// and deflate compressibility of the concatenated code — the measurement
/// harness for codegen-size work.
pub fn writeStats(allocator: std.mem.Allocator, writer: *std.Io.Writer, registry: *const ChunkRegistry, symbols: Symbols) !void {
    const a = allocator;
    const n = registry.count();

    var total = StatRow{};
    var const_count: u64 = 0;
    var source_map_entries: u64 = 0;

    const bucket_lims = [_]u64{ 4, 8, 16, 32, 128, 512, 2048, 8192, std.math.maxInt(u64) };
    const bucket_names = [_][]const u8{ "<=4B", "<=8B", "<=16B", "<=32B", "<=128B", "<=512B", "<=2KB", "<=8KB", ">8KB" };
    var buckets = [_]StatRow{.{}} ** bucket_lims.len;

    var cats = std.enums.EnumArray(ChunkCategory, StatRow).initFill(.{});
    var op_counts = [_]u64{0} ** opcode_mod.count;
    var op_bytes = [_]u64{0} ** opcode_mod.count;

    var pos_sites: u64 = 0;
    var pos_entries: u64 = 0;
    var pos_bytes: u64 = 0;
    var empty_attrs_chunks: u64 = 0;

    // Duplicate-body detection: hash of code bytes → (count, size). Chunks with
    // no local constants are fully parametric, so byte-identical code there is
    // semantically interchangeable; track both scopes.
    const DupInfo = struct { count: u64, size: u64 };
    var dups_all: std.AutoHashMapUnmanaged(u64, DupInfo) = .empty;
    defer dups_all.deinit(a);
    var dups_free: std.AutoHashMapUnmanaged(u64, DupInfo) = .empty;
    defer dups_free.deinit(a);

    // Deflate the concatenated code stream to gauge redundancy. (Compress.init
    // asserts the output writer has usable buffer capacity.)
    var flate_out: std.Io.Writer.Allocating = try .initCapacity(a, 1 << 20);
    defer flate_out.deinit();
    const flate_window = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(flate_window);
    var flate = try std.compress.flate.Compress.init(&flate_out.writer, flate_window, .raw, .default);

    // `symbols` was only needed to render operand text; the stats pass now sizes
    // instructions straight from `operandLen`, so no rendering scratch is needed.
    _ = symbols;

    var id: ChunkId = 0;
    while (id < n) : (id += 1) {
        const chunk = registry.get(id) orelse continue;
        const code = chunk.code;
        total.add(code.len);
        const_count += chunk.constants.len;
        source_map_entries += chunk.source_map.len;
        pos_entries += chunk.attr_pos.len;
        pos_bytes += @as(u64, chunk.attr_pos.len) * 16;
        for (bucket_lims, 0..) |lim, i| {
            if (code.len <= lim) {
                buckets[i].add(code.len);
                break;
            }
        }
        flate.writer.writeAll(code) catch {};

        const h = std.hash.Wyhash.hash(0, code);
        {
            const gop = try dups_all.getOrPut(a, h);
            if (!gop.found_existing) gop.value_ptr.* = .{ .count = 0, .size = code.len };
            gop.value_ptr.count += 1;
        }
        if (chunk.constants.len == 0 and chunk.local_count == 0) {
            const gop = try dups_free.getOrPut(a, h);
            if (!gop.found_existing) gop.value_ptr.* = .{ .count = 0, .size = code.len };
            gop.value_ptr.count += 1;
        }

        // Opcode walk (operand lengths via the same decoder the listing uses).
        var only_const = true;
        var has_agg = false;
        var has_thunk = false;
        var ip: usize = 0;
        while (ip < code.len) {
            const op_byte = code[ip];
            if (op_byte >= opcode_mod.count) {
                ip += 1;
                only_const = false;
                continue;
            }
            const op: OpCode = @enumFromInt(op_byte);
            const start = ip;
            ip += 1;
            // Length-only pass: no rendering, straight from the operand-shape
            // table (the same source `writeOperands` asserts itself against).
            ip = @min(ip + opcode_mod.operandLen(op, code, ip), code.len);
            op_counts[op_byte] += 1;
            op_bytes[op_byte] += ip - start;
            if (!isConstOp(op) and !isAggregateOp(op)) only_const = false;
            if (isAggregateOp(op)) has_agg = true;
            if (isThunkFamilyOp(op)) has_thunk = true;
            switch (op) {
                .attrs_new_named_pos_srt => pos_sites += 1,
                .attrs_new, .attrs_new_srt => {
                    if (code.len == 5 and readU16(code, start + 1) == 0) empty_attrs_chunks += 1;
                },
                else => {},
            }
        }

        const cat: ChunkCategory = switch (chunk.scheduling.trivial) {
            .attr_access => .trivial_attr_access,
            .identity_upvalue => .trivial_identity,
            .literal => .trivial_literal,
            .closure_zero => .trivial_closure0,
            .closure_captures => .trivial_closure_caps,
            .builtins => .trivial_builtins,
            .none => if (only_const and has_agg) .const_builder else if (only_const) .const_scalar else if (has_agg and has_thunk) .shell else .general,
        };
        cats.getPtr(cat).add(code.len);
    }
    flate.finish() catch {};
    flate.writer.flush() catch {};
    const flate_bytes = flate_out.writer.buffered().len;

    // ---- report ----
    try writer.print("chunks {d}   code {d} B   constants {d}   source-map entries {d}\n", .{ total.count, total.bytes, const_count, source_map_entries });
    if (total.count > 0) try writer.print("avg chunk {d} B   deflate(code) {d} B ({d}.{d:0>2}x)\n", .{ total.bytes / total.count, flate_bytes, total.bytes / @max(flate_bytes, 1), (total.bytes * 100 / @max(flate_bytes, 1)) % 100 });

    try writer.writeAll("\nsize buckets            count       bytes\n");
    for (bucket_names, buckets) |bn, b| {
        try writer.print("  {s:<20} {d:>10} {d:>11}\n", .{ bn, b.count, b.bytes });
    }

    try writer.writeAll("\ncategories              count       bytes\n");
    inline for (@typeInfo(ChunkCategory).@"enum".fields) |f| {
        const row = cats.get(@field(ChunkCategory, f.name));
        if (row.count > 0) try writer.print("  {s:<20} {d:>10} {d:>11}\n", .{ f.name, row.count, row.bytes });
    }
    if (empty_attrs_chunks > 0) try writer.print("  (of const_builder: empty-attrs chunks {d})\n", .{empty_attrs_chunks});

    // Top mnemonics by count.
    try writer.writeAll("\ntop mnemonics           count       bytes\n");
    var shown: usize = 0;
    var used = [_]bool{false} ** opcode_mod.count;
    while (shown < 15) : (shown += 1) {
        var best: usize = 0;
        var best_count: u64 = 0;
        for (op_counts, 0..) |c, i| {
            if (!used[i] and c > best_count) {
                best = i;
                best_count = c;
            }
        }
        if (best_count == 0) break;
        used[best] = true;
        try writer.print("  {s:<20} {d:>10} {d:>11}\n", .{ @tagName(@as(OpCode, @enumFromInt(best))), op_counts[best], op_bytes[best] });
    }

    if (total.bytes > 0) {
        try writer.print("\nposition side-table (external to code): sites {d}   entries {d}   bytes {d}\n", .{ pos_sites, pos_entries, pos_bytes });
    }

    // Duplicate summaries.
    inline for (.{ .{ "all chunks", &dups_all }, .{ "const-free chunks", &dups_free } }) |pair| {
        var distinct: u64 = 0;
        var members: u64 = 0;
        var wasted: u64 = 0;
        var it = pair[1].valueIterator();
        while (it.next()) |v| {
            distinct += 1;
            members += v.count;
            wasted += (v.count - 1) * v.size;
        }
        try writer.print("duplicate bodies ({s}): members {d}   distinct {d}   duplicates {d}   wasted bytes {d}\n", .{ pair[0], members, distinct, members - distinct, wasted });
    }
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

    try writeChunk(allocator, &out.writer, 7, &chunk, .{}, .{});
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

    try writeChunk(allocator, &out.writer, null, &chunk, .{}, .{});
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

    try writeChunk(allocator, &out.writer, null, &chunk, .{ .intern = &intern }, .{});
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

    try writeChunk(allocator, &out.writer, null, &chunk, .{}, .{ .show_constants = false });
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "constants (") == null);
}
