//! libgit2 adapter for evaluator-owned Git sources.

const std = @import("std");
const sync = @import("base").sync;
const clock = @import("base").clock;

const c = @cImport({
    @cInclude("git2.h");
    @cInclude("time.h");
});

pub const Credentials = struct { username: []const u8, password: []const u8 };
pub const Reporter = struct {
    ctx: *anyopaque,
    report: *const fn (ctx: *anyopaque, downloaded: u64, total: u64) void,
};
pub const Options = struct {
    credentials: ?Credentials = null,
    reporter: ?Reporter = null,
    ca_file: ?[]const u8 = null,
    proxy_url: ?[]const u8 = null,
    connect_timeout_seconds: u32 = 15,
    stalled_timeout_seconds: u32 = 300,
    /// `$HOME`, for locating `~/.ssh` identities when no agent is running.
    /// Null disables the on-disk key fallback.
    home_dir: ?[]const u8 = null,
    /// Fetch only the pinned commit (`--depth 1`). Ancestry is then unavailable,
    /// so `revCount` is reported as 0 — which is what Nix reports for a shallow
    /// fetch, and why a shallow lock node carries no `revCount`.
    shallow: bool = false,
};
/// A caller-supplied memo for `revCount`, keyed on the resolved rev.
pub const RevCountCache = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, rev: []const u8) ?i64,
    put: *const fn (ctx: *anyopaque, rev: []const u8, count: i64) void,
};

pub const Result = struct {
    rev: [c.GIT_OID_SHA1_HEXSIZE]u8,
    rev_count: i64,
    last_modified: i64,
    last_modified_date: [14]u8,

    pub const rev_len = c.GIT_OID_SHA1_HEXSIZE;
};

