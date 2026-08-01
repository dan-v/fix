//! Deterministic adversarial tests for ready dispatch, parking, and GC phases.

const std = @import("std");
const scheduler_mod = @import("scheduler.zig");
const gc_barrier = @import("scheduler/gc_barrier.zig");

const Scheduler = scheduler_mod.Scheduler;
const ReadyNode = scheduler_mod.ReadyNode;

fn waitFor(value: *const std.atomic.Value(u32), expected: u32) !void {
    var attempts: usize = 0;
    while (value.load(.acquire) != expected) : (attempts += 1) {
        if (attempts == 1_000_000) return error.ConcurrencyDeadlineExceeded;
        std.Thread.yield() catch {};
    }
}

test "concurrency: racing wakers enqueue one ready token" {
    const actor_count = 32;
    var scheduler = try Scheduler.init(std.testing.allocator, 2);
    defer scheduler.deinit();
    var node: ReadyNode = .{};
    var start: std.atomic.Value(u32) = .init(0);
    var threads: [actor_count]std.Thread = undefined;

    const Actor = struct {
        fn run(s: *Scheduler, n: *ReadyNode, gate: *std.atomic.Value(u32)) void {
            while (gate.load(.acquire) == 0) std.atomic.spinLoopHint();
            s.enqueueReady(1, n);
        }
    };

    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Actor.run, .{ &scheduler, &node, &start });
    start.store(1, .release);
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(?*ReadyNode, &node), scheduler.popReady(1));
    try std.testing.expectEqual(@as(?*ReadyNode, null), scheduler.popReady(1));
    try std.testing.expectEqual(@as(u8, 0), node.queued.load(.acquire));
}

