//! Opcode-adjacency profiler (gated behind `-Dopcode-ngram`, off by
//! default — zero cost in normal builds).
//!
//! The question this answers: which adjacent opcode *pairs* are hottest
//! at run time, so we can fuse them into superinstructions (one dispatch
//! instead of two — the dispatch loop's 36% indirect-branch mispredict
//! rate is the measured w=1 bottleneck once the eval was shown NOT to be
//! memory-bound). Existing super-ops (`get_upvalue_attr`, the `_ret`
//! family, `thunk_captures_store_local`) were found this way by hand; this
//! makes the search systematic.
//!
//! ## Adjacency without a length table
//!
//! We count a pair `(prev, cur)` only when it is a true *fall-through*: the
//! VM executed `cur` immediately after `prev` in the same frame, with no
//! control transfer between them. We detect that without decoding operand
//! lengths by two cheap invariants checked at each dispatch:
//!   1. `prev` is not a control-transfer op (jump / branch / call / ret /
//!      halt / fail) — those don't fall through to their static successor.
//!   2. We are still in the *same frame* (`prev_frame == cur_frame`) — a
//!      call/ret or a nested `forceValue` runs on a different frame, so its
//!      ops never pair across the boundary. (Cost: pairs whose first op
//!      triggered an unresolved-thunk force are undercounted — the force
//!      pushes a frame; the already-resolved fast path does not. This biases
//!      *against* force-initiated pairs; documented, not silent.)
//!
//! Run at `--workers=1` so the plain (non-atomic) counters don't race.
//!
//! ## Iterating
//!
//! After fusing the top pair, the *fused* op participates in new pairs on
//! the next profiling run — so re-profiling after each fusion grows
//! superinstructions to triples/quads incrementally (exactly how the
//! existing compound ops were layered). Pairs are therefore sufficient;
//! no dense triple matrix needed.

const std = @import("std");
const build_options = @import("build_options");
const OpCode = @import("../bytecode/opcode.zig").OpCode;
const op_count = @import("../bytecode/opcode.zig").count;

pub const enabled: bool = build_options.opcode_ngram;

const State = struct {
    /// pairs[prev][cur] = times `cur` fell through immediately after `prev`.
    pairs: [op_count][op_count]u64 = @splat(@splat(0)),
    /// Every executed instruction (denominator for pair %).
    total: u64 = 0,
    prev_op: i32 = -1,
    prev_frame: usize = 0,
};

var state: State = .{};

/// True for ops that do not fall through to their static successor.
fn isControlTransfer(op: OpCode) bool {
    return switch (op) {
        .jump, .jump_if_false, .fail_assertion, .call, .tail_call, .call_n, .tail_call_n, .ret, .halt => true,
        else => false,
    };
}

/// Record one executed instruction. `frame` is the current frame pointer
/// (used as an identity token, not dereferenced).
pub inline fn record(op: OpCode, frame: usize) void {
    if (comptime !enabled) return;
    state.total += 1;
    if (state.prev_op >= 0 and state.prev_frame == frame) {
        const prev: OpCode = @enumFromInt(@as(u8, @intCast(state.prev_op)));
        if (!isControlTransfer(prev)) {
            state.pairs[@intFromEnum(prev)][@intFromEnum(op)] += 1;
        }
    }
    state.prev_op = @intFromEnum(op);
    state.prev_frame = frame;
}

const Entry = struct { prev: u8, cur: u8, n: u64 };

pub fn report() void {
    if (comptime !enabled) return;

    const TOP = 50;
    var top: [TOP]Entry = @splat(.{ .prev = 0, .cur = 0, .n = 0 });
    var min_in_top: u64 = 0;
    var nonzero: u64 = 0;
    var paired_total: u64 = 0;

    for (0..op_count) |p| {
        for (0..op_count) |c| {
            const n = state.pairs[p][c];
            if (n == 0) continue;
            nonzero += 1;
            paired_total += n;
            if (n <= min_in_top) continue;
            // Insert into the top-K (small K, linear insert is fine).
            var min_idx: usize = 0;
            var min_val: u64 = std.math.maxInt(u64);
            for (top, 0..) |e, i| {
                if (e.n < min_val) {
                    min_val = e.n;
                    min_idx = i;
                }
            }
            if (n > min_val) {
                top[min_idx] = .{ .prev = @intCast(p), .cur = @intCast(c), .n = n };
                // Recompute the new floor.
                min_in_top = std.math.maxInt(u64);
                for (top) |e| {
                    if (e.n < min_in_top) min_in_top = e.n;
                }
            }
        }
    }

    std.sort.pdq(Entry, &top, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.n > b.n;
        }
    }.lt);

    const pct = struct {
        fn f(n: u64, d: u64) f64 {
            if (d == 0) return 0;
            return @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(d));
        }
    }.f;

    std.debug.print("\n=== opcode-adjacency profile (fusable fall-through pairs) ===\n", .{});
    std.debug.print("instructions executed: {d}\n", .{state.total});
    std.debug.print("fall-through pairs:    {d} ({d:.1}% of instrs); {d} distinct pair shapes\n", .{ paired_total, pct(paired_total, state.total), nonzero });
    std.debug.print("top {d} pairs (prev -> cur), count and % of all instructions:\n", .{TOP});
    for (top) |e| {
        if (e.n == 0) continue;
        const pname = @tagName(@as(OpCode, @enumFromInt(e.prev)));
        const cname = @tagName(@as(OpCode, @enumFromInt(e.cur)));
        std.debug.print("  {d:>12}  {d:>5.2}%   {s} -> {s}\n", .{ e.n, pct(e.n, state.total), pname, cname });
    }
}