/// Materialize a local repository without invoking the Git executable.
/// A pinned revision is exported from its tree; an unpinned worktree copies
/// the current contents of index-tracked paths, so dirty tracked changes are
/// retained while untracked files and repository metadata are excluded.
/// A cheap identity for what `snapshotLocal` would produce from an unpinned
/// local worktree, without copying or serializing anything.
///
/// The snapshot is the content of index-tracked paths, so the index fully
/// determines it: its cached stat data plus each entry's blob oid. Hash the
/// entries (path + oid + mode + file size) and the resolved HEAD. Any tracked
/// edit restages the entry and changes its oid or size, so a stale key cannot
/// survive a content change — and an unstaged edit to a tracked file changes the
/// file's stat data, which libgit2 refreshes into the index on open.
///
/// Returns null when the identity cannot be established cheaply (no index,
/// unreadable repo, conflicts, or submodules requested — those recurse into
/// other repositories and are not summarized here).
pub fn localSnapshotKey(
    allocator: std.mem.Allocator,
    repository_path: []const u8,
    submodules: bool,
) !?[64]u8 {
    if (submodules) return null;
    try ensureInitialized();
    const path_z = try allocator.dupeZ(u8, repository_path);
    defer allocator.free(path_z);
    var repo: ?*c.git_repository = null;
    if (c.git_repository_open_ext(&repo, path_z.ptr, c.GIT_REPOSITORY_OPEN_CROSS_FS, null) < 0) return null;
    defer c.git_repository_free(repo);

    var index: ?*c.git_index = null;
    if (c.git_repository_index(&index, repo.?) < 0) return null;
    defer c.git_index_free(index);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // The index's cached stat data is only as fresh as the last git command, so
    // an unstaged edit would otherwise go unnoticed and serve a stale snapshot.
    // Hash the printed index-to-workdir diff itself. NOT git_diff_patchid: a
    // patch id ignores whitespace within lines, so two dirty states differing
    // only in whitespace would share a key and the second would silently get
    // the first's snapshot. SHOW_BINARY folds binary edits' bytes in too.
    {
        var diff: ?*c.git_diff = null;
        var diff_opts: c.git_diff_options = undefined;
        if (c.git_diff_options_init(&diff_opts, c.GIT_DIFF_OPTIONS_VERSION) != 0) return null;
        diff_opts.flags |= c.GIT_DIFF_SHOW_BINARY;
        if (c.git_diff_index_to_workdir(&diff, repo.?, index.?, &diff_opts) != 0) return null;
        defer c.git_diff_free(diff);
        if (c.git_diff_print(diff.?, c.GIT_DIFF_FORMAT_PATCH, hashDiffLine, &hasher) != 0) return null;
    }
    var head: ?*c.git_object = null;
    if (c.git_revparse_single(&head, repo.?, "HEAD") == 0) {
        defer c.git_object_free(head);
        const oid: *const c.git_oid = c.git_object_id(head);
        hasher.update(&oid.id);
    }

    const count = c.git_index_entrycount(index.?);
    hasher.update(std.mem.asBytes(&count));
    var position: usize = 0;
    while (position < count) : (position += 1) {
        const entry = c.git_index_get_byindex(index.?, position) orelse return null;
        // A conflicted index does not describe a single snapshot.
        if ((entry.*.flags & c.GIT_INDEX_ENTRY_STAGEMASK) != 0) return null;
        hasher.update(std.mem.span(entry.*.path));
        hasher.update(entry.*.id.id[0..]);
        // Copy to locals first: these are C struct fields whose bytes are not
        // directly addressable as a slice.
        const mode: u32 = entry.*.mode;
        const size: u32 = entry.*.file_size;
        const mtime_seconds: i32 = entry.*.mtime.seconds;
        const mtime_nanoseconds: u32 = entry.*.mtime.nanoseconds;
        hasher.update(std.mem.asBytes(&mode));
        hasher.update(std.mem.asBytes(&size));
        hasher.update(std.mem.asBytes(&mtime_seconds));
        hasher.update(std.mem.asBytes(&mtime_nanoseconds));
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// `git_diff_print` line callback: fold every printed diff byte (headers,
/// hunks, content, base85 binary data) into the key hasher, prefixed by the
/// line's origin marker so context/add/remove lines with equal text differ.
fn hashDiffLine(
    delta: [*c]const c.git_diff_delta,
    hunk: [*c]const c.git_diff_hunk,
    line: [*c]const c.git_diff_line,
    payload: ?*anyopaque,
) callconv(.c) c_int {
    _ = delta;
    _ = hunk;
    const hasher: *std.crypto.hash.sha2.Sha256 = @ptrCast(@alignCast(payload.?));
    const origin: u8 = @bitCast(line.*.origin);
    hasher.update(std.mem.asBytes(&origin));
    hasher.update(line.*.content[0..line.*.content_len]);
    return 0;
}

pub fn snapshotLocal(
    allocator: std.mem.Allocator,
    io: std.Io,
    repository_path: []const u8,
    destination: []const u8,
    rev: ?[]const u8,
    submodules: bool,
    rev_count_cache: ?RevCountCache,
    shallow: bool,
) !Result {
    try ensureInitialized();
    const path_z = try allocator.dupeZ(u8, repository_path);
    defer allocator.free(path_z);
    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open_ext(&repo, path_z.ptr, c.GIT_REPOSITORY_OPEN_CROSS_FS, null));
    defer c.git_repository_free(repo);

    const object = try resolveObject(allocator, repo.?, rev, null);
    defer c.git_object_free(object);
    var peeled: ?*c.git_object = null;
    try check(c.git_object_peel(&peeled, object, c.GIT_OBJECT_COMMIT));
    defer c.git_object_free(peeled);
    const commit: *c.git_commit = @ptrCast(peeled.?);

    try std.Io.Dir.cwd().createDirPath(io, destination);
    if (rev != null) {
        try exportCommit(allocator, io, repo.?, commit, repository_path, destination, submodules);
    } else {
        try copyTrackedWorktree(allocator, io, repo.?, repository_path, destination, submodules);
    }
    // A local repository is never actually fetched shallowly, but `shallow` still
    // selects the ancestry-free reporting Nix uses, so revCount stays 0.
    if (shallow) return resultFromCommitShallow(commit);
    return resultFromCommitCached(repo.?, commit, rev_count_cache);
}

var init_mu: sync.BlockingMutex = .{};
var initialized = false;
var network_config_mu: sync.BlockingMutex = .{};
var network_config: GlobalNetworkConfig = .{};

/// libgit2 exposes certificate and timeout settings only as process globals.
/// Configure them once, immutably, so concurrent requests never race and a
/// request can never inherit another request's policy by accident.
const GlobalNetworkConfig = struct {
    configured: bool = false,
    ca_len: ?usize = null,
    ca: [std.fs.max_path_bytes]u8 = undefined,
    connect_timeout_seconds: u32 = 0,
    stalled_timeout_seconds: u32 = 0,
};

fn ensureInitialized() !void {
    init_mu.lock();
    defer init_mu.unlock();
    if (initialized) return;
    if (c.git_libgit2_init() < 0) return error.GitInitializationFailed;
    // The fetch cache is fix's own directory tree, routinely shared across
    // UIDs by CI (a persistent volume mounted into containers with varying
    // users). libgit2's dubious-ownership check would then fail EVERY
    // `git_repository_open` — a total cold-start regression — protecting
    // against a threat (running hooks/config from a foreign repo) that
    // cannot arise here: fix never executes repo-local config or hooks.
    _ = c.git_libgit2_opts(c.GIT_OPT_SET_OWNER_VALIDATION, @as(c_int, 0));
    initialized = true;
}

fn ensureNetworkConfig(options: Options, ca_z: ?[:0]u8) !void {
    network_config_mu.lock();
    defer network_config_mu.unlock();

    if (network_config.configured) {
        const ca_matches = if (options.ca_file) |path|
            network_config.ca_len != null and
                network_config.ca_len.? == path.len and
                std.mem.eql(u8, network_config.ca[0..path.len], path)
        else
            network_config.ca_len == null;
        if (!ca_matches or
            network_config.connect_timeout_seconds != options.connect_timeout_seconds or
            network_config.stalled_timeout_seconds != options.stalled_timeout_seconds)
        {
            return error.GitGlobalConfigurationConflict;
        }
        return;
    }

    if (options.ca_file) |path| {
        if (path.len > network_config.ca.len) return error.NameTooLong;
        const value = ca_z orelse unreachable;
        try check(c.git_libgit2_opts(
            c.GIT_OPT_SET_SSL_CERT_LOCATIONS,
            value.ptr,
            @as(?[*:0]const u8, null),
        ));
        @memcpy(network_config.ca[0..path.len], path);
        network_config.ca_len = path.len;
    }
    try check(c.git_libgit2_opts(
        c.GIT_OPT_SET_SERVER_CONNECT_TIMEOUT,
        timeoutMilliseconds(options.connect_timeout_seconds),
    ));
    try check(c.git_libgit2_opts(
        c.GIT_OPT_SET_SERVER_TIMEOUT,
        timeoutMilliseconds(options.stalled_timeout_seconds),
    ));
    network_config.connect_timeout_seconds = options.connect_timeout_seconds;
    network_config.stalled_timeout_seconds = options.stalled_timeout_seconds;
    network_config.configured = true;
}

fn timeoutMilliseconds(seconds: u32) c_int {
    return @intCast(@min(seconds *| 1000, std.math.maxInt(c_int)));
}

const CallbackContext = struct {
    username: ?[*:0]const u8 = null,
    password: ?[*:0]const u8 = null,
    proxy_url: ?[*:0]const u8 = null,
    credential_origin: ?[*:0]const u8 = null,
    reporter: ?Reporter = null,
    /// `$HOME` (borrowed), for the `~/.ssh` identity fallback.
    home_dir: ?[]const u8 = null,
    /// SSH credential attempt counter. libgit2 re-invokes this callback after a
    /// rejected credential, so it doubles as the index into `ssh_key_names`:
    /// 0 = ssh-agent, then each on-disk key in turn.
    ssh_attempt: usize = 0,

    /// Default identity filenames, in ssh's own preference order. `fix` does not
    /// parse `~/.ssh/config`, so an explicitly configured IdentityFile is still
    /// missed; these cover the conventional layout.
    const ssh_key_names = [_][]const u8{
        "id_ed25519",
        "id_ecdsa",
        "id_ed25519_sk",
        "id_ecdsa_sk",
        "id_rsa",
    };

    fn credentials(out: [*c]?*c.git_credential, url: [*c]const u8, username_from_url: [*c]const u8, allowed: c_uint, payload: ?*anyopaque) callconv(.c) c_int {
        const self: *CallbackContext = @ptrCast(@alignCast(payload orelse return c.GIT_PASSTHROUGH));
        const same_origin = if (self.credential_origin) |origin|
            sameAuthority(std.mem.span(origin), std.mem.span(url))
        else
            false;
        if ((allowed & c.GIT_CREDENTIAL_USERPASS_PLAINTEXT) != 0 and same_origin and self.username != null and self.password != null)
            return c.git_credential_userpass_plaintext_new(out, self.username.?, self.password.?);
        if ((allowed & c.GIT_CREDENTIAL_SSH_KEY) != 0) {
            const username: [*c]const u8 = if (username_from_url != null) username_from_url else "git";
            const attempt = self.ssh_attempt;
            self.ssh_attempt += 1;
            // The agent first, as ssh does. Without one (a CI container, a
            // non-login shell) the agent call fails and libgit2 calls back;
            // fall through to the conventional on-disk identities rather than
            // failing the fetch — and, worse, hanging on the retry loop.
            if (attempt == 0) return c.git_credential_ssh_key_from_agent(out, username);
            return sshKeyFromDisk(out, username, attempt - 1, self.home_dir);
        }
        if ((allowed & c.GIT_CREDENTIAL_USERNAME) != 0) {
            const username: [*c]const u8 = if (username_from_url != null) username_from_url else "git";
            return c.git_credential_username_new(out, username);
        }
        if ((allowed & c.GIT_CREDENTIAL_DEFAULT) != 0) return c.git_credential_default_new(out);
        return c.GIT_PASSTHROUGH;
    }

    /// Offer `~/.ssh/<ssh_key_names[index]>` (with its `.pub`, when present) to
    /// libgit2. Skips absent keys by advancing until one exists, so a machine
    /// with only `id_rsa` still authenticates. Returns GIT_PASSTHROUGH once the
    /// list is exhausted, which surfaces as an auth error, not a retry.
    fn sshKeyFromDisk(out: [*c]?*c.git_credential, username: [*c]const u8, index: usize, home: ?[]const u8) c_int {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var pub_buf: [std.fs.max_path_bytes]u8 = undefined;
        const home_dir = home orelse return c.GIT_PASSTHROUGH;
        var i = index;
        while (i < ssh_key_names.len) : (i += 1) {
            const priv = std.fmt.bufPrintZ(&buf, "{s}/.ssh/{s}", .{ home_dir, ssh_key_names[i] }) catch continue;
            if (!fileExists(priv)) continue;
            const pub_path = std.fmt.bufPrintZ(&pub_buf, "{s}.pub", .{priv}) catch null;
            const pub_arg: [*c]const u8 = if (pub_path) |p|
                (if (fileExists(p)) p.ptr else null)
            else
                null;
            // Passphrase-protected keys cannot be unlocked non-interactively;
            // those need an agent, which is why it is tried first.
            return c.git_credential_ssh_key_new(out, username, pub_arg, priv.ptr, null);
        }
        return c.GIT_PASSTHROUGH;
    }

    fn transfer(stats: [*c]const c.git_indexer_progress, payload: ?*anyopaque) callconv(.c) c_int {
        const self: *CallbackContext = @ptrCast(@alignCast(payload orelse return 0));
        const reporter = self.reporter orelse return 0;
        const done = if (stats != null) stats.*.received_bytes else 0;
        reporter.report(reporter.ctx, done, 0);
        return 0;
    }
};

/// Existence check via blocking libc `access`: the credential callback is a C
/// entry point with no `std.Io` handle in reach. This module always links libc
/// (libgit2/libcurl), so `std.c` is portable here; `std.os.linux` would
/// compile on darwin but misfire at runtime.
fn fileExists(path: [*:0]const u8) bool {
    return std.c.access(path, std.posix.F_OK) == 0;
}

fn sameAuthority(a: []const u8, b: []const u8) bool {
    const authority = struct {
        fn of(url: []const u8) []const u8 {
            const start = if (std.mem.indexOf(u8, url, "://")) |index| index + 3 else 0;
            const end = std.mem.indexOfScalarPos(u8, url, start, '/') orelse url.len;
            return url[start..end];
        }
    }.of;
    return std.ascii.eqlIgnoreCase(authority(a), authority(b));
}

fn configureCallbacks(callbacks: *c.git_remote_callbacks, context: *CallbackContext) !void {
    if (c.git_remote_init_callbacks(callbacks, c.GIT_REMOTE_CALLBACKS_VERSION) < 0) return gitError();
    callbacks.credentials = CallbackContext.credentials;
    callbacks.transfer_progress = CallbackContext.transfer;
    callbacks.payload = context;
}

fn configureFetch(fetch: *c.git_fetch_options, context: *CallbackContext) !void {
    try configureCallbacks(&fetch.callbacks, context);
    fetch.proxy_opts.type = if (context.proxy_url != null) c.GIT_PROXY_SPECIFIED else c.GIT_PROXY_AUTO;
    fetch.proxy_opts.url = context.proxy_url;
    fetch.proxy_opts.credentials = CallbackContext.credentials;
    fetch.proxy_opts.payload = context;
}

fn gitError() anyerror {
    const last = c.git_error_last();
    if (last != null and last.*.klass == c.GIT_ERROR_NET) return error.FetchTransient;
    return error.FetchGitFailed;
}

fn check(code: c_int) !void {
    if (code < 0) return gitError();
}

/// Clone or refresh a worktree, resolve the requested commit, then cleanly
/// check it out. `refresh=false` still opens and validates the existing cache.
/// Fetch a pinned rev into the shared per-URL bare object store (created on
/// first use) and export the commit's tree to `destination` as raw blobs —
/// no worktree, no `.git`, no checkout filters. Objects and shallow tips
/// accumulate in the store across revs, so a rev bump transfers only what
/// the store lacks (the depth-1 tip pack deltas against existing objects).
/// Ancestry-free by design: the caller reports revCount from its lock hint
/// (or 0 for `shallow = true`). The caller serializes access to `odb_path`
/// across threads and processes.
pub fn fetchSharedOdb(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    odb_path: []const u8,
    destination: []const u8,
    rev: []const u8,
    options: Options,
) !Result {
    try ensureInitialized();
    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    const odb_z = try allocator.dupeZ(u8, odb_path);
    defer allocator.free(odb_z);
    const username_z = if (options.credentials) |cred| try allocator.dupeZ(u8, cred.username) else null;
    defer if (username_z) |value| allocator.free(value);
    const password_z = if (options.credentials) |cred| try allocator.dupeZ(u8, cred.password) else null;
    defer if (password_z) |value| allocator.free(value);
    const ca_z = if (options.ca_file) |value| try allocator.dupeZ(u8, value) else null;
    defer if (ca_z) |value| allocator.free(value);
    const proxy_z = if (options.proxy_url) |value| try allocator.dupeZ(u8, value) else null;
    defer if (proxy_z) |value| allocator.free(value);
    try ensureNetworkConfig(options, ca_z);

    var context = CallbackContext{
        .username = if (username_z) |value| value.ptr else null,
        .password = if (password_z) |value| value.ptr else null,
        .proxy_url = if (proxy_z) |value| value.ptr else null,
        .credential_origin = url_z.ptr,
        .reporter = options.reporter,
        .home_dir = options.home_dir,
    };

    var repo: ?*c.git_repository = null;
    if (c.git_repository_open(&repo, odb_z.ptr) < 0) {
        try check(c.git_repository_init(&repo, odb_z.ptr, 1)); // bare
    }
    defer c.git_repository_free(repo);

    // Only fetch when the store doesn't already hold the commit.
    const have = blk: {
        const rev_z = allocator.dupeZ(u8, rev) catch break :blk false;
        defer allocator.free(rev_z);
        var oid: c.git_oid = undefined;
        if (c.git_oid_fromstr(&oid, rev_z.ptr) != 0) break :blk false;
        var existing: ?*c.git_commit = null;
        if (c.git_commit_lookup(&existing, repo.?, &oid) != 0) break :blk false;
        c.git_commit_free(existing);
        break :blk true;
    };
    if (!have) {
        shallowFetchRef(allocator, repo.?, url_z, rev, null, &context) catch {
            // SHA-in-want rejected (see materialize): full ref fetch, with
            // the credential attempt counter restarted so ssh-agent is
            // retried first.
            context.ssh_attempt = 0;
            try fullFetchAll(repo.?, url_z, &context);
        };
    }

    const object = try resolveObject(allocator, repo.?, rev, null);
    defer c.git_object_free(object);
    var peeled: ?*c.git_object = null;
    try check(c.git_object_peel(&peeled, object, c.GIT_OBJECT_COMMIT));
    defer c.git_object_free(peeled);
    const commit: *c.git_commit = @ptrCast(peeled.?);

    try std.Io.Dir.cwd().createDirPath(io, destination);
    try exportCommit(allocator, io, repo.?, commit, odb_path, destination, false);
    return resultFromCommitShallow(commit);
}

pub fn materialize(
    allocator: std.mem.Allocator,
    url: []const u8,
    path: []const u8,
    rev: ?[]const u8,
    ref_name: ?[]const u8,
    submodules: bool,
    refresh: bool,
    options: Options,
) !Result {
    try ensureInitialized();
    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const username_z = if (options.credentials) |cred| try allocator.dupeZ(u8, cred.username) else null;
    defer if (username_z) |value| allocator.free(value);
    const password_z = if (options.credentials) |cred| try allocator.dupeZ(u8, cred.password) else null;
    defer if (password_z) |value| allocator.free(value);
    const ca_z = if (options.ca_file) |value| try allocator.dupeZ(u8, value) else null;
    defer if (ca_z) |value| allocator.free(value);
    const proxy_z = if (options.proxy_url) |value| try allocator.dupeZ(u8, value) else null;
    defer if (proxy_z) |value| allocator.free(value);
    try ensureNetworkConfig(options, ca_z);

    var context = CallbackContext{
        .username = if (username_z) |value| value.ptr else null,
        .password = if (password_z) |value| value.ptr else null,
        .proxy_url = if (proxy_z) |value| value.ptr else null,
        .credential_origin = url_z.ptr,
        .reporter = options.reporter,
        .home_dir = options.home_dir,
    };
    var repo: ?*c.git_repository = null;
    if (c.git_repository_open(&repo, path_z.ptr) < 0) {
        if (options.shallow) {
            // A depth-1 clone only brings the remote's default branch, so a rev
            // on any other branch would be missing. Init empty and fetch just
            // the wanted ref at depth 1 — what `clone --depth 1 --branch` does.
            // Non-bare: the caller reads the checked-out worktree at `path`.
            try check(c.git_repository_init(&repo, path_z.ptr, 0));
            shallowFetchRef(allocator, repo.?, url_z, rev, ref_name, &context) catch {
                // Fetching a pinned rev by object id needs the server to allow
                // SHA-in-want (GitHub/GitLab do; plain git-daemon and some
                // self-hosted forges do not, and depth is irrelevant to that
                // rejection). Fall back to a full ref fetch: strictly more
                // history than asked for, and shallow *reporting* (revCount 0
                // or the locked count) is decided by the caller, not by the
                // clone's actual depth. The credential attempt counter must
                // restart: the failed attempt advanced it past ssh-agent, and
                // the fallback would otherwise skip straight to on-disk keys
                // — failing repos reachable only via agent auth.
                context.ssh_attempt = 0;
                try fullFetchAll(repo.?, url_z, &context);
            };
        } else {
            var clone_opts: c.git_clone_options = undefined;
            try check(c.git_clone_options_init(&clone_opts, c.GIT_CLONE_OPTIONS_VERSION));
            try configureFetch(&clone_opts.fetch_opts, &context);
            clone_opts.checkout_opts.checkout_strategy = c.GIT_CHECKOUT_NONE;
            try check(c.git_clone(&repo, url_z.ptr, path_z.ptr, &clone_opts));
        }
    } else if (refresh) {
        var remote: ?*c.git_remote = null;
        if (c.git_remote_lookup(&remote, repo.?, "origin") == 0) {
            defer c.git_remote_free(remote);
            var fetch_opts: c.git_fetch_options = undefined;
            try check(c.git_fetch_options_init(&fetch_opts, c.GIT_FETCH_OPTIONS_VERSION));
            try configureFetch(&fetch_opts, &context);
            if (options.shallow) fetch_opts.depth = 1;
            fetch_opts.prune = c.GIT_FETCH_PRUNE;
            try check(c.git_remote_fetch(remote.?, null, &fetch_opts, null));
        } else {
            // A shallow-init dir has no configured origin (its fetches go
            // through an anonymous remote); refresh it the same way, at full
            // depth so a rev the shallow fetch could not reach turns up.
            try fullFetchAll(repo.?, url_z, &context);
        }
    }
    defer c.git_repository_free(repo);

    const object = try resolveObject(allocator, repo.?, rev, ref_name);
    defer c.git_object_free(object);
    var peeled: ?*c.git_object = null;
    try check(c.git_object_peel(&peeled, object, c.GIT_OBJECT_COMMIT));
    defer c.git_object_free(peeled);
    const commit: *c.git_commit = @ptrCast(peeled.?);
    const oid = c.git_commit_id(commit);

    var checkout: c.git_checkout_options = undefined;
    try check(c.git_checkout_options_init(&checkout, c.GIT_CHECKOUT_OPTIONS_VERSION));
    checkout.checkout_strategy = c.GIT_CHECKOUT_FORCE | c.GIT_CHECKOUT_RECREATE_MISSING | c.GIT_CHECKOUT_REMOVE_UNTRACKED;
    // RAW blob bytes: libgit2's checkout DOES run `.gitattributes` content
    // filters (crlf etc.) by default — a remote clone of a repo with eol
    // rules materialized filtered content while the local-path export
    // (`exportCommit`) wrote raw blobs, so the two paths hashed differently
    // and remote fetches diverged from the lock's narHash (modern Nix
    // >= 2.20 ingests raw). Caught by the latency rig's git:// serving of
    // the gitattrs fixture repo.
    checkout.disable_filters = 1;
    try check(c.git_checkout_tree(repo.?, peeled.?, &checkout));
    try check(c.git_repository_set_head_detached(repo.?, oid));
    if (submodules) try updateSubmodules(repo.?, &context);
    if (options.shallow) return resultFromCommitShallow(commit);
    return resultFromCommit(repo.?, commit);
}

/// A shallow clone has no ancestry to walk, so `revCount` is 0 — the value Nix
/// reports for a shallow fetch (and why a `shallow` lock node omits revCount).
fn resultFromCommitShallow(commit: *c.git_commit) Result {
    var result: Result = undefined;
    var rev_z: [c.GIT_OID_SHA1_HEXSIZE + 1]u8 = undefined;
    _ = c.git_oid_tostr(&rev_z, rev_z.len, c.git_commit_id(commit));
    @memcpy(&result.rev, rev_z[0..result.rev.len]);
    result.rev_count = 0;
    result.last_modified = @intCast(c.git_commit_time(commit));
    result.last_modified_date = clock.formatUtc(result.last_modified);
    return result;
}

fn resultFromCommit(repo: *c.git_repository, commit: *c.git_commit) !Result {
    return resultFromCommitCached(repo, commit, null);
}

/// `revCount` is a full walk of the commit's ancestry — seconds on a large
/// history, and the same number every time for a given commit. `cache` lets the
/// caller memoize it by rev across runs; a miss just does the walk.
fn resultFromCommitCached(repo: *c.git_repository, commit: *c.git_commit, cache: ?RevCountCache) !Result {
    const oid = c.git_commit_id(commit);
    var result: Result = undefined;
    var rev_z: [c.GIT_OID_SHA1_HEXSIZE + 1]u8 = undefined;
    _ = c.git_oid_tostr(&rev_z, rev_z.len, oid);
    @memcpy(&result.rev, rev_z[0..result.rev.len]);
    result.last_modified = @intCast(c.git_commit_time(commit));
    result.last_modified_date = clock.formatUtc(result.last_modified);
    if (cache) |hook| {
        if (hook.get(hook.ctx, &result.rev)) |count| {
            result.rev_count = count;
            return result;
        }
        result.rev_count = try revisionCount(repo, oid);
        hook.put(hook.ctx, &result.rev, result.rev_count);
        return result;
    }
    result.rev_count = try revisionCount(repo, oid);
    return result;
}

fn copyTrackedWorktree(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *c.git_repository,
    source_root: []const u8,
    destination_root: []const u8,
    submodules: bool,
) !void {
    var index: ?*c.git_index = null;
    try check(c.git_repository_index(&index, repo));
    defer c.git_index_free(index);
    const count = c.git_index_entrycount(index.?);
    var position: usize = 0;
    while (position < count) : (position += 1) {
        const entry = c.git_index_get_byindex(index.?, position) orelse continue;
        // Conflict stages live in the upper flag bits; only the normal stage
        // describes the tracked worktree snapshot.
        if ((entry.*.flags & c.GIT_INDEX_ENTRY_STAGEMASK) != 0) continue;
        const relative = std.mem.span(entry.*.path);
        const source = try std.fs.path.join(allocator, &.{ source_root, relative });
        defer allocator.free(source);
        const destination = try std.fs.path.join(allocator, &.{ destination_root, relative });
        defer allocator.free(destination);
        if (entry.*.mode == c.GIT_FILEMODE_COMMIT) {
            try std.Io.Dir.cwd().createDirPath(io, destination);
            if (submodules) {
                var child: ?*c.git_repository = null;
                const source_z = try allocator.dupeZ(u8, source);
                defer allocator.free(source_z);
                if (c.git_repository_open_ext(&child, source_z.ptr, c.GIT_REPOSITORY_OPEN_CROSS_FS, null) == 0) {
                    defer c.git_repository_free(child);
                    try copyTrackedWorktree(allocator, io, child.?, source, destination, true);
                }
            }
            continue;
        }
        const stat = std.Io.Dir.cwd().statFile(io, source, .{ .follow_symlinks = false }) catch continue;
        switch (stat.kind) {
            .sym_link => {
                const parent = std.fs.path.dirname(destination) orelse destination_root;
                try std.Io.Dir.cwd().createDirPath(io, parent);
                var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const length = try std.Io.Dir.readLinkAbsolute(io, source, &target_buffer);
                const target = target_buffer[0..length];
                // A symlink target is arbitrary text and is usually relative
                // (`../x/y`); `symLinkAbsolute` asserts the target is absolute,
                // so it must not be handed one. Recreate the link verbatim via
                // its parent directory, preserving relative targets as-is.
                var dir = try std.Io.Dir.cwd().openDir(io, parent, .{});
                defer dir.close(io);
                const name = std.fs.path.basename(destination);
                dir.symLink(io, target, name, .{}) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            },
            .file => try std.Io.Dir.copyFileAbsolute(source, destination, io, .{ .make_path = true }),
            else => {},
        }
    }
}

fn exportCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *c.git_repository,
    commit: *c.git_commit,
    source_root: []const u8,
    destination_root: []const u8,
    submodules: bool,
) anyerror!void {
    var tree: ?*c.git_tree = null;
    try check(c.git_commit_tree(&tree, commit));
    defer c.git_tree_free(tree);
    try exportTree(allocator, io, repo, tree.?, source_root, destination_root, "", submodules);
}

