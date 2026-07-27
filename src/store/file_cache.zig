//! Engine-owned filesystem cache.
//!
//! The VM talks to this cache, not directly to the host filesystem. Cold
//! reads are isolated behind `readFile`/`pathExists` so workers can use
//! the same cache without each call going to the kernel.
//!
//! Concurrency: entries are heap-allocated and pinned, so `*Entry`
//! pointers stay valid across hashmap inserts. The map mutex is held
//! only briefly around lookup/insert; per-entry state is then
//! synchronised under a per-entry mutex, so workers reading *different*
//! files do I/O in parallel and workers reading the *same* file
//! serialise on just that path's mutex (rather than the whole cache).

const std = @import("std");
const sync = @import("base").sync;
const vma = @import("runtime").mem_tag.vma;

pub const FileCache = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io,
    /// Path → heap-allocated entry. The pointer stays valid across
    /// map growth, so workers can release `map_mu` immediately after
    /// the lookup and do I/O against the entry without blocking other
    /// paths.
    entries: std.StringHashMapUnmanaged(*Entry),
    /// Protects the hashmap structure only. Held briefly during
    /// lookup / insert, never across I/O.
    map_mu: sync.BlockingMutex = .{},

    const max_read_bytes = 128 * 1024 * 1024;

    pub const FileKind = enum {
        regular,
        directory,
        symlink,
        unknown,

        pub fn nixTypeName(self: FileKind) []const u8 {
            return switch (self) {
                .regular => "regular",
                .directory => "directory",
                .symlink => "symlink",
                .unknown => "unknown",
            };
        }
    };

    pub const DirEntry = struct {
        name: []u8,
        kind: FileKind,
    };

    /// Shared ownership of an immutable byte allocation. Handles are cheap to
    /// copy explicitly with `retain`; reading the bytes does not touch the
    /// refcount.
    pub const ImmutableBytes = struct {
        blob: *Blob,

        const Blob = struct {
            allocator: std.mem.Allocator,
            refs: std.atomic.Value(usize),
            owned: []u8,
        };

        /// Takes ownership of `owned` without copying it. On blob allocation
        /// failure, ownership is still consumed and the bytes are freed.
        pub fn fromOwned(allocator: std.mem.Allocator, owned: []u8) !ImmutableBytes {
            const blob = allocator.create(Blob) catch |err| {
                allocator.free(owned);
                return err;
            };
            blob.* = .{
                .allocator = allocator,
                .refs = .init(1),
                .owned = owned,
            };
            return .{ .blob = blob };
        }

        pub fn bytes(self: ImmutableBytes) []const u8 {
            return self.blob.owned;
        }

        pub fn retain(self: ImmutableBytes) ImmutableBytes {
            const previous = self.blob.refs.fetchAdd(1, .monotonic);
            std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
            return self;
        }

        pub fn release(self: *ImmutableBytes) void {
            if (self.blob.refs.fetchSub(1, .acq_rel) != 1) return;
            const blob = self.blob;
            const allocator = blob.allocator;
            allocator.free(blob.owned);
            allocator.destroy(blob);
        }
    };

    const Entry = struct {
        path: []u8,
        /// Guards the populated-fields below. Held during I/O so a
        /// concurrent reader for the same path waits on the in-flight
        /// fetch rather than duplicating it. Different paths get
        /// different entries → different mutexes → fully parallel.
        mu: sync.BlockingMutex = .{},
        exists_known: bool = false,
        exists: bool = false,
        kind: ?FileKind = null,
        contents: ?ImmutableBytes = null,
        dir_entries: ?[]DirEntry = null,
    };

    pub fn init(allocator: std.mem.Allocator) FileCache {
        return .{
            .allocator = allocator,
            .io = null,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *FileCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |kv| {
            const entry = kv.value_ptr.*;
            self.allocator.free(entry.path);
            if (entry.contents) |*contents| contents.release();
            if (entry.dir_entries) |entries| self.freeDirEntries(entries);
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn setIo(self: *FileCache, io: std.Io) void {
        self.io = io;
    }

    pub fn pathExists(self: *FileCache, path: []const u8) !bool {
        const entry = try self.entryFor(path);
        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.exists_known) return entry.exists;

        const io = self.io orelse return error.FileIoUnavailable;
        // lstat-based existence (matching Nix): the final path component exists
        // even if it is a broken symlink, and a trailing `/`/`/.` on a
        // non-directory does not exist.
        _ = std.Io.Dir.cwd().statFile(io, entry.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                entry.exists_known = true;
                entry.exists = false;
                return false;
            },
            else => return err,
        };

        entry.exists_known = true;
        entry.exists = true;
        return true;
    }

    /// Whether `path`, following symlinks, is a directory. A trailing `/`/`/.`
    /// in `pathExists` requires a directory, and (unlike `fileType`'s lstat)
    /// must resolve a final symlink to its target.
    pub fn isDirectoryFollowing(self: *FileCache, path: []const u8) !bool {
        const io = self.io orelse return error.FileIoUnavailable;
        const entry = try self.entryFor(path);
        const stat = std.Io.Dir.cwd().statFile(io, entry.path, .{ .follow_symlinks = true }) catch return false;
        return stat.kind == .directory;
    }

    /// Trap: deliberately UNcached existence probe. Used by import-from-
    /// derivation to decide whether a demanded store path still needs building,
    /// WITHOUT memoizing the result — a path that becomes valid after an
    /// on-demand build must not be pinned to a stale `false` (as `pathExists`
    /// would). `path` must be absolute (store paths always are).
    pub fn existsUncached(self: *FileCache, path: []const u8) !bool {
        const io = self.io orelse return error.FileIoUnavailable;
        std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    pub fn readFile(self: *FileCache, path: []const u8) ![]const u8 {
        const entry = try self.entryFor(path);
        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.contents) |contents| return contents.bytes();

        const io = self.io orelse return error.FileIoUnavailable;
        // RSS attribution: cached source texts live for the evaluator's
        // lifetime — big ones (≥64 KB) get their own bucket.
        const prev_tag = vma.setAllocTag(.file_cache);
        defer _ = vma.setAllocTag(prev_tag);
        const contents = try std.Io.Dir.cwd().readFileAlloc(
            io,
            entry.path,
            self.allocator,
            .limited(max_read_bytes),
        );
        const handle = try ImmutableBytes.fromOwned(self.allocator, contents);

        entry.exists_known = true;
        entry.exists = true;
        entry.contents = handle;
        entry.kind = .regular;
        return handle.bytes();
    }

    /// Write `data` to `path` (flake lock generation). Returns
    /// `error.AccessDenied` (etc.) when the location is read-only — e.g. a flake
    /// under `/nix/store` — which the caller treats as "don't persist a lock".
    /// The caller uses the freshly generated bytes directly, so the cache is
    /// left untouched (the path was a miss anyway — no lock existed).
    pub fn writeFile(self: *FileCache, path: []const u8, data: []const u8) !void {
        const io = self.io orelse return error.FileIoUnavailable;
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    }

    /// Return a retained immutable handle for a file, populating the same
    /// cache entry used by `readFile` on a cold miss.
    pub fn retainFile(self: *FileCache, path: []const u8) !ImmutableBytes {
        const entry = try self.entryFor(path);
        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.contents) |contents| return contents.retain();

        const io = self.io orelse return error.FileIoUnavailable;
        const prev_tag = vma.setAllocTag(.file_cache);
        defer _ = vma.setAllocTag(prev_tag);
        const owned = try std.Io.Dir.cwd().readFileAlloc(
            io,
            entry.path,
            self.allocator,
            .limited(max_read_bytes),
        );
        const handle = try ImmutableBytes.fromOwned(self.allocator, owned);

        entry.exists_known = true;
        entry.exists = true;
        entry.contents = handle;
        entry.kind = .regular;
        return handle.retain();
    }

    /// Seed the cache so `path` resolves to `contents` as a regular file,
    /// without touching the host filesystem. Used to make a fixed-output store
    /// path readable in storeless eval — its bytes are already known from the
    /// fetch — so `builtins.readFile`/`readFileType` on a `fetchurl` result
    /// behave as they would against Nix's realized store. A no-op if the entry
    /// is already populated.
    pub fn provideRegular(self: *FileCache, path: []const u8, contents: ImmutableBytes) !void {
        const entry = try self.entryFor(path);
        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.contents != null) return;
        entry.contents = contents.retain();
        entry.exists_known = true;
        entry.exists = true;
        entry.kind = .regular;
    }

    pub fn fileType(self: *FileCache, path: []const u8) !FileKind {
        const entry = try self.entryFor(path);
        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.kind) |kind| return kind;

        const io = self.io orelse return error.FileIoUnavailable;
        const stat = std.Io.Dir.cwd().statFile(io, entry.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                entry.exists_known = true;
                entry.exists = false;
                return err;
            },
            else => return err,
        };
        const kind = fileKindFromStd(stat.kind);
        entry.exists_known = true;
        entry.exists = true;
        entry.kind = kind;
        return kind;
    }

    /// Trap: deliberately UNcached. Unlike `readFile`/`fileType`/`readDir`,
    /// this does not take the per-entry mutex or memoize on the `Entry`; it
    /// stats the file fresh on every call.
    pub fn isExecutable(self: *FileCache, path: []const u8) !bool {
        const entry = try self.entryFor(path);
        const io = self.io orelse return error.FileIoUnavailable;
        const stat = try std.Io.Dir.cwd().statFile(io, entry.path, .{ .follow_symlinks = false });
        return @TypeOf(stat.permissions).has_executable_bit and stat.permissions.toMode() & 0o111 != 0;
    }

    /// Trap: deliberately UNcached. Unlike `readFile`/`fileType`/`readDir`,
    /// this does not take the per-entry mutex or memoize on the `Entry`; it
    /// re-reads the symlink target fresh on every call and returns a newly
    /// allocated copy the caller owns.
    pub fn readLink(self: *FileCache, path: []const u8) ![]u8 {
        const entry = try self.entryFor(path);
        const io = self.io orelse return error.FileIoUnavailable;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try std.Io.Dir.readLinkAbsolute(io, entry.path, &buffer);
        return self.allocator.dupe(u8, buffer[0..len]);
    }

    pub fn readDir(self: *FileCache, path: []const u8) ![]const DirEntry {
        return self.readDirCold(path, null);
    }

    /// `readDir` that also reports whether THIS call did the I/O (a cold
    /// miss) vs returning the cached listing. Exactly one caller observes
    /// `cold = true` per path — concurrent readers of the same path
    /// serialise on the entry mutex and see the populated cache. Used by
    /// the readDir-children prefetch hook to fire once per directory.
    pub fn readDirCold(self: *FileCache, path: []const u8, cold: ?*bool) ![]const DirEntry {
        const entry = try self.entryFor(path);
        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.dir_entries) |entries| return entries;
        if (cold) |c| c.* = true;

        const io = self.io orelse return error.FileIoUnavailable;
        var dir = try std.Io.Dir.cwd().openDir(io, entry.path, .{ .iterate = true });
        defer dir.close(io);

        var owned_entries: std.ArrayListUnmanaged(DirEntry) = .empty;
        errdefer {
            self.freeDirEntries(owned_entries.items);
            owned_entries.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (try iter.next(io)) |dir_entry| {
            const name = try self.allocator.dupe(u8, dir_entry.name);
            owned_entries.append(self.allocator, .{
                .name = name,
                .kind = fileKindFromStd(dir_entry.kind),
            }) catch |err| {
                self.allocator.free(name);
                return err;
            };
        }

        entry.exists_known = true;
        entry.exists = true;
        entry.kind = .directory;
        entry.dir_entries = try owned_entries.toOwnedSlice(self.allocator);
        return entry.dir_entries.?;
    }

    fn entryFor(self: *FileCache, path: []const u8) !*Entry {
        self.map_mu.lock();
        if (self.entries.get(path)) |entry| {
            self.map_mu.unlock();
            return entry;
        }
        // We need to insert. Hold the map mutex through canonicalise +
        // alloc + insert; releasing in the middle would let another
        // worker race in with the same path, and we'd both allocate
        // entries.
        defer self.map_mu.unlock();

        const canonical = try self.canonicalPath(path);
        errdefer self.allocator.free(canonical);

        // Recheck under the lock — `path` and the canonical form may
        // differ, and another worker could have inserted the
        // canonical key while we were normalising.
        if (self.entries.get(canonical)) |entry| {
            self.allocator.free(canonical);
            return entry;
        }

        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .path = canonical };

        try self.entries.put(self.allocator, canonical, entry);
        return entry;
    }

    fn canonicalPath(self: *FileCache, path: []const u8) ![]u8 {
        if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
        if (!needsNormalize(path)) return self.allocator.dupe(u8, path);
        return std.fs.path.resolve(self.allocator, &.{path});
    }

    fn needsNormalize(path: []const u8) bool {
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return true;
        }
        return false;
    }

    fn freeDirEntries(self: *FileCache, entries: []DirEntry) void {
        for (entries) |dir_entry| self.allocator.free(dir_entry.name);
        self.allocator.free(entries);
    }

    fn fileKindFromStd(kind: std.Io.File.Kind) FileKind {
        return switch (kind) {
            .file => .regular,
            .directory => .directory,
            .sym_link => .symlink,
            else => .unknown,
        };
    }
};

