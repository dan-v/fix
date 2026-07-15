//! Reactor: a single background thread that runs I/O tasks as stackful fibers on
//! one event loop, driven by `poll(2)`. This is the foundation for moving fix's
//! daemon + HTTP I/O off the "thread per blocking op" model onto one place.
//!
//! An I/O task is a fiber (`base/fiber.zig`) submitted via `submit`. It runs on
//! the reactor thread; when it would block on a socket it calls `waitReadable`/
//! `waitWritable`, which arms the fd and `yield`s back to the loop — the loop
//! runs other tasks, polls, and re-enqueues the task when its fd is ready. Many
//! tasks thus make progress concurrently on ONE thread with no per-op thread.
//! The task's body wakes its demanding compute fiber the usual way (publish a
//! `runtime/future.zig` `Future`), so the compute side is unchanged.
//!
//! Why hand-rolled and not `std.Io`'s evented `Io` (Uring/Kqueue): fix runs on
//! `std.Io.Threaded` (blocking) and has its own stackful-fiber compute scheduler,
//! so a stdlib evented `Io` would mean a second fiber runtime + moving the whole
//! app off `Threaded`. This reuses fix's own `Fiber` primitive on a bespoke
//! reactor thread instead.
//!
//! Loop-owned state (`runnable`, `active`, the fibers) is touched only on the
//! reactor thread. `submit`/`arm`/`deinit` may be called from any thread; they
//! queue under `mu` and poke a self-pipe so the loop picks the work up promptly.
//! Linux-only for now (raw pipe2/poll; darwin kqueue is future work).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const stable = @import("base").sync;
const fiber = @import("base").fiber;

/// I/O-task stack. These fibers run short wire state machines (a handshake, a
/// build's stderr drain), not deep eval recursion, so a modest stack is plenty —
/// and it's mmap-lazy anyway, so this is virtual-address reservation, not RSS.
const io_stack_bytes: usize = 512 * 1024;

pub const EntryFn = fiber.EntryFn;

fn makePipe() ![2]posix.fd_t {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    return .{ fds[0], fds[1] };
}

pub const Interest = enum { readable, writable };

/// Fired (once) on the reactor thread when an armed fd is ready.
pub const Waker = struct {
    ctx: *anyopaque,
    wake: *const fn (ctx: *anyopaque) void,
};

const Reg = struct { fd: posix.fd_t, interest: Interest, waker: Waker };
const PendingOp = struct { entry: EntryFn, arg: *anyopaque };

