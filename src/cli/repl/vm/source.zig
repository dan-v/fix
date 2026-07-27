//! Source-span navigation and breakpoint targets for the VM explorer.
//!
//! These algorithms are independent of terminal state. Keeping them here makes
//! source navigation testable without constructing the full explorer.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");

const bytecode = engine.bytecode;
const ChunkId = runtime.types.ChunkId;

/// A breakpoint target attached to a rendered row. Instruction rows use the
/// exact `(chunk_id, offset)` site; source rows retain the full span so nested
/// expressions that share an entry offset remain independent.
pub const Location = struct {
    chunk_id: ChunkId,
    offset: u32,
    file: []const u8 = "",
    line: u32 = 0,
    /// Present on source-span rows so the document's source excerpt can follow
    /// the highlighted sub-expression rather than remaining on the chunk body.
    span: ?bytecode.Chunk.SourceSpan = null,
};

pub const SpanStats = struct {
    index: usize,
    total: usize,
};

pub fn eql(a: bytecode.Chunk.SourceSpan, b: bytecode.Chunk.SourceSpan) bool {
    return a.file == b.file and a.offset == b.offset and a.len == b.len;
}

pub fn less(a: bytecode.Chunk.SourceSpan, b: bytecode.Chunk.SourceSpan) bool {
    if (a.offset != b.offset) return a.offset < b.offset;
    if (a.len != b.len) return a.len < b.len;
    if (a.line != b.line) return a.line < b.line;
    return a.column < b.column;
}

pub fn first(chunk: *const bytecode.Chunk) ?bytecode.Chunk.SourceSpan {
    var result: ?bytecode.Chunk.SourceSpan = null;
    for (chunk.source_map) |entry| {
        if (result == null or less(entry.span, result.?)) result = entry.span;
    }
    return result;
}

/// Return the one-based position of `current` among the chunk's unique spans.
pub fn stats(chunk: *const bytecode.Chunk, current: bytecode.Chunk.SourceSpan) SpanStats {
    var total: usize = 0;
    var before: usize = 0;
    for (chunk.source_map, 0..) |entry, i| {
        var duplicate = false;
        for (chunk.source_map[0..i]) |previous| {
            if (eql(previous.span, entry.span)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        total += 1;
        if (less(entry.span, current)) before += 1;
    }
    return .{ .index = @min(before + 1, total), .total = total };
}

pub fn adjacent(
    chunk: *const bytecode.Chunk,
    current: bytecode.Chunk.SourceSpan,
    forward: bool,
) ?bytecode.Chunk.SourceSpan {
    var candidate: ?bytecode.Chunk.SourceSpan = null;
    for (chunk.source_map) |entry| {
        const span = entry.span;
        if (eql(span, current)) continue;
        const follows = less(current, span);
        const precedes = less(span, current);
        if ((forward and !follows) or (!forward and !precedes)) continue;
        if (candidate == null or
            (forward and less(span, candidate.?)) or
            (!forward and less(candidate.?, span)))
        {
            candidate = span;
        }
    }
    return candidate;
}

pub fn location(
    id: ChunkId,
    chunk: *const bytecode.Chunk,
    span: bytecode.Chunk.SourceSpan,
) ?Location {
    var start: ?u32 = null;
    for (chunk.source_map) |entry| {
        if (!eql(entry.span, span)) continue;
        if (start == null or entry.start < start.?) start = entry.start;
    }
    return .{
        .chunk_id = id,
        .offset = start orelse return null,
        .line = span.line,
        .span = span,
    };
}

test "span navigation deduplicates and orders source map entries" {
    const early: bytecode.Chunk.SourceSpan = .{
        .file = 1,
        .offset = 4,
        .len = 3,
        .line = 1,
        .column = 5,
    };
    const late: bytecode.Chunk.SourceSpan = .{
        .file = 1,
        .offset = 20,
        .len = 2,
        .line = 2,
        .column = 3,
    };
    const entries = [_]bytecode.Chunk.SourceMapEntry{
        .{ .start = 9, .end = 10, .span = late },
        .{ .start = 2, .end = 3, .span = early },
        .{ .start = 5, .end = 6, .span = early },
    };
    var code: [0]u8 = .{};
    const constants: [0]runtime.Value = .{};
    const chunk: bytecode.Chunk = .{
        .code = &code,
        .constants = &constants,
        .local_count = 0,
        .source_map = &entries,
    };

    try std.testing.expect(eql(early, entries[2].span));
    try std.testing.expectEqual(early, first(&chunk).?);
    try std.testing.expectEqual(SpanStats{ .index = 1, .total = 2 }, stats(&chunk, early));
    try std.testing.expectEqual(late, adjacent(&chunk, early, true).?);
    try std.testing.expectEqual(early, adjacent(&chunk, late, false).?);
    const target = location(7, &chunk, early).?;
    try std.testing.expectEqual(@as(ChunkId, 7), target.chunk_id);
    try std.testing.expectEqual(@as(u32, 2), target.offset);
}
