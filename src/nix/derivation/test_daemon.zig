//! Minimal worker-protocol daemon used by DerivationStore realization tests.
//!
//! It intentionally implements only the operations exercised by the recipe
//! registry: handshake, isValidPath, add-to-store (text/NAR/flat), and
//! buildPaths. It is not a general nix-daemon emulator.

const std = @import("std");
const runtime_store = @import("runtime").store;
const wire = runtime_store.wire;

pub const FakeDaemon = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: []u8,
    server: std.Io.net.Server,
    thread: std.Thread,
    mu: std.Thread.Mutex = .{},
    valid_paths: std.StringHashMapUnmanaged(void) = .empty,
    operations: std.ArrayListUnmanaged(Operation) = .empty,
    fail_next_add: bool = false,
    fail_next_build: bool = false,
    server_error: ?anyerror = null,

    pub const Kind = enum { query, text, nar, flat, build };

    const Operation = struct {
        kind: Kind,
        subject: []u8,
        payload: []u8,
        references: [][]u8,

        fn deinit(self: Operation, allocator: std.mem.Allocator) void {
            allocator.free(self.subject);
            allocator.free(self.payload);
            for (self.references) |reference| allocator.free(reference);
            allocator.free(self.references);
        }
    };

    var next_socket_id: std.atomic.Value(u64) = .init(0);

    pub fn makeSocketPath(allocator: std.mem.Allocator) ![]u8 {
        const id = next_socket_id.fetchAdd(1, .monotonic);
        return std.fmt.allocPrint(allocator, "\x00fix-ifd-test-{d}-{d}", .{ std.Thread.getCurrentId(), id });
    }

    pub fn start(allocator: std.mem.Allocator, io: std.Io) !*FakeDaemon {
        const socket_path = try makeSocketPath(allocator);
        defer allocator.free(socket_path);
        return startAt(allocator, io, socket_path);
    }

    pub fn startAt(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8) !*FakeDaemon {
        const owned_path = try allocator.dupe(u8, socket_path);
        errdefer allocator.free(owned_path);
        const address = try std.Io.net.UnixAddress.init(owned_path);
        var server = try address.listen(io, .{});
        errdefer server.deinit(io);

        const self = try allocator.create(FakeDaemon);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .socket_path = owned_path,
            .server = server,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    /// The connected DerivationStore must be deinitialized before this helper,
    /// so closing the client stream lets the server thread leave its read loop.
    pub fn deinit(self: *FakeDaemon) void {
        // Also cancels a still-blocked accept if a test fails before connecting.
        self.server.socket.close(self.io);
        self.thread.join();
        self.mu.lock();
        var valid = self.valid_paths.keyIterator();
        while (valid.next()) |path| self.allocator.free(path.*);
        self.valid_paths.deinit(self.allocator);
        for (self.operations.items) |operation| operation.deinit(self.allocator);
        self.operations.deinit(self.allocator);
        self.mu.unlock();
        self.allocator.free(self.socket_path);
        self.allocator.destroy(self);
    }

    pub fn socketPath(self: *const FakeDaemon) []const u8 {
        return self.socket_path;
    }

    pub fn markValid(self: *FakeDaemon, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        self.mu.lock();
        defer self.mu.unlock();
        if (self.valid_paths.contains(path)) {
            self.allocator.free(owned);
            return;
        }
        try self.valid_paths.put(self.allocator, owned, {});
    }

    pub fn failNextAdd(self: *FakeDaemon) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.fail_next_add = true;
    }

    pub fn failNextBuild(self: *FakeDaemon) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.fail_next_build = true;
    }

    pub fn count(self: *FakeDaemon, kind: Kind) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var result: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind == kind) result += 1;
        }
        return result;
    }

    pub fn kindAt(self: *FakeDaemon, index: usize) ?Kind {
        self.mu.lock();
        defer self.mu.unlock();
        if (index >= self.operations.items.len) return null;
        return self.operations.items[index].kind;
    }

    pub fn subjectEquals(self: *FakeDaemon, index: usize, expected: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (index >= self.operations.items.len) return false;
        return std.mem.eql(u8, self.operations.items[index].subject, expected);
    }

    pub fn payloadEquals(self: *FakeDaemon, index: usize, expected: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (index >= self.operations.items.len) return false;
        return std.mem.eql(u8, self.operations.items[index].payload, expected);
    }

    pub fn nthSubjectEquals(self: *FakeDaemon, kind: Kind, n: usize, expected: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var seen: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind != kind) continue;
            if (seen == n) return std.mem.eql(u8, operation.subject, expected);
            seen += 1;
        }
        return false;
    }

    pub fn nthPayloadEquals(self: *FakeDaemon, kind: Kind, n: usize, expected: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var seen: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind != kind) continue;
            if (seen == n) return std.mem.eql(u8, operation.payload, expected);
            seen += 1;
        }
        return false;
    }

    pub fn nthMaterializationSubjectEquals(self: *FakeDaemon, n: usize, expected: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var seen: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind != .text and operation.kind != .nar and operation.kind != .flat) continue;
            if (seen == n) return std.mem.eql(u8, operation.subject, expected);
            seen += 1;
        }
        return false;
    }

    pub fn materializationCount(self: *FakeDaemon) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var result: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind == .text or operation.kind == .nar or operation.kind == .flat) result += 1;
        }
        return result;
    }

    pub fn serverResult(self: *FakeDaemon) !void {
        if (self.server_error) |err| return err;
    }

    fn serve(self: *FakeDaemon) void {
        self.serveFallible() catch |err| {
            self.server_error = err;
        };
    }

    fn serveFallible(self: *FakeDaemon) !void {
        const stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        var read_buffer: [64 * 1024]u8 = undefined;
        var write_buffer: [64 * 1024]u8 = undefined;
        var reader = std.Io.net.Stream.Reader.init(stream, self.io, &read_buffer);
        var writer = std.Io.net.Stream.Writer.init(stream, self.io, &write_buffer);
        const input = &reader.interface;
        const output = &writer.interface;

        if ((try wire.readInt(input)) != wire.worker_magic_1) return error.WorkerMagicMismatch;
        try wire.writeInt(output, wire.worker_magic_2);
        try wire.writeInt(output, wire.protocol_version);
        try output.flush();
        _ = try wire.readInt(input); // client protocol
        _ = try wire.readInt(input); // obsolete CPU affinity
        _ = try wire.readInt(input); // obsolete reserveSpace
        try wire.writeString(output, "fix-test-daemon");
        try wire.writeInt(output, 1); // trusted
        try wire.writeInt(output, wire.stderr_last);
        try output.flush();

        while (true) {
            const raw_op = wire.readInt(input) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            const op: wire.Op = std.meta.intToEnum(wire.Op, raw_op) catch return error.UnsupportedWorkerOperation;
            switch (op) {
                .is_valid_path => try self.handleIsValid(input, output),
                .add_to_store => try self.handleAdd(input, output),
                .build_paths => try self.handleBuild(input, output),
                else => return error.UnsupportedWorkerOperation,
            }
        }
    }

    fn handleIsValid(self: *FakeDaemon, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        const path = try wire.readString(self.allocator, input);
        defer self.allocator.free(path);
        try self.appendOperation(.query, path, "", &.{});
        self.mu.lock();
        const valid = self.valid_paths.contains(path);
        self.mu.unlock();
        try wire.writeInt(output, wire.stderr_last);
        try wire.writeBool(output, valid);
        try output.flush();
    }

    fn handleAdd(self: *FakeDaemon, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        const name = try wire.readString(self.allocator, input);
        defer self.allocator.free(name);
        const content_address = try wire.readString(self.allocator, input);
        defer self.allocator.free(content_address);
        const references = try wire.readStrings(self.allocator, input);
        defer freeStrings(self.allocator, references);
        _ = try wire.readBool(input); // repair
        const payload = try readFramed(self.allocator, input);
        defer self.allocator.free(payload);
        const kind: Kind = if (std.mem.eql(u8, content_address, "text:sha256"))
            .text
        else if (std.mem.eql(u8, content_address, "fixed:r:sha256"))
            .nar
        else if (std.mem.eql(u8, content_address, "fixed:sha256"))
            .flat
        else
            return error.UnsupportedContentAddress;
        try self.appendOperation(kind, name, payload, references);

        self.mu.lock();
        const fail = self.fail_next_add;
        self.fail_next_add = false;
        self.mu.unlock();
        if (fail) return writeDaemonError(output, "scripted permanent add failure");

        try wire.writeInt(output, wire.stderr_last);
        const returned_path = try std.fmt.allocPrint(self.allocator, "/nix/store/fake-{s}", .{name});
        defer self.allocator.free(returned_path);
        try writeValidPathInfo(output, returned_path);
        try output.flush();
    }

    fn handleBuild(self: *FakeDaemon, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        const paths = try wire.readStrings(self.allocator, input);
        defer freeStrings(self.allocator, paths);
        _ = try wire.readInt(input); // build mode
        for (paths) |path| try self.appendOperation(.build, path, "", &.{});

        self.mu.lock();
        const fail = self.fail_next_build;
        self.fail_next_build = false;
        self.mu.unlock();
        if (fail) return writeDaemonError(output, "scripted permanent build failure");

        try wire.writeInt(output, wire.stderr_last);
        try wire.writeInt(output, 0);
        try output.flush();
    }

    fn appendOperation(self: *FakeDaemon, kind: Kind, subject: []const u8, payload: []const u8, references: []const []const u8) !void {
        const owned_subject = try self.allocator.dupe(u8, subject);
        errdefer self.allocator.free(owned_subject);
        const owned_payload = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(owned_payload);
        const owned_references = try cloneStrings(self.allocator, references);
        errdefer freeStrings(self.allocator, owned_references);
        self.mu.lock();
        defer self.mu.unlock();
        try self.operations.append(self.allocator, .{
            .kind = kind,
            .subject = owned_subject,
            .payload = owned_payload,
            .references = owned_references,
        });
    }
};

