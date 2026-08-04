//! Narrow worker-runtime capability borrowed by the bytecode VM.
//!
//! The scheduler owns queues, wakeups, policy storage, counters, and the GC
//! barrier.  The VM needs a deliberately smaller vocabulary: submit concrete
//! evaluation work, inspect immutable speculation policy, and meet the GC
//! barrier.  Keeping that vocabulary here prevents VM code from constructing
//! scheduler transport tasks or reaching into scheduler state directly.
//!
//! This is a one-pointer value and every hot-path adapter is inline.  The
//! boundary therefore carries no allocation, virtual dispatch, or extra
//! synchronization cost.

const types = @import("runtime").types;
const scheduler_mod = @import("scheduler.zig");

const Scheduler = scheduler_mod.Scheduler;

pub const Runtime = struct {
    scheduler: *Scheduler,

    pub inline fn init(scheduler: *Scheduler) Runtime {
        return .{ .scheduler = scheduler };
    }

    pub inline fn isSolo(self: Runtime) bool {
        return self.scheduler.worker_count == 1;
    }

    pub inline fn siblingPrefetchEnabled(self: Runtime) bool {
        return self.scheduler.config.sibling_prefetch;
    }

    pub inline fn siblingMin(self: Runtime) u32 {
        return self.scheduler.config.sibling_min;
    }

    pub inline fn siblingMax(self: Runtime) u32 {
        return self.scheduler.config.sibling_max;
    }

    pub inline fn siblingUrgent(self: Runtime) bool {
        return self.scheduler.config.sibling_urgent;
    }

    pub inline fn siblingLog(self: Runtime) bool {
        return self.scheduler.config.sibling_log;
    }

    pub inline fn siblingClaimBudget(self: Runtime) u64 {
        return self.scheduler.config.sibling_claim_budget;
    }

    pub inline fn siblingCreateBudget(self: Runtime) u64 {
        return self.scheduler.config.sibling_budget;
    }

    pub inline fn novelSpeculationEnabled(self: Runtime) bool {
        return self.scheduler.config.spec_novel;
    }

    pub inline fn rescueSpeculationEnabled(self: Runtime) bool {
        return self.scheduler.config.spec_rescue;
    }

    pub inline fn speculationBandBudget(self: Runtime) u64 {
        return self.scheduler.config.spec_band_budget;
    }

    pub inline fn backgroundSuppressed(self: Runtime) bool {
        return self.scheduler.backgroundSuppressed();
    }

    pub inline fn readDirPrefetchMin(self: Runtime) u32 {
        return self.scheduler.config.readdir_prefetch_min;
    }

    pub inline fn takeReadDirPrefetch(self: Runtime, want: u32) u32 {
        return self.scheduler.readDirPrefetchTake(want);
    }

    pub inline fn submitSpeculativeThunk(self: Runtime, id: types.ObjectId, worker_id: u8) bool {
        return self.scheduler.submit(.{ .force_thunk = id }, worker_id);
    }

    pub inline fn submitNovelThunk(self: Runtime, id: types.ObjectId, worker_id: u8) bool {
        return self.scheduler.submitNovel(.{ .force_thunk = id }, worker_id);
    }

    pub inline fn submitUrgentThunk(self: Runtime, id: types.ObjectId, worker_id: u8) bool {
        return self.scheduler.submitUrgent(.{ .force_thunk = id }, worker_id);
    }

    pub inline fn submitUrgentListRange(
        self: Runtime,
        list_id: types.ObjectId,
        offset: u32,
        len: u8,
        worker_id: u8,
    ) bool {
        return self.scheduler.submitUrgent(.{ .force_list_range = .{
            .list_id = list_id,
            .offset = offset,
            .len = len,
        } }, worker_id);
    }

    pub inline fn submitUrgentAttrsRange(
        self: Runtime,
        attrs_id: types.ObjectId,
        offset: u32,
        len: u8,
        worker_id: u8,
    ) bool {
        return self.scheduler.submitUrgent(.{ .force_attrs_range = .{
            .attrs_id = attrs_id,
            .offset = offset,
            .len = len,
        } }, worker_id);
    }

    pub inline fn submitSiblingSweep(
        self: Runtime,
        attrs_id: types.ObjectId,
        urgent: bool,
        worker_id: u8,
    ) bool {
        const task: scheduler_mod.Task = .{ .force_attrs_sweep = attrs_id };
        return if (urgent)
            self.scheduler.submitUrgent(task, worker_id)
        else
            self.scheduler.submit(task, worker_id);
    }

    pub inline fn submitUrgentReadDir(
        self: Runtime,
        dir: types.InternId,
        offset: u32,
        len: u16,
        worker_id: u8,
    ) bool {
        return self.scheduler.submitUrgent(.{ .readdir_prefetch = .{
            .dir = dir,
            .offset = offset,
            .len = len,
        } }, worker_id);
    }

    pub inline fn noteSiblingSweep(self: Runtime, worker_id: u8) void {
        self.scheduler.bumpSweeps(worker_id);
    }

    pub inline fn noteSpeculativeBail(self: Runtime, worker_id: u8) void {
        self.scheduler.noteSpecBail(worker_id);
    }

    pub inline fn promoteFiber(self: Runtime, fiber_id: u32) void {
        self.scheduler.promoteFiber(fiber_id);
    }

    pub inline fn gcStopRequested(self: Runtime) bool {
        return self.scheduler.gcStopRequested();
    }

    pub inline fn gcTryBeginCollection(self: Runtime) bool {
        return self.scheduler.gcTryBeginCollection();
    }

    pub inline fn gcWaitAllParked(self: Runtime, collector_id: u8) void {
        self.scheduler.gcWaitAllParked(collector_id);
    }

    pub inline fn gcEndCollection(self: Runtime, collector_id: u8) void {
        self.scheduler.gcEndCollection(collector_id);
    }

    pub inline fn gcSafepointPark(self: Runtime, worker_id: u8) void {
        self.scheduler.gcSafepointPark(worker_id);
    }

    comptime {
        if (@sizeOf(Runtime) != @sizeOf(*Scheduler))
            @compileError("VM worker runtime must remain a one-pointer capability");
    }
};
