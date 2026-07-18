//! Structured diagnostics and source-span rendering.

const std = @import("std");
const TokenType = @import("token.zig").TokenType;

pub const Diagnostic = struct {
    pub const Severity = enum { err, warning, note };
    pub const Kind = enum { parse, compile };

    severity: Severity = .err,
    kind: Kind = .parse,
    line: u32,
    column: u32,
    offset: u32,
    len: u32,
    token_type: ?TokenType,
    message: []const u8,
    source: ?[]const u8 = null,
    source_path: ?[]const u8 = null,
};

pub const LineSpan = struct {
    start: usize,
    end: usize,
};

pub const SourcePosition = struct {
    line: u32,
    column: u32,
};

pub const LineIndex = struct {
    source_len: usize = 0,
    line_starts: []const u32 = &.{},
    /// Cache of the last lookup. The compiler walks nodes in source order,
    /// so most queries hit a line at or just after the previous query. The
    /// cache turns the binary search into an O(1) check in the common case.
    cache_line: u32 = 0,
    cache_line_start: u32 = 0,
    cache_line_end: u32 = 0,

    pub const empty: LineIndex = .{};

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !LineIndex {
        var line_starts = try std.ArrayListUnmanaged(u32).initCapacity(
            allocator,
            std.mem.count(u8, source, "\n") + 1,
        );
        errdefer line_starts.deinit(allocator);

        line_starts.appendAssumeCapacity(0);
        if (std.mem.indexOfScalar(u8, source, '\r') == null) {
            // Fast path (the common case): LF-only. indexOfScalarPos is
            // SIMD-accelerated; a byte-at-a-time loop over every imported file's
            // source was a measurable compile-time cost.
            var pos: usize = 0;
            while (std.mem.indexOfScalarPos(u8, source, pos, '\n')) |i| {
                line_starts.appendAssumeCapacity(@intCast(i + 1));
                pos = i + 1;
            }
        } else {
            // CR-aware slow path: a lone `\r` (Mac) and `\r\n` both terminate a
            // line, so positions in CR/CRLF files match Nix. Capacity above only
            // counted `\n`, so append (may grow) instead of assuming capacity.
            var i: usize = 0;
            while (i < source.len) : (i += 1) {
                switch (source[i]) {
                    '\n' => try line_starts.append(allocator, @intCast(i + 1)),
                    '\r' => if (i + 1 >= source.len or source[i + 1] != '\n') {
                        try line_starts.append(allocator, @intCast(i + 1));
                    },
                    else => {},
                }
            }
        }

        const first_line_end: u32 = if (line_starts.items.len > 1) line_starts.items[1] else @intCast(source.len);
        const owned = try line_starts.toOwnedSlice(allocator);

        return .{
            .source_len = source.len,
            .line_starts = owned,
            .cache_line = 0,
            .cache_line_start = 0,
            .cache_line_end = first_line_end,
        };
    }

    pub fn deinit(self: *LineIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.line_starts);
        self.* = .empty;
    }

    pub fn positionForOffset(self: *LineIndex, offset: u32) SourcePosition {
        std.debug.assert(self.line_starts.len > 0);

        const target_usize = @min(@as(usize, @intCast(offset)), self.source_len);
        const target: u32 = @intCast(target_usize);

        // Cache hit: still on the same line as the previous query.
        if (target >= self.cache_line_start and target < self.cache_line_end) {
            return .{
                .line = self.cache_line + 1,
                .column = target - self.cache_line_start + 1,
            };
        }

        const line_index = self.lineIndexForTarget(target_usize);
        const line_start = self.line_starts[line_index];
        const line_end: u32 = if (line_index + 1 < self.line_starts.len)
            self.line_starts[line_index + 1]
        else
            @intCast(self.source_len);

        self.cache_line = @intCast(line_index);
        self.cache_line_start = line_start;
        self.cache_line_end = line_end;

        return .{
            .line = @as(u32, @intCast(line_index)) + 1,
            .column = target - line_start + 1,
        };
    }

    fn lineIndexForTarget(self: *const LineIndex, target: usize) usize {
        var low: usize = 0;
        var high: usize = self.line_starts.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const line_start: usize = @intCast(self.line_starts[mid]);
            if (line_start <= target) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low - 1;
    }

    /// 1-based line for a byte offset, WITHOUT touching the mutable lookup
    /// cache — safe to call concurrently (`line_starts` is immutable after
    /// `init`). For read-only consumers that share a `LineIndex` with the
    /// compiler (e.g. the timeline labelling a deferred body mid-compile).
    pub fn lineForOffset(self: *const LineIndex, offset: u32) u32 {
        if (self.line_starts.len == 0) return 0;
        return @as(u32, @intCast(self.lineIndexForTarget(offset))) + 1;
    }
};

pub const RenderOptions = struct {
    color: bool = false,
    show_near: bool = true,
};

pub fn lineForOffset(source: []const u8, offset: u32) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    const target = offsetTarget(source, offset);
    while (i < target) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

pub fn columnForOffset(source: []const u8, offset: u32) u32 {
    var line_start: usize = 0;
    var i: usize = 0;
    const target = offsetTarget(source, offset);
    while (i < target) : (i += 1) {
        if (source[i] == '\n') line_start = i + 1;
    }
    return @intCast(target - line_start + 1);
}

