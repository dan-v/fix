//! Persistent compiled-unit cache subsystem.
//!
//! This public surface joins four independent mechanisms: cache identity,
//! wire encoding, wire validation/decoding, and storage. The codec modules
//! own the on-disk contract; callers only need keys plus serialize/load.

const common = @import("cache/wire.zig");
const key = @import("cache/key.zig");
const encoder = @import("cache/encoder.zig");
const decoder = @import("cache/decoder.zig");

pub const format_version = common.format_version;
pub const Error = common.Error;
pub const UnitRecord = common.UnitRecord;
pub const LoadDeps = common.LoadDeps;
pub const LoadResult = common.LoadResult;

pub const selfBuildId = key.selfBuildId;
pub const KeyContext = key.KeyContext;
pub const Key = key.Key;
pub const computeKey = key.computeKey;

pub const serialize = encoder.serialize;
pub const load = decoder.load;

test {
    _ = @import("cache/tests.zig");
}
