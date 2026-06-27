//! `--print-sched-stats` diagnostics dump.
//!
//! Scheduler/registry/deferred counters, plus the comptime-gated `-Djit`,
//! `-Dprof-main`, and `-Dprof-path` reports. Kept out of `main` so the entry
//! point stays composition; the build-flag-gated subsystem internals are
//! imported here at the top of the file rather than inline at each use.

const std = @import("std");
const Evaluator = @import("../eval.zig").Evaluator;
const jit = @import("../jit.zig");
const prof = @import("../prof.zig");
const prof_path = @import("../prof_path.zig");
const OpCode = @import("../bytecode/opcode.zig").OpCode;
const BuiltinId = @import("runtime").builtins.BuiltinId;

pub fn report(ev: *Evaluator) void {
    const s = ev.schedulerStats();
    std.debug.print(
        "sched: spec_ok={d} spec_rej={d} urgent_ok={d} urgent_rej={d} pops={d} steals={d} parks={d}\n",
        .{ s.speculative_submitted, s.speculative_rejected, s.urgent_submitted, s.urgent_rejected, s.pops, s.steals, s.parks },
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
    if (comptime jit.enabled) reportJit();
    if (comptime prof.enabled) reportProf();
    if (comptime prof_path.enabled) prof_path.report(ev.chunkRegistry(), ev.internTable());
}

fn reportJit() void {
    const c = jit.compile_counts;
    std.debug.print(
        "jit: constant_ret={d} push_lit_ret={d} get_upvalue_ret={d} get_upvalue_attr_ret={d} get_upvalue_attr_attr_ret={d} get_upvalue_attr3_ret={d} eq_null={d} neq_null={d} not={d} builtin_attr_ret={d} upvalue_call_const_ret={d} upvalue_call_upvalue_ret={d} mapattrs_apply={d} genlist_apply={d} unsupported={d}\n",
        .{ c.constant_ret, c.push_lit_ret, c.get_upvalue_ret, c.get_upvalue_attr_ret, c.get_upvalue_attr_attr_ret, c.get_upvalue_attr3_ret, c.get_upvalue_eq_null_ret, c.get_upvalue_neq_null_ret, c.get_upvalue_not_ret, c.builtin_attr_ret, c.upvalue_call_const_ret, c.upvalue_call_upvalue_ret, c.mapattrs_apply, c.genlist_apply, c.unsupported },
    );
    std.debug.print(
        "jit lambdas: identity={d} local_attr_ret={d} local_eq_null={d} local_neq_null={d} local_not={d} as_thunk={d} unsupported={d}\n",
        .{ c.lambda_identity, c.lambda_local_attr_ret, c.lambda_local_eq_null_ret, c.lambda_local_neq_null_ret, c.lambda_local_not_ret, c.lambda_as_thunk, c.unsupported_lambda },
    );
    // Top-10 unsupported chunks by first opcode — useful for picking the next
    // shape to JIT.
    const Slot = struct { op: u8, n: u32 };
    var top: [10]Slot = .{Slot{ .op = 0, .n = 0 }} ** 10;
    for (c.unsupported_by_first_op, 0..) |n, op| {
        if (n == 0) continue;
        var slot: usize = 10;
        for (top, 0..) |t, i| {
            if (n > t.n) {
                slot = i;
                break;
            }
        }
        if (slot < 10) {
            var j: usize = 9;
            while (j > slot) : (j -= 1) top[j] = top[j - 1];
            top[slot] = .{ .op = @intCast(op), .n = n };
        }
    }
    std.debug.print("jit unsupported by first op:", .{});
    for (top) |t| {
        if (t.n == 0) break;
        const name = @tagName(@as(OpCode, @enumFromInt(t.op)));
        std.debug.print(" {s}={d}", .{ name, t.n });
    }
    std.debug.print("\n", .{});
}

fn reportProf() void {
    inline for (@typeInfo(prof.Path).@"enum".fields) |f| {
        const samp = prof.samples[f.value];
        if (samp.calls != 0) {
            std.debug.print("prof: {s}: excl_cy={d} incl_cy={d} calls={d} avg_excl={d}\n", .{
                f.name,
                samp.cycles,
                samp.cycles_inclusive,
                samp.calls,
                samp.cycles / samp.calls,
            });
        }
    }
    // Top builtins by inclusive cycles on main.
    const N = 20;
    const BSlot = struct { id: u16, cycles: u64, incl: u64, calls: u64 };
    var top_b: [N]BSlot = .{BSlot{ .id = 0, .cycles = 0, .incl = 0, .calls = 0 }} ** N;
    for (prof.builtin_samples, 0..) |samp, id| {
        if (samp.calls == 0) continue;
        var slot: usize = N;
        for (top_b, 0..) |entry, i| {
            if (samp.cycles > entry.cycles) {
                slot = i;
                break;
            }
        }
        if (slot < N) {
            var j: usize = N - 1;
            while (j > slot) : (j -= 1) top_b[j] = top_b[j - 1];
            top_b[slot] = .{ .id = @intCast(id), .cycles = samp.cycles, .incl = samp.cycles_inclusive, .calls = samp.calls };
        }
    }
    std.debug.print("prof builtins (top-20 by EXCL cycles — own-body cost):\n", .{});
    for (top_b) |entry| {
        if (entry.cycles == 0) break;
        const name = @tagName(@as(BuiltinId, @enumFromInt(entry.id)));
        std.debug.print("  {s}: excl={d} incl={d} calls={d} avg_excl={d}\n", .{ name, entry.cycles, entry.incl, entry.calls, entry.cycles / entry.calls });
    }
}
