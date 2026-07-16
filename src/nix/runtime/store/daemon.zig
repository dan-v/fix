//! Nix/Lix nix-daemon worker-protocol client.
//!
//! Connects to the daemon's Unix socket, performs the version-negotiating
//! handshake, and exposes store operations. Store mutation on a daemon-managed
//! `/nix/store` (the normal case: the store is `root:nixbld`, not user
//! writable) must go through here rather than touching the filesystem.
//!
//! Phase 1 covers the read/query ops (`isValidPath`, `queryValidPaths`); the
//! add/build ops land in later phases. The connection owns the framed
//! reader/writer and drains the `STDERR_*` sideband after every op.

const std = @import("std");
const wire = @import("wire.zig");

pub const default_socket_path = "/nix/var/nix/daemon-socket/socket";

/// Result type `resProgress` (Nix logging.hh) — a `[done, expected, ...]` update.
const res_progress: u64 = 105;

/// A consumer of the daemon's build activity/log stream (see `buildPaths`).
/// Callbacks run on the calling thread while the build is in progress.
pub const BuildSink = struct {
    context: *anyopaque,
    /// An activity started: `id`, its Nix `ActivityType`, and a description
    /// (e.g. "building '/nix/store/….drv'", "substituting …").
    on_start: *const fn (context: *anyopaque, id: u64, activity_type: u64, text: []const u8) void,
    /// An activity finished.
    on_stop: *const fn (context: *anyopaque, id: u64) void,
    /// Progress for activity `id`: `done`/`expected` units.
    on_progress: *const fn (context: *anyopaque, id: u64, done: u64, expected: u64) void,
    /// A raw log line.
    on_log: *const fn (context: *anyopaque, line: []const u8) void,
};

/// Whether the daemon considers this client trusted (from the >=1.35
/// handshake). Trusted clients may perform privileged ops without restriction.
pub const Trust = enum { unknown, trusted, not_trusted };

/// Build realization mode sent with `build_paths` (Nix's `BuildMode`): the
/// default build, `--repair` (rebuild and fix corrupted paths), or `--check`
/// (rebuild and verify outputs are unchanged).
pub const BuildMode = enum(u64) { normal = 0, repair = 1, check = 2 };

/// A `name = value` daemon setting carried in the `set_options` overrides map.
pub const Setting = struct { name: []const u8, value: []const u8 };

/// Per-connection daemon settings applied via `set_options` (op 19). Mirrors
/// the client settings Nix sends after the handshake: the fixed fields plus a
/// trailing overrides map for any other `nix.conf` key (e.g. `timeout`). The
/// daemon applies the map after the fixed fields, so an override wins.
pub const BuildSettings = struct {
    keep_failed: bool = false,
    keep_going: bool = false,
    fallback: bool = false,
    /// Daemon log verbosity (Nix `Verbosity`: 0 = error … 7 = vomit).
    verbosity: u64 = 0,
    max_build_jobs: u64 = 1,
    max_silent_time: u64 = 0,
    build_cores: u64 = 0,
    use_substitutes: bool = true,
    overrides: []const Setting = &.{},
};

