//! ARC feasibility microbench: cost of atomic refcount RMWs under the
//! sharing patterns the arc-census measured on the NixOS toplevel.
//!
//! Modes (each thread does N fetchAdd(1)/fetchSub(1) pairs):
//!   plain   — non-atomic add on a thread-private padded slot (pure ALU floor)
//!   local   — atomic RMW on a thread-private padded slot (uncontended floor)
//!   shared1 — all threads on ONE slot (the single hottest object: `lib`,
//!             0.47% of all edge incs land here)
//!   hot8    — uniform over 8 padded slots shared by all threads (top-8
//!             objects = 2.3% of edges)
//!   random  — uniform over 8M slots spaced 64B apart (512MB working set):
//!             the refcount field of a cold referent object — DRAM-miss cost
//!             of touching the target's header line on every edge write
//!   mixed   — measured census distribution: 0.5% top1, 1.8% top8 (rest),
//!             5.3% top64 (rest), 92.4% random-cold
//!
//! Standalone: zig build-exe -O ReleaseFast tools/arc_bench.zig
//! Runs every mode at 1 and 8 threads (10M inc/dec pairs per thread).

const std = @import("std");

const CACHE_LINE = 64;
const RANDOM_SLOTS: usize = 1 << 23; // 8M slots * 64B = 512MB

const Padded = struct {
    v: std.atomic.Value(u64) align(CACHE_LINE) = .init(0),
    _pad: [CACHE_LINE - 8]u8 = undefined,
};

const Mode = enum { plain, local, shared1, hot8, random, mixed };

var start_flag: std.atomic.Value(bool) = .init(false);

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn xorshift(s: *u64) u64 {
    var x = s.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    s.* = x;
    return x;
}

const Ctx = struct {
    mode: Mode,
    tid: usize,
    ops: u64,
    locals: []Padded, // one per thread
    hot: []Padded, // 64 shared slots
    cold: []u8, // RANDOM_SLOTS * 64B region; slot i at offset i*64
    ns: u64 = 0,
};

fn coldSlot(cold: []u8, i: usize) *std.atomic.Value(u64) {
    return @ptrCast(@alignCast(cold.ptr + i * CACHE_LINE));
}

fn worker(ctx: *Ctx) void {
    while (!start_flag.load(.acquire)) std.atomic.spinLoopHint();
    var rng: u64 = 0x9E3779B97F4A7C15 ^ (@as(u64, ctx.tid) << 32) | 1;
    var plain_acc: u64 = 0;
    const t0 = nowNs();
    var i: u64 = 0;
    while (i < ctx.ops) : (i += 1) {
        switch (ctx.mode) {
            .plain => {
                // Defeat vectorization with a volatile-ish dependency.
                plain_acc +%= i;
                std.mem.doNotOptimizeAway(&plain_acc);
            },
            .local => {
                _ = ctx.locals[ctx.tid].v.fetchAdd(1, .monotonic);
                _ = ctx.locals[ctx.tid].v.fetchSub(1, .monotonic);
            },
            .shared1 => {
                _ = ctx.hot[0].v.fetchAdd(1, .monotonic);
                _ = ctx.hot[0].v.fetchSub(1, .monotonic);
            },
            .hot8 => {
                const s = &ctx.hot[xorshift(&rng) & 7];
                _ = s.v.fetchAdd(1, .monotonic);
                _ = s.v.fetchSub(1, .monotonic);
            },
            .random => {
                const s = coldSlot(ctx.cold, xorshift(&rng) & (RANDOM_SLOTS - 1));
                _ = s.fetchAdd(1, .monotonic);
                _ = s.fetchSub(1, .monotonic);
            },
            .mixed => {
                const r = xorshift(&rng) % 1000;
                const s = if (r < 5)
                    &ctx.hot[0].v
                else if (r < 23)
                    &ctx.hot[1 + (xorshift(&rng) % 7)].v
                else if (r < 76)
                    &ctx.hot[8 + (xorshift(&rng) % 56)].v
                else
                    coldSlot(ctx.cold, xorshift(&rng) & (RANDOM_SLOTS - 1));
                _ = s.fetchAdd(1, .monotonic);
                _ = s.fetchSub(1, .monotonic);
            },
        }
    }
    ctx.ns = nowNs() - t0;
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    const ops: u64 = 10_000_000;

    const hot = try a.alloc(Padded, 64);
    for (hot) |*h| h.* = .{};
    const cold = try a.alloc(u8, RANDOM_SLOTS * CACHE_LINE);
    @memset(cold, 0); // fault in

    for ([_]usize{ 1, 8 }) |threads| {
        const locals = try a.alloc(Padded, threads);
        for (locals) |*l| l.* = .{};
        inline for (@typeInfo(Mode).@"enum".fields) |mf| {
            const mode: Mode = @enumFromInt(mf.value);
            const ctxs = try a.alloc(Ctx, threads);
            for (ctxs, 0..) |*c, i| c.* = .{ .mode = mode, .tid = i, .ops = ops, .locals = locals, .hot = hot, .cold = cold };
            start_flag.store(false, .release);
            const ts = try a.alloc(std.Thread, threads);
            for (ts, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, worker, .{&ctxs[i]});
            // Let all threads reach the barrier.
            var req: std.os.linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
            _ = std.os.linux.nanosleep(&req, null);
            start_flag.store(true, .release);
            for (ts) |t| t.join();
            var max_ns: u64 = 0;
            for (ctxs) |c| max_ns = @max(max_ns, c.ns);
            // Each op is an inc+dec PAIR (except plain) — report per single RMW.
            const rmws_per_op: u64 = if (mode == .plain) 1 else 2;
            const per_rmw = @as(f64, @floatFromInt(max_ns)) / @as(f64, @floatFromInt(ops * rmws_per_op));
            std.debug.print("{s:<8} threads={d} ops/thread={d} wall={d}ms ns/rmw={d:.2}\n", .{
                @tagName(mode), threads, ops, max_ns / std.time.ns_per_ms, per_rmw,
            });
            a.free(ts);
            a.free(ctxs);
        }
        a.free(locals);
    }
}
