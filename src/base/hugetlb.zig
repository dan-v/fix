//! Explicit 2 MB huge-page (hugetlb) backing for the evaluator's big memory.
//!
//! Why: the eval's working set is dominated by a handful of giant mappings
//! (the flat object store, the ≥2 MB block-cache blocks that back the
//! value/attr segment stores and parse arenas). Backing them with explicit
//! hugetlb pages replaces 512 4 KB TLB entries with one 2 MB entry and cuts
//! first-touch faults 512x — measured −8.3% wall at w=1 on the NixOS
//! toplevel, −57% faults / −47% dTLB misses at w=8, and it removes a +202 ms
//! bimodal slow mode under memory-pressure co-load. Transparent huge pages
//! don't fire on this workload's mapping pattern, so the explicit pool
//! (`vm.nr_hugepages`) is the only route.
//!
//! Policy lives here; the two consumers are `block_cache.zig` (class blocks
//! ≥2 MB and >64 MB pass-throughs) and `segments.zig` (the flat store's
//! reserved prefix). Everything is fail-soft: any hugetlb mmap failure falls
//! back to ordinary pages, and consumers only ever use *reserved*
//! (non-NORESERVE) hugetlb mappings, so the kernel guarantees page faults
//! succeed — pool exhaustion can fail an mmap (handled) but never SIGBUS a
//! touch.
//!
//! Mode is process-global, default *unconfigured* (= off) so that library
//! consumers and early allocations never engage hugetlb before the CLI has
//! resolved the user's intent (see `cli/setup.zig:applyMemoryBacking`):
//!   - `off`  — never.
//!   - `on`   — always try; warn once when the pool can't serve a mapping.
//!   - `auto` — engage only when the 2 MB pool has unreserved capacity for a
//!     sensible floor (`AUTO_FLOOR_BYTES`) at first use; individual mmap
//!     failures after that fall back silently per-mapping.
//!
//! Accounting: hugetlb pages are invisible to VmRSS/VmHWM/statm, so every
//! byte mapped through here is counted in `mapped_bytes`/`peak_mapped_bytes`
//! for the RSS-adjacent reporters (`runtime/gc.zig` footprint helpers,
//! `FIX_MEM_REPORT`, the progress/timeline memory counters).

const std = @import("std");
const builtin = @import("builtin");

pub const HUGE_PAGE: usize = 2 << 20;

/// `auto` engagement floor: the unreserved pool must cover at least this
/// much before auto turns hugetlb on. Sized to fit the flat store's first
/// grow-ahead chunk plus a couple of class blocks — below it the win is
/// negligible and the pool is better left to other consumers.
pub const AUTO_FLOOR_BYTES: usize = 256 << 20;

pub const Mode = enum(u8) { auto, on, off };

/// 0 = unconfigured (treated as off); otherwise `@intFromEnum(Mode) + 1`.
var mode_state: std.atomic.Value(u8) = .init(0);
/// Cached `auto` resolution: 0 = unresolved, 1 = engaged, 2 = declined.
var auto_state: std.atomic.Value(u8) = .init(0);
var warned_fallback: std.atomic.Value(bool) = .init(false);

/// Bytes currently mapped as hugetlb by this process (via `map`/`mapFixed`),
/// and the high-water mark. Reserved (non-NORESERVE) mappings are committed
/// pool pages from the system's point of view, so "mapped" is the honest
/// footprint figure even before every page is touched.
var mapped_bytes: std.atomic.Value(usize) = .init(0);
var peak_mapped_bytes: std.atomic.Value(usize) = .init(0);

/// Set the process-wide mode. Called once by CLI setup before the heap maps;
/// safe to call again (e.g. tests) — consumers read it per-decision, and
/// block ownership is tracked per-mapping, so flipping modes never
/// mismatches an munmap. Re-arms the cached `auto` resolution.
pub fn setMode(m: Mode) void {
    mode_state.store(@intFromEnum(m) + 1, .monotonic);
    auto_state.store(0, .monotonic);
}

pub fn getMode() ?Mode {
    const s = mode_state.load(.monotonic);
    if (s == 0) return null;
    return @enumFromInt(s - 1);
}

/// Parse a mode from CLI/env text. Bare truthy/falsy spellings are accepted
/// so the experiment-era `FIX_HUGETLB=1` keeps working; an *empty* value
/// (env var set to nothing) also means `on`, matching the original
/// presence-only gate.
pub fn parseMode(text: []const u8) ?Mode {
    if (text.len == 0) return .on;
    if (std.mem.eql(u8, text, "auto")) return .auto;
    if (std.mem.eql(u8, text, "on") or std.mem.eql(u8, text, "1") or std.mem.eql(u8, text, "true")) return .on;
    if (std.mem.eql(u8, text, "off") or std.mem.eql(u8, text, "0") or std.mem.eql(u8, text, "false")) return .off;
    return null;
}

