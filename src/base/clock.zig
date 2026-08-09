//! Small process-clock helpers shared by runtime instrumentation.
//!
//! The evaluator's timing counters are advisory. Linux uses the vDSO-backed
//! clock_gettime fast path, Darwin the libc one; other platforms return zero
//! so callers never manufacture durations from incompatible clock domains.

const std = @import("std");
const builtin = @import("builtin");

pub fn monotonicNs() u64 {
    if (comptime builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
        return clampedNs(ts.sec, ts.nsec);
    }
    if (comptime builtin.os.tag.isDarwin()) {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
        return clampedNs(ts.sec, ts.nsec);
    }
    return 0;
}

fn clampedNs(sec_raw: i64, nsec_raw: i64) u64 {
    const sec: u64 = if (sec_raw > 0) @intCast(sec_raw) else 0;
    const nsec: u64 = if (nsec_raw > 0) @intCast(nsec_raw) else 0;
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

/// Render a unix timestamp as Nix's `lastModifiedDate` form: UTC
/// `YYYYMMDDHHMMSS`. Out-of-range inputs (pre-epoch, or past year 9999 — e.g.
/// a garbage lockfile pin) clamp rather than error: this feeds display/version
/// strings, never time arithmetic.
pub fn formatUtc(timestamp: i64) [14]u8 {
    const max_9999 = 253402300799; // 9999-12-31T23:59:59Z
    const secs: u64 = @intCast(std.math.clamp(timestamp, 0, max_9999));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    var out: [14]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable; // clamped input renders exactly 14 bytes
    return out;
}

test "formatUtc renders UTC and clamps out-of-range timestamps" {
    try std.testing.expectEqualStrings("20120306230650", &formatUtc(1_331_075_210));
    try std.testing.expectEqualStrings("19700101000000", &formatUtc(0));
    try std.testing.expectEqualStrings("19700101000000", &formatUtc(-5));
    try std.testing.expectEqualStrings("99991231235959", &formatUtc(std.math.maxInt(i64)));
}

test "supported platforms report a nonzero monotonic clock" {
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return;
    try std.testing.expect(monotonicNs() != 0);
}

test "monotonic units share one clock reading domain" {
    const before = monotonicUs();
    const ns = monotonicNs();
    const after = monotonicUs();
    if (ns == 0) return;
    try std.testing.expect(before <= ns / std.time.ns_per_us);
    try std.testing.expect(ns / std.time.ns_per_us <= after);
}
