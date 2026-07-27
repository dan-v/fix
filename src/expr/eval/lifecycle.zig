//! Engine lifecycle capabilities supplied by the process composition root.

const std = @import("std");
const gc = @import("runtime").gc;
const mem_report = @import("mem_report.zig");

/// Explicit process-owned work to run after evaluator language state has been
/// released. Passed to a release operation rather than stored on Engine.
pub const ReleaseAction = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque) void,
};

pub fn requireActive(engine: anytype) !void {
    if (engine.evaluation_phase != .active) return error.EvaluationFinished;
}

pub fn finish(engine: anytype) void {
    std.debug.assert(engine.evaluation_phase == .active);
    engine.evaluation_phase = .releasing;
    destroy(engine);
    engine.evaluation_phase = .finished;
}

/// Whole-Engine destruction may share the explicit finish path.
pub fn releaseIfActive(engine: anytype) void {
    switch (engine.evaluation_phase) {
        .active => engine.evaluation_phase = .releasing,
        .finished => return,
        .releasing => @panic("evaluation teardown is still running"),
    }
    destroy(engine);
    engine.evaluation_phase = .finished;
}

/// Complete a transition already published by the build-phase owner.
pub fn finishRelease(engine: anytype) void {
    std.debug.assert(engine.evaluation_phase == .releasing);
    destroy(engine);
    engine.evaluation_phase = .finished;
}

fn destroy(engine: anytype) void {
    mem_report.report(
        &engine.heap,
        &engine.intern,
        &engine.registry,
        engine.compilation.retained_arenas.items,
        engine.collection.mem_report_mode,
    );
    gc.recordFinalTotal(&engine.heap.collection.report, engine.heap.totalReservedBytes());
    if (engine.collection.report_on)
        gc.report(&engine.heap.collection.report, engine.heap.collection.budget_bytes);

    // Workers must quiesce before any state borrowed by their VMs is freed.
    engine.execution.scheduler.deinit();
    if (engine.execution.main_worker) |worker| worker.deinit();
    engine.execution.main_worker = null;
    engine.sources.prefetch.seen.deinit(engine.allocator);
    engine.execution.vm_buffers.deinit();

    engine.collection.tracer.deinit();
    engine.collection.import_vms.deinit(engine.allocator);
    engine.collection.extra_roots.deinit(engine.allocator);
    engine.allocator.free(engine.collection.workers);
    engine.report.deinit();
    engine.sources.imports.deinit(engine.allocator);
    engine.sources.search_paths.deinit(engine.allocator);
    engine.sources.fetchers.deinit();
    engine.regexes.deinit();
    engine.effects.deinit();
    engine.store.realization.releaseRecipePayloads();
    engine.sources.files.deinit();
    engine.heap.deinit();

    // AST arenas outlive the heap thunks that point into deferred entries and
    // every worker that can force-compile one.
    engine.compilation.deferred_table.deinit();
    for (engine.compilation.retained_arenas.items) |*arena| arena.deinit();
    engine.compilation.retained_arenas.deinit(engine.allocator);
    engine.registry.deinit();
    engine.intern.deinit();
    engine.builtins_value = null;
}
