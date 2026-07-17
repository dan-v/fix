//! Evaluator-owned network/source fetch cache.
//!
//! Fetching is isolated here for the same reason filesystem I/O is isolated in
//! FileCache: builtin implementations should describe Nix semantics, while this
//! module owns host effects, caching, and subprocess boundaries.

const std = @import("std");
const nix_hash = @import("runtime").hash;
const nar = @import("nar.zig");
const FileCache = @import("file_cache.zig").FileCache;
const sync = @import("base").sync;

/// Download-staging cache under `$XDG_CACHE_HOME/fix` (default `~/.cache/fix`,
/// mirroring Nix's `~/.cache/nix`; falls back to `./.zig-cache/fix` when the
/// environment is unset). This is only a place to land downloads before they
/// are hashed/added to the real store — never a substitute for `/nix/store`.
///
/// Trap: this does NOT memoize within a process run. There is no in-memory
/// cache; the on-disk cache merely skips re-writing/re-extracting
/// already-present paths. Each `fetchUrl`/`fetchTarball` call still
/// re-downloads and re-hashes the bytes on every invocation.
pub const FetchCache = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io,
    /// Download-cache root (owned). Set to `$XDG_CACHE_HOME/fix` (default
    /// `~/.cache/fix`), mirroring Nix's `~/.cache/nix`. When unset (e.g. tests
    /// that never call `setEnvironment`) it falls back to `./.zig-cache/fix`.
    cache_root: ?[]u8 = null,
    /// Max concurrent fetches (`http-connections`; 0 = unlimited). The offload
    /// path (`FiberExecutor.runBlocking`) acquires `conn_sem` when this is > 0.
    max_connections: u32 = 0,
    conn_sem: sync.Semaphore = sync.Semaphore.init(0),
    /// `download-attempts` (nix default 5): how many times to try a download
    /// before giving up, retrying only transient failures (connection errors,
    /// 5xx). See `fetchUrlBytes`.
    download_attempts: u32 = 5,
    /// `access-tokens` from `nix.conf`: `<host>[/<path>] -> <token>`, used to
    /// add an `Authorization: Bearer` header on downloads to a matching host
    /// (private GitHub/GitLab/… archives). Owned; see `setAccessTokens`.
    access_tokens: std.ArrayListUnmanaged(TokenEntry) = .empty,
    /// Parsed `netrc-file` entries: HTTP basic-auth credentials applied to a
    /// plain (non-forge) download whose host matches, as Nix does via curl.
    /// Owned; see `setNetrc`.
    netrc: std.ArrayListUnmanaged(NetrcEntry) = .empty,
    /// The process environment (borrowed), inherited by git/tar/hg subprocesses.
    env: ?*const std.process.Environ.Map = null,
    /// Lazily-built subprocess environment = `env` plus:
    ///   - `GIT_TERMINAL_PROMPT=0` — a git CLI fetch of a private remote fails
    ///     fast instead of blocking on an interactive credential prompt. Nix
    ///     gets this for free via libgit2; we shell out to git, so we set it.
    ///   - `HGPLAIN=` — consistent `hg` output, ignoring a user/system `.hgrc`,
    ///     exactly as Nix's mercurial fetcher (`hgOptions`).
    /// Both are harmless to the unrelated subprocesses (git/tar/hg share this).
    /// Built on first subprocess run (most evals never fetch); freed in deinit.
    subprocess_env: ?std.process.Environ.Map = null,

    const TokenEntry = struct { host: []u8, token: []u8 };
    /// A `netrc` machine entry (owned). `machine == null` is the `default` entry.
    const NetrcEntry = struct { machine: ?[]u8, login: []u8, password: []u8 };

    /// The forge whose token-header convention applies to a download. Like Nix,
    /// `access-tokens` only authenticate forge (and git) fetches, not arbitrary
    /// `fetchurl`/`fetchTarball`; the header format is per-forge (see
    /// `authHeader`). Null on a spec = no token, ever.
    pub const Forge = enum { github, gitlab, sourcehut };

    const command_stdout_limit = 4 * 1024 * 1024;
    const command_stderr_limit = 512 * 1024;
    /// HTTP `User-Agent` for downloads — identifies fix (some hosts, e.g. the
    /// GitHub API, require a non-empty one), mirroring Nix's `Nix/<v>` string.
    const user_agent = "fix";

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
        forge: ?Forge = null,
    };

    pub const TarballSpec = struct {
        url: []const u8,
        name: []const u8 = "source",
        forge: ?Forge = null,
        /// Serialize and hash the unpacked tree while still on the bounded
        /// fetch worker. Direct hashed fetchTarball requests this payload;
        /// unhashed and fetchTree callers retain the original extraction-only
        /// path.
        serialize_nar: bool = false,
    };

    pub const MercurialSpec = struct {
        url: []const u8,
        name: []const u8 = "source",
        rev: ?[]const u8 = null,
    };

    /// Byte-progress callback for a download (from the fetching thread). `total`
    /// 0 = size not yet known. The vm/observ layer wraps a progress span in one
    /// of these; runtime stays unaware of the progress types.
    pub const Reporter = struct {
        ctx: *anyopaque,
        report: *const fn (ctx: *anyopaque, downloaded: u64, total: u64) void,

        fn emit(self: ?Reporter, downloaded: u64, total: u64) void {
            if (self) |r| r.report(r.ctx, downloaded, total);
        }
    };

    pub const UrlResult = struct {
        path: []u8,
        hash: []u8,

        pub fn deinit(self: UrlResult, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            allocator.free(self.hash);
        }
    };

    pub const TarballNar = struct {
        bytes: []u8,
        digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    };

    pub const TarballResult = struct {
        path: []u8,
        nar_payload: ?TarballNar,

        pub fn deinit(self: TarballResult, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            if (self.nar_payload) |payload| allocator.free(payload.bytes);
        }
    };

    pub const GitResult = struct {
        out_path: []u8,
        rev: []u8,
        short_rev: []u8,
        rev_count: i64,
        last_modified: i64,
        last_modified_date: []u8,
        submodules: bool,

        pub fn deinit(self: GitResult, allocator: std.mem.Allocator) void {
            allocator.free(self.out_path);
            allocator.free(self.rev);
            allocator.free(self.short_rev);
            allocator.free(self.last_modified_date);
        }
    };

    pub const MercurialResult = struct {
        out_path: []u8,
        rev: []u8,
        short_rev: []u8,

        pub fn deinit(self: MercurialResult, allocator: std.mem.Allocator) void {
            allocator.free(self.out_path);
            allocator.free(self.rev);
            allocator.free(self.short_rev);
        }
    };

    pub fn init(allocator: std.mem.Allocator) FetchCache {
        return .{
            .allocator = allocator,
            .io = null,
        };
    }

    pub fn deinit(self: *FetchCache) void {
        if (self.cache_root) |root| self.allocator.free(root);
        for (self.access_tokens.items) |t| {
            self.allocator.free(t.host);
            self.allocator.free(t.token);
        }
        self.access_tokens.deinit(self.allocator);
        self.clearNetrc();
        self.netrc.deinit(self.allocator);
        if (self.subprocess_env) |*e| e.deinit();
    }

    fn clearNetrc(self: *FetchCache) void {
        for (self.netrc.items) |e| {
            if (e.machine) |m| self.allocator.free(m);
            self.allocator.free(e.login);
            self.allocator.free(e.password);
        }
        self.netrc.clearRetainingCapacity();
    }

    /// Parse a `netrc`-format file into credential entries, replacing the
    /// current set. Handles the `machine`/`default`/`login`/`password`/`account`
    /// keywords (whitespace-separated tokens); `macdef` bodies are not executed
    /// (the name and next token are skipped). Later duplicate machines just add
    /// another entry; lookup takes the first match.
    pub fn setNetrc(self: *FetchCache, content: []const u8) !void {
        self.clearNetrc();
        var it = std.mem.tokenizeAny(u8, content, " \t\r\n");
        var cur: ?usize = null;
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "machine")) {
                const name = it.next() orelse break;
                try self.netrc.append(self.allocator, .{
                    .machine = try self.allocator.dupe(u8, name),
                    .login = try self.allocator.dupe(u8, ""),
                    .password = try self.allocator.dupe(u8, ""),
                });
                cur = self.netrc.items.len - 1;
            } else if (std.mem.eql(u8, tok, "default")) {
                try self.netrc.append(self.allocator, .{
                    .machine = null,
                    .login = try self.allocator.dupe(u8, ""),
                    .password = try self.allocator.dupe(u8, ""),
                });
                cur = self.netrc.items.len - 1;
            } else if (std.mem.eql(u8, tok, "login")) {
                const v = it.next() orelse break;
                if (cur) |i| {
                    self.allocator.free(self.netrc.items[i].login);
                    self.netrc.items[i].login = try self.allocator.dupe(u8, v);
                }
            } else if (std.mem.eql(u8, tok, "password")) {
                const v = it.next() orelse break;
                if (cur) |i| {
                    self.allocator.free(self.netrc.items[i].password);
                    self.netrc.items[i].password = try self.allocator.dupe(u8, v);
                }
            } else if (std.mem.eql(u8, tok, "account") or std.mem.eql(u8, tok, "macdef")) {
                _ = it.next(); // skip the value / macro name
            }
        }
    }

    /// The `Authorization: Basic` header for a request to `url` if the netrc has
    /// credentials for its host (exact `machine` match, else the `default`
    /// entry). Null if none. Owned; caller frees.
    fn netrcHeader(self: *const FetchCache, url: []const u8) !?AuthHeader {
        if (self.netrc.items.len == 0) return null;
        const host = urlHostPath(url).host;
        var match: ?NetrcEntry = null;
        for (self.netrc.items) |e| {
            if (e.machine) |m| if (std.mem.eql(u8, m, host)) {
                match = e;
                break;
            };
        }
        if (match == null) for (self.netrc.items) |e| {
            if (e.machine == null) {
                match = e;
                break;
            }
        };
        const e = match orelse return null;
        if (e.login.len == 0) return null;
        const alloc = self.allocator;
        const creds = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ e.login, e.password });
        defer alloc.free(creds);
        const enc = std.base64.standard.Encoder;
        const buf = try alloc.alloc(u8, enc.calcSize(creds.len));
        defer alloc.free(buf);
        const b64 = enc.encode(buf, creds);
        return .{
            .name = try alloc.dupe(u8, "Authorization"),
            .value = try std.fmt.allocPrint(alloc, "Basic {s}", .{b64}),
        };
    }

    pub fn setIo(self: *FetchCache, io: std.Io) void {
        self.io = io;
    }

    /// Set the process environment inherited by git/tar/hg subprocesses.
    pub fn setEnvironment(self: *FetchCache, env: *const std.process.Environ.Map) void {
        self.env = env;
        if (self.subprocess_env) |*e| { // rebuild lazily on next use
            e.deinit();
            self.subprocess_env = null;
        }
    }

    /// The environment for a git/tar/hg subprocess: the inherited process env
    /// plus `GIT_TERMINAL_PROMPT=0` and `HGPLAIN=`. Built once and cached. Null
    /// (inherit the parent env unchanged) when no environment was set (tests).
    fn subprocessEnviron(self: *FetchCache) !?*const std.process.Environ.Map {
        if (self.subprocess_env) |*e| return e;
        const parent = self.env orelse return null;
        var env = std.process.Environ.Map.init(self.allocator);
        errdefer env.deinit();
        for (parent.keys(), parent.values()) |k, v| try env.put(k, v);
        try env.put("GIT_TERMINAL_PROMPT", "0");
        try env.put("HGPLAIN", "");
        self.subprocess_env = env;
        return &self.subprocess_env.?;
    }

    /// Parse a `nix.conf` `access-tokens` value — space-separated
    /// `<host>[/<path>]=<token>` entries — replacing the current set. Later
    /// entries win on a duplicate key. Malformed entries (no `=`) are skipped.
    pub fn setAccessTokens(self: *FetchCache, raw: []const u8) !void {
        for (self.access_tokens.items) |t| {
            self.allocator.free(t.host);
            self.allocator.free(t.token);
        }
        self.access_tokens.clearRetainingCapacity();

        var it = std.mem.tokenizeAny(u8, raw, " \t");
        while (it.next()) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            const host = entry[0..eq];
            const token = entry[eq + 1 ..];
            if (host.len == 0 or token.len == 0) continue;
            try self.access_tokens.append(self.allocator, .{
                .host = try self.allocator.dupe(u8, host),
                .token = try self.allocator.dupe(u8, token),
            });
        }
    }

    /// Split `url` into its host (authority without `user@`/`:port`) and path.
    fn urlHostPath(url: []const u8) struct { host: []const u8, path: []const u8 } {
        var rest = url;
        if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
        const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        var authority = rest[0..path_start];
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
        if (std.mem.indexOfScalar(u8, authority, ':')) |c| authority = authority[0..c];
        return .{ .host = authority, .path = rest[path_start..] };
    }

    /// The access token for a request to `url`, matched by the longest
    /// `<host>[/<path>]` key that is a prefix of the URL's `host/path` (so
    /// `github.com/org` beats a bare `github.com`). Null if none matches.
    fn tokenFor(self: *const FetchCache, url: []const u8) ?[]const u8 {
        if (self.access_tokens.items.len == 0) return null;
        const hp = urlHostPath(url);
        const lookup = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ hp.host, hp.path }) catch return null;
        defer self.allocator.free(lookup);

        var best: ?[]const u8 = null;
        var best_len: usize = 0;
        for (self.access_tokens.items) |t| {
            const matches = std.mem.eql(u8, lookup, t.host) or
                (lookup.len > t.host.len and std.mem.startsWith(u8, lookup, t.host) and lookup[t.host.len] == '/');
            if (matches and t.host.len >= best_len) {
                best = t.token;
                best_len = t.host.len;
            }
        }
        return best;
    }

    /// An owned HTTP header for an authenticated forge request.
    pub const AuthHeader = struct {
        name: []u8,
        value: []u8,
        fn deinit(self: AuthHeader, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.value);
        }
    };

    /// Build the `access-tokens` auth header for a `forge` request to `url`, per
    /// Nix's per-forge conventions (`libfetchers/github.cc:accessHeaderFromToken`):
    ///   - github:    `Authorization: token <tok>`
    ///   - sourcehut: `Authorization: Bearer <tok>`
    ///   - gitlab:    token is `<type>:<value>`; `OAuth2:` → `Authorization:
    ///     Bearer <value>`, `PAT:` → `Private-token: <value>`, any other type →
    ///     header `<type>: <value>` (a bare, colon-less token yields the Nix
    ///     degenerate `<token>:` empty-value header). Null if no token matches.
    fn authHeader(self: *const FetchCache, forge: Forge, url: []const u8) !?AuthHeader {
        const token = self.tokenFor(url) orelse return null;
        const alloc = self.allocator;
        return switch (forge) {
            .github => .{
                .name = try alloc.dupe(u8, "Authorization"),
                .value = try std.fmt.allocPrint(alloc, "token {s}", .{token}),
            },
            .sourcehut => .{
                .name = try alloc.dupe(u8, "Authorization"),
                .value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token}),
            },
            .gitlab => blk: {
                const colon = std.mem.indexOfScalar(u8, token, ':');
                const kind = if (colon) |c| token[0..c] else token;
                const value = if (colon) |c| token[c + 1 ..] else "";
                if (std.mem.eql(u8, kind, "OAuth2")) break :blk .{
                    .name = try alloc.dupe(u8, "Authorization"),
                    .value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{value}),
                };
                if (std.mem.eql(u8, kind, "PAT")) break :blk .{
                    .name = try alloc.dupe(u8, "Private-token"),
                    .value = try alloc.dupe(u8, value),
                };
                break :blk .{ .name = try alloc.dupe(u8, kind), .value = try alloc.dupe(u8, value) };
            },
        };
    }

    /// Set the concurrent-fetch cap (`http-connections`; 0 = unlimited).
    pub fn setMaxConnections(self: *FetchCache, n: u32) void {
        self.max_connections = n;
        self.conn_sem = sync.Semaphore.init(n);
    }

    /// Set `download-attempts` (total tries per download; clamped to >= 1).
    pub fn setDownloadAttempts(self: *FetchCache, n: u32) void {
        self.download_attempts = @max(1, n);
    }

    /// The permit semaphore to gate a fetch on, or null when unlimited.
    pub fn connSem(self: *FetchCache) ?*sync.Semaphore {
        return if (self.max_connections > 0) &self.conn_sem else null;
    }

    /// Set the download-cache root (duped/owned). See `cache_root`.
    pub fn setCacheRoot(self: *FetchCache, root: []const u8) !void {
        const owned = try self.allocator.dupe(u8, root);
        if (self.cache_root) |old| self.allocator.free(old);
        self.cache_root = owned;
    }

    /// The download-cache root: the configured `cache_root`, else
    /// `<cwd>/.zig-cache/fix` as a fallback (caller frees).
    fn cacheRootDir(self: *FetchCache, io: std.Io) ![]u8 {
        if (self.cache_root) |root| return self.allocator.dupe(u8, root);
        const cwd = try std.process.currentPathAlloc(io, self.allocator);
        defer self.allocator.free(cwd);
        return std.fs.path.join(self.allocator, &.{ cwd, ".zig-cache", "fix" });
    }

    pub fn fetchGit(self: *FetchCache, files: *FileCache, spec: GitSpec, _: ?Reporter) !GitResult {
        if (localFetchPath(spec.url)) |path| {
            return self.localGit(files, path, spec);
        }
        return self.remoteGit(files, spec);
    }

    pub fn fetchUrl(self: *FetchCache, files: *FileCache, spec: UrlSpec, reporter: ?Reporter) !UrlResult {
        const io = self.io orelse return error.FetchIoUnavailable;
        const body = try self.fetchUrlBytes(files, spec.url, spec.forge, reporter);
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

    pub fn fetchTarball(self: *FetchCache, files: *FileCache, spec: TarballSpec, reporter: ?Reporter) !TarballResult {
        const io = self.io orelse return error.FetchIoUnavailable;
        const archive = try self.fetchUrl(files, .{ .url = spec.url, .name = spec.name, .forge = spec.forge }, reporter);
        defer archive.deinit(self.allocator);

        const out_path = try self.tarballCachePath(io, spec.name, archive.hash);
        errdefer self.allocator.free(out_path);
        if (!try hostPathExists(io, out_path)) {
            try std.Io.Dir.cwd().createDirPath(io, out_path);
            try self.runCommandDiscard(&.{ "tar", "-xf", archive.path, "-C", out_path, "--strip-components=1" });
        }

        const nar_payload: ?TarballNar = if (spec.serialize_nar) payload: {
            const bytes = try nar.serialize(self.allocator, files, out_path, null);
            errdefer self.allocator.free(bytes);
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            break :payload .{ .bytes = bytes, .digest = digest };
        } else null;
        return .{ .path = out_path, .nar_payload = nar_payload };
    }

    pub fn fetchMercurial(self: *FetchCache, files: *FileCache, spec: MercurialSpec, _: ?Reporter) !MercurialResult {
        if (localFetchPath(spec.url)) |path| {
            return self.localMercurial(files, path, spec);
        }
        return self.remoteMercurial(files, spec);
    }

    /// Whether `err` from a download attempt is worth retrying (a transient
    /// connection/server problem) vs. a permanent failure (bad URL, 4xx, OOM).
    fn retryable(err: anyerror) bool {
        return switch (err) {
            error.OutOfMemory,
            error.FetchIoUnavailable,
            error.UnsupportedCompressionMethod,
            error.FetchClientError,
            error.FetchInvalidUrl,
            error.FetchTooManyRedirects,
            => false,
            else => true,
        };
    }

    /// Resolve a redirect `Location` against the current absolute URL `base`,
    /// returning a new owned absolute URL. Handles an absolute Location (the
    /// common case), a scheme-relative `//host/…`, an absolute path `/…`, and a
    /// relative path (against `base`'s directory).
    fn resolveRedirect(self: *FetchCache, base: []const u8, loc: []const u8) ![]u8 {
        const alloc = self.allocator;
        if (std.mem.startsWith(u8, loc, "http://") or std.mem.startsWith(u8, loc, "https://"))
            return alloc.dupe(u8, loc);
        const scheme_end = std.mem.indexOf(u8, base, "://") orelse return error.FetchInvalidUrl;
        if (std.mem.startsWith(u8, loc, "//")) // scheme-relative: keep base's scheme
            return std.fmt.allocPrint(alloc, "{s}:{s}", .{ base[0..scheme_end], loc });
        const authority_start = scheme_end + 3;
        const path_start = std.mem.indexOfScalarPos(u8, base, authority_start, '/') orelse base.len;
        const origin = base[0..path_start]; // scheme://authority
        if (std.mem.startsWith(u8, loc, "/")) // absolute path on the same origin
            return std.fmt.allocPrint(alloc, "{s}{s}", .{ origin, loc });
        // Relative path: replace the last path segment of `base`.
        const last_slash = std.mem.lastIndexOfScalar(u8, base, '/') orelse return error.FetchInvalidUrl;
        const dir = if (last_slash >= path_start) base[0 .. last_slash + 1] else origin;
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ dir, loc });
    }

    fn fetchUrlBytes(self: *FetchCache, files: *FileCache, url: []const u8, forge: ?Forge, reporter: ?Reporter) ![]u8 {
        if (localFetchPath(url)) |path| return self.allocator.dupe(u8, try files.readFile(path));

        const io = self.io orelse return error.FetchIoUnavailable;
        const uri = std.Uri.parse(url) catch return error.FetchInvalidUrl;

        // Retry transient failures up to `download-attempts` times (nix default
        // 5), with a short linear backoff. A permanent failure (4xx, bad URL)
        // returns immediately.
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            return self.fetchUrlAttempt(io, uri, url, forge, reporter) catch |err| {
                if (attempt >= self.download_attempts or !retryable(err)) return err;
                io.sleep(std.Io.Duration.fromMilliseconds(@min(5_000, 250 * @as(i64, attempt))), .awake) catch {};
                continue;
            };
        }
    }

    fn fetchUrlAttempt(self: *FetchCache, io: std.Io, initial_uri: std.Uri, initial_url: []const u8, forge: ?Forge, reporter: ?Reporter) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator, .io = io };
        defer client.deinit();

        // A forge fetch's token is sticky across redirects (computed once): it
        // must reach codeload.github.com after the github.com archive redirect,
        // and the forge is trusted. A plain download's `netrc` credentials are
        // re-evaluated for the *current* host on every hop, so they are never
        // sent to a different host after a redirect. We follow redirects
        // ourselves (`.unhandled`) because std.http can't strip auth for us
        // (it never emits `privileged_headers`).
        const forge_auth: ?AuthHeader = if (forge) |f| try self.authHeader(f, initial_url) else null;
        defer if (forge_auth) |a| a.deinit(self.allocator);

        var current_url: []const u8 = initial_url;
        var current_uri = initial_uri;
        var owned_url: ?[]u8 = null;
        defer if (owned_url) |u| self.allocator.free(u);
        var redirects_left: u32 = 10;

        while (true) {
            // Per-hop auth: the sticky forge token, else netrc for the host we
            // are about to contact (so creds don't cross a redirect boundary).
            const hop_netrc: ?AuthHeader = if (forge_auth == null) try self.netrcHeader(current_url) else null;
            defer if (hop_netrc) |a| a.deinit(self.allocator);
            var extra_headers: []const std.http.Header = &.{};
            var auth_storage: [1]std.http.Header = undefined;
            if (forge_auth orelse hop_netrc) |a| {
                auth_storage[0] = .{ .name = a.name, .value = a.value };
                extra_headers = auth_storage[0..1];
            }

            var req = try client.request(.GET, current_uri, .{
                .redirect_behavior = .unhandled,
                .headers = .{ .user_agent = .{ .override = user_agent } },
                .extra_headers = extra_headers,
            });
            defer req.deinit();
            try req.sendBodiless();

            var redirect_buffer: [8 * 1024]u8 = undefined;
            var response = try req.receiveHead(&redirect_buffer);
            const class = response.head.status.class();
            if (class == .redirect) {
                if (redirects_left == 0) return error.FetchTooManyRedirects;
                const loc = response.head.location orelse return error.FetchHttpStatus;
                const next = try self.resolveRedirect(current_url, loc);
                if (owned_url) |u| self.allocator.free(u);
                owned_url = next;
                current_url = next;
                current_uri = std.Uri.parse(next) catch return error.FetchInvalidUrl;
                redirects_left -= 1;
                continue;
            }
            // 4xx is a permanent client error (bad URL, auth); anything else
            // non-2xx (5xx, unexpected) is transient and gets retried.
            if (class == .client_error) return error.FetchClientError;
            if (class != .success) return error.FetchHttpStatus;

            // Stream (rather than one-shot `fetch`) so we can read `content_length`
            // up front and report bytes as they arrive to the fetch progress span.
            // Content-Length is the compressed wire size; we count decompressed
            // bytes, so it's only a valid progress total when the body is identity.
            const total: u64 = if (response.head.content_encoding == .identity)
                (response.head.content_length orelse 0)
            else
                0;

            // Decompress like std.http's one-shot fetch does, else we'd hash/store
            // the raw gzip/deflate/zstd bytes instead of the real content.
            const decompress_buffer: []u8 = switch (response.head.content_encoding) {
                .identity => &.{},
                .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
                .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
                .compress => return error.UnsupportedCompressionMethod,
            };
            defer if (decompress_buffer.len > 0) self.allocator.free(decompress_buffer);

            var transfer_buffer: [64 * 1024]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

            var body = std.Io.Writer.Allocating.init(self.allocator);
            defer body.deinit();
            var chunk: [64 * 1024]u8 = undefined;
            var downloaded: u64 = 0;
            Reporter.emit(reporter, 0, total);
            while (true) {
                const n = reader.readSliceShort(&chunk) catch return error.FetchHttpStatus;
                if (n == 0) break;
                try body.writer.writeAll(chunk[0..n]);
                downloaded += n;
                Reporter.emit(reporter, downloaded, total);
            }
            return body.toOwnedSlice();
        }
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

        return .{
            .out_path = try self.allocator.dupe(u8, path),
            .rev = rev,
            .short_rev = short_rev,
            .rev_count = rev_count,
            .last_modified = last_modified,
            .last_modified_date = last_modified_date,
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
        const root = try self.cacheRootDir(io);
        defer self.allocator.free(root);
        return std.fs.path.join(self.allocator, &.{ root, "git", digest[0..32] });
    }

    fn remoteMercurialPath(self: *FetchCache, io: std.Io, spec: MercurialSpec) ![]u8 {
        var key: std.ArrayListUnmanaged(u8) = .empty;
        defer key.deinit(self.allocator);
        try key.appendSlice(self.allocator, spec.url);
        try key.append(self.allocator, 0);
        if (spec.rev) |rev| try key.appendSlice(self.allocator, rev);

        const digest = try nix_hash.hashBytes(self.allocator, "sha256", key.items);
        defer self.allocator.free(digest);
        const root = try self.cacheRootDir(io);
        defer self.allocator.free(root);
        return std.fs.path.join(self.allocator, &.{ root, "hg", digest[0..32] });
    }

    fn urlCachePath(self: *FetchCache, io: std.Io, name: []const u8, hash: []const u8) ![]u8 {
        const root = try self.cacheRootDir(io);
        defer self.allocator.free(root);
        const clean_name = try cleanStoreName(self.allocator, name);
        defer self.allocator.free(clean_name);
        return std.fs.path.join(self.allocator, &.{ root, "url", hash[0..32], clean_name });
    }

    fn tarballCachePath(self: *FetchCache, io: std.Io, name: []const u8, hash: []const u8) ![]u8 {
        const root = try self.cacheRootDir(io);
        defer self.allocator.free(root);
        const clean_name = try cleanStoreName(self.allocator, name);
        defer self.allocator.free(clean_name);
        return std.fs.path.join(self.allocator, &.{ root, "tarball", hash[0..32], clean_name });
    }

    fn mercurialResult(self: *FetchCache, path: []const u8, rev: []const u8) !MercurialResult {
        const clean_rev = stripMercurialDirtySuffix(rev);
        const short_len = @min(clean_rev.len, 12);
        const short_rev = try self.allocator.dupe(u8, clean_rev[0..short_len]);
        errdefer self.allocator.free(short_rev);

        return .{
            .out_path = try self.allocator.dupe(u8, path),
            .rev = try self.allocator.dupe(u8, clean_rev),
            .short_rev = short_rev,
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

        // Resolve the actual git directory. In a normal checkout `.git` is a
        // directory; in a linked WORKTREE it is a FILE containing
        // `gitdir: <path-to-worktree-git-dir>` (matching Nix/Lix, which follow
        // it). HEAD is per-worktree, so read it from the resolved git dir…
        const git_dir = (try self.resolveGitDir(files, dot_git, repo_path)) orelse return null;
        defer self.allocator.free(git_dir);
        // …but branches (refs) are SHARED across worktrees — they live in the
        // common dir (`<git_dir>/commondir` → the main `.git`).
        const common_dir = try self.resolveGitCommonDir(files, git_dir);
        defer self.allocator.free(common_dir);

        const head_path = try std.fs.path.join(self.allocator, &.{ git_dir, "HEAD" });
        defer self.allocator.free(head_path);
        const head = std.mem.trim(u8, files.readFile(head_path) catch return null, " \t\r\n");
        if (std.mem.startsWith(u8, head, "ref:")) {
            const ref_name = std.mem.trim(u8, head[4..], " \t\r\n");
            if (try self.readGitRef(files, common_dir, ref_name)) |rev| return rev;
            return self.readPackedGitRef(files, common_dir, ref_name);
        }
        if (head.len == 0) return null;
        return try self.allocator.dupe(u8, head);
    }

    /// The real git directory for `dot_git` (= `<repo>/.git`). A directory is
    /// returned as-is; a worktree's `.git` file (`gitdir: <path>`) is followed
    /// (path resolved relative to the repo when not absolute). Caller owns the
    /// result. Null when `.git` is neither a usable dir nor a gitdir pointer.
    fn resolveGitDir(self: *FetchCache, files: *FileCache, dot_git: []const u8, repo_path: []const u8) !?[]u8 {
        if ((try files.fileType(dot_git)) == .directory) return try self.allocator.dupe(u8, dot_git);
        const contents = std.mem.trim(u8, files.readFile(dot_git) catch return null, " \t\r\n");
        const prefix = "gitdir:";
        if (!std.mem.startsWith(u8, contents, prefix)) return null;
        const target = std.mem.trim(u8, contents[prefix.len..], " \t\r\n");
        if (target.len == 0) return null;
        if (std.fs.path.isAbsolute(target)) return try self.allocator.dupe(u8, target);
        return try std.fs.path.join(self.allocator, &.{ repo_path, target });
    }

    /// The common git directory holding shared refs (`packed-refs`,
    /// `refs/heads/*`). For a linked worktree `<git_dir>/commondir` points at
    /// the main `.git`; otherwise the git dir is its own common dir. Caller
    /// owns the result.
    fn resolveGitCommonDir(self: *FetchCache, files: *FileCache, git_dir: []const u8) ![]u8 {
        const cd_path = try std.fs.path.join(self.allocator, &.{ git_dir, "commondir" });
        defer self.allocator.free(cd_path);
        const contents = std.mem.trim(u8, files.readFile(cd_path) catch return try self.allocator.dupe(u8, git_dir), " \t\r\n");
        if (contents.len == 0) return try self.allocator.dupe(u8, git_dir);
        if (std.fs.path.isAbsolute(contents)) return try self.allocator.dupe(u8, contents);
        return try std.fs.path.join(self.allocator, &.{ git_dir, contents });
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
            .environ_map = try self.subprocessEnviron(),
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

test "access-tokens: parse and longest-prefix host/path match" {
    const testing = std.testing;
    var fc = FetchCache.init(testing.allocator);
    defer fc.deinit();
    try fc.setAccessTokens("github.com=ghp_base gitlab.example.org=glpat github.com/acme=ghp_acme  =skip  bad_no_eq");

    // Bare host match, and the port/scheme are ignored.
    try testing.expectEqualStrings("ghp_base", fc.tokenFor("https://github.com/owner/repo/archive/HEAD.tar.gz").?);
    try testing.expectEqualStrings("ghp_base", fc.tokenFor("https://github.com").?);
    // The longer `github.com/acme` key wins for that org.
    try testing.expectEqualStrings("ghp_acme", fc.tokenFor("https://github.com/acme/thing/archive/HEAD.tar.gz").?);
    // A different self-hosted host.
    try testing.expectEqualStrings("glpat", fc.tokenFor("https://gitlab.example.org/g/p/-/archive/v1/p-v1.tar.gz").?);
    // No token for an unlisted host; `github.comX` must not match `github.com`.
    try testing.expect(fc.tokenFor("https://codeberg.org/o/r") == null);
    try testing.expect(fc.tokenFor("https://github.com.evil.example/x") == null);
}

test "netrc: basic-auth header by machine, else default" {
    const testing = std.testing;
    var fc = FetchCache.init(testing.allocator);
    defer fc.deinit();
    try fc.setNetrc(
        \\machine example.com login alice password s3cret
        \\machine noauth.example
        \\default login guest password g
    );

    const decoded = struct {
        fn creds(fcp: *FetchCache, url: []const u8, out: []u8) ![]const u8 {
            const h = (try fcp.netrcHeader(url)).?;
            defer h.deinit(fcp.allocator);
            try testing.expectEqualStrings("Authorization", h.name);
            const b64 = h.value["Basic ".len..];
            const dec = std.base64.standard.Decoder;
            const n = try dec.calcSizeForSlice(b64);
            try dec.decode(out[0..n], b64);
            return out[0..n];
        }
    };
    var buf: [64]u8 = undefined;
    // Exact machine match.
    try testing.expectEqualStrings("alice:s3cret", try decoded.creds(&fc, "https://example.com/repo.git", &buf));
    // Unknown host falls back to the `default` entry.
    try testing.expectEqualStrings("guest:g", try decoded.creds(&fc, "https://unknown.example/x", &buf));
    // A matched machine with no login yields no header (and does not fall back
    // to `default` — the host has its own entry).
    try testing.expect((try fc.netrcHeader("https://noauth.example/x")) == null);

    var empty = FetchCache.init(testing.allocator);
    defer empty.deinit();
    try testing.expect((try empty.netrcHeader("https://example.com")) == null);
}

test "subprocess env: inherits parent and disables the git terminal prompt" {
    const testing = std.testing;
    var parent = std.process.Environ.Map.init(testing.allocator);
    defer parent.deinit();
    try parent.put("HOME", "/home/u");
    try parent.put("SSH_AUTH_SOCK", "/run/ssh");

    var fc = FetchCache.init(testing.allocator);
    defer fc.deinit();
    fc.setEnvironment(&parent);

    const env = (try fc.subprocessEnviron()).?;
    try testing.expectEqualStrings("0", env.get("GIT_TERMINAL_PROMPT").?);
    try testing.expectEqualStrings("", env.get("HGPLAIN").?);
    try testing.expectEqualStrings("/home/u", env.get("HOME").?); // inherited
    try testing.expectEqualStrings("/run/ssh", env.get("SSH_AUTH_SOCK").?); // inherited (creds/ssh)

    // With no environment set, subprocesses inherit the parent unchanged (null).
    var bare = FetchCache.init(testing.allocator);
    defer bare.deinit();
    try testing.expect((try bare.subprocessEnviron()) == null);
}

test "access-tokens: per-forge auth header (matches Nix)" {
    const testing = std.testing;
    var fc = FetchCache.init(testing.allocator);
    defer fc.deinit();
    try fc.setAccessTokens("github.com=ghp_x gl.example.org=PAT:glpat gl2.example.org=OAuth2:oa sh.example.org=shtok gitea.example.org=abc:def git.sr.ht=srhtok");

    const check = struct {
        fn one(fcp: *FetchCache, forge: FetchCache.Forge, url: []const u8, name: []const u8, value: []const u8) !void {
            const h = (try fcp.authHeader(forge, url)).?;
            defer h.deinit(fcp.allocator);
            try testing.expectEqualStrings(name, h.name);
            try testing.expectEqualStrings(value, h.value);
        }
    };

    // GitHub: `Authorization: token <tok>`.
    try check.one(&fc, .github, "https://github.com/o/r/archive/HEAD.tar.gz", "Authorization", "token ghp_x");
    // SourceHut: `Authorization: Bearer <tok>`.
    try check.one(&fc, .sourcehut, "https://git.sr.ht/~o/r/archive/HEAD.tar.gz", "Authorization", "Bearer srhtok");
    // GitLab PAT: `Private-token: <value>`.
    try check.one(&fc, .gitlab, "https://gl.example.org/g/p", "Private-token", "glpat");
    // GitLab OAuth2: `Authorization: Bearer <value>`.
    try check.one(&fc, .gitlab, "https://gl2.example.org/g/p", "Authorization", "Bearer oa");
    // GitLab unrecognized `<type>:<value>` → header `<type>: <value>`.
    try check.one(&fc, .gitlab, "https://gitea.example.org/g/p", "abc", "def");
    // No token configured for this host → no header.
    try testing.expect((try fc.authHeader(.github, "https://unlisted.example/x")) == null);
}

test "fetchTarball only serializes NAR when requested" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "archive-root", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "archive-root/file.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(base_path);
    const archive_path = try std.fs.path.resolve(testing.allocator, &.{ base_path, "archive.tar.gz" });
    defer testing.allocator.free(archive_path);
    const cache_path = try std.fs.path.resolve(testing.allocator, &.{ base_path, "fetch-cache" });
    defer testing.allocator.free(cache_path);

    const tar = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "tar", "-czf", archive_path, "-C", base_path, "archive-root" },
    });
    defer testing.allocator.free(tar.stdout);
    defer testing.allocator.free(tar.stderr);
    switch (tar.term) {
        .exited => |code| try testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTarFailure,
    }

    var files = FileCache.init(testing.allocator);
    defer files.deinit();
    files.setIo(testing.io);
    var fc = FetchCache.init(testing.allocator);
    defer fc.deinit();
    fc.setIo(testing.io);
    try fc.setCacheRoot(cache_path);

    const url = try std.fmt.allocPrint(testing.allocator, "file://{s}", .{archive_path});
    defer testing.allocator.free(url);
    const unhashed = try fc.fetchTarball(&files, .{ .url = url, .name = "src" }, null);
    defer unhashed.deinit(testing.allocator);
    try testing.expect(unhashed.nar_payload == null);

    const hashed = try fc.fetchTarball(&files, .{ .url = url, .name = "src", .serialize_nar = true }, null);
    defer hashed.deinit(testing.allocator);
    const payload = hashed.nar_payload orelse return error.MissingNarPayload;
    var independently_hashed: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload.bytes, &independently_hashed, .{});
    try testing.expectEqualSlices(u8, &independently_hashed, &payload.digest);
}
