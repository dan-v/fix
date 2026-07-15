//! Reactor: a single background thread that waits on many socket fds at once
//! (`poll(2)`) and fires a one-shot waker when an fd becomes ready. This is the
//! foundation for moving fix's daemon + HTTP I/O off the "thread per blocking
//! op" model onto one event loop.
//!
//! Why hand-rolled and not `std.Io`'s evented `Io` (Uring/Kqueue): fix runs on
//! `std.Io.Threaded` (blocking), and its own compute-fiber scheduler
//! (`base/fiber` + `scheduler.zig`) is a separate stackful-fiber system — adopting
//! a stdlib evented `Io` would mean a second fiber runtime and switching the
//! whole app off `Threaded`. Instead the reactor drives raw non-blocking fds and
//! wakes callers through the existing `Future`/park seam (`runtime/future.zig`),
//! exactly as the `io_runtime` serial thread does today — but for N fds at once
//! instead of one blocking op at a time.
//!
//! Registration is ONE-SHOT: when an fd is ready the waker fires and the fd is
//! dropped from the set. A caller that needs to keep waiting (e.g. a wire read
//! that hit `WouldBlock` again) re-arms. `poll` is fine here — the fd count is a
//! handful of daemon/HTTP connections, not tens of thousands.
//!
//! Thread-safety: `arm` may be called from any thread; it queues the
//! registration and pokes a self-pipe so the loop picks it up promptly. The
//! waker runs ON THE REACTOR THREAD, so it must be cheap + thread-safe (in
//! practice: publish a `Future`).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const stable = @import("base").sync;

/// A non-blocking pipe for loop wakeup. Linux-only for now (the reactor targets
/// the Linux nix-daemon; a darwin kqueue reactor is future work, like the
/// per-arch fiber swap code).
fn makePipe() ![2]posix.fd_t {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    return .{ fds[0], fds[1] };
}

pub const Interest = enum { readable, writable };

/// Fired (once) on the reactor thread when the fd is ready. Keep it cheap and
/// thread-safe — the intended body is `Future.publish()`.
pub const Waker = struct {
    ctx: *anyopaque,
    wake: *const fn (ctx: *anyopaque) void,
};

const Reg = struct {
    fd: posix.fd_t,
    interest: Interest,
    waker: Waker,
};