test "concurrency: concurrent ready producers and consumers lose no nodes" {
    const node_count = 256;
    const producer_count = 4;
    const consumer_count = 4;
    var scheduler = try Scheduler.init(std.testing.allocator, 2);
    defer scheduler.deinit();
    var nodes: [node_count]ReadyNode = @splat(.{});
    var seen: [node_count]std.atomic.Value(u8) = undefined;
    for (&seen) |*value| value.* = .init(0);
    var start: std.atomic.Value(u32) = .init(0);
    var producers_done: std.atomic.Value(u32) = .init(0);
    var consumed: std.atomic.Value(u32) = .init(0);
    var duplicates: std.atomic.Value(u32) = .init(0);
    var producers: [producer_count]std.Thread = undefined;
    var consumers: [consumer_count]std.Thread = undefined;

    const Actors = struct {
        fn produce(s: *Scheduler, all: *[node_count]ReadyNode, id: usize, gate: *std.atomic.Value(u32), done: *std.atomic.Value(u32)) void {
            while (gate.load(.acquire) == 0) std.atomic.spinLoopHint();
            var index = id;
            while (index < node_count) : (index += producer_count) s.enqueueReady(1, &all[index]);
            _ = done.fetchAdd(1, .acq_rel);
        }

        fn consume(
            s: *Scheduler,
            all: *[node_count]ReadyNode,
            observed: *[node_count]std.atomic.Value(u8),
            gate: *std.atomic.Value(u32),
            done: *std.atomic.Value(u32),
            count: *std.atomic.Value(u32),
            dupes: *std.atomic.Value(u32),
        ) void {
            while (gate.load(.acquire) == 0) std.atomic.spinLoopHint();
            while (true) {
                if (s.popReady(1)) |node| {
                    const offset = @intFromPtr(node) - @intFromPtr(&all[0]);
                    const index = offset / @sizeOf(ReadyNode);
                    if (index >= node_count or observed[index].swap(1, .acq_rel) != 0)
                        _ = dupes.fetchAdd(1, .acq_rel);
                    _ = count.fetchAdd(1, .acq_rel);
                } else if (done.load(.acquire) == producer_count and count.load(.acquire) == node_count) {
                    return;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    for (&producers, 0..) |*thread, id| thread.* = try std.Thread.spawn(.{}, Actors.produce, .{ &scheduler, &nodes, id, &start, &producers_done });
    for (&consumers) |*thread| thread.* = try std.Thread.spawn(.{}, Actors.consume, .{ &scheduler, &nodes, &seen, &start, &producers_done, &consumed, &duplicates });
    start.store(1, .release);
    for (producers) |thread| thread.join();
    try waitFor(&consumed, node_count);
    for (consumers) |thread| thread.join();

    try std.testing.expectEqual(@as(u32, 0), duplicates.load(.acquire));
    for (seen) |value| try std.testing.expectEqual(@as(u8, 1), value.load(.acquire));
}

test "concurrency: wake before park is never lost across repeated handoffs" {
    const cycles = 2_000;
    var scheduler = try Scheduler.init(std.testing.allocator, 2);
    defer scheduler.deinit();
    var announced: std.atomic.Value(u32) = .init(0);
    var released: std.atomic.Value(u32) = .init(0);
    var completed: std.atomic.Value(u32) = .init(0);

    const Parker = struct {
        fn run(s: *Scheduler, ready: *std.atomic.Value(u32), go: *std.atomic.Value(u32), done: *std.atomic.Value(u32)) void {
            var cycle: u32 = 1;
            while (cycle <= cycles) : (cycle += 1) {
                ready.store(cycle, .release);
                while (go.load(.acquire) < cycle) std.atomic.spinLoopHint();
                s.parkWorker(1);
                done.store(cycle, .release);
            }
        }
    };

    var parker = try std.Thread.spawn(.{}, Parker.run, .{ &scheduler, &announced, &released, &completed });
    var cycle: u32 = 1;
    while (cycle <= cycles) : (cycle += 1) {
        try waitFor(&announced, cycle);
        scheduler.wakeWorkerPublic(1);
        released.store(cycle, .release);
        try waitFor(&completed, cycle);
    }
    parker.join();
}

test "concurrency: helper teardown waits for external completion callbacks" {
    var scheduler = try Scheduler.init(std.testing.allocator, 3);
    defer scheduler.deinit();
    var arrived: std.atomic.Value(u32) = .init(0);
    var returned: std.atomic.Value(u32) = .init(0);

    const Helper = struct {
        fn run(s: *Scheduler, at_barrier: *std.atomic.Value(u32), done: *std.atomic.Value(u32)) void {
            _ = at_barrier.fetchAdd(1, .acq_rel);
            s.awaitHelpersQuiescent();
            _ = done.fetchAdd(1, .acq_rel);
        }
    };

    scheduler.externalJobBegin();
    var helper1 = try std.Thread.spawn(.{}, Helper.run, .{ &scheduler, &arrived, &returned });
    var helper2 = try std.Thread.spawn(.{}, Helper.run, .{ &scheduler, &arrived, &returned });
    try waitFor(&arrived, 2);
    var probes: usize = 0;
    while (probes < 10_000) : (probes += 1) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(u32, 0), returned.load(.acquire));

    scheduler.externalJobEnd();
    try waitFor(&returned, 2);
    helper1.join();
    helper2.join();
}

test "concurrency: back-to-back GC generations wait for every peer release" {
    const worker_count = 3;
    const cycles = 100;
    var barrier = try gc_barrier.Barrier.init(std.testing.allocator, worker_count);
    defer barrier.deinit(std.testing.allocator);

    const HookState = struct {
        entered: std.atomic.Value(u32) = .init(0),
        fn help(raw: *anyopaque, _: u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.entered.fetchAdd(1, .acq_rel);
        }
    };
    const Peer = struct {
        fn run(b: *gc_barrier.Barrier, worker_id: u8) void {
            b.park(worker_id);
        }
    };

    var hook: HookState = .{};
    barrier.setMarkHook(.{ .ctx = &hook, .help = HookState.help });
    var cycle: u32 = 0;
    while (cycle < cycles) : (cycle += 1) {
        hook.entered.store(0, .release);
        try std.testing.expect(barrier.tryBegin());
        var peer1 = try std.Thread.spawn(.{}, Peer.run, .{ &barrier, @as(u8, 1) });
        var peer2 = try std.Thread.spawn(.{}, Peer.run, .{ &barrier, @as(u8, 2) });
        barrier.waitAllParked(0);
        barrier.openMark();
        try waitFor(&hook.entered, worker_count - 1);
        barrier.closeMark();
        barrier.end(0);
        peer1.join();
        peer2.join();
    }
}