pub const Reactor = struct {
    allocator: std.mem.Allocator,
    ctrl_r: posix.fd_t,
    ctrl_w: posix.fd_t,

    mu: stable.BlockingMutex = .{},
    /// Cross-thread submission queues (guarded by `mu`).
    pending_regs: std.ArrayListUnmanaged(Reg) = .empty,
    pending_ops: std.ArrayListUnmanaged(PendingOp) = .empty,
    shutdown: bool = false,
    thread: ?std.Thread = null,

    // ---- reactor-thread-private ----
    /// fds currently in the poll set (one per suspended-on-I/O task).
    active: std.ArrayListUnmanaged(Reg) = .empty,
    /// Tasks ready to (re)run this tick.
    runnable: std.ArrayListUnmanaged(*fiber.Fiber) = .empty,
    /// Submitted-but-not-finished tasks — the loop stays alive while >0.
    inflight: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !*Reactor {
        const self = try allocator.create(Reactor);
        errdefer allocator.destroy(self);
        const fds = try makePipe();
        self.* = .{ .allocator = allocator, .ctrl_r = fds[0], .ctrl_w = fds[1] };
        return self;
    }

    pub fn start(self: *Reactor) !void {
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    /// Signal drain + join. Callers must have quiesced their tasks (no compute
    /// fiber still parked on an in-flight op) — the loop exits once every
    /// submitted task has finished.
    pub fn deinit(self: *Reactor) void {
        if (self.thread) |t| {
            self.mu.lock();
            self.shutdown = true;
            self.mu.unlock();
            self.poke();
            t.join();
            self.thread = null;
        }
        self.pending_regs.deinit(self.allocator);
        self.pending_ops.deinit(self.allocator);
        self.active.deinit(self.allocator);
        self.runnable.deinit(self.allocator);
        _ = linux.close(self.ctrl_r);
        _ = linux.close(self.ctrl_w);
        const alloc = self.allocator;
        alloc.destroy(self);
    }

    /// Submit an I/O task: `entry(arg)` runs as a fiber on the reactor thread.
    /// `arg` must outlive the task. Callable from any thread.
    pub fn submit(self: *Reactor, entry: EntryFn, arg: *anyopaque) !void {
        self.mu.lock();
        try self.pending_ops.append(self.allocator, .{ .entry = entry, .arg = arg });
        self.mu.unlock();
        self.poke();
    }

    /// Low-level one-shot fd interest (used by the wait helpers; also usable on
    /// its own with a plain `Waker`). Callable from any thread.
    pub fn arm(self: *Reactor, fd: posix.fd_t, interest: Interest, waker: Waker) !void {
        self.mu.lock();
        try self.pending_regs.append(self.allocator, .{ .fd = fd, .interest = interest, .waker = waker });
        self.mu.unlock();
        self.poke();
    }

    /// Called from INSIDE an I/O task: suspend until `fd` is readable/writable.
    /// Must run on the reactor thread (i.e. inside a `submit`ted task).
    pub fn waitReadable(self: *Reactor, fd: posix.fd_t) void {
        self.waitOn(fd, .readable);
    }
    pub fn waitWritable(self: *Reactor, fd: posix.fd_t) void {
        self.waitOn(fd, .writable);
    }

    fn waitOn(self: *Reactor, fd: posix.fd_t, interest: Interest) void {
        const f = fiber.currentFiber() orelse @panic("reactor.waitOn outside a task");
        // The wait node lives on this task's (soon-suspended) stack — valid until
        // the task resumes. Arm directly on `active` (we're on the reactor
        // thread) so no lock / self-poke round-trip.
        var node: WaitNode = .{ .reactor = self, .fiber = f };
        self.active.append(self.allocator, .{
            .fd = fd,
            .interest = interest,
            .waker = .{ .ctx = &node, .wake = WaitNode.onReady },
        }) catch @panic("reactor: OOM arming wait");
        fiber.Fiber.yield();
    }

    const WaitNode = struct {
        reactor: *Reactor,
        fiber: *fiber.Fiber,
        fn onReady(ctx: *anyopaque) void {
            const node: *WaitNode = @ptrCast(@alignCast(ctx));
            // Reactor thread — `runnable` is loop-private, no lock.
            node.reactor.runnable.append(node.reactor.allocator, node.fiber) catch @panic("reactor: OOM re-enqueue");
        }
    };

    fn poke(self: *Reactor) void {
        _ = linux.write(self.ctrl_w, &[_]u8{0}, 1);
    }

    fn loop(self: *Reactor) void {
        var pollfds: std.ArrayListUnmanaged(posix.pollfd) = .empty;
        defer pollfds.deinit(self.allocator);
        while (true) {
            // 1. Adopt cross-thread submissions.
            self.mu.lock();
            const done = self.shutdown;
            self.active.appendSlice(self.allocator, self.pending_regs.items) catch {};
            self.pending_regs.clearRetainingCapacity();
            for (self.pending_ops.items) |op| {
                const f = self.allocator.create(fiber.Fiber) catch continue;
                f.* = fiber.Fiber.init(self.allocator, io_stack_bytes, op.entry, op.arg) catch {
                    self.allocator.destroy(f);
                    continue;
                };
                self.inflight += 1;
                self.runnable.append(self.allocator, f) catch {};
            }
            self.pending_ops.clearRetainingCapacity();
            self.mu.unlock();

            // 2. Run every runnable task until it yields (armed an fd) or finishes.
            //    A task may enqueue more (re-armed) tasks as it runs; drain FIFO.
            while (self.runnable.items.len > 0) {
                const f = self.runnable.orderedRemove(0);
                f.resume_();
                if (f.state == .finished) {
                    f.deinit(self.allocator);
                    self.allocator.destroy(f);
                    self.inflight -= 1;
                }
            }

            // 3. Exit only once drained AND told to stop.
            if (done and self.inflight == 0) return;

            // 4. Poll: control pipe (index 0) + every active fd.
            pollfds.clearRetainingCapacity();
            pollfds.append(self.allocator, .{ .fd = self.ctrl_r, .events = posix.POLL.IN, .revents = 0 }) catch {};
            for (self.active.items) |reg| {
                const ev: i16 = if (reg.interest == .readable) posix.POLL.IN else posix.POLL.OUT;
                pollfds.append(self.allocator, .{ .fd = reg.fd, .events = ev, .revents = 0 }) catch {};
            }
            _ = posix.poll(pollfds.items, -1) catch continue;

            if (pollfds.items[0].revents != 0) {
                var buf: [64]u8 = undefined;
                while (true) {
                    const n = linux.read(self.ctrl_r, &buf, buf.len);
                    if (linux.errno(n) != .SUCCESS or n < buf.len) break;
                }
            }

            // 5. Fire wakers for ready fds and drop them (one-shot). Reverse walk
            //    so swap-removal is index-stable; active[i] <-> pollfds[i+1].
            var i: usize = self.active.items.len;
            while (i > 0) {
                i -= 1;
                if (pollfds.items[i + 1].revents != 0) {
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

/// An I/O task that reads one byte from a non-blocking fd, waiting on the reactor
/// when it would block, then flags done — the end-to-end bridge shape.
const ReadOp = struct {
    reactor: *Reactor,
    fd: posix.fd_t,
    got: std.atomic.Value(u32) = .init(0),

    fn run(ctx: *anyopaque) void {
        const self: *ReadOp = @ptrCast(@alignCast(ctx));
        var buf: [1]u8 = undefined;
        while (true) {
            const n = linux.read(self.fd, &buf, 1);
            switch (linux.errno(n)) {
                .SUCCESS => break,
                .AGAIN => self.reactor.waitReadable(self.fd),
                else => break,
            }
        }
        _ = self.got.fetchAdd(1, .release);
        stable.Futex.wake(&self.got, 1);
    }
    fn await1(self: *ReadOp) void {
        while (self.got.load(.acquire) == 0) stable.Futex.wait(&self.got, 0);
    }
};

test "reactor: I/O task suspends on WouldBlock and resumes on readiness" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const r = try Reactor.init(testing.allocator);
    defer r.deinit();
    try r.start();

    const pair = try testSocketpair();
    defer _ = linux.close(pair[0]);
    defer _ = linux.close(pair[1]);

    var op: ReadOp = .{ .reactor = r, .fd = pair[0] };
    try r.submit(ReadOp.run, &op);
    // The task ran, hit EAGAIN, and parked — not done yet.
    stable.sleepNs(5 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 0), op.got.load(.acquire));
    // Feed it a byte; the reactor wakes + resumes the task to completion.
    _ = linux.write(pair[1], "x", 1);
    op.await1();
    try testing.expectEqual(@as(u32, 1), op.got.load(.acquire));
}

test "reactor: many I/O tasks make progress concurrently on one thread" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const r = try Reactor.init(testing.allocator);
    defer r.deinit();
    try r.start();

    const N = 16;
    var a: [N]posix.fd_t = undefined;
    var b: [N]posix.fd_t = undefined;
    var ops: [N]ReadOp = undefined;
    for (0..N) |i| {
        const pair = try testSocketpair();
        a[i] = pair[0];
        b[i] = pair[1];
        ops[i] = .{ .reactor = r, .fd = a[i] };
        try r.submit(ReadOp.run, &ops[i]);
    }
    defer for (0..N) |i| {
        _ = linux.close(a[i]);
        _ = linux.close(b[i]);
    };
    // All parked. Feed them out of order; each must still complete.
    var order = [_]usize{0} ** N;
    for (0..N) |i| order[i] = (i * 7 + 3) % N;
    for (order) |i| _ = linux.write(b[i], "x", 1);
    for (0..N) |i| ops[i].await1();
    for (0..N) |i| try testing.expectEqual(@as(u32, 1), ops[i].got.load(.acquire));
}
