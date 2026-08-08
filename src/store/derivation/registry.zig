//! Thread-safe registry of evaluated derivations.
//!
//! This is deterministic language/domain state: hash-modulo resolution,
//! output-name lookup, and optional derivation debug records. Store recipes,
//! source ingestion, daemon connections, and builds belong to `realization`.

const std = @import("std");
const sync = @import("base").sync;
const debug_record_mod = @import("debug_record.zig");
const drv_mod = @import("drv.zig");
const types = @import("types.zig");
const clone = @import("clone.zig");

const ComputedPaths = types.ComputedPaths;
const DebugRecord = types.DebugRecord;
const Drv = drv_mod.Drv;
const DrvOutput = types.DrvOutput;
const HashModulo = types.HashModulo;
const HashModuloResolver = types.HashModuloResolver;
const HashModuloView = types.HashModuloView;

pub const Registry = struct {
    allocator: std.mem.Allocator,
    records: std.StringHashMapUnmanaged(Record) = .empty,
    debug_enabled: bool = false,
    debug_records: std.ArrayListUnmanaged(DebugRecord) = .empty,
    mu: sync.BlockingMutex = .{},

    const Record = struct {
        hash_modulo: HashModulo,
        outputs: []const []const u8,

        fn deinit(self: Record, allocator: std.mem.Allocator) void {
            self.hash_modulo.deinit(allocator);
            for (self.outputs) |output| allocator.free(output);
            allocator.free(self.outputs);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.clearDebugRecords();
        self.debug_records.deinit(self.allocator);
        var it = self.records.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.records.deinit(self.allocator);
    }

    pub fn setDebugEnabled(self: *Registry, enabled: bool) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.debug_enabled = enabled;
        if (!enabled) self.clearDebugRecordsLocked();
    }

    pub fn debugEnabled(self: *Registry) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.debug_enabled;
    }

    pub fn clearDebugRecords(self: *Registry) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.clearDebugRecordsLocked();
    }

    fn clearDebugRecordsLocked(self: *Registry) void {
        for (self.debug_records.items) |debug_record| debug_record.deinit(self.allocator);
        self.debug_records.clearRetainingCapacity();
    }

    pub fn debugRecords(self: *const Registry) []const DebugRecord {
        return self.debug_records.items;
    }

    /// One exported record for cross-engine carry-over (see `exportRecords`).
    pub const ExportedRecord = struct {
        drv_path: []u8,
        hash_modulo: HashModulo,
        outputs: []const []const u8,

        pub fn deinit(self: ExportedRecord, allocator: std.mem.Allocator) void {
            allocator.free(self.drv_path);
            self.hash_modulo.deinit(allocator);
            for (self.outputs) |output| allocator.free(output);
            allocator.free(self.outputs);
        }
    };

    /// Snapshot every record into `allocator`-owned memory. Hash-modulo
    /// facts are pure functions of derivation content, so a driver that
    /// recycles whole engines (`--max-memory-size`) can carry them across
    /// and `seedExported` the next engine — cross-epoch derivation
    /// references (aggregate rewrites) then resolve without the original
    /// engine's in-memory graph.
    pub fn exportRecords(self: *Registry, allocator: std.mem.Allocator) ![]ExportedRecord {
        self.mu.lock();
        defer self.mu.unlock();
        const out = try allocator.alloc(ExportedRecord, self.records.count());
        var done: usize = 0;
        errdefer {
            for (out[0..done]) |r| r.deinit(allocator);
            allocator.free(out);
        }
        var it = self.records.iterator();
        while (it.next()) |entry| {
            const view: HashModuloView = switch (entry.value_ptr.hash_modulo) {
                .drv => |hash| .{ .drv = hash },
                .outputs => |outputs| .{ .outputs = outputs },
            };
            const hash_modulo = try clone.cloneHashModulo(allocator, view);
            errdefer hash_modulo.deinit(allocator);
            const names = try allocator.alloc([]const u8, entry.value_ptr.outputs.len);
            var names_done: usize = 0;
            errdefer {
                for (names[0..names_done]) |name| allocator.free(name);
                allocator.free(names);
            }
            for (entry.value_ptr.outputs) |name| {
                names[names_done] = try allocator.dupe(u8, name);
                names_done += 1;
            }
            out[done] = .{
                .drv_path = try allocator.dupe(u8, entry.key_ptr.*),
                .hash_modulo = hash_modulo,
                .outputs = names,
            };
            done += 1;
        }
        return out;
    }

    /// Bulk-install carried-over records (idempotent per path; existing
    /// entries win — they were computed by THIS engine).
    pub fn seedExported(self: *Registry, records: []const ExportedRecord) !void {
        for (records) |exported| {
            const view: HashModuloView = switch (exported.hash_modulo) {
                .drv => |hash| .{ .drv = hash },
                .outputs => |outputs| .{ .outputs = outputs },
            };
            const value: Record = blk: {
                const cloned_hash_modulo = try clone.cloneHashModulo(self.allocator, view);
                errdefer cloned_hash_modulo.deinit(self.allocator);
                const names = try self.allocator.alloc([]const u8, exported.outputs.len);
                var names_done: usize = 0;
                errdefer {
                    for (names[0..names_done]) |name| self.allocator.free(name);
                    self.allocator.free(names);
                }
                for (exported.outputs) |name| {
                    names[names_done] = try self.allocator.dupe(u8, name);
                    names_done += 1;
                }
                break :blk .{ .hash_modulo = cloned_hash_modulo, .outputs = names };
            };
            self.mu.lock();
            defer self.mu.unlock();
            if (self.records.contains(exported.drv_path)) {
                value.deinit(self.allocator);
                continue;
            }
            const key = self.allocator.dupe(u8, exported.drv_path) catch |err| {
                value.deinit(self.allocator);
                return err;
            };
            self.records.put(self.allocator, key, value) catch |err| {
                self.allocator.free(key);
                value.deinit(self.allocator);
                return err;
            };
        }
    }

    pub fn resolver(self: *Registry, store_dir: []const u8) HashModuloResolver {
        return .{ .store_dir = store_dir, .context = self, .resolve = resolveHashModulo };
    }

    pub fn record(self: *Registry, drv_path: []const u8, hash_modulo: HashModuloView, outputs: []const DrvOutput) !void {
        {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.records.contains(drv_path)) return;
        }

        const value: Record = blk: {
            const cloned_hash_modulo = try clone.cloneHashModulo(self.allocator, hash_modulo);
            errdefer cloned_hash_modulo.deinit(self.allocator);
            const cloned_outputs = try clone.cloneOutputNames(self.allocator, outputs);
            errdefer clone.freeOutputNames(self.allocator, cloned_outputs);
            break :blk .{ .hash_modulo = cloned_hash_modulo, .outputs = cloned_outputs };
        };

        self.mu.lock();
        defer self.mu.unlock();
        if (self.records.contains(drv_path)) {
            value.deinit(self.allocator);
            return;
        }
        const key = try self.allocator.dupe(u8, drv_path);
        errdefer self.allocator.free(key);
        try self.records.put(self.allocator, key, value);
    }

    pub fn recordDebug(self: *Registry, store_dir: []const u8, drv: *const Drv, computed: ComputedPaths) !void {
        self.mu.lock();
        const enabled = self.debug_enabled;
        self.mu.unlock();
        if (!enabled) return;

        var new_record = try debug_record_mod.debugRecordFromDrv(self.allocator, drv, computed.drv_path, self.resolver(store_dir));
        errdefer new_record.deinit(self.allocator);

        self.mu.lock();
        defer self.mu.unlock();
        try self.debug_records.append(self.allocator, new_record);
    }

    pub fn outputNames(self: *Registry, drv_path: []const u8) ?[]const []const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        return (self.records.getPtr(drv_path) orelse return null).outputs;
    }

    fn resolveHashModulo(context: *anyopaque, drv_path: []const u8) anyerror!?HashModuloView {
        const self: *Registry = @ptrCast(@alignCast(context));
        self.mu.lock();
        defer self.mu.unlock();
        return (self.records.getPtr(drv_path) orelse return null).hash_modulo.view();
    }
};
