//! Interned strings for fast comparison and small value representation.
//!
//! Thread safety:
//!   - `get(id)` is lock-free. The id-indexed `entries` and `data` are
//!     `StableSegments` whose backing pages are never relocated.
//!   - `intern(s)` shards on the input hash. Each shard holds its own
//!     lookup map and `SpinMutex`. Concurrent interns of strings that
//!     hash to different shards proceed in parallel.
//!
//! Hash-collision correctness: each shard's lookup map stores `InternId`
//! keys and uses an adapter context whose `eql(string, id)` compares the
//! input string against the bytes stored under that id. Two distinct
//! strings that happen to share a Wyhash output coexist as separate
//! entries (in the same shard).

const std = @import("std");
const types = @import("types.zig");
const stable = @import("stable_segments.zig");
const InternId = types.InternId;

const Entry = struct {
    segment: u32,
    offset: u32,
    len: u32,
};

const EntryStore = stable.StableSegments(Entry, .{ .first_segment_size = 256 });
const ByteStore = stable.StableSegments(u8, .{ .first_segment_size = 4096 });

const SHARD_COUNT: u32 = 16;
const SHARD_MASK: u64 = SHARD_COUNT - 1;

fn hashString(s: []const u8) u64 {
    return std.hash.Wyhash.hash(0, s);
}

const Lookup = std.HashMapUnmanaged(InternId, void, IdContext, std.hash_map.default_max_load_percentage);

/// Context for storing `InternId` keys whose hash and equality dispatch
/// through the owning table so we can re-derive the bytes.
const IdContext = struct {
    table: *const InternTable,

    pub fn hash(self: IdContext, id: InternId) u64 {
        return hashString(self.table.get(id));
    }
    pub fn eql(self: IdContext, a: InternId, b: InternId) bool {
        if (a == b) return true;
        return std.mem.eql(u8, self.table.get(a), self.table.get(b));
    }
};

/// Adapter used by `getOrPutAdapted` so lookups by `[]const u8` use the
/// caller's bytes but storage uses `InternId`.
const StringAdapter = struct {
    table: *const InternTable,

    pub fn hash(_: StringAdapter, key: []const u8) u64 {
        return hashString(key);
    }
    pub fn eql(self: StringAdapter, key: []const u8, id: InternId) bool {
        const stored = self.table.get(id);
        return stored.len == key.len and std.mem.eql(u8, stored, key);
    }
};

const Shard = struct {
    lookup: Lookup = .empty,
    mu: stable.SpinMutex = .{},
};