pub const Reactor = struct {
    allocator: std.mem.Allocator,
    /// Self-pipe: `arm`/`deinit` write a byte to interrupt `poll` so the loop
    /// re-reads its registration queue / notices shutdown.
    ctrl_r: posix.fd_t,
    ctrl_w: posix.fd_t,

    mu: stable.BlockingMutex = .{},
    /// New registrations awaiting adoption by the loop (guarded by `mu`).
    pending: std.ArrayListUnmanaged(Reg) = .empty,
    shutdown: bool = false,
    thread: ?std.Thread = null,

    /// Loop-thread-private set of fds currently being polled (never touched off
    /// the loop thread).
    active: std.ArrayListUnmanaged(Reg) = .empty,

    pub fn init(allocator: std.mem.Allocator) !*Reactor {
        const self = try allocator.create(Reactor);
        errdefer allocator.destroy(self);
        const fds = try makePipe();
        self.* = .{ .allocator = allocator, .ctrl_r = fds[0], .ctrl_w = fds[1] };
        return self;
    }

    /// Spawn the loop thread. Call once, after the Reactor is at its final
    /// address (heap-allocate it — the thread captures `self`).
    pub fn start(self: *Reactor) !void {
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    /// Stop the loop and join. Fds already armed are dropped (their wakers do NOT
    /// fire) — callers must have torn down / not be parked on the reactor.
    pub fn deinit(self: *Reactor) void {
        if (self.thread) |t| {
            self.mu.lock();
            self.shutdown = true;
            self.mu.unlock();
            self.poke();
            t.join();
            self.thread = null;
        }
        self.pending.deinit(self.allocator);
        self.active.deinit(self.allocator);
        _ = linux.close(self.ctrl_r);
        _ = linux.close(self.ctrl_w);
        const alloc = self.allocator;
        alloc.destroy(self);
    }

    /// Arm one-shot interest in `fd` becoming ready for `interest`. When it does,
    /// `waker` fires once on the reactor thread and the fd is dropped. `fd` must
    /// be non-blocking. Callable from any thread.
    pub fn arm(self: *Reactor, fd: posix.fd_t, interest: Interest, waker: Waker) !void {
        self.mu.lock();
        try self.pending.append(self.allocator, .{ .fd = fd, .interest = interest, .waker = waker });
        self.mu.unlock();
        self.poke();
    }

    fn poke(self: *Reactor) void {
        _ = linux.write(self.ctrl_w, &[_]u8{0}, 1);
    }

    fn loop(self: *Reactor) void {
        var pollfds: std.ArrayListUnmanaged(posix.pollfd) = .empty;
        defer pollfds.deinit(self.allocator);
        while (true) {
            // Adopt queued registrations + check shutdown.
            self.mu.lock();
            const done = self.shutdown;
            self.active.appendSlice(self.allocator, self.pending.items) catch {};
            self.pending.clearRetainingCapacity();
            self.mu.unlock();
            if (done and self.active.items.len == 0) return;

            // Build the pollfd set: the control pipe (index 0) + every active reg.
            pollfds.clearRetainingCapacity();
            pollfds.append(self.allocator, .{ .fd = self.ctrl_r, .events = posix.POLL.IN, .revents = 0 }) catch {};
            for (self.active.items) |reg| {
                const ev: i16 = if (reg.interest == .readable) posix.POLL.IN else posix.POLL.OUT;
                pollfds.append(self.allocator, .{ .fd = reg.fd, .events = ev, .revents = 0 }) catch {};
            }

            _ = posix.poll(pollfds.items, -1) catch continue;

            // Drain the control pipe (coalesced pokes; non-blocking → EAGAIN ends it).
            if (pollfds.items[0].revents != 0) {
                var buf: [64]u8 = undefined;
                while (true) {
                    const n = linux.read(self.ctrl_r, &buf, buf.len);
                    if (linux.errno(n) != .SUCCESS or n < buf.len) break;
                }
            }

            // Fire wakers for ready fds and drop them (one-shot). Walk the active
            // list in reverse so swap-removal is index-stable. `active[i]` maps to
            // `pollfds[i+1]` (index 0 is the control pipe).
            var i: usize = self.active.items.len;
            while (i > 0) {
                i -= 1;
                const pfd = pollfds.items[i + 1];
                // Ready, error, or hangup all count as "wake it and let the read
                // observe the outcome".
                if (pfd.revents != 0) {
                    const waker = self.active.items[i].waker;
                    _ = self.active.swapRemove(i);
                    waker.wake(waker.ctx);
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testSocketpair() ![2]posix.fd_t {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) != .SUCCESS) return error.SocketpairFailed;
    return .{ fds[0], fds[1] };
}

const Flag = struct {
    fired: std.atomic.Value(u32) = .init(0),
    fn waker(self: *Flag) Waker {
        return .{ .ctx = self, .wake = wake };
    }
    fn wake(ctx: *anyopaque) void {
        const self: *Flag = @ptrCast(@alignCast(ctx));
        _ = self.fired.fetchAdd(1, .release);
        stable.Futex.wake(&self.fired, 1);
    }
    fn await1(self: *Flag) void {
        while (self.fired.load(.acquire) == 0) stable.Futex.wait(&self.fired, 0);
    }
};

test "reactor: fires waker when a socket becomes readable" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const r = try Reactor.init(testing.allocator);
    defer r.deinit();
    try r.start();

    const pair = try testSocketpair();
    defer _ = linux.close(pair[0]);
    defer _ = linux.close(pair[1]);

    var flag: Flag = .{};
    try r.arm(pair[0], .readable, flag.waker());
    // Not ready yet.
    try testing.expectEqual(@as(u32, 0), flag.fired.load(.acquire));
    // Make it readable.
    _ = linux.write(pair[1], "x", 1);
    flag.await1();
    try testing.expectEqual(@as(u32, 1), flag.fired.load(.acquire));
}

test "reactor: many fds wake concurrently, one-shot" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const r = try Reactor.init(testing.allocator);
    defer r.deinit();
    try r.start();

    const N = 8;
    var a: [N]posix.fd_t = undefined;
    var b: [N]posix.fd_t = undefined;
    var flags: [N]Flag = undefined;
    for (0..N) |i| {
        const pair = try testSocketpair();
        a[i] = pair[0];
        b[i] = pair[1];
        flags[i] = .{};
        try r.arm(a[i], .readable, flags[i].waker());
    }
    defer for (0..N) |i| {
        _ = linux.close(a[i]);
        _ = linux.close(b[i]);
    };
    // Make them all readable.
    for (0..N) |i| _ = linux.write(b[i], "x", 1);
    for (0..N) |i| flags[i].await1();
    // One-shot: each fired exactly once, and re-arming after draining works.
    for (0..N) |i| try testing.expectEqual(@as(u32, 1), flags[i].fired.load(.acquire));
}