fn exportTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *c.git_repository,
    tree: *c.git_tree,
    source_root: []const u8,
    destination_root: []const u8,
    prefix: []const u8,
    submodules: bool,
) anyerror!void {
    const count = c.git_tree_entrycount(tree);
    var position: usize = 0;
    while (position < count) : (position += 1) {
        const entry = c.git_tree_entry_byindex(tree, position) orelse continue;
        const name = std.mem.span(c.git_tree_entry_name(entry));
        const relative = if (prefix.len == 0)
            try allocator.dupe(u8, name)
        else
            try std.fs.path.join(allocator, &.{ prefix, name });
        defer allocator.free(relative);
        const destination = try std.fs.path.join(allocator, &.{ destination_root, relative });
        defer allocator.free(destination);
        const mode = c.git_tree_entry_filemode(entry);
        switch (mode) {
            c.GIT_FILEMODE_TREE => {
                try std.Io.Dir.cwd().createDirPath(io, destination);
                var child: ?*c.git_tree = null;
                try check(c.git_tree_lookup(&child, repo, c.git_tree_entry_id(entry)));
                defer c.git_tree_free(child);
                try exportTree(allocator, io, repo, child.?, source_root, destination_root, relative, submodules);
            },
            c.GIT_FILEMODE_BLOB, c.GIT_FILEMODE_BLOB_EXECUTABLE, c.GIT_FILEMODE_LINK => {
                var blob: ?*c.git_blob = null;
                try check(c.git_blob_lookup(&blob, repo, c.git_tree_entry_id(entry)));
                defer c.git_blob_free(blob);
                const raw: [*]const u8 = @ptrCast(c.git_blob_rawcontent(blob.?));
                const raw_contents = raw[0..@intCast(c.git_blob_rawsize(blob.?))];
                const parent = std.fs.path.dirname(destination) orelse destination_root;
                try std.Io.Dir.cwd().createDirPath(io, parent);
                if (mode == c.GIT_FILEMODE_LINK) {
                    // A symlink blob's content is arbitrary text and usually a
                    // RELATIVE target (`../x/y`); `symLinkAbsolute` asserts an
                    // absolute target (see copyTrackedWorktree, which hit the
                    // same trap). Recreate via the parent dir, verbatim.
                    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{});
                    defer dir.close(io);
                    dir.symLink(io, raw_contents, std.fs.path.basename(destination), .{}) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                } else {
                    // Raw blob bytes — what modern Nix (>= 2.20) ingests. No
                    // `.gitattributes` filters run (Nix <= 2.19 / Lix apply
                    // `git archive` filters and hash differently; fix
                    // supports only the modern semantics).
                    try std.Io.Dir.cwd().writeFile(io, .{
                        .sub_path = destination,
                        .data = raw_contents,
                        .flags = .{ .permissions = if (mode == c.GIT_FILEMODE_BLOB_EXECUTABLE) .executable_file else .default_file },
                    });
                }
            },
            c.GIT_FILEMODE_COMMIT => {
                try std.Io.Dir.cwd().createDirPath(io, destination);
                if (submodules) {
                    const source = try std.fs.path.join(allocator, &.{ source_root, relative });
                    defer allocator.free(source);
                    const source_z = try allocator.dupeZ(u8, source);
                    defer allocator.free(source_z);
                    var child_repo: ?*c.git_repository = null;
                    if (c.git_repository_open_ext(&child_repo, source_z.ptr, c.GIT_REPOSITORY_OPEN_CROSS_FS, null) == 0) {
                        defer c.git_repository_free(child_repo);
                        var child_object: ?*c.git_object = null;
                        try check(c.git_object_lookup(&child_object, child_repo.?, c.git_tree_entry_id(entry), c.GIT_OBJECT_COMMIT));
                        defer c.git_object_free(child_object);
                        const child_commit: *c.git_commit = @ptrCast(child_object.?);
                        try exportCommit(allocator, io, child_repo.?, child_commit, source, destination, true);
                    }
                }
            },
            else => {},
        }
    }
}