pub const DaemonStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    rbuf: []u8,
    wbuf: []u8,
    /// The daemon's advertised protocol version (its own, not the negotiated
    /// minimum — version-gated wire fields key off `protocolMinor` of this).
    daemon_version: u64 = 0,
    trusted: Trust = .unknown,
    /// Last daemon-reported error message (owned), surfaced with
    /// `error.DaemonError`. Freed on deinit / overwritten on the next error.
    last_error: ?[]u8 = null,
    /// While true, STDERR_NEXT build-log lines are forwarded to our stderr
    /// (set during `buildPaths`) instead of being discarded.
    log_build: bool = false,
    /// Set during `buildPaths` to forward the activity/log stream (progress
    /// nodes). When set, logs go to the sink instead of stderr.
    build_sink: ?BuildSink = null,

    /// Connect to the daemon socket and complete the handshake. Heap-allocated
    /// so the framed reader/writer (which hold interior pointers) stay put.
    pub fn connect(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8) !*DaemonStore {
        const self = try allocator.create(DaemonStore);
        errdefer allocator.destroy(self);

        const addr = try std.Io.net.UnixAddress.init(socket_path);
        const stream = try addr.connect(io);
        errdefer stream.close(io);

        const rbuf = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(rbuf);
        const wbuf = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(wbuf);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .reader = std.Io.net.Stream.Reader.init(stream, io, rbuf),
            .writer = std.Io.net.Stream.Writer.init(stream, io, wbuf),
            .rbuf = rbuf,
            .wbuf = wbuf,
        };

        try self.handshake();
        return self;
    }

    pub fn deinit(self: *DaemonStore) void {
        if (self.last_error) |msg| self.allocator.free(msg);
        self.stream.close(self.io);
        self.allocator.free(self.rbuf);
        self.allocator.free(self.wbuf);
        self.allocator.destroy(self);
    }

    fn w(self: *DaemonStore) *std.Io.Writer {
        return &self.writer.interface;
    }
    fn r(self: *DaemonStore) *std.Io.Reader {
        return &self.reader.interface;
    }

    fn handshake(self: *DaemonStore) !void {
        try wire.writeInt(self.w(), wire.worker_magic_1);
        try self.w().flush();

        if ((try wire.readInt(self.r())) != wire.worker_magic_2) return error.WorkerMagicMismatch;
        self.daemon_version = try wire.readInt(self.r());
        if (wire.protocolMajor(self.daemon_version) != wire.protocolMajor(wire.protocol_version))
            return error.ProtocolMajorMismatch;

        try wire.writeInt(self.w(), wire.protocol_version);
        const minor = wire.protocolMinor(self.daemon_version);
        // Two obsolete fields the daemon still expects on the modern protocol:
        // CPU affinity (>=14) and reserveSpace (>=11). Both send 0/false.
        if (minor >= 14) try wire.writeInt(self.w(), 0);
        if (minor >= 11) try wire.writeInt(self.w(), 0);
        try self.w().flush();

        if (minor >= 33) {
            const nix_version = try wire.readString(self.allocator, self.r());
            self.allocator.free(nix_version); // informational; unused
        }
        if (minor >= 35) {
            self.trusted = switch (try wire.readInt(self.r())) {
                1 => .trusted,
                2 => .not_trusted,
                else => .unknown,
            };
        }
        try self.processStderr();
    }

    // --- operations -------------------------------------------------------

    /// Whether `path` (a full `/nix/store/...` path) is a valid store path.
    pub fn isValidPath(self: *DaemonStore, path: []const u8) !bool {
        try self.beginOp(.is_valid_path);
        try wire.writeString(self.w(), path);
        try self.flushAndDrain();
        return try wire.readBool(self.r());
    }

    /// Of `paths`, those the daemon considers valid. When `substitute` is true
    /// the daemon may consult substituters. Caller frees each element and the
    /// returned slice.
    pub fn queryValidPaths(self: *DaemonStore, allocator: std.mem.Allocator, paths: []const []const u8, substitute: bool) ![][]u8 {
        try self.beginOp(.query_valid_paths);
        try wire.writeStrings(self.w(), paths);
        if (wire.protocolMinor(self.daemon_version) >= 27) try wire.writeBool(self.w(), substitute);
        try self.flushAndDrain();
        return try wire.readStrings(allocator, self.r());
    }

    /// Add `text` to the store as a text-addressed object named `name`
    /// (`references` are full store paths it refers to). This is what a `.drv`
    /// file and `builtins.toFile` need. Returns the resulting `/nix/store/...`
    /// path (owned by `allocator`). Idempotent: an already-present object just
    /// returns its path.
    ///
    /// Uses the modern `AddToStore` op with text ingestion rather than the
    /// legacy `AddTextToStore` (op 8) — Lix rejects op 8 once the negotiated
    /// protocol is >= 1.25, so op 8 is not portable across Lix/Nix. The content
    /// is streamed raw through the framed sink; the daemon hashes it under the
    /// `text:sha256` scheme (same addressing as `builtins.toFile`/`.drv`
    /// paths).
    pub fn addTextToStore(self: *DaemonStore, allocator: std.mem.Allocator, name: []const u8, text: []const u8, references: []const []const u8) ![]u8 {
        try self.beginOp(.add_to_store);
        try wire.writeString(self.w(), name);
        try wire.writeString(self.w(), "text:sha256");
        try wire.writeStrings(self.w(), references);
        try wire.writeBool(self.w(), false); // repair
        try self.writeFramed(text);
        try self.flushAndDrain();
        return try self.readValidPathInfo(allocator);
    }

    /// Add a NAR-serialized tree to the store under `name`, content-addressed
    /// recursively (`nar:sha256`) — the addressing `builtins.path`/`filterSource`
    /// and fetched sources use. `nar_bytes` is a `nix-archive-1` stream (see
    /// `host.nar.serialize`). Returns the resulting store path (owned by
    /// `allocator`). Idempotent.
    pub fn addPath(self: *DaemonStore, allocator: std.mem.Allocator, name: []const u8, nar_bytes: []const u8, references: []const []const u8) ![]u8 {
        try self.beginOp(.add_to_store);
        try wire.writeString(self.w(), name);
        // `fixed:r:sha256` = fixed-output, recursive (NAR) ingestion, sha256 —
        // the addressing `builtins.path`/`nix store add` use. (The daemon
        // rejects `nar:...`; recognized prefixes are `text` and `fixed`.)
        try wire.writeString(self.w(), "fixed:r:sha256");
        try wire.writeStrings(self.w(), references);
        try wire.writeBool(self.w(), false); // repair
        try self.writeFramed(nar_bytes);
        try self.flushAndDrain();
        return try self.readValidPathInfo(allocator);
    }

    /// Read an `AddToStore` response — a `ValidPathInfo` — returning its path
    /// (owned by `allocator`) and consuming the rest so the connection stays in
    /// sync for the next op. Field order (protocol >= 16): path, deriver,
    /// narHash, references, registrationTime, narSize, ultimate, sigs, ca.
    fn readValidPathInfo(self: *DaemonStore, allocator: std.mem.Allocator) ![]u8 {
        const path = try wire.readString(allocator, self.r());
        errdefer allocator.free(path);
        try wire.skipString(self.r()); // deriver
        try wire.skipString(self.r()); // narHash
        try wire.skipStrings(self.r()); // references
        _ = try wire.readInt(self.r()); // registrationTime
        _ = try wire.readInt(self.r()); // narSize
        _ = try wire.readInt(self.r()); // ultimate (bool)
        try wire.skipStrings(self.r()); // sigs
        try wire.skipString(self.r()); // ca
        return path;
    }

    /// Add a flat (non-NAR) file's raw `bytes` to the store under `name`,
    /// content-addressed as `fixed:sha256` (flat) — the addressing
    /// `builtins.fetchurl` uses. Returns the store path (owned by `allocator`).
    pub fn addFlatFile(self: *DaemonStore, allocator: std.mem.Allocator, name: []const u8, bytes: []const u8, references: []const []const u8) ![]u8 {
        try self.beginOp(.add_to_store);
        try wire.writeString(self.w(), name);
        try wire.writeString(self.w(), "fixed:sha256"); // flat (no `r:`)
        try wire.writeStrings(self.w(), references);
        try wire.writeBool(self.w(), false); // repair
        try self.writeFramed(bytes);
        try self.flushAndDrain();
        return try self.readValidPathInfo(allocator);
    }

    /// Stream `data` through the worker protocol's framed sink: one
    /// `[u64 len][bytes]` frame followed by a zero-length terminator frame.
    /// Frame payloads are raw (not 8-byte padded like protocol strings).
    fn writeFramed(self: *DaemonStore, data: []const u8) !void {
        if (data.len != 0) {
            try wire.writeInt(self.w(), data.len);
            try self.w().writeAll(data);
        }
        try wire.writeInt(self.w(), 0);
    }

    /// Realize `derived_paths` (each a legacy `<drvpath>!<outputs>` string, e.g.
    /// `/nix/store/xxx.drv!*` for all outputs). The daemon builds or substitutes
    /// the outputs; build logs stream over STDERR_NEXT and are forwarded to our
    /// stderr while this runs. Errors (with the daemon's message) on failure.
    pub fn buildPaths(self: *DaemonStore, derived_paths: []const []const u8, sink: ?BuildSink, mode: BuildMode) !void {
        try self.beginOp(.build_paths);
        try wire.writeStrings(self.w(), derived_paths);
        try wire.writeInt(self.w(), @intFromEnum(mode));
        self.build_sink = sink;
        self.log_build = sink == null; // sink consumes logs itself
        defer {
            self.build_sink = null;
            self.log_build = false;
        }
        try self.flushAndDrain();
        _ = try wire.readInt(self.r()); // dummy result int
    }

    /// Register an indirect GC root (`add_indirect_root`, op 12): the daemon
    /// records `<gcroots>/auto/<hash>` -> `link_path`, so the store path the
    /// symlink at `link_path` points to survives GC. `link_path` must be an
    /// existing absolute symlink into the store; the caller creates it first.
    pub fn addIndirectRoot(self: *DaemonStore, link_path: []const u8) !void {
        try self.beginOp(.add_indirect_root);
        try wire.writeString(self.w(), link_path);
        try self.flushAndDrain(); // no result, just the stderr stream
    }

    /// Send per-connection client settings (`set_options`, op 19). Field order
    /// matches Nix's `RemoteStore::setOptions`: the fixed settings, four obsolete
    /// placeholders, then (protocol minor >= 12) the `name/value` overrides map.
    pub fn setOptions(self: *DaemonStore, s: BuildSettings) !void {
        try self.beginOp(.set_options);
        const out = self.w();
        try wire.writeBool(out, s.keep_failed);
        try wire.writeBool(out, s.keep_going);
        try wire.writeBool(out, s.fallback);
        try wire.writeInt(out, s.verbosity);
        try wire.writeInt(out, s.max_build_jobs);
        try wire.writeInt(out, s.max_silent_time);
        try wire.writeInt(out, 0); // obsolete useBuildHook
        try wire.writeInt(out, 7); // verboseBuild != lvlError -> quiet build logs
        try wire.writeInt(out, 0); // obsolete logType
        try wire.writeInt(out, 0); // obsolete printBuildTrace
        try wire.writeInt(out, s.build_cores);
        try wire.writeBool(out, s.use_substitutes);
        if (wire.protocolMinor(self.daemon_version) >= 12) {
            try wire.writeInt(out, s.overrides.len);
            for (s.overrides) |o| {
                try wire.writeString(out, o.name);
                try wire.writeString(out, o.value);
            }
        }
        try self.flushAndDrain(); // set_options has no result, just the stderr stream
    }

    // --- op plumbing ------------------------------------------------------

    fn beginOp(self: *DaemonStore, op: wire.Op) !void {
        try wire.writeInt(self.w(), @intFromEnum(op));
    }

    /// Flush the request and drain the STDERR_* sideband up to the response.
    fn flushAndDrain(self: *DaemonStore) !void {
        try self.w().flush();
        try self.processStderr();
    }

    /// Consume the STDERR_* message stream until STDERR_LAST. Log lines are
    /// discarded; a STDERR_ERROR is captured into `last_error` and surfaced as
    /// `error.DaemonError`. Activity/result records are skipped structurally so
    /// the stream stays in sync.
    fn processStderr(self: *DaemonStore) !void {
        while (true) {
            switch (try wire.readInt(self.r())) {
                wire.stderr_last => return,
                wire.stderr_error => return self.readError(),
                wire.stderr_next => if (self.build_sink) |s| {
                    const line = try wire.readString(self.allocator, self.r());
                    defer self.allocator.free(line);
                    s.on_log(s.context, line);
                } else if (self.log_build) {
                    const line = try wire.readString(self.allocator, self.r());
                    defer self.allocator.free(line);
                    std.debug.print("{s}", .{line});
                } else try wire.skipString(self.r()),
                wire.stderr_start_activity => try self.readStartActivity(),
                wire.stderr_stop_activity => {
                    const act = try wire.readInt(self.r());
                    if (self.build_sink) |s| s.on_stop(s.context, act);
                },
                wire.stderr_result => try self.readResult(),
                // Legacy non-framed source/sink: not used by the ops we issue.
                wire.stderr_read, wire.stderr_write => return error.UnexpectedStderrStreaming,
                else => return error.UnknownStderrMessage,
            }
        }
    }

    fn readError(self: *DaemonStore) !void {
        // Proto >= 26 Error serialization: type, level, name, msg, havePos,
        // then a trace list. We keep `msg`; everything else is skipped.
        try wire.skipString(self.r()); // type ("Error")
        _ = try wire.readInt(self.r()); // level
        try wire.skipString(self.r()); // name (ignored)
        const msg = try wire.readString(self.allocator, self.r());
        // Deliberately no errdefer-free on `msg`: it becomes `last_error`, which
        // we keep across the `error.DaemonError` return (an errdefer here would
        // free the buffer we just stored and leave a dangling `last_error`).
        _ = try wire.readInt(self.r()); // havePos (0)
        const n_traces = try wire.readInt(self.r());
        if (n_traces > wire.max_wire_len) return error.WireListTooLong;
        var i: u64 = 0;
        while (i < n_traces) : (i += 1) {
            _ = try wire.readInt(self.r()); // havePos
            try wire.skipString(self.r()); // trace hint
        }
        if (self.last_error) |old| self.allocator.free(old);
        self.last_error = msg;
        return error.DaemonError;
    }

    fn skipFields(self: *DaemonStore) !void {
        const n = try wire.readInt(self.r());
        if (n > wire.max_wire_len) return error.WireListTooLong;
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            switch (try wire.readInt(self.r())) {
                0 => _ = try wire.readInt(self.r()), // int field
                1 => try wire.skipString(self.r()), // string field
                else => return error.UnknownActivityField,
            }
        }
    }

    fn readStartActivity(self: *DaemonStore) !void {
        const act = try wire.readInt(self.r());
        _ = try wire.readInt(self.r()); // level
        const activity_type = try wire.readInt(self.r());
        const text = try wire.readString(self.allocator, self.r());
        defer self.allocator.free(text);
        try self.skipFields();
        _ = try wire.readInt(self.r()); // parent
        if (self.build_sink) |s| if (text.len != 0) s.on_start(s.context, act, activity_type, text);
    }

    fn readResult(self: *DaemonStore) !void {
        const act = try wire.readInt(self.r());
        const result_type = try wire.readInt(self.r());
        // Capture the first two int fields; for `resProgress` they are
        // done/expected. Consume the rest to stay in sync.
        const n = try wire.readInt(self.r());
        if (n > wire.max_wire_len) return error.WireListTooLong;
        var ints: [2]u64 = .{ 0, 0 };
        var int_count: usize = 0;
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            switch (try wire.readInt(self.r())) {
                0 => {
                    const v = try wire.readInt(self.r());
                    if (int_count < ints.len) ints[int_count] = v;
                    int_count += 1;
                },
                1 => try wire.skipString(self.r()),
                else => return error.UnknownActivityField,
            }
        }
        if (self.build_sink) |s| if (result_type == res_progress) s.on_progress(s.context, act, ints[0], ints[1]);
    }
};
