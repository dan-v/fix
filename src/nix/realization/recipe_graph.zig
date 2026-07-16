//! Owned realization recipes, deferred fetches, and single-writer claims.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("base").sync;
const owned_strings = @import("base").owned_strings;
const runtime = @import("runtime");
const FileCache = @import("../host.zig").FileCache;

pub const SpanGroup = enum { store, source };

pub const RootClaimHook = struct {
    ctx: *anyopaque,
    observe: *const fn (ctx: *anyopaque, store_path: []const u8) void,
};

pub const PendingFetch = struct {
    url: []u8,
    name: []u8,
    recursive: bool,
    hash_hex: []u8,

    pub fn deinit(self: PendingFetch, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
        allocator.free(self.hash_hex);
    }

    pub fn clone(self: PendingFetch, allocator: std.mem.Allocator) !PendingFetch {
        const url = try allocator.dupe(u8, self.url);
        errdefer allocator.free(url);
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const hash_hex = try allocator.dupe(u8, self.hash_hex);
        return .{ .url = url, .name = name, .recursive = self.recursive, .hash_hex = hash_hex };
    }
};

pub const Recipe = struct {
    payload: Payload,
    span_group: ?SpanGroup = null,

    pub const TextPayload = struct {
        bytes: []u8,
        references: [][]u8,
    };

    pub const Payload = union(enum) {
        text: TextPayload,
        nar: []u8,
        flat: FileCache.ImmutableBytes,
    };

    pub fn deinit(self: *Recipe, allocator: std.mem.Allocator) void {
        switch (self.payload) {
            .text => |text| {
                allocator.free(text.bytes);
                owned_strings.free(allocator, text.references);
            },
            .nar => |nar_bytes| allocator.free(nar_bytes),
            .flat => |*bytes| bytes.release(),
        }
        allocator.destroy(self);
    }

    pub fn textMatches(self: *const Recipe, text: []const u8, refs: []const []const u8) bool {
        const existing = switch (self.payload) {
            .text => |payload| payload,
            else => return false,
        };
        if (!std.mem.eql(u8, existing.bytes, text) or existing.references.len != refs.len) return false;
        for (existing.references, refs) |left, right| {
            if (!std.mem.eql(u8, left, right)) return false;
        }
        return true;
    }

    pub fn narMatches(self: *const Recipe, nar_bytes: []const u8) bool {
        return switch (self.payload) {
            .nar => |existing| std.mem.eql(u8, existing, nar_bytes),
            else => false,
        };
    }

    pub fn flatMatches(self: *const Recipe, handle: FileCache.ImmutableBytes) bool {
        return switch (self.payload) {
            .flat => |existing| std.mem.eql(u8, existing.bytes(), handle.bytes()),
            else => false,
        };
    }

    pub fn references(self: *const Recipe) []const []const u8 {
        return switch (self.payload) {
            .text => |text| text.references,
            else => &.{},
        };
    }

    pub fn payloadPointer(self: *const Recipe) usize {
        return switch (self.payload) {
            .text => |text| @intFromPtr(text.bytes.ptr),
            .nar => |bytes| @intFromPtr(bytes.ptr),
            .flat => |bytes| @intFromPtr(bytes.bytes().ptr),
        };
    }
};

pub const Claim = struct {
    mu: sync.BlockingMutex = .{},
    future: runtime.future.Future = runtime.future.Future.initClaimed(runtime.future.makeClaimer(0)),
    refs: std.atomic.Value(usize) = .init(1),
    state: State = .writing,
    err: ?anyerror = null,
    waiting_on: ?*Claim = null,

    pub const State = enum { writing, success, retry, permanent_failure };

    pub fn retain(self: *Claim) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Claim, allocator: std.mem.Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        allocator.destroy(self);
    }

    pub fn publish(self: *Claim, state: State, err: ?anyerror) void {
        self.mu.lock();
        self.state = state;
        self.err = err;
        self.mu.unlock();
        self.future.publish();
    }
};

pub const RecipeVariantForTest = enum { text, nar, flat };