/// Fetch a single commit at depth 1 into a freshly initialized repository. When
/// a rev is pinned it is fetched by object id: the branch tip may have moved past
/// it, and a depth-1 fetch of the tip then cannot reach it. Otherwise the ref
/// (or the remote's HEAD) is fetched, as a shallow clone would. The result is
/// written under `refs/remotes/origin/*` so `resolveObject` still finds it.
/// Full-depth fetch of all branches and tags through an anonymous remote —
/// the fallback when a by-object-id shallow fetch is rejected, and the
/// refresh path for shallow-init directories (which configure no origin).
fn fullFetchAll(repo: *c.git_repository, url_z: [:0]const u8, context: *CallbackContext) !void {
    var remote: ?*c.git_remote = null;
    try check(c.git_remote_create_anonymous(&remote, repo, url_z.ptr));
    defer c.git_remote_free(remote);
    var fetch_opts: c.git_fetch_options = undefined;
    try check(c.git_fetch_options_init(&fetch_opts, c.GIT_FETCH_OPTIONS_VERSION));
    try configureFetch(&fetch_opts, context);
    var refspec_ptrs = [_][*c]u8{
        @constCast("+refs/heads/*:refs/remotes/origin/*"),
        @constCast("+refs/tags/*:refs/tags/*"),
    };
    var refspecs = c.git_strarray{ .strings = &refspec_ptrs, .count = refspec_ptrs.len };
    try check(c.git_remote_fetch(remote.?, &refspecs, &fetch_opts, null));
}

