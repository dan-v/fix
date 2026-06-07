//! Worker with a per-task fiber pool.
//!
//! Each helper thread (and the main thread, while it's running an
//! evaluation) owns a Worker. The Worker owns:
//!   - A free list of `.finished` fibers ready to be reset for a new task.
//!   - A ready list of `.suspended` fibers whose blocking thunks have
//!     resolved (their `wake_fn` pushed them here).
//!   - The set of all fibers it has ever allocated, for cleanup.
//!
//! There is *no* fixed pool size. A fresh fiber is allocated on demand
//! when a task arrives and no free fiber is available. Recycled fibers
//! are reset (stack pointer rewound to top, new entry/arg installed)
//! rather than reallocated, so the per-task cost is just a memcpy of
//! the trampoline address.
//!
//! Each fiber has its own VM (the bytecode value stack + frames must be
//! per-fiber; sharing one VM across fibers would corrupt state). Shared
//! pointers (heap, registry, intern, scheduler) live on the VM but
//! point at evaluator-owned tables.
//!
//! Fibers are pinned to their worker — only the worker calls `resume_`.
//! The wake_fn pushes a remote-resolver's wake into the ready list
//! atomically (via a SpinMutex) and nudges the worker's wake_word so
//! it parks for at most one futex round-trip.

