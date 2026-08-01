//! Deterministic adversarial tests for the Future waiter protocol.
//!
//! These tests orchestrate the interesting interleavings with atomics rather
//! than sleeps. They intentionally use only Future's public protocol surface:
//! the confidence machinery must not add branches to the production hot path.

const std = @import("std");
const future_mod = @import("future.zig");

const Future = future_mod.Future;
const Waiter = future_mod.Waiter;

fn waitFor(value: *const std.atomic.Value(u32), expected: u32) !void {
    var attempts: usize = 0;
    while (value.load(.acquire) != expected) : (attempts += 1) {
        if (attempts == 1_000_000) return error.ConcurrencyDeadlineExceeded;
        std.Thread.yield() catch {};
    }
}

const CountingWaiter = struct {
    waiter: Waiter,
    wake_count: *std.atomic.Value(u32),

    fn init(wake_count: *std.atomic.Value(u32)) CountingWaiter {
        return .{ .waiter = .{ .wake_fn = wake }, .wake_count = wake_count };
    }

    fn wake(node: *Waiter) void {
        const self: *CountingWaiter = @fieldParentPtr("waiter", node);
        _ = self.wake_count.fetchAdd(1, .acq_rel);
    }
};

test "concurrency: resolve between busy observation and waiter enrollment" {
    var future = Future.initClaimed(1);
    var wake_count: std.atomic.Value(u32) = .init(0);
    var waiter = CountingWaiter.init(&wake_count);
    var busy_seen: std.atomic.Value(u32) = .init(0);
    var may_enroll: std.atomic.Value(u32) = .init(0);
    var enrolled: std.atomic.Value(u32) = .init(2);

    const Actor = struct {
        fn run(
            f: *Future,
            w: *Waiter,
            busy: *std.atomic.Value(u32),
            proceed: *std.atomic.Value(u32),
            result: *std.atomic.Value(u32),
        ) void {
            result.store(if (f.tryClaim(2) == .busy) 2 else 3, .release);
            busy.store(1, .release);
            while (proceed.load(.acquire) == 0) std.atomic.spinLoopHint();
            result.store(if (f.enrollWaiter(w)) 1 else 0, .release);
        }
    };

    var actor = try std.Thread.spawn(.{}, Actor.run, .{ &future, &waiter.waiter, &busy_seen, &may_enroll, &enrolled });
    try waitFor(&busy_seen, 1);
    try std.testing.expectEqual(@as(u32, 2), enrolled.load(.acquire));

    future.publish();
    may_enroll.store(1, .release);
    actor.join();

    try std.testing.expectEqual(@as(u32, 0), enrolled.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), wake_count.load(.acquire));
    try std.testing.expectEqual(future_mod.ClaimResult.already_resolved, future.tryClaim(2));
}

test "concurrency: publish after enrollment wakes every waiter exactly once" {
    const waiter_count = 24;
    var future = Future.initClaimed(1);
    var wake_count: std.atomic.Value(u32) = .init(0);
    var enrolled_count: std.atomic.Value(u32) = .init(0);
    var start: std.atomic.Value(u32) = .init(0);
    var failures: std.atomic.Value(u32) = .init(0);
    var waiters: [waiter_count]CountingWaiter = undefined;
    var threads: [waiter_count]std.Thread = undefined;

    const Actor = struct {
        fn run(
            f: *Future,
            w: *Waiter,
            gate: *std.atomic.Value(u32),
            enrolled: *std.atomic.Value(u32),
            failed: *std.atomic.Value(u32),
        ) void {
            while (gate.load(.acquire) == 0) std.atomic.spinLoopHint();
            if (f.tryClaim(2) != .busy or !f.enrollWaiter(w)) {
                _ = failed.fetchAdd(1, .acq_rel);
                return;
            }
            _ = enrolled.fetchAdd(1, .acq_rel);
        }
    };

    for (&waiters, &threads) |*waiter, *thread| {
        waiter.* = CountingWaiter.init(&wake_count);
        thread.* = try std.Thread.spawn(.{}, Actor.run, .{ &future, &waiter.waiter, &start, &enrolled_count, &failures });
    }
    start.store(1, .release);
    try waitFor(&enrolled_count, waiter_count);

    future.publish();
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(u32, 0), failures.load(.acquire));
    try std.testing.expectEqual(@as(u32, waiter_count), wake_count.load(.acquire));
    try std.testing.expect(future.waiters_head == null);
    for (waiters) |waiter| try std.testing.expect(waiter.waiter.next == null);
}

test "concurrency: release publication makes payload visible after wake" {
    const Shared = struct {
        future: Future = Future.initClaimed(1),
        payload: u64 = 0,
    };
    const ObservingWaiter = struct {
        waiter: Waiter,
        woke: std.atomic.Value(u32) = .init(0),

        fn wake(node: *Waiter) void {
            const self: *@This() = @fieldParentPtr("waiter", node);
            self.woke.store(1, .release);
        }
    };
    const Reader = struct {
        fn run(shared: *Shared, waiter: *ObservingWaiter, enrolled: *std.atomic.Value(u32), observed: *std.atomic.Value(u64)) void {
            if (shared.future.tryClaim(2) != .busy) return;
            if (!shared.future.enrollWaiter(&waiter.waiter)) return;
            enrolled.store(1, .release);
            while (waiter.woke.load(.acquire) == 0) std.atomic.spinLoopHint();
            if (shared.future.tryClaim(2) != .already_resolved) return;
            observed.store(shared.payload, .release);
        }
    };

    var shared: Shared = .{};
    var waiter: ObservingWaiter = .{ .waiter = .{ .wake_fn = ObservingWaiter.wake } };
    var enrolled: std.atomic.Value(u32) = .init(0);
    var observed: std.atomic.Value(u64) = .init(0);
    var reader = try std.Thread.spawn(.{}, Reader.run, .{ &shared, &waiter, &enrolled, &observed });
    try waitFor(&enrolled, 1);

    shared.payload = 0xfeed_beef_dead_cafe;
    shared.future.publish();
    reader.join();

    try std.testing.expectEqual(@as(u64, 0xfeed_beef_dead_cafe), observed.load(.acquire));
}
