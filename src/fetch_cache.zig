//! Evaluator-owned network/source fetch cache.
//!
//! Fetching is isolated here for the same reason filesystem I/O is isolated in
//! FileCache: builtin implementations should describe Nix semantics, while this
//! module owns host effects, caching, and subprocess boundaries.

const std = @import("std");
const nix_hash = @import("runtime/hash.zig");
const FileCache = @import("file_cache.zig").FileCache;

pub const FetchCache = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io,

    const command_stdout_limit = 4 * 1024 * 1024;
    const command_stderr_limit = 512 * 1024;

    pub const GitSpec = struct {
        url: []const u8,
        name: []const u8 = "source",
        rev: ?[]const u8 = null,
        ref: ?[]const u8 = null,
        submodules: bool = false,
    };

    pub const UrlSpec = struct {
        url: []const u8,
        name: []const u8,
    };

    pub const TarballSpec = struct {
        url: []const u8,
        name: []const u8 = "source",
    };

    pub const MercurialSpec = struct {
        url: []const u8,
        name: []const u8 = "source",
        rev: ?[]const u8 = null,
    };

    pub const UrlResult = struct {
        path: []u8,
        hash: []u8,

        pub fn deinit(self: UrlResult, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            allocator.free(self.hash);
        }
    };

    pub const GitResult = struct {
        out_path: []u8,
        rev: []u8,
        short_rev: []u8,
        rev_count: i64,
        last_modified: i64,
        last_modified_date: []u8,
        nar_hash: []u8,
        submodules: bool,

        pub fn deinit(self: GitResult, allocator: std.mem.Allocator) void {
            allocator.free(self.out_path);
            allocator.free(self.rev);
            allocator.free(self.short_rev);
            allocator.free(self.last_modified_date);
            allocator.free(self.nar_hash);
        }
    };

    pub const MercurialResult = struct {
        out_path: []u8,
        rev: []u8,
        short_rev: []u8,
        nar_hash: []u8,

        pub fn deinit(self: MercurialResult, allocator: std.mem.Allocator) void {
            allocator.free(self.out_path);
            allocator.free(self.rev);
            allocator.free(self.short_rev);
            allocator.free(self.nar_hash);
        }
    };

    pub fn init(allocator: std.mem.Allocator) FetchCache {
        return .{
            .allocator = allocator,
            .io = null,
        };
    }

    pub fn deinit(self: *FetchCache) void {
        _ = self;
    }

    pub fn setIo(self: *FetchCache, io: std.Io) void {
        self.io = io;
    }

    pub fn fetchGit(self: *FetchCache, files: *FileCache, spec: GitSpec) !GitResult {
        if (localFetchPath(spec.url)) |path| {
            return self.localGit(files, path, spec);
        }
        return self.remoteGit(files, spec);
    }

    pub fn fetchUrl(self: *FetchCache, files: *FileCache, spec: UrlSpec) !UrlResult {
        const io = self.io orelse return error.FetchIoUnavailable;
        const body = try self.fetchUrlBytes(files, spec.url);
        defer self.allocator.free(body);

        const hash = try nix_hash.hashBytes(self.allocator, "sha256", body);
        errdefer self.allocator.free(hash);
        const path = try self.urlCachePath(io, spec.name, hash);
        errdefer self.allocator.free(path);

        if (!try hostPathExists(io, path)) {
            if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
        }

        return .{ .path = path, .hash = hash };
    }

    pub fn fetchTarball(self: *FetchCache, files: *FileCache, spec: TarballSpec) ![]u8 {
        const io = self.io orelse return error.FetchIoUnavailable;
        const archive = try self.fetchUrl(files, .{ .url = spec.url, .name = spec.name });
        defer archive.deinit(self.allocator);

        const out_path = try self.tarballCachePath(io, spec.name, archive.hash);
        errdefer self.allocator.free(out_path);
        if (!try hostPathExists(io, out_path)) {
            try std.Io.Dir.cwd().createDirPath(io, out_path);
            try self.runCommandDiscard(&.{ "tar", "-xf", archive.path, "-C", out_path, "--strip-components=1" });
        }
        return out_path;
    }

    pub fn fetchMercurial(self: *FetchCache, files: *FileCache, spec: MercurialSpec) !MercurialResult {
        if (localFetchPath(spec.url)) |path| {
            return self.localMercurial(files, path, spec);
        }
        return self.remoteMercurial(files, spec);
    }

    fn fetchUrlBytes(self: *FetchCache, files: *FileCache, url: []const u8) ![]u8 {
        if (localFetchPath(url)) |path| return self.allocator.dupe(u8, try files.readFile(path));

        const io = self.io orelse return error.FetchIoUnavailable;
        var client = std.http.Client{ .allocator = self.allocator, .io = io };
        defer client.deinit();

        var body = std.Io.Writer.Allocating.init(self.allocator);
        defer body.deinit();
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &body.writer,
        });
        if (result.status.class() != .success) return error.FetchHttpStatus;
        return body.toOwnedSlice();
    }

    fn localGit(self: *FetchCache, files: *FileCache, path: []const u8, spec: GitSpec) !GitResult {
        const rev = if (spec.rev) |r| try self.allocator.dupe(u8, r) else try self.localGitRevision(files, path) orelse try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(rev);
        return self.gitResult(path, rev, spec.submodules, self.io != null);
    }

    fn remoteGit(self: *FetchCache, files: *FileCache, spec: GitSpec) !GitResult {
        const io = self.io orelse return error.FetchIoUnavailable;
        const path = try self.remoteGitPath(io, spec);
        defer self.allocator.free(path);

        const git_dir = try std.fs.path.join(self.allocator, &.{ path, ".git" });
        defer self.allocator.free(git_dir);
        if (!try files.pathExists(git_dir)) {
            try std.Io.Dir.cwd().createDirPath(io, path);
            if (spec.ref) |ref| {
                try self.runCommandDiscard(&.{ "git", "clone", "--filter=blob:none", "--branch", ref, "--single-branch", spec.url, path });
            } else {
                try self.runCommandDiscard(&.{ "git", "clone", "--filter=blob:none", spec.url, path });
            }
        }

        if (spec.rev) |rev| {
            try self.runCommandDiscard(&.{ "git", "-C", path, "checkout", "--detach", rev });
        } else if (spec.ref) |ref| {
            try self.runCommandDiscard(&.{ "git", "-C", path, "checkout", ref });
        }
        if (spec.submodules) {
            try self.runCommandDiscard(&.{ "git", "-C", path, "submodule", "update", "--init", "--recursive" });
        }

        const rev = try self.gitOneLine(&.{ "git", "-C", path, "rev-parse", "HEAD" });
        errdefer self.allocator.free(rev);
        return self.gitResult(path, rev, spec.submodules, true);
    }

    fn localMercurial(self: *FetchCache, files: *FileCache, path: []const u8, spec: MercurialSpec) !MercurialResult {
        const rev = if (spec.rev) |r| try self.allocator.dupe(u8, r) else try self.localMercurialRevision(files, path) orelse try self.allocator.dupe(u8, "");
        defer self.allocator.free(rev);
        return self.mercurialResult(path, rev);
    }

    fn remoteMercurial(self: *FetchCache, files: *FileCache, spec: MercurialSpec) !MercurialResult {
        const io = self.io orelse return error.FetchIoUnavailable;
        const path = try self.remoteMercurialPath(io, spec);
        defer self.allocator.free(path);

        const hg_dir = try std.fs.path.join(self.allocator, &.{ path, ".hg" });
        defer self.allocator.free(hg_dir);
        if (!try files.pathExists(hg_dir)) {
            try std.Io.Dir.cwd().createDirPath(io, path);
            try self.runCommandDiscard(&.{ "hg", "clone", spec.url, path });
        }

        if (spec.rev) |rev| {
            try self.runCommandDiscard(&.{ "hg", "--cwd", path, "update", "--rev", rev });
        }

        const rev = try self.commandOneLine(&.{ "hg", "--cwd", path, "id", "--id" });
        defer self.allocator.free(rev);
        return self.mercurialResult(path, stripMercurialDirtySuffix(rev));
    }

    fn gitResult(self: *FetchCache, path: []const u8, rev: []u8, submodules: bool, query_git: bool) !GitResult {
        errdefer self.allocator.free(rev);

        const short_len = @min(rev.len, 7);
        const short_rev = try self.allocator.dupe(u8, rev[0..short_len]);
        errdefer self.allocator.free(short_rev);

        const rev_count: i64 = if (query_git and rev.len != 0)
            try self.gitOneLineInt(&.{ "git", "-C", path, "rev-list", "--count", "HEAD" })
        else
            0;

        const last_modified: i64 = if (query_git and rev.len != 0)
            try self.gitOneLineInt(&.{ "git", "-C", path, "log", "-1", "--format=%ct" })
        else
            0;

        const last_modified_date = if (query_git and rev.len != 0)
            try self.gitOneLine(&.{ "git", "-C", path, "log", "-1", "--date=format:%Y%m%d%H%M%S", "--format=%cd" })
        else
            try self.allocator.dupe(u8, "19700101000000");
        errdefer self.allocator.free(last_modified_date);

        const nar_hash = try self.sourceHash(path, rev);
        errdefer self.allocator.free(nar_hash);

        return .{
            .out_path = try self.allocator.dupe(u8, path),
            .rev = rev,
            .short_rev = short_rev,
            .rev_count = rev_count,
            .last_modified = last_modified,
            .last_modified_date = last_modified_date,
            .nar_hash = nar_hash,
            .submodules = submodules,
        };
    }

    fn remoteGitPath(self: *FetchCache, io: std.Io, spec: GitSpec) ![]u8 {
        var key: std.ArrayListUnmanaged(u8) = .empty;
        defer key.deinit(self.allocator);
        try key.appendSlice(self.allocator, spec.url);
        try key.append(self.allocator, 0);
        if (spec.rev) |rev| try key.appendSlice(self.allocator, rev);
        try key.append(self.allocator, 0);
        if (spec.ref) |ref| try key.appendSlice(self.allocator, ref);
        try key.append(self.allocator, 0);
        try key.append(self.allocator, @intFromBool(spec.submodules));

        const digest = try nix_hash.hashBytes(self.allocator, "sha256", key.items);
        defer self.allocator.free(digest);
        const cwd = try std.process.currentPathAlloc(io, self.allocator);
        defer self.allocator.free(cwd);
        return std.fs.path.join(self.allocator, &.{ cwd, ".zig-cache", "fix-fetch", "git", digest[0..32] });
    }

    fn remoteMercurialPath(self: *FetchCache, io: std.Io, spec: MercurialSpec) ![]u8 {
        var key: std.ArrayListUnmanaged(u8) = .empty;
        defer key.deinit(self.allocator);
        try key.appendSlice(self.allocator, spec.url);
        try key.append(self.allocator, 0);
        if (spec.rev) |rev| try key.appendSlice(self.allocator, rev);

        const digest = try nix_hash.hashBytes(self.allocator, "sha256", key.items);
        defer self.allocator.free(digest);
        const cwd = try std.process.currentPathAlloc(io, self.allocator);
        defer self.allocator.free(cwd);
        return std.fs.path.join(self.allocator, &.{ cwd, ".zig-cache", "fix-fetch", "hg", digest[0..32] });
    }

    fn urlCachePath(self: *FetchCache, io: std.Io, name: []const u8, hash: []const u8) ![]u8 {
        const cwd = try std.process.currentPathAlloc(io, self.allocator);
        defer self.allocator.free(cwd);
        const clean_name = try cleanStoreName(self.allocator, name);
        defer self.allocator.free(clean_name);
        return std.fs.path.join(self.allocator, &.{ cwd, ".zig-cache", "fix-fetch", "url", hash[0..32], clean_name });
    }

    fn tarballCachePath(self: *FetchCache, io: std.Io, name: []const u8, hash: []const u8) ![]u8 {
        const cwd = try std.process.currentPathAlloc(io, self.allocator);
        defer self.allocator.free(cwd);
        const clean_name = try cleanStoreName(self.allocator, name);
        defer self.allocator.free(clean_name);
        return std.fs.path.join(self.allocator, &.{ cwd, ".zig-cache", "fix-fetch", "tarball", hash[0..32], clean_name });
    }

    pub fn sourceHash(self: *FetchCache, path: []const u8, rev: []const u8) ![]u8 {
        var key: std.ArrayListUnmanaged(u8) = .empty;
        defer key.deinit(self.allocator);
        try key.appendSlice(self.allocator, path);
        try key.append(self.allocator, '\n');
        try key.appendSlice(self.allocator, rev);
        const digest = try nix_hash.hashBytes(self.allocator, "sha256", key.items);
        defer self.allocator.free(digest);
        return std.fmt.allocPrint(self.allocator, "sha256-{s}", .{digest});
    }

    fn mercurialResult(self: *FetchCache, path: []const u8, rev: []const u8) !MercurialResult {
        const clean_rev = stripMercurialDirtySuffix(rev);
        const short_len = @min(clean_rev.len, 12);
        const short_rev = try self.allocator.dupe(u8, clean_rev[0..short_len]);
        errdefer self.allocator.free(short_rev);

        const nar_hash = try self.sourceHash(path, clean_rev);
        errdefer self.allocator.free(nar_hash);

        return .{
            .out_path = try self.allocator.dupe(u8, path),
            .rev = try self.allocator.dupe(u8, clean_rev),
            .short_rev = short_rev,
            .nar_hash = nar_hash,
        };
    }

    fn localMercurialRevision(self: *FetchCache, files: *FileCache, repo_path: []const u8) !?[]u8 {
        const hg_dir = try std.fs.path.join(self.allocator, &.{ repo_path, ".hg" });
        defer self.allocator.free(hg_dir);
        if (!try files.pathExists(hg_dir)) return null;
        if (self.io == null) return null;
        const rev = self.commandOneLine(&.{ "hg", "--cwd", repo_path, "id", "--id" }) catch return null;
        defer self.allocator.free(rev);
        return try self.allocator.dupe(u8, stripMercurialDirtySuffix(rev));
    }

    fn localGitRevision(self: *FetchCache, files: *FileCache, repo_path: []const u8) !?[]u8 {
        const dot_git = try std.fs.path.join(self.allocator, &.{ repo_path, ".git" });
        defer self.allocator.free(dot_git);
        if (!try files.pathExists(dot_git)) return null;
        if ((try files.fileType(dot_git)) != .directory) return null;

        const head_path = try std.fs.path.join(self.allocator, &.{ dot_git, "HEAD" });
        defer self.allocator.free(head_path);
        const head = std.mem.trim(u8, files.readFile(head_path) catch return null, " \t\r\n");
        if (std.mem.startsWith(u8, head, "ref:")) {
            const ref_name = std.mem.trim(u8, head[4..], " \t\r\n");
            if (try self.readGitRef(files, dot_git, ref_name)) |rev| return rev;
            return self.readPackedGitRef(files, dot_git, ref_name);
        }
        if (head.len == 0) return null;
        return try self.allocator.dupe(u8, head);
    }

    fn readGitRef(self: *FetchCache, files: *FileCache, dot_git: []const u8, ref_name: []const u8) !?[]u8 {
        const ref_path = try std.fs.path.join(self.allocator, &.{ dot_git, ref_name });
        defer self.allocator.free(ref_path);
        const contents = files.readFile(ref_path) catch return null;
        const rev = std.mem.trim(u8, contents, " \t\r\n");
        if (rev.len == 0) return null;
        return try self.allocator.dupe(u8, rev);
    }

    fn readPackedGitRef(self: *FetchCache, files: *FileCache, dot_git: []const u8, ref_name: []const u8) !?[]u8 {
        const packed_path = try std.fs.path.join(self.allocator, &.{ dot_git, "packed-refs" });
        defer self.allocator.free(packed_path);
        const contents = files.readFile(packed_path) catch return null;

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            if (std.mem.eql(u8, line[space + 1 ..], ref_name)) {
                return try self.allocator.dupe(u8, line[0..space]);
            }
        }
        return null;
    }

    fn gitOneLine(self: *FetchCache, argv: []const []const u8) ![]u8 {
        return self.commandOneLine(argv);
    }

    fn commandOneLine(self: *FetchCache, argv: []const []const u8) ![]u8 {
        const result = try self.runGit(argv, null);
        defer self.allocator.free(result.stderr);
        defer self.allocator.free(result.stdout);
        return self.allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    }

    fn gitOneLineInt(self: *FetchCache, argv: []const []const u8) !i64 {
        const text = try self.gitOneLine(argv);
        defer self.allocator.free(text);
        return std.fmt.parseInt(i64, text, 10) catch return error.InvalidGitOutput;
    }

    fn runCommandDiscard(self: *FetchCache, argv: []const []const u8) !void {
        const result = try self.runGit(argv, null);
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
    }

    fn runGit(self: *FetchCache, argv: []const []const u8, cwd: ?[]const u8) !std.process.RunResult {
        const io = self.io orelse return error.FetchIoUnavailable;
        const result = try std.process.run(self.allocator, io, .{
            .argv = argv,
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
            .stdout_limit = .limited(command_stdout_limit),
            .stderr_limit = .limited(command_stderr_limit),
        });
        errdefer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        switch (result.term) {
            .exited => |code| if (code == 0) return result,
            else => {},
        }
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
        return error.FetchCommandFailed;
    }
};

fn cleanStoreName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const clean_name = try allocator.alloc(u8, name.len);
    errdefer allocator.free(clean_name);
    for (name, clean_name) |c, *out| {
        out.* = if (c == '/' or c == 0 or std.ascii.isWhitespace(c)) '-' else c;
    }
    return clean_name;
}

fn hostPathExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn localFetchPath(url: []const u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(url)) return url;
    if (std.mem.startsWith(u8, url, "file://")) return url["file://".len..];
    return null;
}

fn stripMercurialDirtySuffix(rev: []const u8) []const u8 {
    if (std.mem.endsWith(u8, rev, "+")) return rev[0 .. rev.len - 1];
    return rev;
}