const CountingAllocator = struct {
    child: std.mem.Allocator,
    tracked_payload_ptr: std.atomic.Value(usize) = .init(0),
    payload_free_count: std.atomic.Value(usize) = .init(0),

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn trackPayload(self: *CountingAllocator, payload: []u8) void {
        std.debug.assert(self.tracked_payload_ptr.load(.seq_cst) == 0);
        self.tracked_payload_ptr.store(@intFromPtr(payload.ptr), .seq_cst);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const is_payload = @intFromPtr(buf.ptr) == self.tracked_payload_ptr.load(.seq_cst);
        self.child.rawFree(buf, alignment, ret_addr);
        if (is_payload) _ = self.payload_free_count.fetchAdd(1, .monotonic);
    }
};

fn makeOwnedBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const owned = try allocator.alloc(u8, bytes.len);
    @memcpy(owned, bytes);
    return owned;
}

fn hammerRetainRelease(shared: *FileCache.ImmutableBytes, iterations: usize) void {
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var retained = shared.retain();
        std.debug.assert(std.mem.eql(u8, retained.bytes(), "thread-safe"));
        retained.release();
    }
}

test "FileCache.ImmutableBytes.fromOwned preserves pointer and frees once" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const payload_allocator = counting.allocator();
    const original = "payload-transfer";
    const owned = try makeOwnedBytes(payload_allocator, original);
    const original_ptr = @intFromPtr(owned.ptr);
    counting.trackPayload(owned);

    var payload = try FileCache.ImmutableBytes.fromOwned(payload_allocator, owned);
    try std.testing.expectEqual(original_ptr, @intFromPtr(payload.bytes().ptr));
    try std.testing.expectEqualStrings(original, payload.bytes());
    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));

    payload.release();
    try std.testing.expectEqual(@as(usize, 1), counting.payload_free_count.load(.seq_cst));
}