pub fn lineSpan(source: []const u8, offset: u32) LineSpan {
    const target = offsetTarget(source, offset);
    var start = target;
    while (start > 0 and source[start - 1] != '\n') {
        start -= 1;
    }

    var end = target;
    while (end < source.len and source[end] != '\n') {
        end += 1;
    }

    return .{ .start = start, .end = end };
}

pub fn writeAll(writer: *std.Io.Writer, source: []const u8, diagnostics: []const Diagnostic) !void {
    try writeAllWithOptions(writer, source, diagnostics, .{});
}

pub fn writeAllWithOptions(writer: *std.Io.Writer, source: []const u8, diagnostics: []const Diagnostic, options: RenderOptions) !void {
    for (diagnostics) |diagnostic| {
        try writeOne(writer, source, diagnostic, options);
    }
}

fn writeOne(writer: *std.Io.Writer, source: []const u8, diagnostic: Diagnostic, options: RenderOptions) !void {
    const diagnostic_source = diagnostic.source orelse source;
    switch (diagnostic.severity) {
        .err => switch (diagnostic.kind) {
            .parse => {
                try style(writer, options, .error_label);
                try writer.writeAll("error");
                try reset(writer, options);
                try writer.writeAll(": parse error at ");
                try writeLocation(writer, diagnostic);
                try writer.print(": {s}\n", .{diagnostic.message});
            },
            .compile => {
                try style(writer, options, .error_label);
                try writer.writeAll("error");
                try reset(writer, options);
                try writer.print(": {s} at ", .{diagnostic.message});
                try writeLocation(writer, diagnostic);
                try writer.writeByte('\n');
            },
        },
        .warning => {
            try style(writer, options, .warning_label);
            try writer.writeAll("warning");
            try reset(writer, options);
            try writer.print(": {s} at ", .{diagnostic.message});
            try writeLocation(writer, diagnostic);
            try writer.writeByte('\n');
        },
        .note => {
            try style(writer, options, .note_label);
            try writer.writeAll("note");
            try reset(writer, options);
            try writer.print(": {s} at ", .{diagnostic.message});
            try writeLocation(writer, diagnostic);
            try writer.writeByte('\n');
        },
    }

    const source_line = lineSpan(diagnostic_source, diagnostic.offset);
    try style(writer, options, .gutter);
    try writer.print("{d: >4} | {s}\n", .{ diagnostic.line, diagnostic_source[source_line.start..source_line.end] });
    try writer.writeAll("     | ");
    try reset(writer, options);
    try writeSpaces(writer, diagnostic.column - 1);

    try style(writer, options, if (diagnostic.severity == .err) .error_caret else .note_caret);
    // Diagnostics normally point at a token on one line, while evaluation
    // traces may carry the span of a whole (multi-line) expression.  This is
    // a one-line excerpt, so never extend its caret or `near` text past the
    // displayed line.
    const target = offsetTarget(diagnostic_source, diagnostic.offset);
    const remaining_on_line: u32 = @intCast(source_line.end - target);
    const caret_count = @max(@as(u32, 1), @min(diagnostic.len, remaining_on_line));
    var i: u32 = 0;
    while (i < caret_count) : (i += 1) {
        try writer.writeByte('^');
    }
    try reset(writer, options);

    if (options.show_near and (diagnostic.token_type == null or diagnostic.token_type.? != .eof)) {
        const start = target;
        const len: usize = @min(@as(usize, @intCast(diagnostic.len)), source_line.end - start);
        if (len > 0) {
            try style(writer, options, .near);
            try writer.print(" near `{s}`", .{diagnostic_source[start .. start + len]});
            try reset(writer, options);
        }
    }
    try writer.writeByte('\n');
}

fn writeLocation(writer: *std.Io.Writer, diagnostic: Diagnostic) !void {
    if (diagnostic.source_path) |path| {
        try writer.print("{s}:{d}:{d}", .{ path, diagnostic.line, diagnostic.column });
    } else {
        try writer.print("{d}:{d}", .{ diagnostic.line, diagnostic.column });
    }
}

fn writeSpaces(writer: *std.Io.Writer, count: u32) !void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try writer.writeByte(' ');
    }
}

fn offsetTarget(source: []const u8, offset: u32) usize {
    return @min(@as(usize, @intCast(offset)), source.len);
}

const Style = enum {
    error_label,
    warning_label,
    note_label,
    error_caret,
    note_caret,
    gutter,
    near,
};

fn style(writer: *std.Io.Writer, options: RenderOptions, which: Style) !void {
    if (!options.color) return;
    try writer.writeAll(switch (which) {
        .error_label => "\x1b[1;31m",
        .warning_label => "\x1b[1;33m",
        .note_label => "\x1b[1;36m",
        .error_caret => "\x1b[31m",
        .note_caret => "\x1b[36m",
        .gutter => "\x1b[2m",
        .near => "\x1b[2m",
    });
}

fn reset(writer: *std.Io.Writer, options: RenderOptions) !void {
    if (options.color) try writer.writeAll("\x1b[0m");
}

test "line index matches offset helpers" {
    const source = "first\nsecond\n\nfourth";
    var index = try LineIndex.init(std.testing.allocator, source);
    defer index.deinit(std.testing.allocator);

    const offsets = [_]u32{ 0, 4, 5, 6, 12, 13, 14, 20, 100 };
    for (offsets) |offset| {
        const position = index.positionForOffset(offset);
        try std.testing.expectEqual(lineForOffset(source, offset), position.line);
        try std.testing.expectEqual(columnForOffset(source, offset), position.column);
    }
}
