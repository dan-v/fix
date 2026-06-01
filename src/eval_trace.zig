//! Evaluation error messages and Nix-style error contexts.

const std = @import("std");

pub const Trace = struct {
    allocator: std.mem.Allocator,
    message: ?[]u8 = null,
    frames: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Trace {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Trace) void {
        self.clear();
        self.frames.deinit(self.allocator);
    }

    pub fn clear(self: *Trace) void {
        if (self.message) |message| self.allocator.free(message);
        self.message = null;
        for (self.frames.items) |frame| self.allocator.free(frame);
        self.frames.clearRetainingCapacity();
    }

    pub fn setMessage(self: *Trace, message: []const u8) !void {
        const owned = try self.allocator.dupe(u8, message);
        if (self.message) |old| self.allocator.free(old);
        self.message = owned;
    }

    pub fn pushFrame(self: *Trace, frame: []const u8) !void {
        try self.frames.append(self.allocator, try self.allocator.dupe(u8, frame));
    }

    pub fn frameCount(self: *const Trace) usize {
        return self.frames.items.len;
    }
};
