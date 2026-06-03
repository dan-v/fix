//! Evaluation error messages and Nix-style error contexts.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");

pub const Trace = struct {
    pub const Frame = struct {
        message: []u8,
        diagnostic: ?diagnostic.Diagnostic = null,
        source_path: ?[]u8 = null,

        fn deinit(self: Frame, allocator: std.mem.Allocator) void {
            allocator.free(self.message);
            if (self.source_path) |path| allocator.free(path);
        }
    };

    allocator: std.mem.Allocator,
    message: ?[]u8 = null,
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    captured_stack: bool = false,

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
        for (self.frames.items) |frame| frame.deinit(self.allocator);
        self.frames.clearRetainingCapacity();
        self.captured_stack = false;
    }

    pub fn setMessage(self: *Trace, message: []const u8) !void {
        const owned = try self.allocator.dupe(u8, message);
        if (self.message) |old| self.allocator.free(old);
        self.message = owned;
    }

    pub fn setMessageIfAbsent(self: *Trace, message: []const u8) !void {
        if (self.message != null) return;
        try self.setMessage(message);
    }

    pub fn pushFrame(self: *Trace, frame: []const u8) !void {
        try self.frames.append(self.allocator, .{
            .message = try self.allocator.dupe(u8, frame),
        });
    }

    pub fn pushDiagnosticFrame(self: *Trace, source_path: ?[]const u8, frame: diagnostic.Diagnostic) !void {
        const message = try self.allocator.dupe(u8, frame.message);
        errdefer self.allocator.free(message);
        const owned_path = if (source_path) |path| try self.allocator.dupe(u8, path) else null;
        errdefer if (owned_path) |path| self.allocator.free(path);

        var owned_frame = frame;
        owned_frame.message = message;
        try self.frames.append(self.allocator, .{
            .message = message,
            .diagnostic = owned_frame,
            .source_path = owned_path,
        });
    }

    pub fn markCapturedStack(self: *Trace) void {
        self.captured_stack = true;
    }

    pub fn frameCount(self: *const Trace) usize {
        return self.frames.items.len;
    }
};
