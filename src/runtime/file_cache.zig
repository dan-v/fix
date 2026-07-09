//! Evaluator-owned filesystem cache.
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
//! For a NixOS toplevel eval — hundreds of imports across helper
//! workers — this is the difference between file I/O being a
//! single-file-at-a-time pipeline and a fan-out.

const std = @import("std");
const stable = @import("stable_segments.zig");
const vma = @import("mem_tag.zig").vma;

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
    map_mu: stable.BlockingMutex = .{},

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

    const Entry = struct {
        path: []u8,
        /// Guards the populated-fields below. Held during I/O so a
        /// concurrent reader for the same path waits on the in-flight
        /// fetch rather than duplicating it. Different paths get
        /// different entries → different mutexes → fully parallel.
        mu: stable.BlockingMutex = .{},
        exists_known: bool = false,
        exists: bool = false,
        kind: ?FileKind = null,
        contents: ?[]u8 = null,
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
            if (entry.contents) |contents| self.allocator.free(contents);
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
        std.Io.Dir.accessAbsolute(io, entry.path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
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

    pub fn readFile(self: *FileCache, path: []const u8) ![]const u8 {
        const entry = try self.entryFor(path);
        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.contents) |contents| return contents;

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
        errdefer self.allocator.free(contents);

        entry.exists_known = true;
        entry.exists = true;
        entry.contents = contents;
        entry.kind = .regular;
        return contents;
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
