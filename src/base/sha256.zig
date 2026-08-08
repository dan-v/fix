//! SHA-256 with runtime hardware dispatch.
//!
//! Drop-in for `std.crypto.hash.sha2.Sha256` (same digests, same streaming
//! shape). On x86_64 the build links a twin of the std hasher compiled with
//! `+sha,+avx2` (`sha256_hw.zig`); a one-time cpuid probe routes every hasher
//! through it when the machine has SHA-NI, which `-Dcpu=baseline` binaries
//! otherwise leave unused (~5x on Zen 3). Everywhere else this is exactly the
//! std hasher.

const std = @import("std");
const builtin = @import("builtin");

const StdSha256 = std.crypto.hash.sha2.Sha256;

const hw_available = builtin.cpu.arch == .x86_64 and builtin.os.tag != .windows;

const hw = if (hw_available) struct {
    pub const state_bytes = 128;
    const State = extern struct { bytes: [state_bytes]u8 align(16) };
    extern fn fix_sha256_hw_layout() usize;
    extern fn fix_sha256_hw_init(state: *State) void;
    extern fn fix_sha256_hw_update(state: *State, ptr: [*]const u8, len: usize) void;
    extern fn fix_sha256_hw_final(state: *State, out: *[StdSha256.digest_length]u8) void;
} else struct {};

/// Lazily probed; both values are idempotent so a racing double-store is
/// benign.
var use_hw_cache = std.atomic.Value(u8).init(0); // 0 unknown, 1 no, 2 yes

fn useHw() bool {
    if (!hw_available) return false;
    const cached = use_hw_cache.load(.monotonic);
    if (cached != 0) return cached == 2;
    const decided: u8 = if (probeHw()) 2 else 1;
    use_hw_cache.store(decided, .monotonic);
    return decided == 2;
}

/// The std hardware path requires SHA-NI and AVX2, with OS-managed YMM state
/// (mirrors the comptime gate in std.crypto.sha2, checked at runtime).
fn probeHw() bool {
    if (!hw_available) return false;
    const leaf1 = cpuid(1, 0);
    const osxsave = leaf1.ecx & (1 << 27) != 0;
    if (!osxsave) return false;
    const xcr0 = xgetbv0();
    if (xcr0 & 0b110 != 0b110) return false; // XMM and YMM state enabled
    const leaf7 = cpuid(7, 0);
    const avx2 = leaf7.ebx & (1 << 5) != 0;
    const sha = leaf7.ebx & (1 << 29) != 0;
    if (!(avx2 and sha)) return false;
    // Refuse the blob handoff if the two compilations ever disagree on the
    // std hasher's layout.
    return hw.fix_sha256_hw_layout() == @sizeOf(StdSha256);
}

const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf: u32, sub: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn xgetbv0() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("xgetbv"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [xcr] "{ecx}" (@as(u32, 0)),
    );
    return (@as(u64, hi) << 32) | lo;
}

pub const Sha256 = struct {
    pub const digest_length = StdSha256.digest_length;
    pub const block_length = StdSha256.block_length;
    pub const Options = StdSha256.Options;

    impl: union(enum) {
        soft: StdSha256,
        hard: if (hw_available) hw.State else void,
    },

    pub fn init(options: Options) Sha256 {
        _ = options;
        if (useHw()) {
            var state: Sha256 = .{ .impl = .{ .hard = undefined } };
            if (hw_available) hw.fix_sha256_hw_init(&state.impl.hard);
            return state;
        }
        return .{ .impl = .{ .soft = StdSha256.init(.{}) } };
    }

    pub fn update(self: *Sha256, bytes: []const u8) void {
        switch (self.impl) {
            .soft => |*impl| impl.update(bytes),
            .hard => |*state| if (hw_available) hw.fix_sha256_hw_update(state, bytes.ptr, bytes.len),
        }
    }

    pub fn final(self: *Sha256, out: *[digest_length]u8) void {
        switch (self.impl) {
            .soft => |*impl| impl.final(out),
            .hard => |*state| if (hw_available) hw.fix_sha256_hw_final(state, out),
        }
    }

    pub fn finalResult(self: *Sha256) [digest_length]u8 {
        var result: [digest_length]u8 = undefined;
        self.final(&result);
        return result;
    }

    pub fn hash(bytes: []const u8, out: *[digest_length]u8, options: Options) void {
        var hasher = Sha256.init(options);
        hasher.update(bytes);
        hasher.final(out);
    }
};

test "hardware and software digests agree across split points" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var payload: [4096]u8 = undefined;
    random.bytes(&payload);

    // Lengths straddling block/buffer boundaries plus random splits.
    const lengths = [_]usize{ 0, 1, 55, 56, 63, 64, 65, 127, 128, 129, 1000, 4096 };
    for (lengths) |len| {
        var expected: [Sha256.digest_length]u8 = undefined;
        StdSha256.hash(payload[0..len], &expected, .{});

        var whole: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(payload[0..len], &whole, .{});
        try std.testing.expectEqualSlices(u8, &expected, &whole);

        var streaming = Sha256.init(.{});
        var at: usize = 0;
        while (at < len) {
            const chunk = @min(len - at, random.intRangeAtMost(usize, 1, 97));
            streaming.update(payload[at .. at + chunk]);
            at += chunk;
        }
        var split: [Sha256.digest_length]u8 = undefined;
        streaming.final(&split);
        try std.testing.expectEqualSlices(u8, &expected, &split);
    }
}
