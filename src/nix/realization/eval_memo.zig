//! Evaluation-local memoization for lazy derivations and source ingestion.

const std = @import("std");
const stable = @import("base").sync;

const source_ingest_stripes = 64;

const LazyDrvEntry = struct { token: u64, bits: u64 };
const SourceMemoEntry = struct { store_path: []u8, nar_hash: []u8, token: u64 };

pub const SourceMemoHit = struct { store_path: []u8, nar_hash: []u8 };

pub const EvalMemo = struct {
    allocator: std.mem.Allocator,
    lazy_drv_cache: std.AutoHashMapUnmanaged(u32, LazyDrvEntry) = .empty,
    lazy_drv_mu: stable.SpinMutex = .{},
    source_memo: std.StringHashMapUnmanaged(SourceMemoEntry) = .empty,
    source_memo_mu: stable.SpinMutex = .{},
    source_ingest_locks: [source_ingest_stripes]stable.BlockingMutex = @splat(.{}),

    pub fn init(allocator: std.mem.Allocator) EvalMemo {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EvalMemo) void {
        self.lazy_drv_cache.deinit(self.allocator);
        var source_entries = self.source_memo.iterator();
        while (source_entries.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.store_path);
            self.allocator.free(entry.value_ptr.nar_hash);
        }
        self.source_memo.deinit(self.allocator);
    }

    fn sourceKey(
        allocator: std.mem.Allocator,
        path: []const u8,
        name: []const u8,
        recursive: bool,
        filter_id: ?u32,
    ) ![]u8 {
        const rf: u8 = if (recursive) 'r' else 'f';
        if (filter_id) |fid| {
            return std.fmt.allocPrint(allocator, "{c}{s}\x00{s}\x00{d}", .{ rf, name, path, fid });
        }
        return std.fmt.allocPrint(allocator, "{c}{s}\x00{s}", .{ rf, name, path });
    }

    pub fn sourceIngestLock(self: *EvalMemo, path: []const u8, name: []const u8) *stable.BlockingMutex {
        var hash = std.hash.Wyhash.init(0);
        hash.update(path);
        hash.update(&[_]u8{0});
        hash.update(name);
        return &self.source_ingest_locks[hash.final() % source_ingest_stripes];
    }

    pub fn lookupSource(
        self: *EvalMemo,
        out_allocator: std.mem.Allocator,
        path: []const u8,
        name: []const u8,
        recursive: bool,
        filter_id: ?u32,
        token: ?u64,
    ) !?SourceMemoHit {
        const key = try sourceKey(self.allocator, path, name, recursive, filter_id);
        defer self.allocator.free(key);
        self.source_memo_mu.lock();
        defer self.source_memo_mu.unlock();
        const entry = self.source_memo.get(key) orelse return null;
        if (token) |expected| if (entry.token != expected) return null;
        const store_path = try out_allocator.dupe(u8, entry.store_path);
        errdefer out_allocator.free(store_path);
        const nar_hash = try out_allocator.dupe(u8, entry.nar_hash);
        return .{ .store_path = store_path, .nar_hash = nar_hash };
    }

    pub fn storeSource(
        self: *EvalMemo,
        path: []const u8,
        name: []const u8,
        recursive: bool,
        filter_id: ?u32,
        token: u64,
        store_path: []const u8,
        nar_hash: []const u8,
    ) !void {
        const key = try sourceKey(self.allocator, path, name, recursive, filter_id);
        errdefer self.allocator.free(key);
        const owned_store_path = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(owned_store_path);
        const owned_nar_hash = try self.allocator.dupe(u8, nar_hash);
        errdefer self.allocator.free(owned_nar_hash);

        self.source_memo_mu.lock();
        defer self.source_memo_mu.unlock();
        const gop = try self.source_memo.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(key);
            const stale = filter_id != null and gop.value_ptr.token != token;
            if (!stale) {
                self.allocator.free(owned_store_path);
                self.allocator.free(owned_nar_hash);
                return;
            }
            self.allocator.free(gop.value_ptr.store_path);
            self.allocator.free(gop.value_ptr.nar_hash);
        }
        gop.value_ptr.* = .{ .store_path = owned_store_path, .nar_hash = owned_nar_hash, .token = token };
    }

    pub fn lookupLazyDerivation(self: *EvalMemo, attrs_id: u32, token: u64) ?u64 {
        self.lazy_drv_mu.lock();
        defer self.lazy_drv_mu.unlock();
        const entry = self.lazy_drv_cache.get(attrs_id) orelse return null;
        return if (entry.token == token) entry.bits else null;
    }

    pub fn cacheLazyDerivation(self: *EvalMemo, attrs_id: u32, token: u64, value_bits: u64) !void {
        self.lazy_drv_mu.lock();
        defer self.lazy_drv_mu.unlock();
        try self.lazy_drv_cache.put(self.allocator, attrs_id, .{ .token = token, .bits = value_bits });
    }

    pub fn visitLiveLazyValues(self: *EvalMemo, token: u64, context: anytype, comptime visit: anytype) void {
        self.lazy_drv_mu.lock();
        defer self.lazy_drv_mu.unlock();
        var entries = self.lazy_drv_cache.iterator();
        while (entries.next()) |entry| {
            if (entry.value_ptr.token == token) visit(context, entry.value_ptr.bits);
        }
    }
};
