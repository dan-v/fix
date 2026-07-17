//! Owns the evaluator's two low-level GC callback registrations as one
//! component: heap collection requests and parked-scheduler mark assistance.

const ObjectHeap = @import("runtime").heap.ObjectHeap;
const Scheduler = @import("workers/scheduler.zig").Scheduler;

pub const Driver = struct {
    context: *anyopaque,
    collect: *const fn (context: *anyopaque, collector_id: u8) void,
    help_mark: *const fn (context: *anyopaque, worker_id: u8) void,
};

pub const Coordinator = struct {
    driver: ?Driver = null,

    /// Install once, after the owning Evaluator has reached its final address.
    pub fn install(self: *Coordinator, heap: *ObjectHeap, scheduler: *Scheduler, driver: Driver) void {
        if (self.driver != null) return;
        self.driver = driver;
        heap.setGcHook(.{ .ctx = self, .sample = collectThunk });
        scheduler.gcSetMarkHook(.{ .ctx = self, .help = helpMarkThunk });
    }

    fn collectThunk(context: *anyopaque, collector_id: u8) void {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        const driver = self.driver orelse return;
        driver.collect(driver.context, collector_id);
    }

    fn helpMarkThunk(context: *anyopaque, worker_id: u8) void {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        const driver = self.driver orelse return;
        driver.help_mark(driver.context, worker_id);
    }
};