test "FileCache.ImmutableBytes retain release holds bytes until final release" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const payload_allocator = counting.allocator();
    const original = "retained-payload";
    const owned = try makeOwnedBytes(payload_allocator, original);
    const original_ptr = @intFromPtr(owned.ptr);
    counting.trackPayload(owned);

    var payload = try FileCache.ImmutableBytes.fromOwned(payload_allocator, owned);
    var retained = payload.retain();

    try std.testing.expectEqual(original_ptr, @intFromPtr(payload.bytes().ptr));
    try std.testing.expectEqual(@intFromPtr(payload.bytes().ptr), @intFromPtr(retained.bytes().ptr));
    payload.release();
    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));
    try std.testing.expectEqualStrings(original, retained.bytes());

    retained.release();
    try std.testing.expectEqual(@as(usize, 1), counting.payload_free_count.load(.seq_cst));
}

test "FileCache aliases share blob pointers and metadata" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const payload_allocator = counting.allocator();
    var cache = FileCache.init(std.testing.allocator);
    const original = "shared-alias-payload";
    const owned = try makeOwnedBytes(payload_allocator, original);
    const original_ptr = @intFromPtr(owned.ptr);
    counting.trackPayload(owned);

    var payload = try FileCache.ImmutableBytes.fromOwned(payload_allocator, owned);
    var alias_seed = payload.retain();

    try cache.provideRegular("/virtual/cache-alpha", payload);
    try cache.provideRegular("/virtual/cache-beta", alias_seed);
    payload.release();
    alias_seed.release();
    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));

    try std.testing.expect(try cache.pathExists("/virtual/cache-alpha"));
    try std.testing.expect(try cache.pathExists("/virtual/cache-beta"));
    try std.testing.expectEqual(FileCache.FileKind.regular, try cache.fileType("/virtual/cache-alpha"));
    try std.testing.expectEqual(FileCache.FileKind.regular, try cache.fileType("/virtual/cache-beta"));

    const alpha_read = try cache.readFile("/virtual/cache-alpha");
    const beta_read = try cache.readFile("/virtual/cache-beta");
    try std.testing.expectEqual(original_ptr, @intFromPtr(alpha_read.ptr));
    try std.testing.expectEqual(@intFromPtr(alpha_read.ptr), @intFromPtr(beta_read.ptr));
    try std.testing.expectEqualStrings(original, alpha_read);
    try std.testing.expectEqualStrings(original, beta_read);

    var retained_alpha = try cache.retainFile("/virtual/cache-alpha");
    var retained_beta = try cache.retainFile("/virtual/cache-beta");
    try std.testing.expectEqual(original_ptr, @intFromPtr(retained_alpha.bytes().ptr));
    try std.testing.expectEqual(@intFromPtr(retained_alpha.bytes().ptr), @intFromPtr(retained_beta.bytes().ptr));

    retained_alpha.release();
    retained_beta.release();
    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));
    cache.deinit();
    try std.testing.expectEqual(@as(usize, 1), counting.payload_free_count.load(.seq_cst));
}

