//! Low-level mutual-exclusion primitives.
//!
//! Two complementary locks used across the tree: `SpinMutex` for very short
//! critical sections (an allocator call at most) and `BlockingMutex` for
//! sections that may contend, where parking beats burning a core.

const std = @import("std");
const builtin = @import("builtin");

/// Minimal portable futex: park/wake a thread on a `u32` word. The whole
/// tree's blocking primitives (this file's Semaphore/BlockingMutex, the
/// scheduler's worker park, the IO runtime's job queue) route through here.
///
/// Linux uses the private futex; Darwin uses `__ulock` COMPARE_AND_WAIT (the
/// same primitive libdispatch/pthread_cond sit on — this mirrors what
/// `std.Io.Threaded` does, since std 0.16 only exposes futexes through a full
/// `Io` instance, not as a free function). Every other OS falls back to a
/// yield, so callers MUST re-check their condition in a loop — which they all
/// already do, since spurious wakeups are possible on every backend anyway.
///
/// The Linux path is byte-identical to the hand-rolled `switch` blocks it
/// replaced: zero behavior change on the platform we bench, real blocking
/// (instead of a busy spin) added for Darwin.
pub const Futex = struct {
    /// Park while `ptr.* == expect`. Returns on a matching `wake`, a spurious
    /// wakeup, or immediately if the value already differs.
    pub fn wait(ptr: *const std.atomic.Value(u32), expect: u32) void {
        switch (builtin.os.tag) {
            .linux => _ = std.os.linux.futex_4arg(
                @ptrCast(ptr),
                .{ .cmd = .WAIT, .private = true },
                expect,
                null,
            ),
            .macos, .ios, .tvos, .watchos, .visionos => {
                const flags: std.c.UL = .{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true };
                _ = std.c.__ulock_wait(flags, @ptrCast(ptr), expect, 0);
            },
            else => std.Thread.yield() catch {},
        }
    }

    /// Wake up to `n` threads parked on `ptr`.
    pub fn wake(ptr: *const std.atomic.Value(u32), n: u32) void {
        switch (builtin.os.tag) {
            .linux => _ = std.os.linux.futex_3arg(
                @ptrCast(ptr),
                .{ .cmd = .WAKE, .private = true },
                @min(n, std.math.maxInt(i32)),
            ),
            .macos, .ios, .tvos, .watchos, .visionos => {
                const flags: std.c.UL = .{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true, .WAKE_ALL = n > 1 };
                _ = std.c.__ulock_wake(flags, @ptrCast(ptr), 0);
            },
            else => {},
        }
    }
};

/// Sleep the current thread for approximately `ns` nanoseconds. Portable
/// across Linux (direct `nanosleep` syscall, no libc) and other POSIX
/// systems including Darwin (libc `nanosleep`). For coarse background-poll
/// delays that don't want the `std.Io` scheduler — `std.Thread.sleep` no
/// longer exists in the Io-refactored std. EINTR is treated as "close
/// enough"; these are timers, not deadlines. The comptime gate keeps the
/// libc `nanosleep` reference out of codegen on Linux (which links no libc).
pub fn sleepNs(ns: u64) void {
    const ts: std.posix.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.nanosleep(&ts, null);
    } else {
        _ = std.c.nanosleep(&ts, null);
    }
}

/// Spinlock built on `std.atomic.Mutex`. Short critical sections only —
/// writers on the segmented-storage primitives are O(allocator call) at most.
pub const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

/// Futex-based counting semaphore. Used to cap concurrent fetches
/// (`http-connections`); acquirers park on the count word when it hits zero.
/// Threads that block here are IO threads (not compute workers), so parking is
/// free — it bounds concurrent network ops, the resource actually being limited.
pub const Semaphore = struct {
    count: std.atomic.Value(u32),

    pub fn init(permits: u32) Semaphore {
        return .{ .count = .init(permits) };
    }

    pub fn acquire(self: *Semaphore) void {
        while (true) {
            var c = self.count.load(.acquire);
            while (c > 0) {
                if (self.count.cmpxchgWeak(c, c - 1, .acquire, .monotonic)) |actual| {
                    c = actual;
                } else {
                    return;
                }
            }
            // count == 0: wait for a release to bump it.
            Futex.wait(&self.count, 0);
        }
    }

    pub fn release(self: *Semaphore) void {
        _ = self.count.fetchAdd(1, .release);
        Futex.wake(&self.count, 1);
    }
};

/// Tri-state futex mutex. Uncontended lock/unlock is a single cmpxchg
/// plus a release store. Under contention, waiters park on a futex
/// (Linux) or yield (other platforms) instead of burning the core.
///
/// State encoding:
///   0 = unlocked
///   1 = locked, no waiters known
///   2 = locked, at least one waiter is parked or about to park
pub const BlockingMutex = struct {
    state: std.atomic.Value(u32) = .init(0),

    const SPIN_ATTEMPTS: u32 = 40;

    pub fn lock(self: *BlockingMutex) void {
        if (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) return;
        self.lockSlow();
    }

    fn lockSlow(self: *BlockingMutex) void {
        var i: u32 = 0;
        while (i < SPIN_ATTEMPTS) : (i += 1) {
            if (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) return;
            std.atomic.spinLoopHint();
        }
        while (true) {
            // Swap to "contended" so the unlocker knows to wake us. If the
            // mutex was unlocked between our spins and now, we've taken it
            // by virtue of swapping in 2.
            const prev = self.state.swap(2, .acquire);
            if (prev == 0) return;
            Futex.wait(&self.state, 2);
        }
    }

    pub fn unlock(self: *BlockingMutex) void {
        const prev = self.state.swap(0, .release);
        if (prev == 2) {
            Futex.wake(&self.state, 1);
        }
    }
};
