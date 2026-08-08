//! Seeded, reproducible concurrency stress for protocols whose state spaces are
//! too large for unit tests. Every failure reports the seed and iteration.

const std = @import("std");
const builtin = @import("builtin");
const base = @import("base");
const expr = @import("expr");

const Engine = expr.Engine;

/// On Darwin, Zig's in-process segfault handler has wedged unwinding this
/// binary's fiber stacks (a crashed nightly printed the one-line header, then
/// hung until the runner's 10-minute timeout — no trace). Let the OS
/// CrashReporter take the fault instead: it writes a full every-thread `.ips`
/// report the workflow dumps on failure, and the process dies immediately.
pub const std_options: std.Options = .{
    .enable_segfault_handler = !builtin.os.tag.isDarwin(),
};

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
    else switch (random.uintLessThan(u8, 4)) {
        0 => try arithmeticSource(
            allocator,
            random.intRangeAtMost(u32, 400, 1_200),
            random.intRangeAtMost(u32, 512, 1_536),
            random.intRangeAtMost(u32, 16, 40),
        ),
        1 => try stringSource(
            allocator,
            random.intRangeAtMost(u32, 200, 600),
            random.intRangeAtMost(u32, 3, 97),
            random.intRangeAtMost(u32, 128, 512),
        ),
        2 => try attrsetSource(
            allocator,
            random.intRangeAtMost(u32, 200, 800),
            random.intRangeAtMost(u32, 1, 9),
        ),
        else => try tryEvalSource(
            allocator,
            random.intRangeAtMost(u32, 128, 512),
        ),
    };
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

fn arithmeticSource(allocator: std.mem.Allocator, n: u32, fan: u32, garbage_width: u32) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\let
        \\  n = {d};
        \\  shared = builtins.foldl' (acc: x: acc + x) 0 (builtins.genList (x: x + 1) n);
        \\  demands = builtins.genList (i: shared + i - i) {d};
        \\  garbage = builtins.genList (i: builtins.genList (j: i + j) {d}) {d};
        \\in builtins.deepSeq garbage (builtins.deepSeq demands shared)
    , .{ n, fan, garbage_width, fan });
}

/// Shared interned string demanded from many fibers through slicing and
/// re-concatenation — exercises string building and context machinery.
fn stringSource(allocator: std.mem.Allocator, n: u32, stride: u32, fan: u32) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\let
        \\  parts = builtins.genList (i: builtins.toString (i * i + {d})) {d};
        \\  shared = builtins.concatStringsSep "-" parts;
        \\  demands = builtins.genList (i: builtins.substring (i * {d}) 24 shared) {d};
        \\in builtins.concatStringsSep "|" demands
    , .{ stride, n, stride, fan });
}

/// Attribute-set construction and traversal rendered through toJSON, so the
/// differential compares the full structure, ordering included.
fn attrsetSource(allocator: std.mem.Allocator, n: u32, scale: u32) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\let
        \\  base = builtins.listToAttrs (builtins.genList (i: {{
        \\    name = "k${{builtins.toString i}}";
        \\    value = i * {d};
        \\  }}) {d});
        \\  mapped = builtins.mapAttrs (name: value: value + builtins.stringLength name) base;
        \\in builtins.toJSON (base // mapped)
    , .{ scale, n });
}

/// Mixed success/failure fan-out under tryEval: sticky cached failures must
/// recover identically no matter which worker computed or replayed them.
fn tryEvalSource(allocator: std.mem.Allocator, fan: u32) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\let
        \\  attempts = builtins.genList (i: builtins.tryEval (
        \\    if builtins.bitAnd i 7 == 3 then throw "boom ${{builtins.toString i}}" else i * 2
        \\  )) {d};
        \\in builtins.toJSON (builtins.map (a: if a.success then a.value else -1) attempts)
    , .{fan});
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
        const serial_text = try renderDeep(&serial, allocator, serial_value);
        defer allocator.free(serial_text);
        const parallel_text = try renderDeep(&parallel, allocator, parallel_value);
        defer allocator.free(parallel_text);
        if (!std.mem.eql(u8, serial_text, parallel_text)) return error.ValueMismatch;
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

/// Deep-force and render a value so the differential compares the entire
/// result structure — lists, attrsets, strings — not just an integer scalar.
fn renderDeep(engine: *Engine, allocator: std.mem.Allocator, value: anytype) ![]u8 {
    try engine.forceDeep(value);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try engine.writeValue(&out.writer, value);
    return allocator.dupe(u8, out.written());
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
