//! VM explorer view semantics shared by tree, page, and preview projections.
//!
//! Methods are parameterized by the private explorer state type and wired as
//! direct aliases by `operations.zig`; this module owns the behavior below.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const width_mod = @import("../width.zig");
const vm_model = @import("model.zig");
const source_render = @import("../../source_render.zig");
const debugger = @import("../../debugger.zig");
const base = @import("base");
const tui = base.tui;
const Evaluator = engine.Evaluator;
const DebugSession = engine.DebugSession;
const ChunkId = runtime.types.ChunkId;
const bytecode = engine.bytecode;
const disasm = engine.bytecode.disasm;

const Category = vm_model.Category;
const HeapView = vm_model.HeapView;
const RowAction = vm_model.RowAction;
const Page = vm_model.Page;
const PageBuilder = vm_model.PageBuilder;
const Visit = vm_model.Visit;
const RangeKind = vm_model.RangeKind;
const ChunkEquivalence = vm_model.ChunkEquivalence;
const Range = vm_model.Range;
const TreeRow = vm_model.TreeRow;
const LineRange = vm_model.LineRange;
const NavigationState = vm_model.NavigationState;
const TreeState = vm_model.TreeState;
const HeapIndexState = vm_model.HeapIndexState;
const ReferenceIndexState = vm_model.ReferenceIndexState;
const Viewport = vm_model.Viewport;

const disasm_options: disasm.Options = .{
    .show_constants = true,
    .show_source = true,
    .show_bytes = true,
    .recurse = false,
};

pub const debug_help_text =
    \\Debug pause
    \\
    \\  s / n / f      step into / next / finish
    \\  c              continue (resume evaluation)
    \\  q / Ctrl-D     abort evaluation
    \\  p              toggle a breakpoint on the selected instruction/span
    \\  ↑/↓ j/k        select a tree row (frames, chunks, heap)
    \\  Enter          open the selected frame / follow a reference
    \\  i / :          evaluate an expression / run a command
    \\  break F:L      set a source-line breakpoint
;

pub fn debugPageOf(arena: std.mem.Allocator, page: *PageBuilder, title: []const u8) !Page {
    return .{
        .title = try arena.dupe(u8, title),
        .lines = page.lines.items,
        .actions = page.actions.items,
        .locations = page.locations.items,
    };
}

/// A one-line, length-capped snippet of a source span for the span list.
pub fn spanSnippet(arena: std.mem.Allocator, source: ?[]const u8, target: anytype, max_cells: usize) ![]const u8 {
    const text = source orelse return "";
    const start = @min(@as(usize, target.offset), text.len);
    const end = @min(start +| @as(usize, target.len), text.len);
    if (start >= end) return "";
    const raw = text[start..end];
    const out = try arena.dupe(u8, raw);
    for (out) |*b| if (b.* == '\n' or b.* == '\r' or b.* == '\t') {
        b.* = ' ';
    };
    return width_mod.endEllipsis(arena, out, max_cells);
}

pub fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) continue :outer;
        }
        return true;
    }
    return false;
}

/// Two tree rows denote the same node (ignoring depth), for cursor preservation.
pub fn treeRowsEqual(a: TreeRow, b: TreeRow) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .category => |x| b.category.kind == x.kind,
        .name => |x| b.name.key == x.key,
        .chunk => |x| b.chunk.id == x.id,
        .range => |x| std.meta.eql(b.range.key(), x.key()),
        .heap => |x| b.heap.view == x.view,
        .object => |x| b.object.id == x.id,
        .store_record => |x| b.store_record.view == x.view and b.store_record.id == x.id,
        .debug_root => true,
        .debug_frame => |x| b.debug_frame.index == x.index,
        .debug_value => true,
    };
}

pub fn returnValueHeading(reason: engine.BreakReason) []const u8 {
    return switch (reason) {
        .return_step => "RETURN VALUE",
        .eval_error => "ERROR VALUE",
        else => "BREAK VALUE",
    };
}

pub fn reasonName(reason: engine.BreakReason) []const u8 {
    return switch (reason) {
        .entry => "entry",
        .break_builtin => "break",
        .line_breakpoint => "breakpoint",
        .step => "step",
        .return_step => "return",
        .eval_error => "error",
    };
}

pub fn disasmTarget(line: []const u8) RowAction {
    if (storeRefId(line, "chunk[0x")) |id| {
        return .{ .chunk = @intCast(id) };
    }
    if (storeRefId(line, "objects[0x")) |id| {
        return .{ .object = @intCast(id) };
    }
    if (storeRefId(line, "intern[0x")) |id| {
        return .{ .store_record = .{ .view = .intern, .id = @intCast(id) } };
    }
    if (storeRefId(line, "builtin[0x")) |id| {
        return .{ .store_record = .{ .view = .builtin, .id = @intCast(id) } };
    }
    return .none;
}

pub fn disasmOffset(chunk: *const bytecode.Chunk, line: []const u8) ?usize {
    const trimmed = std.mem.trimStart(u8, line, " │\t");
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return null;
    const offset = std.fmt.parseInt(usize, trimmed[0..end], 16) catch return null;
    return if (offset < chunk.code.len) offset else null;
}

pub fn storeRefId(line: []const u8, prefix: []const u8) ?u64 {
    const start = (std.mem.indexOf(u8, line, prefix) orelse return null) + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, ']') orelse return null;
    return std.fmt.parseInt(u64, line[start..end], 16) catch null;
}

pub fn sourceFileMatches(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) or std.mem.eql(u8, std.fs.path.basename(a), std.fs.path.basename(b));
}
