//! IoRuntime: a single background OS thread that runs submitted closures
//! serially, off the compute-fiber workers.
//!
//! The nix-daemon connection is blocking and strictly serial — one socket,
//! objects added in topological (force) order — so a single thread draining a
//! queue matches it exactly while keeping every socket syscall off the worker
//! threads. A compute fiber submits a job and parks (see `vm/io_offload.zig`);
//! this thread does the blocking work and, from inside the job closure, wakes
//! the fiber. The thread futex-sleeps while the queue is empty, so it costs no
//! CPU and does not compete with the compute pool.
//!
//! Deliberately minimal: it knows nothing about fibers, futures, or the
//! scheduler. A job is just `run(ctx)`; whatever wake/park the submitter needs
//! lives entirely in `ctx`. The queue is intrusive (nodes live on the parked
//! submitter's stack) so `submit` never allocates and cannot fail.

const std = @import("std");
const builtin = @import("builtin");
const stable = @import("base").sync;

pub const Job = struct {
    run: *const fn (*anyopaque) void,
    ctx: *anyopaque,
    /// Intrusive FIFO link; owned by the queue between `submit` and dispatch.
    next: ?*Job = null,
};

pub const IoRuntime = struct {
    mu: stable.BlockingMutex = .{},
    /// Bumped on every submit and on shutdown; the idle thread futex-waits on
    /// it (a condvar-by-sequence, so a submit that races the wait bumps the
    /// value and the wait returns immediately rather than being lost).
    seq: std.atomic.Value(u32) = .init(0),
    head: ?*Job = null,
    tail: ?*Job = null,
    thread: ?std.Thread = null,
    shutdown: bool = false,

    pub fn init() IoRuntime {
        return .{};
    }

    /// Spawn the background thread. Must be called once, after the IoRuntime is
    /// at its final address (heap-allocate it — the thread captures `self`).
    pub fn start(self: *IoRuntime) !void {
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    /// Stop the background thread after draining any queued jobs, then join.
    /// Callers must ensure no fiber is still parked waiting on an unsubmitted
    /// job (drive the worker pool to quiescence first).
    pub fn deinit(self: *IoRuntime) void {
        if (self.thread) |t| {
            self.mu.lock();
            self.shutdown = true;
            self.mu.unlock();
            self.wake();
            t.join();
            self.thread = null;
        }
    }

    /// Enqueue a job for the background thread. `job` must outlive its
    /// execution — in practice it lives on the submitting fiber's stack, which
    /// stays parked until the job's closure wakes it. Alloc-free and infallible.
    pub fn submit(self: *IoRuntime, job: *Job) void {
        job.next = null;
        self.mu.lock();
        if (self.tail) |tl| {
            tl.next = job;
        } else {
            self.head = job;
        }
        self.tail = job;
        self.mu.unlock();
        self.wake();
    }

    fn wake(self: *IoRuntime) void {
        _ = self.seq.fetchAdd(1, .release);
        switch (builtin.os.tag) {
            .linux => _ = std.os.linux.futex_3arg(
                @ptrCast(&self.seq),
                .{ .cmd = .WAKE, .private = true },
                1,
            ),
            else => {},
        }
    }

    fn loop(self: *IoRuntime) void {
        while (true) {
            self.mu.lock();
            while (self.head == null and !self.shutdown) {
                // Sample the sequence under the lock, release it, then sleep
                // while `seq` is unchanged — a `wake()` between unlock and wait
                // bumps `seq`, so the wait returns instead of being lost.
                const s = self.seq.load(.acquire);
                self.mu.unlock();
                switch (builtin.os.tag) {
                    .linux => _ = std.os.linux.futex_4arg(
                        @ptrCast(&self.seq),
                        .{ .cmd = .WAIT, .private = true },
                        s,
                        null,
                    ),
                    else => std.Thread.yield() catch {},
                }
                self.mu.lock();
            }
            if (self.head == null and self.shutdown) {
                self.mu.unlock();
                return;
            }
            // Detach the whole chain and release the lock before running any
            // job — a job closure can take a while (a store transfer) and must
            // not block submitters.
            var j = self.head;
            self.head = null;
            self.tail = null;
            self.mu.unlock();

            while (j) |node| {
                // Read `next` BEFORE running: `node.run` wakes the parked fiber,
                // which may resume and reuse the stack frame the node lives in
                // before we look at it again.
                const next = node.next;
                node.run(node.ctx);
                j = next;
            }
        }
    }
};
