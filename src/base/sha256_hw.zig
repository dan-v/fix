//! Hardware-path twin of `std.crypto.hash.sha2.Sha256`.
//!
//! std's SHA-NI implementation is comptime-gated on `+sha,+avx2`, which a
//! `-Dcpu=baseline` binary never satisfies. This file is compiled as its own
//! module with those features added (build.zig, x86_64 only) so the gate
//! opens, and exports the std hasher behind a C ABI. `sha256.zig` in the
//! ordinary-features build dispatches here after a cpuid check.
//!
//! The state blob crosses the boundary opaquely: only this compilation unit
//! ever interprets it as `std.crypto.hash.sha2.Sha256`. `fix_sha256_hw_layout`
//! lets the caller verify at runtime that both compilations agree on the
//! state's size before trusting the blob (they always should — the struct
//! stores no vectors, and CPU features don't change field layout).

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const state_bytes = 128;

comptime {
    std.debug.assert(@sizeOf(Sha256) <= state_bytes);
    std.debug.assert(@alignOf(Sha256) <= 16);
}

const State = extern struct { bytes: [state_bytes]u8 align(16) };

export fn fix_sha256_hw_layout() usize {
    return @sizeOf(Sha256);
}

export fn fix_sha256_hw_init(state: *State) void {
    const impl: *Sha256 = @ptrCast(state);
    impl.* = Sha256.init(.{});
}

export fn fix_sha256_hw_update(state: *State, ptr: [*]const u8, len: usize) void {
    const impl: *Sha256 = @ptrCast(state);
    impl.update(ptr[0..len]);
}

export fn fix_sha256_hw_final(state: *State, out: *[Sha256.digest_length]u8) void {
    const impl: *Sha256 = @ptrCast(state);
    impl.final(out);
}