fn shallowFetchRef(
    allocator: std.mem.Allocator,
    repo: *c.git_repository,
    url_z: [:0]const u8,
    rev: ?[]const u8,
    ref_name: ?[]const u8,
    context: *CallbackContext,
) !void {
    var remote: ?*c.git_remote = null;
    try check(c.git_remote_create_anonymous(&remote, repo, url_z.ptr));
    defer c.git_remote_free(remote);

    var fetch_opts: c.git_fetch_options = undefined;
    try check(c.git_fetch_options_init(&fetch_opts, c.GIT_FETCH_OPTIONS_VERSION));
    try configureFetch(&fetch_opts, context);
    fetch_opts.depth = 1;

    const spec = if (rev) |value|
        try std.fmt.allocPrintSentinel(allocator, "+{s}:refs/remotes/origin/pinned", .{value}, 0)
    else if (ref_name) |value| name: {
        const short = if (std.mem.startsWith(u8, value, "refs/heads/")) value["refs/heads/".len..] else value;
        break :name if (std.mem.startsWith(u8, short, "refs/"))
            try std.fmt.allocPrintSentinel(allocator, "+{s}:refs/remotes/origin/{s}", .{ short, std.fs.path.basename(short) }, 0)
        else
            try std.fmt.allocPrintSentinel(allocator, "+refs/heads/{s}:refs/remotes/origin/{s}", .{ short, short }, 0);
    } else try allocator.dupeZ(u8, "+HEAD:refs/remotes/origin/HEAD");
    defer allocator.free(spec);

    var refspec_ptrs = [_][*c]u8{@constCast(spec.ptr)};
    var refspecs = c.git_strarray{ .strings = &refspec_ptrs, .count = 1 };
    try check(c.git_remote_fetch(remote.?, &refspecs, &fetch_opts, null));
}