const std = @import("std");
const types = @import("runtime/types.zig");
const Value = @import("runtime/value.zig").Value;
const thunk_mod = @import("runtime/thunk.zig");
const stable = @import("runtime/stable_segments.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const Task = @import("scheduler.zig").Task;
const vm_mod = @import("vm.zig");
const VM = vm_mod.VM;
const vm_force = @import("vm/force.zig");
const fiber_mod = @import("fiber.zig");
const InnerFiber = fiber_mod.Fiber;
const worker_id_mod = @import("runtime/worker_id.zig");

/// VM constructor injected by the embedder (eval.zig). Returns a VM
/// initialised for the given (worker_id, fiber_id). The Worker patches
/// the VM's claimer_id to match the fiber id.
pub const InitVmFn = *const fn (ctx: *anyopaque, worker_id: u8, fiber_id: u32) anyerror!VM;

pub const FiberState = enum(u8) {
    /// Currently running on the CPU, or about to be resumed.
    running,
    /// Yielded mid-task because a sub-thunk was `.busy`; its waiter is
    /// enrolled on that thunk's list, awaiting a wake.
    suspended,
    /// Completed a task; on the free list, available to be reset for a
    /// new task.
    free,
};

/// One in-flight evaluation. Owns a stack, a Context (via InnerFiber),
/// and a VM. Lives until the Worker is torn down — once allocated, it
/// is reused via `Fiber.reset` across tasks.
pub const Fiber = struct {
    worker: *Worker,
    fiber_id: u32,
    inner: InnerFiber,
    vm: VM,
    state: FiberState,
    /// Task currently assigned to this fiber. Read by the fiber's entry
    /// on first run; nil'd before processing so a recycled fiber sees a
    /// fresh assignment on its next reset.
    current_task: ?Task,
    /// Linked-list node for ready/free lists. Only one is "active" at a
    /// time given the fiber state, so we share the link.
    next_in_list: ?*Fiber,
    /// Thunk waiter — `wake_fn` recovers the parent via `@fieldParentPtr`
    /// and enqueues the fiber onto its worker's ready list.
    waiter: thunk_mod.Waiter,

    fn wakeImpl(w: *thunk_mod.Waiter) void {
        const self: *Fiber = @fieldParentPtr("waiter", w);
        self.worker.enqueueReady(self);
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    scheduler: *Scheduler,
    helper_idx: u8,
    worker_id: u8,
    init_vm_ctx: *anyopaque,
    init_vm_fn: InitVmFn,

    /// Every fiber we have ever allocated. Owned by the Worker; freed in
    /// deinit. Index in this list = fiber_id (stable identity).
    fibers: std.ArrayList(*Fiber),

    /// LIFO of fibers that have finished their task and are ready to be
    /// reset for a new one. Only touched by the worker thread itself.
    free_head: ?*Fiber,

    /// Lock-free Treiber stack of fibers whose blocking thunk just
    /// resolved. Multi-producer (remote wake_fns), single-consumer (the
    /// owning worker). LIFO order — newer wakes process first, which is
    /// fine since the wake order isn't semantically meaningful and the
    /// stack has the simplest correctness story.
    ready_head: std.atomic.Value(?*Fiber),

    shutdown_requested: std.atomic.Value(u8),

    pub fn init(
        allocator: std.mem.Allocator,
        scheduler: *Scheduler,
        helper_idx: u8,
        worker_id: u8,
        init_vm_ctx: *anyopaque,
        init_vm_fn: InitVmFn,
    ) !*Worker {
        const self = try allocator.create(Worker);
        self.* = .{
            .allocator = allocator,
            .scheduler = scheduler,
            .helper_idx = helper_idx,
            .worker_id = worker_id,
            .init_vm_ctx = init_vm_ctx,
            .init_vm_fn = init_vm_fn,
            .fibers = .empty,
            .free_head = null,
            .ready_head = .init(null),
            .shutdown_requested = .init(0),
        };
        return self;
    }

    pub fn deinit(self: *Worker) void {
        for (self.fibers.items) |f| {
            f.inner.deinit(self.allocator);
            f.vm.deinit();
            self.allocator.destroy(f);
        }
        self.fibers.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn requestShutdown(self: *Worker) void {
        self.shutdown_requested.store(1, .release);
        self.nudge();
    }

    /// Helper-side park; pairs with `nudge`.
    fn nudge(self: *Worker) void {
        self.scheduler.wakeHelperPublic(self.helper_idx);
    }

    fn shouldStop(self: *Worker) bool {
        return self.scheduler.isShutdown() or self.shutdown_requested.load(.acquire) != 0;
    }

    /// Helper main loop. Repeatedly resumes ready fibers, allocates new
    /// fibers for scheduler tasks, or parks until something happens.
    pub fn run(self: *Worker) void {
        worker_id_mod.current = self.worker_id;
        while (!self.shouldStop()) {
            if (self.popReady()) |f| {
                self.runFiber(f);
                continue;
            }
            if (self.pickTask()) |task| {
                const f = self.acquireFreeFiber() catch |err| {
                    std.log.err("worker {d} failed to allocate fiber: {s}", .{ self.worker_id, @errorName(err) });
                    continue;
                };
                f.current_task = task;
                f.inner.reset(slotEntry, @ptrCast(f));
                f.state = .running;
                self.runFiber(f);
                continue;
            }
            if (self.shouldStop()) break;
            self.scheduler.parkHelper(self.helper_idx);
        }
    }

    /// Drive a custom one-shot fiber to completion, draining the ready
    /// list and scheduler tasks while it's suspended. Used by the main
    /// thread to run the top-level evaluation (or a render/force entry
    /// point) inside a fiber so its `.busy` collisions yield rather
    /// than block the OS thread.
    pub fn runTopLevel(
        self: *Worker,
        entry: fiber_mod.EntryFn,
        arg: *anyopaque,
    ) !void {
        worker_id_mod.current = self.worker_id;
        const top = try self.acquireFreeFiber();
        top.current_task = null;
        top.inner.reset(entry, arg);
        top.state = .running;
        self.runFiber(top);

        while (top.state != .free) {
            if (self.popReady()) |f| {
                self.runFiber(f);
                continue;
            }
            if (self.pickTask()) |task| {
                const f = try self.acquireFreeFiber();
                f.current_task = task;
                f.inner.reset(slotEntry, @ptrCast(f));
                f.state = .running;
                self.runFiber(f);
                continue;
            }
            self.scheduler.parkHelper(self.helper_idx);
        }

        // The top fiber has retired to free. Drain any remaining
        // suspended fibers before returning so their waiter pointers
        // don't dangle on thunk lists past `deinit`.
        while (self.anyFiberSuspended()) {
            if (self.popReady()) |f| {
                self.runFiber(f);
                continue;
            }
            if (self.pickTask()) |task| {
                const f = try self.acquireFreeFiber();
                f.current_task = task;
                f.inner.reset(slotEntry, @ptrCast(f));
                f.state = .running;
                self.runFiber(f);
                continue;
            }
            self.scheduler.parkHelper(self.helper_idx);
        }
    }

    /// Resume the fiber and update bookkeeping based on what state it
    /// returned in. The fiber either yielded (still `.suspended`),
    /// finished its work (entry returned → reset state to `.free` and
    /// push onto free list), or in a degenerate case is somehow still
    /// running (treated as same as suspended; the next wake will hit it).
    fn runFiber(self: *Worker, f: *Fiber) void {
        f.inner.resume_();
        switch (f.inner.state) {
            .finished => {
                // Entry returned cleanly. Recycle.
                f.state = .free;
                self.pushFree(f);
            },
            .suspended => {
                // Yielded inside the body (force.busy enrolled on a
                // waiter list). The fiber's state was set to .suspended
                // by force.zig before yield; we just leave it.
            },
            .ready, .running => unreachable,
        }
    }

    fn pickTask(self: *Worker) ?Task {
        if (self.scheduler.pop(self.helper_idx)) |t| return t;
        if (self.scheduler.stealAny(self.helper_idx)) |t| return t;
        return null;
    }

    /// Pop a fiber from the free list (LIFO — best cache locality), or
    /// allocate a fresh one if the list is empty. The new fiber has its
    /// own stack + VM; the caller must `reset` it with the actual entry.
    fn acquireFreeFiber(self: *Worker) !*Fiber {
        if (self.free_head) |head| {
            self.free_head = head.next_in_list;
            head.next_in_list = null;
            return head;
        }
        return self.allocateFiber();
    }

    fn allocateFiber(self: *Worker) !*Fiber {
        const fiber_id: u32 = @intCast(self.fibers.items.len);
        const f = try self.allocator.create(Fiber);
        errdefer self.allocator.destroy(f);

        var vm = try self.init_vm_fn(self.init_vm_ctx, self.worker_id, fiber_id);
        errdefer vm.deinit();

        var inner = try InnerFiber.init(self.allocator, InnerFiber.min_stack_bytes, slotEntry, undefined);
        errdefer inner.deinit(self.allocator);

        f.* = .{
            .worker = self,
            .fiber_id = fiber_id,
            .inner = inner,
            .vm = vm,
            .state = .free,
            .current_task = null,
            .next_in_list = null,
            .waiter = .{ .wake_fn = Fiber.wakeImpl },
        };
        f.vm.claimer_id = thunk_mod.makeClaimer(self.worker_id, fiber_id);

        try self.fibers.append(self.allocator, f);
        return f;
    }

    fn pushFree(self: *Worker, f: *Fiber) void {
        f.next_in_list = self.free_head;
        self.free_head = f;
    }

    /// Push a resumable fiber onto the ready stack. Called from any
    /// thread (resolver fires the wake_fn). Lock-free CAS loop — see
    /// `ready_head` for the protocol.
    fn enqueueReady(self: *Worker, f: *Fiber) void {
        while (true) {
            const old = self.ready_head.load(.acquire);
            f.next_in_list = old;
            if (self.ready_head.cmpxchgWeak(old, f, .release, .acquire) == null) break;
        }
        self.nudge();
    }

    /// Pop a fiber from the ready stack. Called only from the owning
    /// worker thread, so the CAS races only against producers — never
    /// against another popper.
    fn popReady(self: *Worker) ?*Fiber {
        while (true) {
            const head = self.ready_head.load(.acquire) orelse return null;
            const next = head.next_in_list;
            if (self.ready_head.cmpxchgWeak(head, next, .release, .acquire) == null) {
                head.next_in_list = null;
                return head;
            }
        }
    }

    fn anyFiberSuspended(self: *Worker) bool {
        for (self.fibers.items) |f| {
            if (f.state == .suspended) return true;
        }
        return false;
    }
};

/// Standard fiber entry: run one task to completion and return.
/// On entry, the worker has already set `current_task` and reset the
/// fiber. The fiber's claimer_id was set at allocation; VM stack/frame
/// state is from the previous task — reset before doing anything.
fn slotEntry(arg: *anyopaque) void {
    const f: *Fiber = @ptrCast(@alignCast(arg));
    f.vm.sp = 0;
    f.vm.frames_len = 0;
    const task = f.current_task orelse return;
    f.current_task = null;
    switch (task) {
        .force_thunk => |thunk_id| {
            const v = Value.thunk(thunk_id);
            _ = vm_force.forceValueSpeculative(&f.vm, v) catch {};
        },
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

        fn initVm(ctx: *anyopaque, worker_id: u8, _: u32) anyerror!VM {
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

    const worker = try Worker.init(testing.allocator, &sched, 0, 1, &ctx, TestCtx.initVm);
    defer worker.deinit();

    try testing.expectEqual(@as(u8, 1), worker.worker_id);
    try testing.expect(worker.fibers.items.len == 0); // none allocated yet
    try testing.expect(worker.free_head == null);
    try testing.expect(worker.ready_head.load(.acquire) == null);
}
