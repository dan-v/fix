//! Per-path import deduplication primitives.
//!
//! ImportEntry is the futex-backed claim+wait protocol for path
//! deduplication: the first thread to cmpxchg UNRESOLVED→EVALUATING
//! does the work; others either wait on the futex (main thread) or
//! bail with `error.ImportContended` (helpers, to avoid deadlock with
//! a main thread holding a contended thunk).
//!
//! Scoped imports skip this dedup — each call carries a distinct scope
//! Value — so cycle detection for them is a thread-local linked list
//! threaded through the import call stack.

const std = @import("std");
const Value = @import("../runtime/value.zig").Value;

pub const INVALID_CLAIMER: u8 = 0xFF;

pub const ImportEntry = struct {
    pub const STATE_UNRESOLVED: u32 = 0;
    pub const STATE_EVALUATING: u32 = 1;
    pub const STATE_RESOLVED: u32 = 2;
    pub const STATE_FAILED: u32 = 3;

    state: std.atomic.Value(u32) = .init(STATE_UNRESOLVED),
    claimer: std.atomic.Value(u8) = .init(INVALID_CLAIMER),
    result: Value = Value.null_val,

    pub fn waitForChange(self: *ImportEntry, from: u32) void {
        switch (@import("builtin").os.tag) {
            .linux => {
                _ = std.os.linux.futex_4arg(
                    @ptrCast(&self.state),
                    .{ .cmd = .WAIT, .private = true },
                    from,
                    null,
                );
            },
            else => std.Thread.yield() catch {},
        }
    }

    pub fn wakeAll(self: *ImportEntry) void {
        switch (@import("builtin").os.tag) {
            .linux => {
                _ = std.os.linux.futex_3arg(
                    @ptrCast(&self.state),
                    .{ .cmd = .WAKE, .private = true },
                    std.math.maxInt(i32),
                );
            },
            else => {},
        }
    }
};

/// Per-thread linked list of in-progress *scoped* import paths.
/// `pushFrame` returns the prior top so the caller can restore it on
/// scope exit; `checkCycle` walks the chain looking for `path`.
pub const ScopedFrame = struct {
    path: []const u8,
    next: ?*const ScopedFrame,
};

threadlocal var scoped_stack_top: ?*const ScopedFrame = null;

pub fn scopedStackTop() ?*const ScopedFrame {
    return scoped_stack_top;
}

pub fn pushScopedFrame(frame: *ScopedFrame) ?*const ScopedFrame {
    const prev = scoped_stack_top;
    frame.next = prev;
    scoped_stack_top = frame;
    return prev;
}

pub fn popScopedFrame(prev: ?*const ScopedFrame) void {
    scoped_stack_top = prev;
}

pub fn checkScopedCycle(path: []const u8) !void {
    var cursor = scoped_stack_top;
    while (cursor) |node| {
        if (std.mem.eql(u8, node.path, path)) return error.ImportCycle;
        cursor = node.next;
    }
}

/// Synthetic source for `<nix/fetchurl.nix>`, hard-coded so the
/// evaluator doesn't need a corepkgs store path on disk.
pub fn corepkgsSource(path: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, path, "/__corepkgs__/fetchurl.nix")) return null;
    return
    \\{
    \\  name ? baseNameOf url,
    \\  url,
    \\  hash ? "",
    \\  sha256 ? "",
    \\  executable ? false,
    \\  ...
    \\}:
    \\let
    \\  outputHash = if hash != "" then hash else sha256;
    \\in
    \\derivation {
    \\  inherit name url executable;
    \\  urls = [ url ];
    \\  builder = "builtin:fetchurl";
    \\  system = "builtin";
    \\  inherit outputHash;
    \\  outputHashAlgo = if hash != "" then null else "sha256";
    \\  outputHashMode = if executable then "recursive" else "flat";
    \\  preferLocalBuild = true;
    \\  impureEnvVars = [ "http_proxy" "https_proxy" "ftp_proxy" "all_proxy" "no_proxy" ];
    \\  unpack = false;
    \\}
    ;
}
