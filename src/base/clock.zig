//! Small process-clock helpers shared by runtime instrumentation.
//!
//! The evaluator's timing counters are advisory. Linux uses the vDSO-backed
//! clock_gettime fast path; unsupported platforms return zero so callers never
//! manufacture durations from incompatible clock domains.

const std = @import("std");
const builtin = @import("builtin");

pub fn monotonicNs() u64 {
    if (comptime builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
    const nsec: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
    return sec * std.time.ns_per_s + nsec;
}

pub fn monotonicUs() u64 {
    return monotonicNs() / std.time.ns_per_us;
}

pub fn unixTimeSec() i64 {
    if (comptime builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return ts.sec;
}

test "monotonic units share one clock reading domain" {
    const before = monotonicUs();
    const ns = monotonicNs();
    const after = monotonicUs();
    if (ns == 0) return;
    try std.testing.expect(before <= ns / std.time.ns_per_us);
    try std.testing.expect(ns / std.time.ns_per_us <= after);
}
