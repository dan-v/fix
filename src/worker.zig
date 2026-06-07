//! Helper worker with a fiber pool.
//!
//! Replaces the old "one VM per helper thread, synchronously runs each
//! force_thunk task to completion" model with a pool of fiber slots:
//!
//!   - Each slot owns its own `VM` (stack/frames are mutated by the
//!     fiber body; sharing one VM across fibers would corrupt state).
//!   - Each slot owns a `Fiber` whose entry loop pulls a task, runs it,
//!     yields, repeats — or yields mid-task when its evaluation hits a
//!     `.busy` thunk (see vm/force.zig).
//!
//! The worker's `run` loop is the scheduler:
//!   1. Resume any slot whose `resumable` flag was set by a remote
//!      thunk-resolver (the fiber was waiting on that thunk).
//!   2. Find an idle slot AND a task; assign the task and resume.
//!   3. If nothing to do, park on the scheduler's wake word.
//!
//! Slot fibers don't migrate between workers. The owning worker is the
//! only one that ever calls `resume_` on a slot's fiber. Remote
//! resolvers signal a slot from a different thread, but they only touch
//! the (atomic) `resumable` flag and the wake word — never the fiber
//! itself.

const std = @import("std");
const types = @import("runtime/types.zig");
const Value = @import("runtime/value.zig").Value;
const thunk_mod = @import("runtime/thunk.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const Task = @import("scheduler.zig").Task;
const vm_mod = @import("vm.zig");
const VM = vm_mod.VM;
const vm_force = @import("vm/force.zig");
const fiber_mod = @import("fiber.zig");
const Fiber = fiber_mod.Fiber;
const worker_id_mod = @import("runtime/worker_id.zig");

/// How many fiber slots per worker. Tuning knob: too few and a worker
/// stalls when all its in-flight fibers are blocked on remote thunks;
/// too many and per-worker memory (each slot is a VM + a fiber stack)
/// gets expensive. Four is a reasonable starting point — most blocked
/// chains are shallow.
pub const slots_per_worker: u8 = 4;

/// VM constructor injected by the embedder (eval.zig). Returns a VM
/// initialised for the given (worker_id, slot_idx). The Worker then
/// patches the VM's claimer_id to match the slot.
pub const InitVmFn = *const fn (ctx: *anyopaque, worker_id: u8, slot_idx: u8) anyerror!VM;

pub const SlotState = enum(u8) {
    /// Never resumed, or just finished a task. The fiber's entry loop
    /// is parked at "wait for a task assignment".
    idle,
    /// A task has been assigned and the fiber is executing it (either
    /// actively on the CPU or about to be resumed).
    running,
    /// The fiber yielded mid-task because some sub-thunk is `.busy`.
    /// `waiter` is on that thunk's waiter list.
    suspended,
};

pub const FiberSlot = struct {
    worker: *Worker,
    slot_idx: u8,
    fiber: Fiber,
    vm: VM,
    state: SlotState,
    /// Task currently assigned to this slot. The fiber's entry loop
    /// consumes it on resume and nils the field as part of starting.
    current_task: ?Task,
    /// Set by a remote thunk-resolver via `wakeImpl`; cleared by the
    /// worker's main loop when it picks the slot to resume.
    resumable: std.atomic.Value(u8),
    /// Embedding for the thunk waiter list. The thunk module sees a
    /// `Waiter`; `wake_fn` here recovers the slot via `@fieldParentPtr`.
    waiter: thunk_mod.Waiter,

    fn wakeImpl(w: *thunk_mod.Waiter) void {
        const self: *FiberSlot = @fieldParentPtr("waiter", w);
        self.resumable.store(1, .release);
        self.worker.nudge();
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    scheduler: *Scheduler,
    /// 0-based index into the scheduler's per-helper data structures.
    /// `worker_id = helper_idx + 1` (worker 0 is the main thread).
    helper_idx: u8,
    worker_id: u8,
    slots: []FiberSlot,
    shutdown_requested: std.atomic.Value(u8),

    pub fn init(
        allocator: std.mem.Allocator,
        scheduler: *Scheduler,
        helper_idx: u8,
        init_vm_ctx: *anyopaque,
        init_vm_fn: InitVmFn,
    ) !*Worker {
        // The worker is allocated on the heap so slot pointers back to it
        // remain stable. Slots store `*Worker` for the nudge path; if the
        // worker moved we'd dangle.
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);

        const slots = try allocator.alloc(FiberSlot, slots_per_worker);
        errdefer allocator.free(slots);

        self.* = .{
            .allocator = allocator,
            .scheduler = scheduler,
            .helper_idx = helper_idx,
            .worker_id = helper_idx + 1,
            .slots = slots,
            .shutdown_requested = .init(0),
        };

        // Two-phase slot init: allocate VMs and fibers, then patch the
        // back-pointers and claimer ids. If init fails mid-stream, we
        // tear down everything created so far.
        var initialized: u8 = 0;
        errdefer {
            for (slots[0..initialized]) |*s| {
                s.fiber.deinit(allocator);
                s.vm.deinit();
            }
        }
        for (slots, 0..) |*s, i| {
            const slot_idx: u8 = @intCast(i);
            var vm = try init_vm_fn(init_vm_ctx, self.worker_id, slot_idx);
            errdefer vm.deinit();
            vm.claimer_id = thunk_mod.makeClaimer(self.worker_id, slot_idx);
            const fiber = try Fiber.init(allocator, Fiber.min_stack_bytes, slotEntry, undefined);
            s.* = .{
                .worker = self,
                .slot_idx = slot_idx,
                .fiber = fiber,
                .vm = vm,
                .state = .idle,
                .current_task = null,
                .resumable = .init(0),
                .waiter = .{ .wake_fn = FiberSlot.wakeImpl },
            };
            // Bind the fiber's entry argument to the slot pointer now
            // that the slot lives at a stable address.
            s.fiber.entry_arg = s;
            initialized += 1;
        }

        return self;
    }

    pub fn deinit(self: *Worker) void {
        for (self.slots) |*s| {
            s.fiber.deinit(self.allocator);
            s.vm.deinit();
        }
        self.allocator.free(self.slots);
        self.allocator.destroy(self);
    }

    /// Set the shutdown flag and nudge so a parked worker wakes to see it.
    pub fn requestShutdown(self: *Worker) void {
        self.shutdown_requested.store(1, .release);
        self.nudge();
    }

    /// Called by remote resolvers (via FiberSlot.wakeImpl) and by the
    /// scheduler. Sets the wake_word and futex_wakes the worker.
    pub fn nudge(self: *Worker) void {
        self.scheduler.wakeHelperPublic(self.helper_idx);
    }

    /// Main loop. Drives the slot pool until shutdown.
    pub fn run(self: *Worker) void {
        worker_id_mod.current = self.worker_id;
        while (!self.shouldStop()) {
            // 1. Resume any slot whose blocking thunk has resolved.
            if (self.pickResumableSlot()) |slot| {
                self.resumeSlot(slot);
                continue;
            }
            // 2. Find an idle slot + a pending task; start fresh work.
            if (self.pickIdleSlot()) |slot| {
                if (self.pickTask()) |task| {
                    slot.current_task = task;
                    self.resumeSlot(slot);
                    continue;
                }
            }
            // 3. Nothing actionable; park until somebody nudges us.
            if (self.shouldStop()) break;
            self.scheduler.parkHelper(self.helper_idx);
        }
        // Shutdown: drain the fibers so their stacks deinit cleanly.
        // Each slot's entry loop checks `shutdown_requested` after yield;
        // resuming once is enough for it to return.
        for (self.slots) |*s| {
            if (s.state == .idle) self.resumeSlot(s);
        }
    }

    fn shouldStop(self: *Worker) bool {
        return self.scheduler.isShutdown() or self.shutdown_requested.load(.acquire) != 0;
    }

    fn pickResumableSlot(self: *Worker) ?*FiberSlot {
        for (self.slots) |*s| {
            if (s.state != .suspended) continue;
            if (s.resumable.swap(0, .acq_rel) == 0) continue;
            return s;
        }
        return null;
    }

    fn pickIdleSlot(self: *Worker) ?*FiberSlot {
        for (self.slots) |*s| {
            if (s.state == .idle) return s;
        }
        return null;
    }

    fn pickTask(self: *Worker) ?Task {
        if (self.scheduler.pop(self.helper_idx)) |t| return t;
        if (self.scheduler.stealAny(self.helper_idx)) |t| return t;
        return null;
    }

    fn resumeSlot(self: *Worker, slot: *FiberSlot) void {
        _ = self;
        slot.state = .running;
        slot.fiber.resume_();
        // The fiber either: completed its task (state .idle), suspended
        // mid-task on a busy thunk (state .suspended), or terminated
        // entirely (state .idle and shutdown_requested true).
    }
};

/// Fiber entry: an infinite loop pulling tasks from the slot. Yields
/// when no task is assigned so the worker can wake us up later.
fn slotEntry(arg: *anyopaque) void {
    const slot: *FiberSlot = @ptrCast(@alignCast(arg));
    while (true) {
        if (slot.worker.shutdown_requested.load(.acquire) != 0) return;
        if (slot.current_task) |task| {
            slot.current_task = null;
            // Reset the VM's bytecode state so this task starts fresh.
            slot.vm.sp = 0;
            slot.vm.frames_len = 0;
            switch (task) {
                .force_thunk => |thunk_id| {
                    const v = Value.thunk(thunk_id);
                    _ = vm_force.forceValueSpeculative(&slot.vm, v) catch {};
                },
            }
        }
        slot.state = .idle;
        Fiber.yield();
    }
}

// ---- Tests ----

const testing = std.testing;

test "Worker basic init/deinit" {
    var sched = try Scheduler.init(testing.allocator, 2);
    defer sched.deinit();

    const TestCtx = struct {
        registry: @import("bytecode.zig").ChunkRegistry,
        intern: @import("runtime/intern.zig").InternTable,
        heap: @import("runtime/heap.zig").ObjectHeap,
        files: @import("file_cache.zig").FileCache,
        fetchers: @import("fetch_cache.zig").FetchCache,
        derivations: @import("derivation.zig").DerivationStore,
        sched: *Scheduler,
        arena: std.heap.ArenaAllocator,
        opcode_counts: if (vm_mod.opcode_profile_enabled) vm_mod.OpcodeCounts else void,

        fn initVm(ctx: *anyopaque, worker_id: u8, _: u8) anyerror!VM {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return VM.init(
                self.arena.allocator(),
                &self.registry,
                &self.intern,
                &self.heap,
                &self.files,
                &self.fetchers,
                &self.derivations,
                self.sched,
                null,
                null,
                null,
                null,
                Value.null_val,
                worker_id,
                if (comptime vm_mod.opcode_profile_enabled) &self.opcode_counts else {},
            );
        }
    };

    var ctx: TestCtx = .{
        .registry = try @import("bytecode.zig").ChunkRegistry.init(testing.allocator),
        .intern = try @import("runtime/intern.zig").InternTable.init(testing.allocator),
        .heap = try @import("runtime/heap.zig").ObjectHeap.init(testing.allocator, 2),
        .files = @import("file_cache.zig").FileCache.init(testing.allocator),
        .fetchers = @import("fetch_cache.zig").FetchCache.init(testing.allocator),
        .derivations = @import("derivation.zig").DerivationStore.init(testing.allocator),
        .sched = &sched,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .opcode_counts = if (vm_mod.opcode_profile_enabled) [_]u64{0} ** @import("bytecode.zig").opcode.count else {},
    };
    defer {
        ctx.registry.deinit();
        ctx.intern.deinit();
        ctx.heap.deinit();
        ctx.files.deinit();
        ctx.fetchers.deinit();
        ctx.derivations.deinit();
        ctx.arena.deinit();
    }

    const worker = try Worker.init(testing.allocator, &sched, 0, &ctx, TestCtx.initVm);
    defer worker.deinit();

    try testing.expectEqual(@as(u8, 1), worker.worker_id);
    try testing.expectEqual(@as(usize, slots_per_worker), worker.slots.len);
    for (worker.slots, 0..) |*s, i| {
        try testing.expectEqual(@as(u8, @intCast(i)), s.slot_idx);
        try testing.expectEqual(thunk_mod.makeClaimer(1, @intCast(i)), s.vm.claimer_id);
        try testing.expectEqual(SlotState.idle, s.state);
    }
}
