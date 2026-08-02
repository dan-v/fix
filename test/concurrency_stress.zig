//! Seeded, reproducible concurrency stress for protocols whose state spaces are
//! too large for unit tests. Every failure reports the seed and iteration.

const std = @import("std");
const base = @import("base");
const expr = @import("expr");

const Engine = expr.Engine;

/// Payload lanes for the queue stress. `NarrowLane` exercises the plain
/// atomic slot transport; `WideLane` exercises the two-word seqlock slots
/// that carry the GC marker's u128 range descriptors, encoding each index
/// redundantly in both halves so a read that mixes two different writes'
/// words is caught as tearing.
const NarrowLane = struct {
    const T = u32;
    fn encode(index: u32) T {
        return index;
    }
    fn decode(value: T) ?u32 {
        return value;
    }
};

const WideLane = struct {
    const T = u128;
    const salt: u64 = 0x9e37_79b9_7f4a_7c15;
    fn encode(index: u32) T {
        const i: u64 = index;
        return (@as(u128, i ^ salt) << 64) | i;
    }
    fn decode(value: T) ?u32 {
        const low: u64 = @truncate(value);
        const high: u64 = @truncate(value >> 64);
        if (high != (low ^ salt) or low > std.math.maxInt(u32)) return null;
        return @intCast(low);
    }
};

const Options = struct {
    seed: u64 = 0x6a09_e667_f3bc_c909,
    iterations: usize = 25,
};

const queue_worker_counts = [_]u8{ 2, 3, 4, 6, 8 };
const evaluator_worker_counts = [_]u8{ 2, 3, 4, 8, 16 };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const options = try parseOptions(allocator, init);
    var prng = std.Random.DefaultPrng.init(options.seed);
    const random = prng.random();

    std.debug.print("concurrency-stress seed={d} iterations={d}\n", .{ options.seed, options.iterations });
    for (0..options.iterations) |iteration| {
        runIteration(allocator, random, iteration) catch |err| {
            std.debug.print("FAIL seed={d} iteration={d}: {s}\n", .{ options.seed, iteration, @errorName(err) });
            return err;
        };
        std.debug.print("ok seed={d} iteration={d}\n", .{ options.seed, iteration });
    }
}

fn parseOptions(allocator: std.mem.Allocator, init: std.process.Init) !Options {
    var options: Options = .{};
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--seed")) {
            const value = args.next() orelse return error.MissingSeed;
            options.seed = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            const value = args.next() orelse return error.MissingIterations;
            options.iterations = try std.fmt.parseInt(usize, value, 10);
            if (options.iterations == 0) return error.InvalidIterations;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }
    return options;
}

fn runIteration(allocator: std.mem.Allocator, random: std.Random, iteration: usize) !void {
    const queue_workers = queue_worker_counts[random.uintLessThan(usize, queue_worker_counts.len)];
    const queue_items = random.intRangeAtMost(u32, 2_048, 8_192);
    const initial_capacity = @as(u32, 1) << random.intRangeAtMost(u3, 1, 4);
    try stressQueue(NarrowLane, allocator, random, queue_workers, queue_items, initial_capacity);
    try stressQueue(WideLane, allocator, random, queue_workers, queue_items, initial_capacity);

    const evaluator_workers = evaluator_worker_counts[random.uintLessThan(usize, evaluator_worker_counts.len)];
    const failure_case = iteration % 5 == 4;
    const source = if (failure_case)
        try failureSource(allocator, iteration, random.intRangeAtMost(u32, 128, 512))
    else
        try successSource(
            allocator,
            random.intRangeAtMost(u32, 400, 1_200),
            random.intRangeAtMost(u32, 512, 1_536),
            random.intRangeAtMost(u32, 16, 40),
        );
    defer allocator.free(source);

    try differentialEval(allocator, source, evaluator_workers, .{
        .disable_speculation = random.boolean(),
        .disable_fanout = random.boolean(),
    });
}

const ParallelToggles = struct {
    disable_speculation: bool,
    disable_fanout: bool,
};

fn successSource(allocator: std.mem.Allocator, n: u32, fan: u32, garbage_width: u32) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\let
        \\  n = {d};
        \\  shared = builtins.foldl' (acc: x: acc + x) 0 (builtins.genList (x: x + 1) n);
        \\  demands = builtins.genList (i: shared + i - i) {d};
        \\  garbage = builtins.genList (i: builtins.genList (j: i + j) {d}) {d};
        \\in builtins.deepSeq garbage (builtins.deepSeq demands shared)
    , .{ n, fan, garbage_width, fan });
}

fn failureSource(allocator: std.mem.Allocator, iteration: usize, fan: u32) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\let
        \\  shared = builtins.throw "concurrency-stress-{d}";
        \\  demands = builtins.genList (_: shared) {d};
        \\in builtins.deepSeq demands 0
    , .{ iteration, fan });
}