/// Should a consumer *attempt* hugetlb right now? The mmap itself remains
/// the authoritative check (pool state races are resolved by clean mmap
/// failure + fallback); this only gates the attempt.
pub fn wanted() bool {
    if (comptime builtin.os.tag != .linux) return false;
    const m = getMode() orelse return false;
    return switch (m) {
        .off => false,
        .on => true,
        .auto => autoEngaged(),
    };
}

/// `auto`: resolve once — default huge page size must be 2 MB and the pool
/// must have `AUTO_FLOOR_BYTES` of unreserved capacity. Cached (the answer
/// gates a whole run's policy; per-mapping failures degrade gracefully
/// anyway).
fn autoEngaged() bool {
    const s = auto_state.load(.monotonic);
    if (s != 0) return s == 1;
    const ok = defaultHugePageIs2M() and availablePoolBytes() >= AUTO_FLOOR_BYTES;
    auto_state.store(if (ok) 1 else 2, .monotonic);
    return ok;
}

/// Unreserved 2 MB-pool capacity in bytes: (free − reserved) huge pages.
/// 0 when the pool is absent or sysfs is unreadable.
pub fn availablePoolBytes() usize {
    const free = readSysUint("/sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages") orelse return 0;
    const resv = readSysUint("/sys/kernel/mm/hugepages/hugepages-2048kB/resv_hugepages") orelse 0;
    if (resv >= free) return 0;
    return @as(usize, @intCast(free - resv)) * HUGE_PAGE;
}

/// MAP_HUGETLB without a size suffix uses the kernel's *default* huge page
/// size; all our alignment/rounding assumes 2 MB. On a `default_hugepagesz=1G`
/// system the mmaps would mostly fail (clean fallback), but `auto` shouldn't
/// even engage there.
fn defaultHugePageIs2M() bool {
    var buf: [8192]u8 = undefined;
    const text = readFileInto("/proc/meminfo", &buf) orelse return false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Hugepagesize:")) continue;
        var it = std.mem.tokenizeScalar(u8, line["Hugepagesize:".len..], ' ');
        const tok = it.next() orelse return false;
        const kb = std.fmt.parseInt(u64, tok, 10) catch return false;
        return kb == 2048;
    }
    return false;
}

fn readSysUint(path: [:0]const u8) ?u64 {
    var buf: [64]u8 = undefined;
    const text = readFileInto(path, &buf) orelse return null;
    return parseLeadingUint(text);
}

/// First whitespace-delimited token as an unsigned integer.
pub fn parseLeadingUint(text: []const u8) ?u64 {
    var it = std.mem.tokenizeAny(u8, text, " \t\n");
    const tok = it.next() orelse return null;
    return std.fmt.parseInt(u64, tok, 10) catch null;
}

/// Raw-syscall file read (no allocator, callable at any init order).
fn readFileInto(path: [:0]const u8, buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .linux) return null;
    const linux = std.os.linux;
    const fd_raw = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_raw)));
    if (fd < 0) return null;
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    const rd: isize = @bitCast(n);
    if (rd <= 0) return null;
    return buf[0..@intCast(rd)];
}

pub fn roundedLen(len: usize) usize {
    return std.mem.alignForward(usize, len, HUGE_PAGE);
}

/// Map `len` (rounded up to 2 MB) of anonymous private hugetlb memory.
/// Non-NORESERVE: the pool pages are reserved at mmap time, so faults on the
/// returned region are guaranteed to succeed — exhaustion fails *here*,
/// cleanly, and the caller falls back to its ordinary allocation path.
pub fn map(len: usize) ?[*]align(std.heap.page_size_min) u8 {
    if (comptime builtin.os.tag != .linux) return null;
    const rounded = roundedLen(len);
    const mem = std.posix.mmap(
        null,
        rounded,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .HUGETLB = true },
        -1,
        0,
    ) catch {
        noteFallback();
        return null;
    };
    noteMapped(rounded);
    return mem.ptr;
}

/// Overlay `[addr, addr+len)` — 2 MB-aligned, a 2 MB multiple — with reserved
/// hugetlb pages (MAP_FIXED atomically replaces the existing mapping there).
/// The flat store uses this to grow its huge prefix ahead of the bump cursor;
/// the caller must guarantee the range holds no live data (a replaced
/// mapping's contents are discarded). Returns false (existing mapping left
/// intact — a failed MAP_FIXED mmap changes nothing) when the pool can't
/// serve the reservation.
pub fn mapFixed(addr: [*]u8, len: usize) bool {
    if (comptime builtin.os.tag != .linux) return false;
    std.debug.assert(@intFromPtr(addr) % HUGE_PAGE == 0 and len % HUGE_PAGE == 0 and len > 0);
    const aligned: [*]align(std.heap.page_size_min) u8 = @alignCast(addr);
    _ = std.posix.mmap(
        aligned,
        len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .HUGETLB = true, .FIXED = true },
        -1,
        0,
    ) catch {
        noteFallback();
        return false;
    };
    noteMapped(len);
    return true;
}