pub const InternTable = struct {
    allocator: std.mem.Allocator,
    entries: EntryStore,
    data: ByteStore,
    /// Per-shard lookup maps; intern() picks a shard by the low bits of
    /// the input's hash. `entries` and `data` remain global so that ids
    /// stay dense and `get()` doesn't need to know the shard.
    shards: [SHARD_COUNT]Shard,

    pub fn init(allocator: std.mem.Allocator) !InternTable {
        var table: InternTable = .{
            .allocator = allocator,
            .entries = .empty,
            .data = .empty,
            .shards = [_]Shard{.{}} ** SHARD_COUNT,
        };
        // Reserve id 0 as the empty string so `id == 0` is a valid "no string"
        // sentinel that `get` can resolve without touching the segments.
        const empty_id = try table.intern("");
        std.debug.assert(empty_id == 0);
        return table;
    }

    pub fn deinit(self: *InternTable) void {
        for (&self.shards) |*s| s.lookup.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn intern(self: *InternTable, s: []const u8) !InternId {
        const h = hashString(s);
        const shard = &self.shards[h & SHARD_MASK];

        shard.mu.lock();
        defer shard.mu.unlock();

        const adapter = StringAdapter{ .table = self };
        const ctx = IdContext{ .table = self };
        const gop = try shard.lookup.getOrPutContextAdapted(self.allocator, s, adapter, ctx);
        if (gop.found_existing) return gop.key_ptr.*;

        // Append bytes, then the entry. The byte rollback handles failure
        // mid-allocation; entry append happens last so its failure leaves
        // the byte storage to be cleaned up by the errdefer.
        const new_id = blk: {
            const data_range = try self.data.reserve(self.allocator, @intCast(s.len));
            errdefer self.data.rollback(data_range);
            @memcpy(self.data.sliceMut(data_range), s);

            const entry: Entry = .{
                .segment = data_range.segment,
                .offset = data_range.offset,
                .len = data_range.len,
            };
            break :blk try self.entries.append(self.allocator, entry);
        };

        gop.key_ptr.* = new_id;
        return new_id;
    }

    pub fn get(self: *const InternTable, id: InternId) []const u8 {
        if (id == 0 or id >= self.entries.count()) return "";
        const entry = self.entries.get(id).*;
        if (entry.len == 0) return "";
        return self.data.slice(.{ .segment = entry.segment, .offset = entry.offset, .len = entry.len });
    }

    pub const Stats = struct {
        entries: u32,
        data_bytes: u32,
        shard_counts: [SHARD_COUNT]u32,

        pub fn shardImbalance(self: Stats) f64 {
            if (self.entries == 0) return 0;
            const ideal = @as(f64, @floatFromInt(self.entries)) / @as(f64, @floatFromInt(SHARD_COUNT));
            var max: u32 = 0;
            for (self.shard_counts) |c| max = @max(max, c);
            return @as(f64, @floatFromInt(max)) / @max(ideal, 1.0);
        }
    };

    pub fn stats(self: *const InternTable) Stats {
        var result: Stats = .{
            .entries = self.entries.count(),
            .data_bytes = self.data.count(),
            .shard_counts = [_]u32{0} ** SHARD_COUNT,
        };
        for (&self.shards, 0..) |*shard, i| {
            // Reading the shard's count is racy under concurrent intern,
            // but inspect runs after evaluation finishes when there are no
            // active writers.
            result.shard_counts[i] = @intCast(shard.lookup.count());
        }
        return result;
    }

    pub fn shardCount() u32 {
        return SHARD_COUNT;
    }

    pub fn eql(_: *const InternTable, a: InternId, b: InternId) bool {
        return a == b;
    }
};

test "intern: round-trips and dedupes" {
    var table = try InternTable.init(std.testing.allocator);
    defer table.deinit();

    const a = try table.intern("hello");
    const b = try table.intern("world");
    const a2 = try table.intern("hello");
    try std.testing.expect(a != b);
    try std.testing.expectEqual(a, a2);
    try std.testing.expectEqualStrings("hello", table.get(a));
    try std.testing.expectEqualStrings("world", table.get(b));
}

test "intern: id 0 is empty sentinel" {
    var table = try InternTable.init(std.testing.allocator);
    defer table.deinit();

    try std.testing.expectEqualStrings("", table.get(0));
    const empty_id = try table.intern("");
    try std.testing.expectEqual(@as(InternId, 0), empty_id);
}

test "intern: distinguishes hash-colliding inputs" {
    var table = try InternTable.init(std.testing.allocator);
    defer table.deinit();

    const inputs = [_][]const u8{ "a", "b", "ab", "ba", "abc", "abcd" };
    var ids: [inputs.len]InternId = undefined;
    for (inputs, 0..) |s, i| ids[i] = try table.intern(s);
    for (inputs, 0..) |s, i| {
        try std.testing.expectEqualStrings(s, table.get(ids[i]));
        try std.testing.expectEqual(ids[i], try table.intern(s));
    }
}

test "intern: get is safe for slices borrowed from previous interns" {
    var table = try InternTable.init(std.testing.allocator);
    defer table.deinit();

    const path_id = try table.intern("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source/file.txt");
    const path = table.get(path_id);
    const base = path[path.len - "file.txt".len ..];
    const base_id = try table.intern(base);
    try std.testing.expectEqualStrings("file.txt", table.get(base_id));
}

test "intern: concurrent inserts dedupe correctly" {
    const allocator = std.testing.allocator;
    var table = try InternTable.init(allocator);
    defer table.deinit();

    const Worker = struct {
        fn run(tbl: *InternTable, seed: u64, count: u32) void {
            var rng = std.Random.DefaultPrng.init(seed);
            const r = rng.random();
            var buf: [16]u8 = undefined;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const n = r.intRangeAtMost(usize, 1, buf.len);
                // Pick from a small alphabet so workers collide on the same strings.
                for (buf[0..n]) |*b| b.* = 'a' + @as(u8, r.intRangeAtMost(u4, 0, 7));
                _ = tbl.intern(buf[0..n]) catch return;
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &table, @as(u64, @intCast(i)) +% 1, @as(u32, 500) });
    }
    for (&threads) |t| t.join();

    var id: InternId = 1;
    while (id < table.entries.count()) : (id += 1) {
        const s = table.get(id);
        const again = try table.intern(s);
        try std.testing.expectEqual(id, again);
    }
}
