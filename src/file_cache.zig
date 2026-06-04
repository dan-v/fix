//! Evaluator-owned filesystem cache.
//!
//! The VM talks to this cache, not directly to the host filesystem. Cold reads
//! are isolated behind `readFile`/`pathExists`; a later async backend can make
//! those calls suspend/reschedule evaluator work without changing builtin
//! semantics or VM call sites.

const std = @import("std");

pub const FileCache = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io,
    entries: std.StringHashMapUnmanaged(Entry),

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
            self.allocator.free(kv.value_ptr.path);
            if (kv.value_ptr.contents) |contents| self.allocator.free(contents);
            if (kv.value_ptr.dir_entries) |entries| self.freeDirEntries(entries);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn setIo(self: *FileCache, io: std.Io) void {
        self.io = io;
    }

    pub fn pathExists(self: *FileCache, path: []const u8) !bool {
        var entry = try self.entryFor(path);
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
        var entry = try self.entryFor(path);
        if (entry.contents) |contents| return contents;

        const io = self.io orelse return error.FileIoUnavailable;
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
        var entry = try self.entryFor(path);
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

    pub fn isExecutable(self: *FileCache, path: []const u8) !bool {
        const entry = try self.entryFor(path);
        const io = self.io orelse return error.FileIoUnavailable;
        const stat = try std.Io.Dir.cwd().statFile(io, entry.path, .{ .follow_symlinks = false });
        return @TypeOf(stat.permissions).has_executable_bit and stat.permissions.toMode() & 0o111 != 0;
    }

    pub fn readLink(self: *FileCache, path: []const u8) ![]u8 {
        const entry = try self.entryFor(path);
        const io = self.io orelse return error.FileIoUnavailable;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try std.Io.Dir.readLinkAbsolute(io, entry.path, &buffer);
        return self.allocator.dupe(u8, buffer[0..len]);
    }

    pub fn readDir(self: *FileCache, path: []const u8) ![]const DirEntry {
        var entry = try self.entryFor(path);
        if (entry.dir_entries) |entries| return entries;

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
        if (self.entries.getPtr(path)) |entry| return entry;

        const canonical = try self.canonicalPath(path);
        errdefer self.allocator.free(canonical);

        const gop = try self.entries.getOrPut(self.allocator, canonical);
        if (gop.found_existing) {
            self.allocator.free(canonical);
            return gop.value_ptr;
        }

        gop.key_ptr.* = canonical;
        gop.value_ptr.* = .{ .path = canonical };
        return gop.value_ptr;
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
