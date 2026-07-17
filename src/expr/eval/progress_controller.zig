//! Optional progress sink and background sampler lifecycle.

const std = @import("std");
const sync = @import("base").sync;
const progress = @import("../observ.zig").progress;

const SampleFn = *const fn (context: *anyopaque) void;
const sample_period_ms = 50;
const stop_check_ms = 10;

pub const Controller = struct {
    sink: ?progress.Sink = null,
    wait: progress.ProgressWait = .{},
    thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    sample_context: ?*anyopaque = null,
    sample_fn: ?SampleFn = null,

    pub fn setSink(self: *Controller, sink: ?progress.Sink) void {
        self.sink = sink;
    }

    pub fn start(self: *Controller, context: *anyopaque, callback: SampleFn) void {
        if (self.sink == null or self.thread != null) return;
        self.sample_context = context;
        self.sample_fn = callback;
        self.stop_requested.store(false, .release);
        self.thread = std.Thread.spawn(.{}, sampleLoop, .{self}) catch null;
    }

    pub fn stop(self: *Controller) void {
        if (self.thread) |thread| {
            self.stop_requested.store(true, .release);
            thread.join();
            self.thread = null;
        }
        self.sample();
        self.sample_context = null;
        self.sample_fn = null;
    }

    pub fn sample(self: *Controller) void {
        const context = self.sample_context orelse return;
        const callback = self.sample_fn orelse return;
        callback(context);
    }

    fn sampleLoop(self: *Controller) void {
        while (!self.stop_requested.load(.acquire)) {
            self.sample();
            var slept: u32 = 0;
            while (slept < sample_period_ms and !self.stop_requested.load(.acquire)) : (slept += stop_check_ms) {
                sync.sleepNs(stop_check_ms * std.time.ns_per_ms);
            }
        }
    }
};