pub const Graph = struct {
    allocator: std.mem.Allocator,
    recipes: std.StringHashMapUnmanaged(*Recipe) = .empty,
    claims: std.StringHashMapUnmanaged(*Claim) = .empty,
    realized_outputs: std.StringHashMapUnmanaged(void) = .empty,
    pending_fetches: std.StringHashMapUnmanaged(PendingFetch) = .empty,
    mu: sync.BlockingMutex = .{},
    test_root_claim_hook: if (builtin.is_test) ?RootClaimHook else void = if (builtin.is_test) null else {},
    test_producer_payload_pointers: if (builtin.is_test) std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)) else void = if (builtin.is_test) .empty else {},

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Graph) void {
        self.releaseRecipePayloads();
        self.recipes.deinit(self.allocator);
        self.mu.lock();
        defer self.mu.unlock();
        var claims = self.claims.iterator();
        while (claims.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.release(self.allocator);
        }
        self.claims.deinit(self.allocator);
        var realized = self.realized_outputs.keyIterator();
        while (realized.next()) |key| self.allocator.free(key.*);
        self.realized_outputs.deinit(self.allocator);
        var pending = self.pending_fetches.iterator();
        while (pending.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.pending_fetches.deinit(self.allocator);
        if (comptime builtin.is_test) {
            var pointers = self.test_producer_payload_pointers.iterator();
            while (pointers.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            self.test_producer_payload_pointers.deinit(self.allocator);
        }
    }

    pub fn recordPendingFetch(self: *Graph, store_path: []const u8, url: []const u8, name: []const u8, recursive: bool, hash_hex: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.pending_fetches.contains(store_path)) return;
        const key = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(key);
        const url_copy = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(url_copy);
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const hash_copy = try self.allocator.dupe(u8, hash_hex);
        errdefer self.allocator.free(hash_copy);
        try self.pending_fetches.put(self.allocator, key, .{ .url = url_copy, .name = name_copy, .recursive = recursive, .hash_hex = hash_copy });
    }

    pub fn peekPendingFetch(self: *Graph, store_path: []const u8) !?PendingFetch {
        self.mu.lock();
        defer self.mu.unlock();
        return if (self.pending_fetches.get(store_path)) |entry| try entry.clone(self.allocator) else null;
    }

    pub fn removePendingFetch(self: *Graph, store_path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const removed = self.pending_fetches.fetchRemove(store_path) orelse return;
        self.allocator.free(removed.key);
        removed.value.deinit(self.allocator);
    }

    pub fn recordOwnedText(self: *Graph, store_path: []const u8, text: []u8, references: []const []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.recipes.get(store_path)) |recipe| {
            defer self.allocator.free(text);
            if (recipe.textMatches(text, references)) return;
            return error.RecipeConflict;
        }
        errdefer self.allocator.free(text);
        const recipe = try self.allocator.create(Recipe);
        errdefer self.allocator.destroy(recipe);
        const owned_refs = try owned_strings.clone(self.allocator, references);
        errdefer owned_strings.free(self.allocator, owned_refs);
        recipe.* = .{ .payload = .{ .text = .{ .bytes = text, .references = owned_refs } }, .span_group = .store };
        const key = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(key);
        try self.recipes.put(self.allocator, key, recipe);
    }

    pub fn recordOwnedNar(self: *Graph, store_path: []const u8, nar_bytes: []u8) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.recipes.get(store_path)) |recipe| {
            defer self.allocator.free(nar_bytes);
            if (recipe.narMatches(nar_bytes)) return;
            return error.RecipeConflict;
        }
        errdefer self.allocator.free(nar_bytes);
        const recipe = try self.allocator.create(Recipe);
        errdefer self.allocator.destroy(recipe);
        recipe.* = .{ .payload = .{ .nar = nar_bytes }, .span_group = .source };
        const key = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(key);
        try self.recipes.put(self.allocator, key, recipe);
    }

    pub fn recordFlat(self: *Graph, store_path: []const u8, handle: FileCache.ImmutableBytes, span_group: ?SpanGroup) !void {
        self.mu.lock();
        defer self.mu.unlock();
        var retained = handle.retain();
        if (self.recipes.get(store_path)) |recipe| {
            defer retained.release();
            if (recipe.flatMatches(handle)) return;
            return error.RecipeConflict;
        }
        errdefer retained.release();
        const recipe = try self.allocator.create(Recipe);
        errdefer self.allocator.destroy(recipe);
        recipe.* = .{ .payload = .{ .flat = retained }, .span_group = span_group };
        const key = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(key);
        try self.recipes.put(self.allocator, key, recipe);
    }

    pub fn releaseRecipePayloads(self: *Graph) void {
        self.mu.lock();
        defer self.mu.unlock();
        var recipes = self.recipes.iterator();
        while (recipes.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.recipes.clearRetainingCapacity();
    }
};
