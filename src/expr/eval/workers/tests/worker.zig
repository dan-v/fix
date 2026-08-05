const std = @import("std");
const testing = std.testing;
const bytecode = @import("../../../bytecode.zig");
const scheduler_mod = @import("../scheduler.zig");
const worker_mod = @import("../worker.zig");
const vm_mod = @import("../../../vm.zig");
const runtime = @import("runtime");
const store_domain = @import("store");
const fetchers_mod = @import("fetchers");
const RealizationStore = @import("store").RealizationStore;
const arena_mod = @import("base").arena;

test "Worker basic init/deinit" {
    var sched = try scheduler_mod.Scheduler.init(testing.allocator, 2);
    defer sched.deinit();

    const TestCtx = struct {
        registry: bytecode.ChunkRegistry,
        intern: runtime.intern.InternTable,
        heap: runtime.heap.ObjectHeap,
        files: store_domain.FileCache,
        fetchers: fetchers_mod.FetchService,
        realization: RealizationStore,
        sched: *scheduler_mod.Scheduler,
        arena: arena_mod.ArenaAllocator,

        fn initVm(ctx: *anyopaque, _: u8, _: u32, scratch: std.mem.Allocator) anyerror!vm_mod.VM {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return vm_mod.VM.init(.{
                .driver = &vm_mod.driver,
                .allocator = scratch,
                .registry = &self.registry,
                .intern = &self.intern,
                .heap = &self.heap,
                .files = &self.files,
                .fetchers = &self.fetchers,
                .realization = &self.realization,
                .workers = @import("../vm_runtime.zig").Runtime.init(self.sched),
            });
        }
    };

    var ctx: TestCtx = .{
        .registry = try bytecode.ChunkRegistry.init(testing.allocator),
        .intern = try runtime.intern.InternTable.init(testing.allocator),
        .heap = try runtime.heap.ObjectHeap.init(testing.allocator, 2),
        .files = store_domain.FileCache.init(testing.allocator),
        .fetchers = try fetchers_mod.FetchService.init(testing.allocator, .{}),
        .realization = RealizationStore.init(testing.allocator),
        .sched = &sched,
        .arena = arena_mod.ArenaAllocator.init(testing.allocator),
    };
    defer {
        ctx.registry.deinit();
        ctx.intern.deinit();
        ctx.heap.deinit();
        ctx.files.deinit();
        ctx.fetchers.deinit();
        ctx.realization.deinit();
        ctx.arena.deinit();
    }

    const worker = try worker_mod.Worker.init(testing.allocator, &sched, 1, &ctx, TestCtx.initVm);
    defer worker.deinit();

    try testing.expectEqual(@as(u8, 1), worker.worker_id);
    try testing.expectEqual(@as(usize, worker_mod.prewarm_fiber_count), worker.fibers.items.len);
    try testing.expect(worker.free_head != null);
    try testing.expect(sched.popReady(1) == null);
    for (worker.fibers.items) |fiber| {
        try testing.expectEqual(runtime.future.makeClaimer(fiber.fiber_id), fiber.ctx.claimer_id);
        try testing.expectEqual(worker_mod.FiberState.free, fiber.lifecycle());
    }
    for (worker.fibers.items, 0..) |fiber, i| {
        for (worker.fibers.items[i + 1 ..]) |other| {
            try testing.expect(fiber.fiber_id != other.fiber_id);
        }
    }
}
