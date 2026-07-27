//! Explicit borrowed-or-owned byte text.
//!
//! A tagged union keeps ownership and the slice carrying it in one value, so
//! callers cannot construct the contradictory states admitted by
//! `text + owned: bool`. Owning values are move-only by convention: after
//! transferring one, reset the source or use `take`.

const std = @import("std");

pub const TextRef = union(enum) {
    borrowed: []const u8,
    owned: []u8,

    pub fn slice(self: TextRef) []const u8 {
        return switch (self) {
            .borrowed => |text| text,
            .owned => |text| text,
        };
    }

    pub fn isOwned(self: TextRef) bool {
        return switch (self) {
            .borrowed => false,
            .owned => true,
        };
    }

    /// Transfer this value out and leave an inert borrowed value behind.
    pub fn take(self: *TextRef) TextRef {
        const value = self.*;
        self.* = .{ .borrowed = "" };
        return value;
    }

    pub fn deinit(self: *TextRef, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .borrowed => {},
            .owned => |text| allocator.free(text),
        }
        self.* = .{ .borrowed = "" };
    }
};

test "TextRef owns exactly its owned variant" {
    var borrowed: TextRef = .{ .borrowed = "borrowed" };
    borrowed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", borrowed.slice());

    var owned: TextRef = .{ .owned = try std.testing.allocator.dupe(u8, "owned") };
    try std.testing.expect(owned.isOwned());
    var moved = owned.take();
    try std.testing.expectEqualStrings("", owned.slice());
    try std.testing.expectEqualStrings("owned", moved.slice());
    moved.deinit(std.testing.allocator);
}
