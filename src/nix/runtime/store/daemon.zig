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

/// Whether the daemon considers this client trusted (from the >=1.35
/// handshake). Trusted clients may perform privileged ops without restriction.
pub const Trust = enum { unknown, trusted, not_trusted };

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
    /// `runtime.nar.serialize`). Returns the resulting store path (owned by
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
                wire.stderr_next => try wire.skipString(self.r()),
                wire.stderr_start_activity => try self.skipStartActivity(),
                wire.stderr_stop_activity => _ = try wire.readInt(self.r()),
                wire.stderr_result => try self.skipResult(),
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

    fn skipStartActivity(self: *DaemonStore) !void {
        _ = try wire.readInt(self.r()); // act id
        _ = try wire.readInt(self.r()); // level
        _ = try wire.readInt(self.r()); // type
        try wire.skipString(self.r()); // text
        try self.skipFields();
        _ = try wire.readInt(self.r()); // parent
    }

    fn skipResult(self: *DaemonStore) !void {
        _ = try wire.readInt(self.r()); // act id
        _ = try wire.readInt(self.r()); // type
        try self.skipFields();
    }
};