fn resolveObject(allocator: std.mem.Allocator, repo: *c.git_repository, rev: ?[]const u8, ref_name: ?[]const u8) !*c.git_object {
    var candidates: [4]?[]u8 = @splat(null);
    defer for (candidates) |candidate| if (candidate) |value| allocator.free(value);
    var count: usize = 0;
    if (rev) |value| {
        candidates[count] = try allocator.dupe(u8, value);
        count += 1;
    } else if (ref_name) |value| {
        if (std.mem.startsWith(u8, value, "refs/heads/")) {
            candidates[count] = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{value["refs/heads/".len..]});
            count += 1;
        } else if (std.mem.startsWith(u8, value, "refs/")) {
            // `shallowFetchRef` lands any other qualified ref (refs/tags/x)
            // at refs/remotes/origin/<basename>; without this candidate a
            // shallow tag fetch always "missed" and re-fetched the whole
            // repo through the refresh fallback.
            candidates[count] = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{std.fs.path.basename(value)});
            count += 1;
        } else if (!std.mem.startsWith(u8, value, "refs/")) {
            candidates[count] = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{value});
            count += 1;
            candidates[count] = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{value});
            count += 1;
        }
        candidates[count] = try allocator.dupe(u8, value);
        count += 1;
    } else {
        candidates[count] = try allocator.dupe(u8, "refs/remotes/origin/HEAD");
        count += 1;
        candidates[count] = try allocator.dupe(u8, "HEAD");
        count += 1;
    }
    for (candidates[0..count]) |candidate| {
        const expression = try allocator.dupeZ(u8, candidate.?);
        defer allocator.free(expression);
        var object: ?*c.git_object = null;
        if (c.git_revparse_single(&object, repo, expression.ptr) == 0) return object.?;
    }
    return error.FetchGitRevisionNotFound;
}

