//! Interned strings for fast comparison and small value representation.

const std = @import("std");
const types = @import("types.zig");
const InternId = types.InternId;

const Entry = struct {
    key: InternId,
    len: u32,
    offset: u32,
};

pub const InternTable = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex,
    data: std.ArrayListUnmanaged(u8),
    entries: std.ArrayListUnmanaged(Entry),
    lookup: std.HashMapUnmanaged(u64, InternId, LookupCtx, std.hash_map.default_max_load_percentage),

    const LookupCtx = struct {
        pub fn hash(_: @This(), key: u64) u64 { return key; }
        pub fn eql(_: @This(), a: u64, b: u64) bool { return a == b; }
    };

    pub fn init(allocator: std.mem.Allocator) !InternTable {
        var table = InternTable{
            .allocator = allocator,
            .mutex = .unlocked,
            .data = .empty,
            .entries = .empty,
            .lookup = .empty,
        };
        try table.entries.append(allocator, .{ .key = 0, .len = 0, .offset = 0 });
        return table;
    }

    pub fn deinit(self: *InternTable) void {
        self.data.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.lookup.deinit(self.allocator);
    }

    pub fn intern(self: *InternTable, s: []const u8) !InternId {
        const hash = hashString(s);

        // Lock-free read path — check if already present.
        if (self.lookup.get(hash)) |id| {
            const entry = self.entries.items[id];
            const stored = self.data.items[entry.offset..][0..entry.len];
            if (stored.len == s.len and std.mem.eql(u8, stored, s)) {
                return id;
            }
        }

        // Locked insertion path.
        while (!std.atomic.Mutex.tryLock(&self.mutex)) {
            std.atomic.spinLoopHint();
        }
        defer std.atomic.Mutex.unlock(&self.mutex);

        // Double-check after acquiring lock.
        if (self.lookup.get(hash)) |id| {
            const entry = self.entries.items[id];
            const stored = self.data.items[entry.offset..][0..entry.len];
            if (stored.len == s.len and std.mem.eql(u8, stored, s)) {
                return id;
            }
        }

        const offset: u32 = @intCast(self.data.items.len);
        try self.data.appendSlice(self.allocator, s);

        const id: InternId = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, .{
            .key = id,
            .len = @intCast(s.len),
            .offset = offset,
        });

        try self.lookup.put(self.allocator, hash, id);
        return id;
    }

    pub fn get(self: *const InternTable, id: InternId) []const u8 {
        if (id == 0 or id >= self.entries.items.len) return "";
        const entry = self.entries.items[id];
        return self.data.items[entry.offset..][0..entry.len];
    }

    pub fn eql(_: *const InternTable, a: InternId, b: InternId) bool {
        return a == b;
    }

    fn hashString(s: []const u8) u64 {
        var h: u64 = 14695981039346656037;
        for (s) |c| {
            h ^= c;
            h *%= 1099511628211;
        }
        return h;
    }
};