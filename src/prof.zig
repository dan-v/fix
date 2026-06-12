//! Lightweight rdtsc-based profiler for the main thread's hot
//! serial paths. Build-gated on `-Dprof-main`; off-build compiles
//! to no-ops with zero runtime footprint.
//!
//! Helpers don't update counters (we only care about main's serial
//! pathlength), so the per-call overhead on workers is one
//! thread-local load + branch. On main it's two `rdtsc`s plus
//! stack push/pop.
//!
//! **Exclusive time.** A per-thread call stack tracks the nested
//! instrumented scopes; at `end`, the inclusive delta is recorded
//! as the sample's exclusive cycles, *minus* time already attributed
//! to nested child scopes. The parent's `child_exclusion` then
//! absorbs the popped scope's inclusive delta. This means the
//! printed cycles for each path are wall-cycles spent *inside that
//! routine but not inside any inner instrumented routine* — what
//! you want for finding bottlenecks.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const worker_id = @import("runtime/worker_id.zig");

/// Compile-time switch. False when `-Dprof-main` wasn't passed.
/// `rdtsc` is x86_64-only, so we additionally gate on arch.
pub const enabled: bool = build_options.prof_main and builtin.cpu.arch == .x86_64;

/// Tag for every instrumented path. Keep names short — they appear
/// in the stats line as-is.
pub const Path = enum {
    /// `force.forceValue` end-to-end, including both fast and slow
    /// thunk paths. Covers explicit caller forces.
    force_value,
    /// `forceThunkImpl` slow path — the thunk was not already
    /// resolved when `forceValue` peeked.
    force_thunk_slow,
    /// `access.getAttrValue` — attr lookup (post-force on the
    /// attrs operand, post-cached-lookup, post-force on the result).
    get_attr_value,
    /// `closures.callValue` — helper-callable closure entry.
    call_value,
    /// `closures.doCall` — interpreter-side closure entry.
    do_call,
    /// `closures.doTailCall` — interpreter-side closure tail entry.
    do_tail_call,
    /// `closures.runIsolatedFrame` — bytecode runner for a
    /// freshly-pushed frame.
    run_isolated_frame,
    /// `closures.makeBytecodeThunkFromCaptures` — non-trivial path
    /// (when the trivial-body short-circuit didn't apply).
    make_bytecode_thunk,
    /// Time spent in `Fiber.yield()` when a force hits a `.busy`
    /// thunk — the fiber suspends until the resolver wakes it. While
    /// suspended, worker 0 may run other fibers / drain tasks; the
    /// TSC doesn't stop, so this cycles count is wall-clock cycles,
    /// not CPU-cycles. The exclusive-time accounting subtracts any
    /// instrumented work that happens *on the same OS thread* during
    /// the yield.
    wait_busy_thunk,
    /// Time spent in `parkAndAccount` on worker 0 (the OS thread
    /// running main) when its ready queue is empty. Pure idle time
    /// from main's perspective; if this is large, helpers aren't
    /// keeping main fed.
    park_main_worker,
};

pub const Sample = struct {
    calls: u64 = 0,
    /// Exclusive cycles — time spent in this routine but not inside
    /// any inner instrumented routine.
    cycles: u64 = 0,
    /// Inclusive cycles — time spent in this routine including
    /// nested instrumented routines. Useful as a sanity check.
    cycles_inclusive: u64 = 0,
};

const path_count = @typeInfo(Path).@"enum".fields.len;

/// Per-path counters. Main-thread-only writes; reads (for printing)
/// happen after the eval finishes.
pub var samples: [path_count]Sample = @splat(.{});

const StackFrame = struct {
    path: Path,
    start_tsc: u64,
    /// Sum of inclusive deltas of nested instrumented calls that
    /// have already returned. Used to compute exclusive time at end.
    child_exclusion: u64,
};

const stack_cap: usize = 256;

/// Per-thread instrumentation stack. Only worker 0 writes to it.
threadlocal var prof_stack: [stack_cap]StackFrame = undefined;
threadlocal var prof_stack_len: usize = 0;

/// Read the TSC. `rdtsc` returns a 64-bit counter formed from
/// edx:eax. We use it as a coarse time source — the TSC is
/// invariant on modern x86_64 so it doesn't pause across power
/// states; the ratio to wall time is constant within a run.
inline fn rdtsc() u64 {
    if (!enabled) return 0;
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        :
        : .{ .memory = true });
    return (@as(u64, high) << 32) | @as(u64, low);
}

/// Start a measurement on the main thread. Returns a sentinel
/// (UINT64_MAX) on helpers and on disabled builds; the matching
/// `end` ignores that case. The real returned value is the
/// `prof_stack` index of the pushed frame (always < stack_cap).
pub inline fn start(comptime path: Path) u64 {
    if (!enabled) return std.math.maxInt(u64);
    if (worker_id.current != 0) return std.math.maxInt(u64);
    if (prof_stack_len >= stack_cap) return std.math.maxInt(u64);
    const idx = prof_stack_len;
    prof_stack[idx] = .{
        .path = path,
        .start_tsc = rdtsc(),
        .child_exclusion = 0,
    };
    prof_stack_len += 1;
    return idx;
}

/// End a measurement started by `start`. No-op on disabled builds
/// and helper threads.
pub inline fn end(comptime path: Path, t: u64) void {
    if (!enabled) return;
    if (t == std.math.maxInt(u64)) return;
    const now = rdtsc();
    // The expected stack invariant: `t` indexes the topmost frame
    // and its path matches what we pushed. Tolerate mismatches by
    // unwinding only if depth is consistent — defensive guard
    // against unexpected control-flow that bypasses defer.
    if (prof_stack_len == 0 or prof_stack_len - 1 != t) return;
    const frame = &prof_stack[t];
    if (frame.path != path) return;
    const inclusive = now - frame.start_tsc;
    const exclusive = inclusive - frame.child_exclusion;
    const s = &samples[@intFromEnum(path)];
    s.calls += 1;
    s.cycles += exclusive;
    s.cycles_inclusive += inclusive;
    prof_stack_len -= 1;
    // Attribute the popped scope's inclusive delta to the parent's
    // child_exclusion so the parent's exclusive time skips it.
    if (prof_stack_len > 0) {
        prof_stack[prof_stack_len - 1].child_exclusion += inclusive;
    }
}