/// Unmap a region obtained from `map` (`rounded_len` = the 2 MB-rounded
/// length `map` actually mapped).
pub fn unmap(ptr: [*]u8, rounded_len: usize) void {
    const bytes: [*]align(std.heap.page_size_min) u8 = @alignCast(ptr);
    std.posix.munmap(bytes[0..rounded_len]);
    noteUnmapped(rounded_len);
}

fn noteMapped(n: usize) void {
    const now = mapped_bytes.fetchAdd(n, .monotonic) + n;
    var peak = peak_mapped_bytes.load(.monotonic);
    while (now > peak) {
        peak = peak_mapped_bytes.cmpxchgWeak(peak, now, .monotonic, .monotonic) orelse break;
    }
}

/// Public for consumers whose teardown unmaps hugetlb ranges as part of a
/// larger munmap (the flat store frees its whole reservation in one call).
pub fn noteUnmapped(n: usize) void {
    _ = mapped_bytes.fetchSub(n, .monotonic);
}

pub fn mappedBytes() usize {
    return mapped_bytes.load(.monotonic);
}

pub fn peakMappedBytes() usize {
    return peak_mapped_bytes.load(.monotonic);
}

/// `on` means the user asked for hugetlb explicitly — tell them once when
/// the pool can't serve it (auto stays silent; fallback is its contract).
fn noteFallback() void {
    if (getMode() != .on) return;
    if (comptime builtin.is_test) return; // stderr corrupts the test runner
    if (warned_fallback.swap(true, .monotonic)) return;
    std.debug.print(
        "fix: warning: hugetlb pool exhausted or unavailable; falling back to normal pages " ++
            "(provision with `sysctl vm.nr_hugepages=N`, or pass --hugetlb off)\n",
        .{},
    );
}

test "parseMode accepts mode names and truthy/falsy spellings" {
    try std.testing.expectEqual(@as(?Mode, .auto), parseMode("auto"));
    try std.testing.expectEqual(@as(?Mode, .on), parseMode("on"));
    try std.testing.expectEqual(@as(?Mode, .on), parseMode("1"));
    try std.testing.expectEqual(@as(?Mode, .on), parseMode("true"));
    try std.testing.expectEqual(@as(?Mode, .on), parseMode("")); // env set-but-empty
    try std.testing.expectEqual(@as(?Mode, .off), parseMode("off"));
    try std.testing.expectEqual(@as(?Mode, .off), parseMode("0"));
    try std.testing.expectEqual(@as(?Mode, .off), parseMode("false"));
    try std.testing.expectEqual(@as(?Mode, null), parseMode("yes"));
    try std.testing.expectEqual(@as(?Mode, null), parseMode("2"));
}

test "mode state: unconfigured is off; setMode round-trips" {
    // Restore the pristine state for later tests regardless of outcome.
    const saved = mode_state.load(.monotonic);
    defer mode_state.store(saved, .monotonic);
    mode_state.store(0, .monotonic);
    try std.testing.expectEqual(@as(?Mode, null), getMode());
    try std.testing.expect(!wanted());
    setMode(.off);
    try std.testing.expectEqual(@as(?Mode, .off), getMode());
    try std.testing.expect(!wanted());
    setMode(.on);
    try std.testing.expectEqual(@as(?Mode, .on), getMode());
}

test "parseLeadingUint" {
    try std.testing.expectEqual(@as(?u64, 2048), parseLeadingUint("2048\n"));
    try std.testing.expectEqual(@as(?u64, 7), parseLeadingUint("  7 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), parseLeadingUint("x"));
    try std.testing.expectEqual(@as(?u64, null), parseLeadingUint(""));
}

test "roundedLen rounds to 2 MB" {
    try std.testing.expectEqual(HUGE_PAGE, roundedLen(1));
    try std.testing.expectEqual(HUGE_PAGE, roundedLen(HUGE_PAGE));
    try std.testing.expectEqual(2 * HUGE_PAGE, roundedLen(HUGE_PAGE + 1));
}

test "map/unmap: accounting balances whether or not the pool serves it" {
    if (comptime builtin.os.tag != .linux) return;
    const saved = mode_state.load(.monotonic);
    defer mode_state.store(saved, .monotonic);
    setMode(.on);
    const before = mappedBytes();
    if (map(3 << 20)) |p| {
        // Rounded to 2 huge pages; memory is usable end to end.
        try std.testing.expectEqual(before + (4 << 20), mappedBytes());
        try std.testing.expect(peakMappedBytes() >= mappedBytes());
        p[0] = 0xAB;
        p[(4 << 20) - 1] = 0xCD;
        try std.testing.expectEqual(@as(u8, 0xAB), p[0]);
        unmap(p, 4 << 20);
    }
    try std.testing.expectEqual(before, mappedBytes());
}
