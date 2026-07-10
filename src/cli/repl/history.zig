//! Persistent repl history.
//!
//! Entries live in `$XDG_STATE_HOME/fix/repl-history` (default
//! `~/.local/state/fix/repl-history`), one per line, newlines and backslashes
//! escaped so multiline inputs round-trip as single entries. New entries are
//! appended to the file as they are accepted (crash-safe); the in-memory list
//! is capped and consecutive duplicates are collapsed. All file I/O is
//! best-effort: a missing or unwritable history file just means no
//! persistence.

const std = @import("std");

pub const max_entries = 1000;

pub const History = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io,
    entries: std.ArrayListUnmanaged([]u8) = .empty,
    path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator, .io = null };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |e| self.allocator.free(e);
        self.entries.deinit(self.allocator);
        if (self.path) |p| self.allocator.free(p);
    }

    /// Resolve the history path from the environment and load existing
    /// entries. Call once at repl start (interactive mode only).
    pub fn open(self: *History, io: std.Io, env: *const std.process.Environ.Map) void {
        self.io = io;
        self.path = historyPath(self.allocator, env) catch null;
        self.load() catch {};
    }

    fn historyPath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
        if (env.get("XDG_STATE_HOME")) |dir| {
            if (dir.len != 0) return std.fs.path.join(allocator, &.{ dir, "fix", "repl-history" });
        }
        const home = env.get("HOME") orelse return error.NoHome;
        if (home.len == 0) return error.NoHome;
        return std.fs.path.join(allocator, &.{ home, ".local", "state", "fix", "repl-history" });
    }

    fn load(self: *History) !void {
        const io = self.io orelse return;
        const path = self.path orelse return;
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(4 << 20)) catch return;
        defer self.allocator.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const decoded = try decode(self.allocator, line);
            if (decoded.len == 0) {
                self.allocator.free(decoded);
                continue;
            }
            try self.push(decoded);
        }
    }

    /// Add an accepted input line. Skips empties and consecutive duplicates;
    /// appends to the history file when one is open.
    pub fn add(self: *History, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.entries.items.len != 0 and
            std.mem.eql(u8, self.entries.items[self.entries.items.len - 1], trimmed))
            return;
        try self.push(try self.allocator.dupe(u8, trimmed));
        self.appendToFile(trimmed) catch {};
    }

    /// Take ownership of `entry` and append, evicting the oldest past the cap.
    fn push(self: *History, entry: []u8) !void {
        if (self.entries.items.len >= max_entries) {
            self.allocator.free(self.entries.orderedRemove(0));
        }
        try self.entries.append(self.allocator, entry);
    }

    pub fn count(self: *const History) usize {
        return self.entries.items.len;
    }

    pub fn get(self: *const History, index: usize) []const u8 {
        return self.entries.items[index];
    }

    /// Most recent entry at or before `from` containing `needle`
    /// (case-sensitive substring, like readline's reverse-i-search).
    pub fn searchBack(self: *const History, needle: []const u8, from: usize) ?usize {
        if (self.entries.items.len == 0) return null;
        var i = @min(from, self.entries.items.len - 1) + 1;
        while (i > 0) {
            i -= 1;
            if (std.mem.indexOf(u8, self.entries.items[i], needle) != null) return i;
        }
        return null;
    }

    fn appendToFile(self: *History, entry: []const u8) !void {
        const io = self.io orelse return;
        const path = self.path orelse return;
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        }
        const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return;
        defer file.close(io);
        const end = file.length(io) catch return;
        var buf: [4096]u8 = undefined;
        var w = file.writerStreaming(io, &buf);
        w.seekTo(end) catch return;
        encode(&w.interface, entry) catch return;
        w.interface.writeByte('\n') catch return;
        w.interface.flush() catch return;
    }

    fn encode(w: *std.Io.Writer, entry: []const u8) !void {
        for (entry) |c| switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            else => try w.writeByte(c),
        };
    }

    fn decode(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (line[i] == '\\' and i + 1 < line.len) {
                i += 1;
                switch (line[i]) {
                    'n' => try out.append(allocator, '\n'),
                    '\\' => try out.append(allocator, '\\'),
                    else => {
                        try out.append(allocator, '\\');
                        try out.append(allocator, line[i]);
                    },
                }
            } else {
                try out.append(allocator, line[i]);
            }
        }
        return out.toOwnedSlice(allocator);
    }
};

const testing = std.testing;

test "add dedups consecutive and skips empties" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.add("1 + 1");
    try h.add("1 + 1");
    try h.add("   ");
    try h.add("x");
    try testing.expectEqual(@as(usize, 2), h.count());
    try testing.expectEqualStrings("1 + 1", h.get(0));
    try testing.expectEqualStrings("x", h.get(1));
}

test "multiline entries round-trip through encode/decode" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const original = "let\n  x = \"a\\nb\";\nin x";
    try History.encode(&buf.writer, original);
    try testing.expect(std.mem.indexOfScalar(u8, buf.written(), '\n') == null);
    const back = try History.decode(testing.allocator, buf.written());
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(original, back);
}

test "searchBack finds most recent match first" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.add("builtins.map");
    try h.add("1 + 2");
    try h.add("map f xs");
    try testing.expectEqual(@as(?usize, 2), h.searchBack("map", h.count() - 1));
    try testing.expectEqual(@as(?usize, 0), h.searchBack("map", 1));
    try testing.expectEqual(@as(?usize, null), h.searchBack("zzz", h.count() - 1));
}