fn revisionCount(repo: *c.git_repository, oid: *const c.git_oid) !i64 {
    var walk: ?*c.git_revwalk = null;
    try check(c.git_revwalk_new(&walk, repo));
    defer c.git_revwalk_free(walk);
    try check(c.git_revwalk_push(walk.?, oid));
    var next: c.git_oid = undefined;
    var count: i64 = 0;
    while (c.git_revwalk_next(&next, walk.?) == 0) count += 1;
    return count;
}

fn updateSubmodules(repo: *c.git_repository, context: *CallbackContext) !void {
    const State = struct {
        context: *CallbackContext,
        failed: bool = false,
        fn each(submodule: ?*c.git_submodule, _: [*c]const u8, payload: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(payload orelse return -1));
            var opts: c.git_submodule_update_options = undefined;
            if (c.git_submodule_update_options_init(&opts, c.GIT_SUBMODULE_UPDATE_OPTIONS_VERSION) < 0) return -1;
            configureFetch(&opts.fetch_opts, self.context) catch return -1;
            opts.checkout_opts.checkout_strategy = c.GIT_CHECKOUT_FORCE | c.GIT_CHECKOUT_RECREATE_MISSING | c.GIT_CHECKOUT_REMOVE_UNTRACKED;
            // Raw blobs, as for the parent tree (see materialize).
            opts.checkout_opts.disable_filters = 1;
            if (c.git_submodule_update(submodule.?, 1, &opts) < 0) {
                self.failed = true;
                return -1;
            }
            var child: ?*c.git_repository = null;
            if (c.git_submodule_open(&child, submodule.?) == 0) {
                defer c.git_repository_free(child);
                updateSubmodules(child.?, self.context) catch {
                    self.failed = true;
                    return -1;
                };
            }
            return 0;
        }
    };
    var state = State{ .context = context };
    const code = c.git_submodule_foreach(repo, State.each, &state);
    if (code < 0 or state.failed) return gitError();
}

