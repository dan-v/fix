//! Bounded output capture for the interactive REPL screen.
//!
//! Evaluation output can be arbitrarily large (a NixOS value easily spans
//! millions of lines), so the TUI must not use an allocating writer and hope
//! for the best. `Capture` is an ordinary `std.Io.Writer` that counts every
//! byte but retains only the newest `limit` bytes for the visible transcript.

const std = @import("std");

pub const Capture = struct {
    allocator: std.mem.Allocator,
    limit: usize,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    total: u64 = 0,
    writer: std.Io.Writer = .{
        .vtable = &.{ .drain = drain },
        .buffer = &.{},
    },

    pub fn init(allocator: std.mem.Allocator, limit: usize) Capture {
        return .{ .allocator = allocator, .limit = limit };
    }

    pub fn deinit(self: *Capture) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn clear(self: *Capture) void {
        self.bytes.clearRetainingCapacity();
        self.total = 0;
    }

    pub fn written(self: *const Capture) []const u8 {
        return self.bytes.items;
    }

    pub fn omitted(self: *const Capture) u64 {
        return self.total -| self.bytes.items.len;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Capture = @alignCast(@fieldParentPtr("writer", w));
        const literals = data[0 .. data.len - 1];
        const pattern = data[data.len - 1];
        var consumed: usize = 0;
        for (literals) |part| {
            self.appendTail(part) catch return error.WriteFailed;
            consumed += part.len;
        }
        for (0..splat) |_| {
            self.appendTail(pattern) catch return error.WriteFailed;
            consumed += pattern.len;
        }
        return consumed;
    }

    fn appendTail(self: *Capture, incoming: []const u8) !void {
        self.total +|= incoming.len;
        if (self.limit == 0 or incoming.len == 0) return;
        if (incoming.len >= self.limit) {
            self.bytes.clearRetainingCapacity();
            try self.bytes.appendSlice(self.allocator, incoming[incoming.len - self.limit ..]);
            return;
        }

        const overflow = self.bytes.items.len + incoming.len -| self.limit;
        if (overflow > 0) {
            std.mem.copyForwards(u8, self.bytes.items[0 .. self.bytes.items.len - overflow], self.bytes.items[overflow..]);
            self.bytes.items.len -= overflow;
        }
        try self.bytes.appendSlice(self.allocator, incoming);
    }
};

test "bounded transcript capture retains the newest bytes" {
    var capture = Capture.init(std.testing.allocator, 8);
    defer capture.deinit();

    try capture.writer.writeAll("abc");
    try capture.writer.writeAll("defghij");
    try std.testing.expectEqualStrings("cdefghij", capture.written());
    try std.testing.expectEqual(@as(u64, 2), capture.omitted());

    try capture.writer.splatByteAll('!', 3);
    try std.testing.expectEqualStrings("fghij!!!", capture.written());
    try std.testing.expectEqual(@as(u64, 5), capture.omitted());
}

test "oversized writes do not allocate beyond the transcript limit" {
    var capture = Capture.init(std.testing.allocator, 4);
    defer capture.deinit();

    try capture.writer.writeAll("0123456789");
    try std.testing.expectEqualStrings("6789", capture.written());
    try std.testing.expectEqual(@as(u64, 6), capture.omitted());
}
