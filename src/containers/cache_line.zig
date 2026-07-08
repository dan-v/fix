//! The `Isolated` cache-line-padded atomic wrapper — pads a value onto its
//! own destructive-interference block (128B on x86_64) to prevent false
//! sharing between hot atomics.

const std = @import("std");

/// A `std.atomic.Value(T)` alone in one full destructive-interference
/// block (128B on x86_64 — the L2 spatial prefetcher pulls line PAIRS,
/// so 64B isolation still ping-pongs). The `align` pins the block start
/// and the pad fills the rest, so the layout can never place another
/// field in the block — field `align` alone does not give that: Zig
/// backfills the alignment gap with whatever fields fit.
///
/// Access the value through `.v`.
pub fn Isolated(comptime T: type) type {
    return struct {
        v: std.atomic.Value(T) align(std.atomic.cache_line),
        _pad: [std.atomic.cache_line - @sizeOf(std.atomic.Value(T))]u8 = undefined,

        pub fn init(value: T) @This() {
            return .{ .v = .init(value) };
        }

        comptime {
            std.debug.assert(@sizeOf(@This()) == std.atomic.cache_line);
        }
    };
}