fn createTestCommit(allocator: std.mem.Allocator, repository_path: []const u8, message: []const u8) !void {
    try ensureInitialized();
    const path_z = try allocator.dupeZ(u8, repository_path);
    defer allocator.free(path_z);
    const message_z = try allocator.dupeZ(u8, message);
    defer allocator.free(message_z);
    var repo: ?*c.git_repository = null;
    if (c.git_repository_open(&repo, path_z.ptr) < 0)
        try check(c.git_repository_init(&repo, path_z.ptr, 0));
    defer c.git_repository_free(repo);

    var index: ?*c.git_index = null;
    try check(c.git_repository_index(&index, repo.?));
    defer c.git_index_free(index);
    try check(c.git_index_add_bypath(index.?, "file"));
    try check(c.git_index_write(index.?));
    var tree_oid: c.git_oid = undefined;
    try check(c.git_index_write_tree(&tree_oid, index.?));
    var tree: ?*c.git_tree = null;
    try check(c.git_tree_lookup(&tree, repo.?, &tree_oid));
    defer c.git_tree_free(tree);

    var signature: ?*c.git_signature = null;
    try check(c.git_signature_now(&signature, "Fix Test", "fix@example.invalid"));
    defer c.git_signature_free(signature);
    var parent_object: ?*c.git_object = null;
    defer if (parent_object) |object| c.git_object_free(object);
    var parent_peeled: ?*c.git_object = null;
    defer if (parent_peeled) |object| c.git_object_free(object);
    var parent_commit: ?*c.git_commit = null;
    if (c.git_revparse_single(&parent_object, repo.?, "HEAD") == 0) {
        try check(c.git_object_peel(&parent_peeled, parent_object.?, c.GIT_OBJECT_COMMIT));
        parent_commit = @ptrCast(parent_peeled.?);
    }
    var parents = [_]?*const c.git_commit{parent_commit};
    var commit_oid: c.git_oid = undefined;
    try check(c.git_commit_create(
        &commit_oid,
        repo.?,
        "HEAD",
        signature.?,
        signature.?,
        null,
        message_z.ptr,
        tree.?,
        @intFromBool(parent_commit != null),
        if (parent_commit != null) &parents else null,
    ));
}

test "libgit2 clone, refresh, checkout, and metadata" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "source", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/file", .data = "one" });
    const source = try tmp.dir.realPathFileAlloc(testing.io, "source", testing.allocator);
    defer testing.allocator.free(source);
    const clone = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(clone);
    const clone_path = try std.fs.path.join(testing.allocator, &.{ clone, "clone" });
    defer testing.allocator.free(clone_path);
    const url = try std.fmt.allocPrint(testing.allocator, "file://{s}", .{source});
    defer testing.allocator.free(url);

    try createTestCommit(testing.allocator, source, "one");

    const first = try materialize(testing.allocator, url, clone_path, null, null, false, true, .{});
    try testing.expectEqual(@as(i64, 1), first.rev_count);
    try testing.expect(first.last_modified > 0);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/file", .data = "two" });
    try createTestCommit(testing.allocator, source, "two");
    const second = try materialize(testing.allocator, url, clone_path, null, null, false, true, .{});
    try testing.expect(!std.mem.eql(u8, &first.rev, &second.rev));
    try testing.expectEqual(@as(i64, 2), second.rev_count);
}
