//! `--print-sched-stats` diagnostics dump.
//!
//! Scheduler/registry/deferred counters, plus the comptime-gated `-Djit`,
//! `-Dprof-main`, and `-Dprof-path` reports. Kept out of `main` so the entry
//! point stays a thin composition; the build-flag-gated subsystem internals
//! are imported here at the top of the file rather than inline at each use.

const std = @import("std");
const Evaluator = @import("../eval.zig").Evaluator;
const jit = @import("../jit/native.zig");
const prof = @import("../probe/prof.zig");
const prof_path = @import("../probe/prof_path.zig");
const thunk_census = @import("../probe/thunk_census.zig");

pub fn report(ev: *Evaluator) void {
    const s = ev.schedulerStats();
    std.debug.print(
        "sched: spec_ok={d} spec_rej={d} urgent_ok={d} urgent_rej={d} pops={d} steals={d} parks={d} scavenges={d}\n",
        .{ s.speculative_submitted, s.speculative_rejected, s.urgent_submitted, s.urgent_rejected, s.pops, s.steals, s.parks, s.scavenges },
    );
    std.debug.print("registry: chunks={d}\n", .{ev.chunkStats().chunks});
    {
        const d = ev.deferred_table.stats();
        std.debug.print("deferred: registered={d} compiled={d} ({d:.1}% forced)\n", .{
            d.registered, d.compiled,
            if (d.registered == 0) @as(f64, 0) else 100.0 * @as(f64, @floatFromInt(d.compiled)) / @as(f64, @floatFromInt(d.registered)),
        });
    }
    // Total CPU time across all workers (fiber resume vs futex park). At
    // workers=N the ratio busy/(busy+idle) is the average worker utilisation; a
    // high idle share means helpers are starved for work even though wall time
    // hasn't converged.
    std.debug.print(
        "sched: busy_ms={d} idle_ms={d} util={d:.2}%\n",
        .{
            s.busy_ns / std.time.ns_per_ms,
            s.idle_ns / std.time.ns_per_ms,
            if (s.busy_ns + s.idle_ns == 0) @as(f64, 0) else 100.0 * @as(f64, @floatFromInt(s.busy_ns)) / @as(f64, @floatFromInt(s.busy_ns + s.idle_ns)),
        },
    );
    // Speculation precision (instrument I1, docs/plans/parallel-redesign-plan.md):
    // of all thunks that reached `.resolved`, how many were ever demanded by
    // a real caller vs. pre-forced (speculation / fan-out) and never observed.
    // The undemanded share is the speculative-waste fraction by COUNT.
    {
        const h = ev.heapStats();
        const dem = h.resolved_demanded;
        const undem = h.resolved_undemanded;
        const tot = dem + undem;
        var created: u64 = 0;
        for (h.thunk_states) |c| created += c;
        std.debug.print(
            "spec-census: thunks={d} resolved={d} demanded={d} undemanded={d} ({d:.1}% undemanded)\n",
            .{ created, tot, dem, undem, if (tot == 0) @as(f64, 0) else 100.0 * @as(f64, @floatFromInt(undem)) / @as(f64, @floatFromInt(tot)) },
        );
    }
    if (comptime thunk_census.enabled) thunk_census.report();
    if (comptime jit.enabled) jit.report();
    if (comptime prof.enabled) prof.report(ev.chunkRegistry(), ev.internTable());
    if (comptime prof_path.enabled) prof_path.report(ev.chunkRegistry(), ev.internTable());
}
