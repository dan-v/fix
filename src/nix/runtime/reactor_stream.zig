//! `std.Io.Reader`/`std.Io.Writer` backed by a raw non-blocking fd + the reactor.
//!
//! These mirror `std.Io.net.Stream.Reader`/`Writer` (their `readVec`/`drain`),
//! but instead of a blocking `netRead`/`netWrite` they do a non-blocking
//! `readv`/`writev` and, on `EAGAIN`, `reactor.waitReadable`/`waitWritable` —
//! which suspends the current I/O task (a fiber on the reactor thread) until the
//! fd is ready, then retries. So the existing `wire.*` framing (which is written
//! against `std.Io.Reader`/`Writer`) runs unchanged on the reactor: many daemon
//! connections drive their protocol concurrently on one thread.
//!
//! MUST be used from inside a `reactor.submit`ted task (so `waitReadable` can
//! yield); the fd MUST be non-blocking. Linux-only (raw readv/writev), like the
//! reactor.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Reactor = @import("reactor.zig").Reactor;

const max_iovecs = 8;

/// Non-blocking connect to a Unix socket, driven by the reactor: create the
/// socket non-blocking, `connect` (which returns EINPROGRESS), `waitWritable`
/// until it settles, then check `SO_ERROR`. MUST run inside a reactor task.
/// Returns the connected non-blocking fd (caller closes it).
pub fn connectUnix(reactor: *Reactor, path: []const u8) !posix.fd_t {
    const rc_fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc_fd) != .SUCCESS) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(rc_fd);
    errdefer _ = linux.close(fd);

    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    const salen: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);

    while (true) {
        switch (linux.errno(linux.connect(fd, @ptrCast(&addr), salen))) {
            .SUCCESS => return fd,
            .INPROGRESS, .AGAIN => {
                reactor.waitWritable(fd);
                var so_err: u32 = 0;
                var len: linux.socklen_t = @sizeOf(u32);
                _ = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_err), &len);
                if (so_err != 0) return error.ConnectFailed;
                return fd;
            },
            .INTR => {},
            else => return error.ConnectFailed,
        }
    }
}

pub const Reader = struct {
    reactor: *Reactor,
    fd: posix.fd_t,
    interface: std.Io.Reader,
    err: ?anyerror = null,

    pub fn init(reactor: *Reactor, fd: posix.fd_t, buffer: []u8) Reader {
        return .{
            .reactor = reactor,
            .fd = fd,
            .interface = .{
                .vtable = &.{ .stream = streamImpl, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
        var iovecs: [max_iovecs]posix.iovec = undefined;
        const dest_n, const data_size = try io_r.writableVectorPosix(&iovecs, data);
        std.debug.assert(iovecs[0].len > 0);
        while (true) {
            const n = linux.readv(self.fd, &iovecs, dest_n);
            switch (linux.errno(n)) {
                .SUCCESS => {
                    if (n == 0) return error.EndOfStream;
                    if (n > data_size) {
                        io_r.end += n - data_size;
                        return data_size;
                    }
                    return n;
                },
                .AGAIN => self.reactor.waitReadable(self.fd),
                .INTR => {},
                .CONNRESET => {
                    self.err = error.ConnectionResetByPeer;
                    return error.ReadFailed;
                },
                else => {
                    self.err = error.Unexpected;
                    return error.ReadFailed;
                },
            }
        }
    }
};

pub const Writer = struct {
    reactor: *Reactor,
    fd: posix.fd_t,
    interface: std.Io.Writer,
    err: ?anyerror = null,

    pub fn init(reactor: *Reactor, fd: posix.fd_t, buffer: []u8) Writer {
        return .{
            .reactor = reactor,
            .fd = fd,
            .interface = .{
                .vtable = &.{ .drain = drain, .sendFile = sendFile },
                .buffer = buffer,
                .end = 0,
            },
        };
    }

    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
        // Gather the writer's buffered bytes, then the `data` slices, then the
        // last slice repeated `splat` times (up to the iovec cap — anything that
        // overflows is handled by a subsequent drain call).
        var iovecs: [max_iovecs]posix.iovec_const = undefined;
        var n_iov: usize = 0;
        const buffered = io_w.buffered();
        if (buffered.len > 0) {
            iovecs[n_iov] = .{ .base = buffered.ptr, .len = buffered.len };
            n_iov += 1;
        }
        if (data.len > 0) {
            for (data[0 .. data.len - 1]) |bytes| {
                if (n_iov == max_iovecs) break;
                if (bytes.len == 0) continue;
                iovecs[n_iov] = .{ .base = bytes.ptr, .len = bytes.len };
                n_iov += 1;
            }
            const pattern = data[data.len - 1];
            if (pattern.len > 0) {
                var reps: usize = 0;
                while (reps < splat and n_iov < max_iovecs) : (reps += 1) {
                    iovecs[n_iov] = .{ .base = pattern.ptr, .len = pattern.len };
                    n_iov += 1;
                }
            }
        }
        if (n_iov == 0) return 0;
        while (true) {
            const n = linux.writev(self.fd, &iovecs, n_iov);
            switch (linux.errno(n)) {
                .SUCCESS => return io_w.consume(n),
                .AGAIN => self.reactor.waitWritable(self.fd),
                .INTR => {},
                .PIPE => {
                    self.err = error.BrokenPipe;
                    return error.WriteFailed;
                },
                else => {
                    self.err = error.Unexpected;
                    return error.WriteFailed;
                },
            }
        }
    }

    fn sendFile(io_w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
        _ = io_w;
        _ = file_reader;
        _ = limit;
        // The daemon wire protocol never sends files; force the caller's
        // fallback (read-then-write) path.
        return error.Unimplemented;
    }
};

// ---------------------------------------------------------------------------
// Tests: run reader + writer as reactor tasks over a non-blocking socketpair and
// exchange a length-prefixed message, exercising suspend-on-EAGAIN both ways.
// ---------------------------------------------------------------------------

const testing = std.testing;
const stable = @import("base").sync;

fn nbSocketpair() ![2]posix.fd_t {
    var fds: [2]i32 = undefined;
    const t: u32 = linux.SOCK.STREAM | linux.SOCK.NONBLOCK;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, t, 0, &fds)) != .SUCCESS) return error.SocketpairFailed;
    return .{ fds[0], fds[1] };
}