fn differentialEval(
    allocator: std.mem.Allocator,
    source: []const u8,
    worker_count: u8,
    toggles: ParallelToggles,
) !void {
    var serial = try Engine.init(allocator, .{ .worker_count = 1 });
    defer serial.deinit();
    serial.configureMemory(16 << 20, null, false);

    var parallel = try Engine.init(allocator, .{ .worker_count = worker_count });
    defer parallel.deinit();
    parallel.configureMemory(16 << 20, null, false);
    parallel.setParallelismToggles(toggles.disable_speculation, toggles.disable_fanout);

    const serial_result = serial.evaluate(source);
    const parallel_result = parallel.evaluate(source);
    if (serial_result) |serial_value| {
        const parallel_value = parallel_result catch return error.ParallelUnexpectedFailure;
        if (serial_value.asInt() != parallel_value.asInt()) return error.ValueMismatch;
    } else |serial_error| {
        if (parallel_result) |_| {
            return error.ParallelUnexpectedSuccess;
        } else |parallel_error| {
            if (serial_error != parallel_error) return error.ErrorMismatch;
            const serial_message = serial.getTrace().message;
            const parallel_message = parallel.getTrace().message;
            if ((serial_message == null) != (parallel_message == null)) return error.ErrorMessageMismatch;
            if (serial_message) |message| {
                if (!std.mem.eql(u8, message, parallel_message.?)) return error.ErrorMessageMismatch;
            }
        }
    }
}

fn stressQueue(
    comptime Lane: type,
    allocator: std.mem.Allocator,
    random: std.Random,
    worker_count: u8,
    item_count: u32,
    initial_capacity: u32,
) !void {
    const Queue = base.GrowableDeque(Lane.T);
    var queue = try Queue.init(allocator, initial_capacity);
    defer queue.deinit(allocator);

    const seen = try allocator.alloc(std.atomic.Value(u8), item_count);
    defer allocator.free(seen);
    for (seen) |*slot| slot.* = .init(0);

    var start: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    var taken: std.atomic.Value(u32) = .init(0);
    var invalid: std.atomic.Value(u32) = .init(0);
    var threads: [queue_worker_counts[queue_worker_counts.len - 1]]std.Thread = undefined;
    var spawned: usize = 0;
    var joined = false;
    defer if (!joined) {
        start.store(true, .release);
        done.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    };

    const Stealer = struct {
        fn record(
            slots: []std.atomic.Value(u8),
            count: *std.atomic.Value(u32),
            bad: *std.atomic.Value(u32),
            value: Lane.T,
        ) void {
            const index = Lane.decode(value) orelse {
                _ = bad.fetchOr(4, .acq_rel); // torn wide-slot read
                return;
            };
            if (index >= slots.len) {
                _ = bad.fetchOr(1, .acq_rel);
                return;
            }
            if (slots[index].cmpxchgStrong(0, 1, .acq_rel, .acquire) != null)
                _ = bad.fetchOr(2, .acq_rel);
            _ = count.fetchAdd(1, .acq_rel);
        }

        fn run(
            q: *Queue,
            gate: *std.atomic.Value(bool),
            finished: *std.atomic.Value(bool),
            slots: []std.atomic.Value(u8),
            count: *std.atomic.Value(u32),
            bad: *std.atomic.Value(u32),
        ) void {
            while (!gate.load(.acquire)) std.atomic.spinLoopHint();
            while (true) {
                if (q.steal()) |value| {
                    record(slots, count, bad, value);
                } else if (finished.load(.acquire)) {
                    if (q.steal()) |value| record(slots, count, bad, value) else return;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    const stealers = @as(usize, worker_count - 1);
    for (threads[0..stealers]) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Stealer.run, .{ &queue, &start, &done, seen, &taken, &invalid });
        spawned += 1;
    }

    const gated_prefix = @min(item_count, initial_capacity * 16);
    for (0..item_count) |index| {
        try queue.push(allocator, Lane.encode(@intCast(index)));
        if (index + 1 == gated_prefix) start.store(true, .release);
        if (random.uintLessThan(u8, 4) == 0) {
            if (queue.pop()) |value| Stealer.record(seen, &taken, &invalid, value);
        }
    }
    start.store(true, .release);
    while (queue.pop()) |value| Stealer.record(seen, &taken, &invalid, value);
    done.store(true, .release);
    for (threads[0..stealers]) |thread| thread.join();
    joined = true;

    if (invalid.load(.acquire) != 0) return error.InvalidQueueResult;
    if (taken.load(.acquire) != item_count) return error.LostQueueItem;
    for (seen) |slot| if (slot.load(.acquire) != 1) return error.LostQueueItem;
}
