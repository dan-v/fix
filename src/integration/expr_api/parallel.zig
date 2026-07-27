//! End-to-end tests that exercise the scheduler with multiple helpers.
//! These re-run the same evaluations as the single-threaded suite but
//! configure the Engine with helper threads so the speculative
//! force_thunk path is actually traversed.

const std = @import("std");
const expr = @import("expr");
const Engine = expr.Engine;

test "parallel: arithmetic with 4 workers" {
    const alloc = std.testing.allocator;
    var ev = try Engine.init(alloc, .{ .worker_count = 4 });
    defer ev.deinit();

    const result = try ev.evaluate("10 + 32");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "parallel: recursive let with 4 workers" {
    const alloc = std.testing.allocator;
    var ev = try Engine.init(alloc, .{ .worker_count = 4 });
    defer ev.deinit();

    const result = try ev.evaluate(
        \\let
        \\  f = n: if n == 0 then 0 else n + f (n - 1);
        \\in f 50
    );
    try std.testing.expectEqual(@as(i64, 50 * 51 / 2), result.asInt());
}

test "parallel: large attrset with 8 workers" {
    const alloc = std.testing.allocator;
    var ev = try Engine.init(alloc, .{ .worker_count = 8 });
    defer ev.deinit();

    const result = try ev.evaluate(
        \\let
        \\  a = { x = 1; y = 2; z = 3; };
        \\  b = { x = 10; y = 20; z = 30; w = 40; };
        \\  m = a // b;
        \\in m.x + m.y + m.z + m.w
    );
    try std.testing.expectEqual(@as(i64, 100), result.asInt());
}

test "parallel: list operations with 4 workers" {
    const alloc = std.testing.allocator;
    var ev = try Engine.init(alloc, .{ .worker_count = 4 });
    defer ev.deinit();

    const result = try ev.evaluate(
        \\let
        \\  xs = [1 2 3 4 5];
        \\  ys = [6 7 8 9 10];
        \\  zs = xs ++ ys;
        \\in builtins.length zs
    );
    try std.testing.expectEqual(@as(i64, 10), result.asInt());
}

test "parallel: automatic collector dispatches a major with 4 workers" {
    const alloc = std.testing.allocator;
    var ev = try Engine.init(alloc, .{ .worker_count = 4 });
    defer ev.deinit();
    ev.configureMemory(64 << 20, null, false);

    // Install the workers/collector, then use the first explicit safepoint to
    // arm tracking. Objects made below are consequently eligible for sweep.
    _ = try ev.evaluate("1");
    const armed = ev.collectNow();
    try std.testing.expect(armed.ran);
    try std.testing.expectEqual(@as(u64, 0), armed.collections);

    const live = try ev.evaluate("{ answer = 42; }");
    try ev.gcSetExternalRoots(&.{live});
    defer ev.gcSetExternalRoots(&.{}) catch {};
    const garbage = try ev.evaluate("{ discard = [ 1 2 3 4 ]; }");
    const garbage_id = garbage.asObjectId();

    // Force the normal collection hook (not collectMajorNow's direct call) to
    // take its major branch. This is the policy state a sufficiently large
    // preceding minor would establish in a real evaluation.
    ev.heap.gcNoteMinorPromoted(std.math.maxInt(u64));
    const collected = ev.collectNow();
    try std.testing.expectEqual(@as(u64, 1), collected.collections);
    try std.testing.expect(!ev.heap.isObjectAllocatedForTest(garbage_id));

    const attrs = try ev.heap.getAttrs(live.asObjectId());
    try std.testing.expectEqual(@as(usize, 1), attrs.len);
    try std.testing.expectEqual(@as(i64, 42), attrs[0].value.asInt());
}

test "parallel: forceDeep fans wide attrset out to helpers" {
    // Constructs an attrset where every value is a thunk whose body is
    // big enough to make speculation worth it, then strict-forces the
    // whole tree. The fan-out path in forceDeepInner submits every
    // child to helpers urgently — `forceDeep` should complete without
    // hangs or errors regardless of how the work is distributed.
    const alloc = std.testing.allocator;
    var ev = try Engine.init(alloc, .{ .worker_count = 4 });
    defer ev.deinit();

    const value = try ev.evaluate(
        \\let
        \\  heavy = n: builtins.foldl' (a: b: a + b) 0 (builtins.genList (i: i + n) 64);
        \\in builtins.listToAttrs (builtins.genList (i: {
        \\  name = "k${toString i}";
        \\  value = heavy i;
        \\}) 32)
    );
    try ev.forceDeep(value);
}