test "FileCache.ImmutableBytes concurrent retain release frees once" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const payload_allocator = counting.allocator();
    const owned = try makeOwnedBytes(payload_allocator, "thread-safe");
    const original_ptr = @intFromPtr(owned.ptr);
    counting.trackPayload(owned);
    var payload = try FileCache.ImmutableBytes.fromOwned(payload_allocator, owned);
    try std.testing.expectEqual(original_ptr, @intFromPtr(payload.bytes().ptr));

    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, hammerRetainRelease, .{ &payload, 2_000 + index });
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));
    payload.release();
    try std.testing.expectEqual(@as(usize, 1), counting.payload_free_count.load(.seq_cst));
}

test "FileCache provideRegular idempotent seeding preserves payload pointer without leaks" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const payload_allocator = counting.allocator();
    var cache = FileCache.init(std.testing.allocator);
    const original = "idempotent-payload";
    const owned = try makeOwnedBytes(payload_allocator, original);
    const original_ptr = @intFromPtr(owned.ptr);
    counting.trackPayload(owned);

    var payload = try FileCache.ImmutableBytes.fromOwned(payload_allocator, owned);
    var duplicate_seed = payload.retain();

    try cache.provideRegular("/virtual/cache-dup", payload);
    try cache.provideRegular("/virtual/cache-dup", duplicate_seed);
    payload.release();
    duplicate_seed.release();
    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));

    const read_back = try cache.readFile("/virtual/cache-dup");
    try std.testing.expectEqual(original_ptr, @intFromPtr(read_back.ptr));
    try std.testing.expectEqualStrings(original, read_back);

    var retained = try cache.retainFile("/virtual/cache-dup");
    try std.testing.expectEqual(original_ptr, @intFromPtr(retained.bytes().ptr));
    retained.release();

    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));
    cache.deinit();
    try std.testing.expectEqual(@as(usize, 1), counting.payload_free_count.load(.seq_cst));
}