fn cloneStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![][]u8 {
    const result = try allocator.alloc([]u8, strings.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |string| allocator.free(string);
        allocator.free(result);
    }
    while (initialized < result.len) : (initialized += 1) {
        result[initialized] = try allocator.dupe(u8, strings[initialized]);
    }
    return result;
}

fn freeStrings(allocator: std.mem.Allocator, strings: []const []u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

fn readFramed(allocator: std.mem.Allocator, input: *std.Io.Reader) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);
    while (true) {
        const len = try wire.readInt(input);
        if (len == 0) return result.toOwnedSlice(allocator);
        if (len > wire.max_wire_len) return error.WireStringTooLong;
        const old_len = result.items.len;
        try result.resize(allocator, old_len + @as(usize, @intCast(len)));
        try input.readSliceAll(result.items[old_len..]);
    }
}

fn writeDaemonError(output: *std.Io.Writer, message: []const u8) !void {
    try wire.writeInt(output, wire.stderr_error);
    try wire.writeString(output, "Error");
    try wire.writeInt(output, 0);
    try wire.writeString(output, "Error");
    try wire.writeString(output, message);
    try wire.writeInt(output, 0); // no position
    try wire.writeInt(output, 0); // no traces
    try output.flush();
}

fn writeValidPathInfo(output: *std.Io.Writer, path: []const u8) !void {
    try wire.writeString(output, path);
    try wire.writeString(output, ""); // deriver
    try wire.writeString(output, "sha256:fake");
    try wire.writeStrings(output, &.{});
    try wire.writeInt(output, 0); // registration time
    try wire.writeInt(output, 0); // NAR size
    try wire.writeInt(output, 0); // ultimate
    try wire.writeStrings(output, &.{}); // signatures
    try wire.writeString(output, ""); // content address
}

// Keep the protocol helper independently compiled: Task 4's guarded RED tests
// must not hide syntax or framing mistakes in test-only infrastructure.
test "fake derivation daemon supports the concrete DaemonStore protocol subset" {
    var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
    defer fake.deinit();

    const daemon = try runtime_store.DaemonStore.connect(std.testing.allocator, std.testing.io, fake.socketPath());
    defer daemon.deinit();
    try std.testing.expect(!(try daemon.isValidPath("/nix/store/missing")));
    const written = try daemon.addTextToStore(std.testing.allocator, "example", "payload", &.{});
    defer std.testing.allocator.free(written);
    try daemon.buildPaths(&.{"/nix/store/example.drv^out"}, null, .normal);
    try std.testing.expectEqual(@as(usize, 1), fake.count(.query));
    try std.testing.expectEqual(@as(usize, 1), fake.count(.text));
    try std.testing.expectEqual(@as(usize, 1), fake.count(.build));
}