const WriteTask = struct {
    reactor: *Reactor,
    fd: posix.fd_t,
    payload: []const u8,
    done: std.atomic.Value(u32) = .init(0),
    fn run(ctx: *anyopaque) void {
        const self: *WriteTask = @ptrCast(@alignCast(ctx));
        var buf: [64]u8 = undefined;
        var w = Writer.init(self.reactor, self.fd, &buf);
        w.interface.writeInt(u64, self.payload.len, .little) catch {};
        w.interface.writeAll(self.payload) catch {};
        w.interface.flush() catch {};
        _ = self.done.fetchAdd(1, .release);
        stable.Futex.wake(&self.done, 1);
    }
};

const ReadTask = struct {
    reactor: *Reactor,
    fd: posix.fd_t,
    got: [64]u8 = undefined,
    got_len: usize = 0,
    matched: std.atomic.Value(u32) = .init(0),
    expect: []const u8 = "",
    fn run(ctx: *anyopaque) void {
        const self: *ReadTask = @ptrCast(@alignCast(ctx));
        var buf: [64]u8 = undefined;
        var r = Reader.init(self.reactor, self.fd, &buf);
        const len = r.interface.takeInt(u64, .little) catch return;
        r.interface.readSliceAll(self.got[0..@intCast(len)]) catch return;
        self.got_len = @intCast(len);
        if (std.mem.eql(u8, self.got[0..self.got_len], self.expect)) _ = self.matched.fetchAdd(1, .release);
        stable.Futex.wake(&self.matched, 0);
    }
    fn await1(self: *ReadTask) void {
        while (self.matched.load(.acquire) == 0) stable.Futex.wait(&self.matched, 0);
    }
};

const daemon_socket = "/nix/var/nix/daemon-socket/socket";
const worker_magic_1: u64 = 0x6e697863;
const worker_magic_2: u64 = 0x6478696f;

const DaemonHandshake = struct {
    reactor: *Reactor,
    magic2: u64 = 0,
    connect_err: bool = false,
    ready: std.atomic.Value(u32) = .init(0),
    fn signal(self: *DaemonHandshake) void {
        _ = self.ready.fetchAdd(1, .release);
        stable.Futex.wake(&self.ready, 1);
    }
    fn run(ctx: *anyopaque) void {
        const self: *DaemonHandshake = @ptrCast(@alignCast(ctx));
        const fd = connectUnix(self.reactor, daemon_socket) catch {
            self.connect_err = true;
            self.signal();
            return;
        };
        defer _ = linux.close(fd);
        var rbuf: [256]u8 = undefined;
        var wbuf: [256]u8 = undefined;
        var r = Reader.init(self.reactor, fd, &rbuf);
        var w = Writer.init(self.reactor, fd, &wbuf);
        w.interface.writeInt(u64, worker_magic_1, .little) catch {
            self.signal();
            return;
        };
        w.interface.flush() catch {
            self.signal();
            return;
        };
        self.magic2 = r.interface.takeInt(u64, .little) catch 0;
        self.signal();
    }
    fn await1(self: *DaemonHandshake) void {
        while (self.ready.load(.acquire) == 0) stable.Futex.wait(&self.ready, 0);
    }
};

test "reactor stream: connect + handshake against the live nix-daemon" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    // Skip if no daemon socket (CI).
    if (linux.errno(linux.access(daemon_socket, linux.F_OK)) != .SUCCESS) return error.SkipZigTest;

    const r = try Reactor.init(testing.allocator);
    defer r.deinit();
    try r.start();

    var hs: DaemonHandshake = .{ .reactor = r };
    try r.submit(DaemonHandshake.run, &hs);
    hs.await1();
    if (hs.connect_err) return error.SkipZigTest; // daemon present but unreachable
    try testing.expectEqual(worker_magic_2, hs.magic2);
}

test "reactor stream: reader + writer exchange a message over one reactor thread" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const r = try Reactor.init(testing.allocator);
    defer r.deinit();
    try r.start();

    const pair = try nbSocketpair();
    defer _ = linux.close(pair[0]);
    defer _ = linux.close(pair[1]);

    const msg = "hello over the reactor stream, long enough to matter";
    var rt: ReadTask = .{ .reactor = r, .fd = pair[0], .expect = msg };
    var wt: WriteTask = .{ .reactor = r, .fd = pair[1], .payload = msg };
    // Submit the reader first: it parks on EAGAIN until the writer feeds it.
    try r.submit(ReadTask.run, &rt);
    try r.submit(WriteTask.run, &wt);
    rt.await1();
    try testing.expectEqual(@as(u32, 1), rt.matched.load(.acquire));
    try testing.expectEqualStrings(msg, rt.got[0..rt.got_len]);
}
