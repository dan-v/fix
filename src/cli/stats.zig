//! Shared `--stats` evaluator diagnostics.
//!
//! Heap, intern, chunk, scheduler, and deferred counters, plus the
//! comptime-gated `-Dprof-main` and `-Dprof-path` reports. Reports go to
//! stderr so evaluated values and store paths remain machine-readable on
//! stdout.

const std = @import("std");
const engine = @import("expr");
const Engine = engine.Engine;
const prof = engine.probe.prof;
const prof_path = engine.probe.prof_path;

pub fn report(ev: *Engine) void {
    if (std.c.getenv("FIX_THUNK_CENSUS") != null) ev.dumpThunkCensus(20);
    const h = ev.heapStats();
    std.debug.print(
        "heap: objects={d} values={d} attrs={d} attr_positions={d} strbytes={d}\n",
        .{ h.objects, h.values, h.attrs, h.attr_positions, h.bytes },
    );
    const intern = ev.internStats();
    std.debug.print(
        "intern: entries={d} data_bytes={d} shard_imbalance={d:.2}x\n",
        .{ intern.entries, intern.data_bytes, intern.shardImbalance() },
    );
    const chunks = ev.chunkStats();
    std.debug.print(
        "chunks: count={d} code_bytes={d} constants={d} source_spans={d} max_code_bytes={d}\n",
        .{ chunks.chunks, chunks.code_bytes, chunks.const_count, chunks.source_map_entries, chunks.max_code_bytes },
    );
    const s = ev.schedulerStats();
    std.debug.print(
        "sched: spec_ok={d} spec_rej={d} urgent_ok={d} urgent_rej={d} pops={d} steals={d} parks={d} sweeps={d} evicts={d} novel={d} spec_bails={d}\n",
        .{ s.speculative_submitted, s.speculative_rejected, s.urgent_submitted, s.urgent_rejected, s.pops, s.steals, s.parks, s.sweeps, s.evicts, s.novel_ok, s.spec_bails },
    );
    {
        const d = ev.deferredStats();
        std.debug.print("deferred: registered={d} compiled={d} ({d:.1}% forced)\n", .{
            d.registered,                                                                                                                d.compiled,
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
    // Speculation precision (instrument I1, docs/perf/probes.md):
    // of all thunks that reached `.resolved`, how many were ever demanded by
    // a real caller vs. pre-forced (speculation / fan-out) and never observed.
    // The undemanded share is the speculative-waste fraction by COUNT.
    {
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
    if (comptime prof.enabled) {
        prof.report(ev.chunkRegistry(), ev.internTable());
        reportSchedulerScanCensus();
        // Demand-prediction de-risk censuses (see heap.zig): junk ratios
        // for demand-descendant scavenging and sibling prefetch.
        ev.tooling().reportCreationCensus();
    }
    if (comptime prof_path.enabled) prof_path.report(ev.chunkRegistry(), ev.internTable());
}

fn reportSchedulerScanCensus() void {
    const t = engine.workers.scanCensus() orelse return;
    const total = t.ready_pop_cy + t.ready_steal_cy + t.pop_own_cy +
        t.urgent_steal_cy + t.novel_steal_cy + t.spec_steal_cy;
    if (total == 0) return;
    std.debug.print("prof scan-census (all workers, drain-loop probe cycles, total={d}):\n", .{total});
    inline for (.{ "ready_pop", "ready_steal", "pop_own", "urgent_steal", "novel_steal", "spec_steal" }) |name| {
        const cy = @field(t, name ++ "_cy");
        const calls = @field(t, name ++ "_calls");
        const hits = @field(t, name ++ "_hits");
        std.debug.print("  {s}: cy={d} ({d:.1}%) calls={d} hits={d} ({d:.2}% hit) avg_cy={d}\n", .{
            name,                                                                 cy,
            100.0 * @as(f64, @floatFromInt(cy)) / @as(f64, @floatFromInt(total)), calls,
            hits,                                                                 if (calls == 0) @as(f64, 0) else 100.0 * @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(calls)),
            if (calls == 0) 0 else cy / calls,
        });
    }
}
