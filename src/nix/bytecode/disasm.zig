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
};

/// Bytes shown per row: the hex column is a fixed 4 cells wide (so the opcode
/// byte, operand bytes, mnemonic, and interpretation all align), and longer
/// records wrap onto continuation rows.
const bytes_per_line = 4;

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
    depth: u8,
    visited: *Visited,
) anyerror!void {
    if (chunk_id) |id| try visited.put(std.heap.page_allocator, id, {});
    // Each chunk is a top-level group: a colored header and a left-margin guide
    // (in the chunk's own color) down every line of its body.
    const cc: [3]u8 = if (chunk_id) |id| hueColor(id) else .{ 0x9a, 0x9a, 0x9a };
    try writeChunkHeader(writer, chunk_id, chunk, symbols, cc, options.use_color);
    if (options.show_constants and chunk.constants.len > 0) {
        try writeGuide(writer, cc, options.use_color);
        try writer.print("  constants ({d}):\n", .{chunk.constants.len});
        for (chunk.constants, 0..) |c, i| {
            try writeGuide(writer, cc, options.use_color);
            try writer.print("    #{d:0>4}  ", .{i});
            try writeValueDigest(writer, c, symbols);
            try writer.writeByte('\n');
        }
    }

    var ip: usize = 0;
    var referenced_chunks: std.AutoArrayHashMapUnmanaged(ChunkId, void) = .empty;
    defer referenced_chunks.deinit(std.heap.page_allocator);

    // Source filenames are hoisted onto their own comment line: one at the top
    // of the chunk (before any bytes) and again only if the file changes
    // mid-chunk. Instruction lines then carry just the `line:col+len` position.
    var last_file: ?InternId = null;
    if (options.show_source) {
        if (chunkPrimaryFile(chunk, chunk_id, symbols)) |f| {
            try writeGuide(writer, cc, options.use_color);
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
            try writeGuide(writer, cc, options.use_color);
            try writeOffset(writer, start, options.use_color);
            try writer.writeAll("  ");
            if (options.show_bytes) try writeByteField(writer, chunk.code[start..ip], options.use_color);
            if (options.use_color) try writer.writeAll("\x1b[2m");
            try writer.print(".byte 0x{x:0>2}", .{op_byte});
            if (options.use_color) try writer.writeAll("\x1b[0m");
            try writer.writeByte('\n');
            continue;
        }
        const op: OpCode = @enumFromInt(op_byte);
        ip += 1;

        // Decode the operands into a scratch buffer first: we need the full
        // instruction byte-range (to print the raw-byte column ahead of the
        // mnemonic) before writing the line, and operand text is always short.
        var opbuf: [2048]u8 = undefined;
        var ow: std.Io.Writer = .fixed(&opbuf);
        ip = try writeOperands(&ow, chunk, op, ip, symbols, &referenced_chunks);
        const operand_text = opbuf[0..ow.end];
        const insn = chunk.code[start..ip];

        // Find the narrowest source span covering this instruction; hoist its
        // filename onto its own line when it changes from the previous one.
        const span: ?Chunk.SourceSpan = if (options.show_source) bestSpan(chunk, start) else null;
        if (span) |s| {
            if (s.file) |f| {
                if (last_file == null or last_file.? != f) {
                    try writeGuide(writer, cc, options.use_color);
                    try writeFileLine(writer, f, symbols, options.use_color);
                    last_file = f;
                }
            }
        }

        try writeGuide(writer, cc, options.use_color);
        try writeOffset(writer, start, options.use_color);
        try writer.writeAll("  ");
        if (isMultiline(op)) {
            // The header row carries only the opcode byte + mnemonic; each
            // operand becomes an indented child row below.
            if (options.show_bytes) try writeByteField(writer, insn[0..1], options.use_color);
            try writer.writeByte(' '); // gap column between the bytes and the mnemonic
            try writeMnemonic(writer, op, options.use_color);
            if (span) |s| try writePosColumn(writer, s, options.use_color);
            try writeOperandFields(writer, chunk, op, start + 1, ip, operand_text, symbols, cc, options.show_bytes, options.use_color);
            try writer.writeByte('\n');
        } else {
            // Zero or one simple operand: keep it all on the mnemonic row. The
            // opcode byte + mnemonic share one color; the operand bytes and its
            // interpretation share another (linked), like the multi-row style.
            const opcol = hueColor(@intFromEnum(op) + 1);
            if (options.show_bytes) {
                var c: usize = 0;
                while (c < bytes_per_line) : (c += 1) {
                    if (c >= insn.len) {
                        try writer.writeAll("   ");
                    } else {
                        try writeByteCellColored(writer, insn[c], if (c == 0) byteRgb(op_byte) else opcol, options.use_color);
                    }
                }
            }
            try writer.writeByte(' '); // gap column between the bytes and the mnemonic
            try writeMnemonic(writer, op, options.use_color);
            if (operand_text.len > 0) {
                if (options.use_color) try writer.print("\x1b[38;2;{d};{d};{d}m", .{ opcol[0], opcol[1], opcol[2] });
                try writer.writeAll(operand_text);
                if (options.use_color) try writer.writeAll("\x1b[0m");
            }
            if (span) |s| try writePosColumn(writer, s, options.use_color);
            try writer.writeByte('\n');
            // Wrap any remaining instruction bytes onto continuation rows.
            if (options.show_bytes and insn.len > bytes_per_line) {
                var o: usize = bytes_per_line;
                while (o < insn.len) : (o += bytes_per_line) {
                    try writeGuide(writer, cc, options.use_color);
                    try writer.writeAll("        ");
                    var c: usize = o;
                    while (c < o + bytes_per_line and c < insn.len) : (c += 1) try writeByteCellColored(writer, insn[c], opcol, options.use_color);
                    try writer.writeByte('\n');
                }
            }
        }
    }

    if (options.recurse) {
        const reg = symbols.registry orelse return;
        if (options.max_depth != 0 and depth + 1 >= options.max_depth) return;
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

fn writeOffset(writer: *std.Io.Writer, off: usize, use_color: bool) !void {
    try writer.writeAll("  ");
    if (use_color) try writer.writeAll("\x1b[2m");
    try writer.print("{x:0>4}", .{off});
    if (use_color) try writer.writeAll("\x1b[0m");
}

/// Write the mnemonic followed by a single space. When colored, it takes the
/// same per-value color as its opcode byte, so the mnemonic and its leading hex
/// cell visually match.
fn writeMnemonic(writer: *std.Io.Writer, op: OpCode, use_color: bool) !void {
    const name = @tagName(op);
    if (use_color) {
        const rgb = byteRgb(@intFromEnum(op));
        try writer.print("\x1b[38;2;{d};{d};{d}m{s}\x1b[0m", .{ rgb[0], rgb[1], rgb[2], name });
    } else {
        try writer.writeAll(name);
    }
    try writer.writeByte(' ');
}

// ---------------------------------------------------------------------------
// `--fields` mode: one line per operand field
// ---------------------------------------------------------------------------

/// A legible color for sequence position `seq`. Consecutive values land a
/// golden angle (~137.5°) apart, so neighbouring groups are always well
/// separated — we care more about telling adjacent parts apart than about a
/// given value always mapping to the same color.
fn hueColor(seq: usize) [3]u8 {
    const hue: f32 = @floatCast(@mod(@as(f64, @floatFromInt(seq)) * 137.508, 360.0));
    return hsvToRgb(hue, 0.62, 0.99);
}

fn writeByteCellColored(writer: *std.Io.Writer, b: u8, rgb: [3]u8, use_color: bool) !void {
    if (use_color) {
        try writer.print("\x1b[38;2;{d};{d};{d}m{x:0>2}\x1b[0m ", .{ rgb[0], rgb[1], rgb[2], b });
    } else {
        try writer.print("{x:0>2} ", .{b});
    }
}

/// One `--fields` operand line: a run of colored byte-groups (each `len` bytes
/// at `byte_off`, whose interpretation `text` takes that group's color) and dim
/// structural glue (`len == 0`). Groups may be listed in display order even when
/// that differs from byte order — the shared color is the link, not position.
const Tok = struct { byte_off: u16 = 0, len: u16 = 0, text: []const u8, colored: bool = false, color: [3]u8 = .{ 0x9a, 0x9a, 0x9a } };

const Line = struct {
    toks: [24]Tok = undefined,
    n: usize = 0,
    buf: [1024]u8 = undefined,
    used: usize = 0,

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
            if (t.colored and t.len > 0) {
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
fn writeGuide(writer: *std.Io.Writer, rgb: [3]u8, use_color: bool) !void {
    if (use_color) {
        try writer.print("\x1b[38;2;{d};{d};{d}m│\x1b[0m ", .{ rgb[0], rgb[1], rgb[2] });
    } else {
        try writer.writeAll("│ ");
    }
}

/// Like `writeGuide` but a column wider — used for the operand-hierarchy guides
/// so each nesting level is clearly indented (the chunk left margin stays thin).
fn writeGuideWide(writer: *std.Io.Writer, rgb: [3]u8, use_color: bool) !void {
    if (use_color) {
        try writer.print("\x1b[38;2;{d};{d};{d}m│\x1b[0m  ", .{ rgb[0], rgb[1], rgb[2] });
    } else {
        try writer.writeAll("│  ");
    }
}

/// The closing corner drawn for a group's last member — `⌊` (a full-height
/// vertical with the foot at the bottom), so the gutter reads as ending.
fn writeGuideCorner(writer: *std.Io.Writer, rgb: [3]u8, use_color: bool) !void {
    if (use_color) {
        try writer.print("\x1b[38;2;{d};{d};{d}m⌊\x1b[0m  ", .{ rgb[0], rgb[1], rgb[2] });
    } else {
        try writer.writeAll("⌊  ");
    }
}

/// Render one operand line at `off` under `guides` (ancestor colors), then
/// advance `off` past its bytes. Bytes stay in their fixed column (aligned under
/// the opcode byte); the hierarchy guides sit in the mnemonic gutter to the
/// right of the bytes, so the interpretation reads as an indented child of the
/// mnemonic. Long records wrap at `bytes_per_line`, guides repeating on each
/// row (a continuous gutter) but the interpretation only on the first. `seq` is
/// the running per-instruction color counter (shared with the mnemonic).
fn emitLine(writer: *std.Io.Writer, code: []const u8, off: *usize, line: *Line, seq: *usize, guides: []const [3]u8, last_in_group: bool, cc: [3]u8, show_bytes: bool, use_color: bool) !void {
    const base = off.*;
    const total = line.total();
    line.paint(seq);
    const rows: u16 = if (!show_bytes or total == 0) 1 else (total + bytes_per_line - 1) / bytes_per_line;
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        try writer.writeByte('\n');
        try writeGuide(writer, cc, use_color); // chunk left margin
        try writer.writeAll("        "); // blank offset column
        if (show_bytes) {
            var c: u16 = 0;
            while (c < bytes_per_line) : (c += 1) {
                const pos = r * bytes_per_line + c;
                if (pos < total) try writeByteCellColored(writer, code[base + pos], line.colorAt(pos), use_color) else try writer.writeAll("   ");
            }
        }
        try writer.writeByte(' '); // gap column between the bytes and the gutter
        // The hierarchy gutter: the last member closes with `└` on its content
        // row and drops the guide on its wrapped continuation rows (a guide
        // shouldn't dangle past the last actual line).
        if (r > 0 and last_in_group) {
            for (guides) |_| try writer.writeAll("   ");
        } else {
            for (guides, 0..) |gc, gi| {
                if (r == 0 and last_in_group and gi + 1 == guides.len) {
                    try writeGuideCorner(writer, gc, use_color);
                } else {
                    try writeGuideWide(writer, gc, use_color);
                }
            }
        }
        if (r != 0) continue; // continuation rows: bytes + gutter only
        for (line.toks[0..line.n]) |t| {
            if (use_color) {
                if (t.colored and t.len > 0) {
                    try writer.print("\x1b[38;2;{d};{d};{d}m", .{ t.color[0], t.color[1], t.color[2] });
                } else {
                    try writer.writeAll("\x1b[2m");
                }
            }
            try writer.writeAll(t.text);
        }
        if (use_color) try writer.writeAll("\x1b[0m");
    }
    off.* += total;
}

/// `chunk 0x{id} [name]`, the id bytes and hex tinted together.
fn emitChunkLine(writer: *std.Io.Writer, code: []const u8, off: *usize, id_len: u16, id: ChunkId, symbols: Symbols, seq: *usize, guides: []const [3]u8, cc: [3]u8, show_bytes: bool, use_color: bool) !void {
    var l = Line{};
    l.glue("chunk ", .{});
    l.group(0, id_len, "0x{x}", .{id});
    if (chunkNameOf(symbols, id)) |name| l.glue(" {s}", .{name});
    try emitLine(writer, code, off, &l, seq, guides, false, cc, show_bytes, use_color);
}

/// A `{count} {label}` line (count is a u16 at `off`).
fn emitCountLine(writer: *std.Io.Writer, code: []const u8, off: *usize, label: []const u8, seq: *usize, guides: []const [3]u8, cc: [3]u8, show_bytes: bool, use_color: bool) !void {
    var l = Line{};
    l.group(0, 2, "{d}", .{readU16(code, off.*)});
    l.glue(" {s}", .{label});
    try emitLine(writer, code, off, &l, seq, guides, false, cc, show_bytes, use_color);
}

/// The `n` inline capture descriptors (3 bytes each: kind byte + u16 index),
/// each a child line under `guides`, tinting `local`/`upvalue` with the kind
/// byte and the index with its bytes.
fn emitCaptureDescriptors(writer: *std.Io.Writer, code: []const u8, off: *usize, n: u16, seq: *usize, guides: []const [3]u8, cc: [3]u8, show_bytes: bool, use_color: bool) !void {
    var k: usize = 0;
    while (k < n) : (k += 1) {
        var l = Line{};
        l.group(0, 1, "{s}", .{if (code[off.*] == 0) "local" else "upvalue"});
        l.glue("[", .{});
        l.group(1, 2, "{d}", .{readU16(code, off.* + 1)});
        l.glue("]", .{});
        try emitLine(writer, code, off, &l, seq, guides, k == n - 1, cc, show_bytes, use_color);
    }
}

/// Render an instruction's operands as one line per field. `ip` is the byte
/// offset just past the opcode; `end_ip` is the authoritative instruction end
/// (from `writeOperands`), and `operand_text` its compact decode — used both as
/// the fallback comment for opcodes without a bespoke breakdown and as a guard:
/// any bytes a bespoke arm fails to consume are dumped as a trailing field so a
/// miscount can never bleed into the next instruction.
fn writeOperandFields(
    writer: *std.Io.Writer,
    chunk: *const Chunk,
    op: OpCode,
    ip: usize,
    end_ip: usize,
    operand_text: []const u8,
    symbols: Symbols,
    cc: [3]u8,
    show_bytes: bool,
    use_color: bool,
) !void {
    const code = chunk.code;
    var off = ip;
    // Per-instruction color counter, seeded from the opcode so the mnemonic
    // (byteRgb == hueColor of the opcode) and the operands form one golden-angle
    // sequence — adjacent parts always differ.
    var seq: usize = @intFromEnum(op) + 1;
    // Ancestor guide colors: level 0 is the mnemonic, deeper levels are the
    // count lines that a capture/position list hangs under. Direct operands use
    // `g[0..1]`; list members use `g[0..2]` with the count's color at `g[1]`.
    var g: [3][3]u8 = undefined;
    g[0] = byteRgb(@intFromEnum(op));
    switch (op) {
        .closure, .closure_long => {
            const wide = op == .closure_long;
            const id_len: u16 = if (wide) 4 else 2;
            const id: ChunkId = if (wide) readU32(code, off) else @intCast(readU16(code, off));
            try emitChunkLine(writer, code, &off, id_len, id, symbols, &seq, g[0..1], cc, show_bytes, use_color);
            var l = Line{};
            l.group(0, 2, "{d}", .{readU16(code, off)});
            l.glue(" upvalues (from stack)", .{});
            try emitLine(writer, code, &off, &l, &seq, g[0..1], false, cc, show_bytes, use_color);
        },
        .thunk_captures, .thunk_captures_eager, .thunk_captures_long, .thunk_captures_eager_long, .apply_arg => {
            const wide = op == .thunk_captures_long or op == .thunk_captures_eager_long or op == .apply_arg;
            const id_len: u16 = if (wide) 4 else 2;
            const id: ChunkId = if (wide) readU32(code, off) else @intCast(readU16(code, off));
            try emitChunkLine(writer, code, &off, id_len, id, symbols, &seq, g[0..1], cc, show_bytes, use_color);
            const n = readU16(code, off);
            g[1] = hueColor(seq); // the "captures" count line's color
            try emitCountLine(writer, code, &off, "captures", &seq, g[0..1], cc, show_bytes, use_color);
            try emitCaptureDescriptors(writer, code, &off, n, &seq, g[0..2], cc, show_bytes, use_color);
        },
        .closure_captures, .closure_captures_long => {
            const wide = op == .closure_captures_long;
            const id_len: u16 = if (wide) 4 else 2;
            const id: ChunkId = if (wide) readU32(code, off) else @intCast(readU16(code, off));
            try emitChunkLine(writer, code, &off, id_len, id, symbols, &seq, g[0..1], cc, show_bytes, use_color);
            const n = readU16(code, off);
            g[1] = hueColor(seq);
            try emitCountLine(writer, code, &off, "captures", &seq, g[0..1], cc, show_bytes, use_color);
            try emitCaptureDescriptors(writer, code, &off, n, &seq, g[0..2], cc, show_bytes, use_color);
        },
        .thunk_captures_store_local, .thunk_captures_store_cell_local, .thunk_captures_eager_store_local, .thunk_captures_eager_store_cell_local => {
            const id: ChunkId = @intCast(readU16(code, off));
            try emitChunkLine(writer, code, &off, 2, id, symbols, &seq, g[0..1], cc, show_bytes, use_color);
            const n = readU16(code, off);
            g[1] = hueColor(seq);
            try emitCountLine(writer, code, &off, "captures", &seq, g[0..1], cc, show_bytes, use_color);
            try emitCaptureDescriptors(writer, code, &off, n, &seq, g[0..2], cc, show_bytes, use_color);
            var l = Line{};
            l.glue("→ local[", .{});
            l.group(0, 1, "{d}", .{code[off]});
            l.glue("]", .{});
            try emitLine(writer, code, &off, &l, &seq, g[0..1], false, cc, show_bytes, use_color);
        },
        .build_attrs_with_pos, .build_attrs_with_pos_sorted => {
            try emitCountLine(writer, code, &off, "entries", &seq, g[0..1], cc, show_bytes, use_color);
            const pos_count = readU16(code, off);
            g[1] = hueColor(seq); // the "positions" count line's color
            try emitCountLine(writer, code, &off, "positions", &seq, g[0..1], cc, show_bytes, use_color);
            var k: usize = 0;
            while (k < pos_count) : (k += 1) {
                // 16-byte record: name id, file id, line, column (u32 LE each).
                // Shown name / line:col / basename — each tinted by its bytes,
                // so display order can differ from byte order (color is the link).
                // Wrapped 4 bytes/row (one u32 field per row), comment on row 0.
                const nm: InternId = readU32(code, off);
                const fl: InternId = readU32(code, off + 4);
                const ln = readU32(code, off + 8);
                const cl = readU32(code, off + 12);
                var l = Line{};
                l.glue("[{d}] ", .{k});
                if (symbols.internName(nm)) |s| l.group(0, 4, "\"{s}\"", .{s}) else l.group(0, 4, "0x{x}", .{nm});
                l.glue(" @ ", .{});
                if (symbols.internName(fl)) |s| l.group(4, 4, "{s}", .{std.fs.path.basename(s)}) else l.group(4, 4, "file 0x{x}", .{fl});
                l.glue(":", .{});
                l.group(8, 4, "{d}", .{ln});
                l.glue(":", .{});
                l.group(12, 4, "{d}", .{cl});
                try emitLine(writer, code, &off, &l, &seq, g[0..2], k == pos_count - 1, cc, show_bytes, use_color);
            }
        },
        .defer_attr_value => {
            var l = Line{};
            l.glue("deferred #", .{});
            l.group(0, 4, "{d}", .{readU32(code, off)});
            try emitLine(writer, code, &off, &l, &seq, g[0..1], false, cc, show_bytes, use_color);
            const env = readU16(code, off);
            g[1] = hueColor(seq);
            try emitCountLine(writer, code, &off, "env", &seq, g[0..1], cc, show_bytes, use_color);
            try emitCaptureDescriptors(writer, code, &off, env, &seq, g[0..2], cc, show_bytes, use_color);
        },
        else => {
            // No bespoke breakdown: the whole operand is one group, labelled
            // with the compact decode.
            if (end_ip > off) {
                var l = Line{};
                l.group(0, @intCast(end_ip - off), "{s}", .{operand_text});
                try emitLine(writer, code, &off, &l, &seq, g[0..1], false, cc, show_bytes, use_color);
            }
        },
    }
    // Guard: dump any bytes a bespoke arm under-counted as a trailing field.
    if (off < end_ip) {
        var l = Line{};
        l.group(0, @intCast(end_ip - off), "{s}", .{"…"});
        try emitLine(writer, code, &off, &l, &seq, g[0..1], false, cc, show_bytes, use_color);
    }
}

/// Instructions with a list of sub-fields (captures / positions) are drawn
/// across multiple indented rows; everything else fits on one line.
fn isMultiline(op: OpCode) bool {
    return switch (op) {
        .closure,
        .closure_long,
        .thunk_captures,
        .thunk_captures_eager,
        .thunk_captures_long,
        .thunk_captures_eager_long,
        .apply_arg,
        .closure_captures,
        .closure_captures_long,
        .thunk_captures_store_local,
        .thunk_captures_store_cell_local,
        .thunk_captures_eager_store_local,
        .thunk_captures_eager_store_cell_local,
        .build_attrs_with_pos,
        .build_attrs_with_pos_sorted,
        .defer_attr_value,
        => true,
        else => false,
    };
}

fn writeChunkHeader(writer: *std.Io.Writer, chunk_id: ?ChunkId, chunk: *const Chunk, symbols: Symbols, cc: [3]u8, use_color: bool) !void {
    if (use_color) try writer.print("\x1b[1;38;2;{d};{d};{d}m", .{ cc[0], cc[1], cc[2] });
    if (chunk_id) |id| {
        try writer.print("chunk 0x{x}", .{id});
    } else {
        try writer.writeAll("chunk");
    }
    if (use_color) try writer.writeAll("\x1b[0m");
    // Best-effort compiler-attributed name (the binding a lambda/thunk was
    // compiled for), when name capture was on. See ChunkRegistry.recordName.
    if (chunk_id) |id| {
        if (symbols.registry) |reg| {
            if (reg.nameOf(id)) |name_id| {
                if (symbols.internName(name_id)) |name| {
                    if (use_color) try writer.writeAll("\x1b[1;32m");
                    try writer.print(" {s}", .{name});
                    if (use_color) try writer.writeAll("\x1b[0m");
                }
            }
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
        try writeGuide(writer, cc, use_color);
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
        try writeGuide(writer, cc, use_color);
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

/// The best-effort name attributed to chunk `id`, resolved to text.
fn chunkNameOf(symbols: Symbols, id: ChunkId) ?[]const u8 {
    const reg = symbols.registry orelse return null;
    const name_id = reg.nameOf(id) orelse return null;
    return symbols.internName(name_id);
}

/// `chunk 0x{id}` followed by its best-effort name when known, so a reference
/// reads `chunk 0x62 fetchGit` rather than a bare id.
fn writeChunkRef(writer: *std.Io.Writer, id: ChunkId, symbols: Symbols) !void {
    try writer.print("chunk 0x{x}", .{id});
    if (chunkNameOf(symbols, id)) |name| try writer.print(" {s}", .{name});
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

        .add_int, .sub_int, .mul_int, .div_int, .negate_int,
        .add_float, .sub_float, .mul_float, .div_float,
        .eq, .neq, .eq_null, .neq_null, .lt, .lte, .gt, .gte, .not,
        .fail_assertion, .push_builtins,
        .merge_attrs, .merge_attrs_strict, .concat_lists,
        .get_attr_dynamic,
        .call, .tail_call, .make_cell, .make_lazy_shell, .ret, .halt => {},

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

        .closure => {
            // `.closure` carries no inline capture descriptors (captures come
            // off the stack); `.closure_captures`/`.thunk_captures*` do.
            const id: ChunkId = @intCast(readU16(code, ip));
            ip += 2;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} upvalues", .{upvalues});
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .thunk_captures, .thunk_captures_eager => {
            const id: ChunkId = @intCast(readU16(code, ip));
            ip += 2;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} captures", .{upvalues});
            ip += @as(usize, upvalues) * 3; // inline capture descriptors
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
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} captures → local[{d}]", .{ upvalues, slot });
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .closure_long => {
            const id: ChunkId = readU32(code, ip);
            ip += 4;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} upvalues", .{upvalues});
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .thunk_captures_long, .thunk_captures_eager_long, .apply_arg => {
            const id: ChunkId = readU32(code, ip);
            ip += 4;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} captures", .{upvalues});
            ip += @as(usize, upvalues) * 3; // inline capture descriptors
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .closure_captures => {
            const id: ChunkId = @intCast(readU16(code, ip));
            ip += 2;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} captures", .{upvalues});
            ip += @as(usize, upvalues) * 3;
            try referenced_chunks.put(std.heap.page_allocator, id, {});
        },
        .closure_captures_long => {
            const id: ChunkId = readU32(code, ip);
            ip += 4;
            const upvalues = readU16(code, ip);
            ip += 2;
            try writeChunkRef(writer, id, symbols);
            try writer.print(", {d} captures", .{upvalues});
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
            try writer.print("0x{x}", .{id});
        }
    }
    try writer.writeByte('"');
}

fn writeInternRef(writer: *std.Io.Writer, id: InternId, symbols: Symbols) !void {
    if (symbols.internName(id)) |name| {
        try writer.writeByte('"');
        try writer.writeAll(name);
        try writer.print("\" (0x{x})", .{id});
    } else {
        try writer.print("0x{x}", .{id});
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
    if (use_color) try writer.writeAll("\x1b[2m");
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
fn writePosColumn(writer: *std.Io.Writer, span: Chunk.SourceSpan, use_color: bool) !void {
    if (use_color) try writer.writeAll("\x1b[2m");
    try writer.print("   ; {d}:{d}+{d}", .{ span.line, span.column, span.len });
    if (use_color) try writer.writeAll("\x1b[0m");
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
        .list => try writer.print("list 0x{x}", .{value.asObjectId()}),
        .attrs => try writer.print("attrs 0x{x}", .{value.asObjectId()}),
        .closure => try writer.print("closure 0x{x}", .{value.asObjectId()}),
        .thunk => try writer.print("thunk 0x{x}", .{value.asObjectId()}),
        .builtin => try writer.print("builtin 0x{x}", .{value.asBuiltinId()}),
        .builtin_closure => try writer.print("builtin_closure 0x{x}", .{value.asObjectId()}),
        .string_context => try writer.print("string_ctx 0x{x}", .{value.asObjectId()}),
        .boxed_int => try writer.print("boxed_int 0x{x}", .{value.asObjectId()}),
        .partial_app => try writer.print("partial_app 0x{x}", .{value.asObjectId()}),
    }
}

fn writeStringRef(writer: *std.Io.Writer, kind: []const u8, id: InternId, symbols: Symbols) !void {
    if (symbols.internName(id)) |text| {
        try writer.print("{s} \"", .{kind});
        try writeEscapedSnippet(writer, text, 40);
        try writer.print("\" (0x{x})", .{id});
    } else {
        try writer.print("{s} 0x{x}", .{ kind, id });
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

    try std.testing.expect(std.mem.indexOf(u8, text, "chunk 0x7") != null);
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
