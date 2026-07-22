//! Demand-committed language effects (`trace`, `warn`, ...).
//!
//! Speculative evaluation may compute a thunk before a real caller observes
//! it.  Effect records discovered while doing that work are grouped and
//! published with the thunk/import result.  A later speculative consumer
//! propagates the same record pointers into its own group; a real consumer
//! atomically fires them.  Sharing the record (rather than copying it) makes
//! the effect happen exactly once whichever demanded ancestor reaches it
//! first.

const std = @import("std");
const SpinMutex = @import("base").sync.SpinMutex;

pub const Kind = enum {
    trace,
    warning,
};

/// Application-provided effect output.  `emit_fn` may be called concurrently
/// by independent demanded evaluator fibers and must synchronize its target.
pub const Sink = struct {
    context: ?*anyopaque = null,
    emit_fn: ?*const fn (?*anyopaque, Kind, []const u8) void = null,

    pub fn emit(self: Sink, kind: Kind, message: []const u8) void {
        const emit_fn = self.emit_fn orelse return;
        emit_fn(self.context, kind, message);
    }
};

pub const Record = struct {
    fired: std.atomic.Value(u8) = .init(0),
    kind: Kind,
    message: []const u8,
};

pub const Journal = std.ArrayListUnmanaged(*Record);

pub const GroupId = u32;
pub const no_group: GroupId = 0;

pub const Store = struct {
    allocator: std.mem.Allocator,
    mu: SpinMutex = .{},
    sink: Sink = .{},
    records: std.ArrayListUnmanaged(*Record) = .empty,
    /// GroupId is index + 1. Group backing slices are immutable after they are
    /// published, so readers only need the mutex while copying the descriptor.
    groups: std.ArrayListUnmanaged([]*Record) = .empty,
    stderr_io: ?std.Io = null,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.groups.items) |group| self.allocator.free(group);
        self.groups.deinit(self.allocator);
        for (self.records.items) |record| {
            self.allocator.free(record.message);
            self.allocator.destroy(record);
        }
        self.records.deinit(self.allocator);
    }

    pub fn setSink(self: *Store, sink: Sink) void {
        // Configuration is changed only while the evaluator is quiescent.
        self.sink = sink;
    }

    /// Install the ordinary CLI stderr sink. Keeping the `std.Io` value in the
    /// evaluator avoids a callback context pointing into a command's stack.
    pub fn setStderr(self: *Store, io: std.Io) void {
        self.stderr_io = io;
        self.sink = .{ .context = self, .emit_fn = emitStderr };
    }

    pub fn emitNow(self: *Store, kind: Kind, message: []const u8) void {
        self.sink.emit(kind, message);
    }

    /// Allocate an unfired record and append it to a speculative fiber's
    /// journal. The Store owns the record; the journal only borrows it.
    pub fn hold(self: *Store, journal: *Journal, journal_allocator: std.mem.Allocator, kind: Kind, message: []const u8) !void {
        const record = try self.allocator.create(Record);
        errdefer self.allocator.destroy(record);
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);
        record.* = .{ .kind = kind, .message = owned_message };

        self.mu.lock();
        self.records.ensureUnusedCapacity(self.allocator, 1) catch |err| {
            self.mu.unlock();
            return err;
        };
        journal.append(journal_allocator, record) catch |err| {
            self.mu.unlock();
            return err;
        };
        self.records.appendAssumeCapacity(record);
        self.mu.unlock();
    }

    /// Freeze a journal suffix into an immutable group. Duplicate pointers can
    /// arise when a shared effect-bearing child is used more than once; remove
    /// them here to keep ancestor groups compact.
    pub fn makeGroup(self: *Store, records: []const *Record) !GroupId {
        if (records.len == 0) return no_group;

        var group = try self.allocator.alloc(*Record, records.len);
        errdefer self.allocator.free(group);
        var len: usize = 0;
        for (records) |record| {
            var seen = false;
            for (group[0..len]) |prior| {
                if (prior == record) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                group[len] = record;
                len += 1;
            }
        }
        if (len != group.len) {
            const exact = try self.allocator.alloc(*Record, len);
            @memcpy(exact, group[0..len]);
            self.allocator.free(group);
            group = exact;
        }

        self.mu.lock();
        defer self.mu.unlock();
        if (self.groups.items.len == std.math.maxInt(GroupId)) return error.OutOfMemory;
        try self.groups.append(self.allocator, group);
        return @intCast(self.groups.items.len);
    }

    /// Observe a published group. Genuine demand fires each record once;
    /// speculative observation propagates each still-unfired record into the
    /// current journal so a demanded ancestor can commit it later. Returns true
    /// when an unfired effect was emitted or propagated.
    pub fn observe(
        self: *Store,
        group_id: GroupId,
        demand: bool,
        journal: *Journal,
        journal_allocator: std.mem.Allocator,
    ) !bool {
        if (group_id == no_group) return false;
        self.mu.lock();
        const index: usize = group_id - 1;
        const group = if (index < self.groups.items.len) self.groups.items[index] else &.{};
        self.mu.unlock();

        var touched = false;
        if (demand) {
            for (group) |record| {
                if (record.fired.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
                    touched = true;
                    self.sink.emit(record.kind, record.message);
                }
            }
        } else {
            for (group) |record| {
                if (record.fired.load(.acquire) != 0) continue;
                try journal.append(journal_allocator, record);
                touched = true;
            }
        }
        return touched;
    }

    fn emitStderr(raw: ?*anyopaque, kind: Kind, message: []const u8) void {
        const self: *Store = @ptrCast(@alignCast(raw.?));
        const io = self.stderr_io orelse return;
        var buffer: [4096]u8 = undefined;
        var locked = io.lockStderr(&buffer, null) catch return;
        defer io.unlockStderr();
        const writer = &locked.file_writer.interface;
        writer.print("{s}: {s}\n", .{ switch (kind) {
            .trace => "trace",
            .warning => "warning",
        }, message }) catch return;
        writer.flush() catch {};
    }
};

test "effect records shared by groups fire only once" {
    const Capture = struct {
        count: usize = 0,
        fn emit(raw: ?*anyopaque, _: Kind, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.count += 1;
        }
    };
    var capture: Capture = .{};
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    store.setSink(.{ .context = &capture, .emit_fn = Capture.emit });
    var journal: Journal = .empty;
    defer journal.deinit(std.testing.allocator);
    try store.hold(&journal, std.testing.allocator, .trace, "once");
    const first = try store.makeGroup(journal.items);
    const second = try store.makeGroup(journal.items);
    try std.testing.expect(try store.observe(first, true, &journal, std.testing.allocator));
    try std.testing.expect(!(try store.observe(second, true, &journal, std.testing.allocator)));
    try std.testing.expectEqual(@as(usize, 1), capture.count);
}
