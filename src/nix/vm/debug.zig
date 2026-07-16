//! Dispatch-boundary invariant checks for the VM.
//!
//! These assertions guard against bugs in the bytecode loop, especially the
//! kind that appear when optimizing dispatch (e.g. caching `code`/`frame`
//! across iterations). They are gated on the `debug_checks` build option
//! and compile to nothing in release builds.
//!
//! Use:
//!   const debug = @import("debug.zig");
//!   debug.checkFrameSync(self, frame, code, "after .call");

const std = @import("std");
const build_options = @import("build_options");
const vm_mod = @import("context.zig");
const types = @import("runtime").types;

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const stack = @import("stack.zig");

pub const enabled = build_options.debug_checks;

/// Verify that `frame` is the current top frame and `code` is the body the
/// VM is about to dispatch from. Call this anywhere the dispatch loop has
/// just refreshed `frame`/`code` after a frame-changing opcode.
pub inline fn checkFrameSync(
    self: *VM,
    frame: *const Frame,
    code: []const u8,
    site: []const u8,
) void {
    if (comptime !enabled) return;
    checkFrameSyncSlow(self, frame, code, site);
}

fn checkFrameSyncSlow(
    self: *VM,
    frame: *const Frame,
    code: []const u8,
    site: []const u8,
) void {
    if (self.frames_len == 0) {
        std.debug.panic("VM invariant: no frames at dispatch ({s})", .{site});
    }
    const current = stack.currentFrame(self);
    if (current != frame) {
        std.debug.panic(
            "VM invariant: cached frame pointer 0x{x} != current 0x{x} at {s} (depth={d})",
            .{ @intFromPtr(frame), @intFromPtr(current), site, self.frames_len },
        );
    }
    if (code.ptr != current.chunk_ptr.code.ptr or code.len != current.chunk_ptr.code.len) {
        std.debug.panic(
            "VM invariant: cached code [{x}+{d}] != frame.chunk_ptr.code [{x}+{d}] at {s}",
            .{ @intFromPtr(code.ptr), code.len, @intFromPtr(current.chunk_ptr.code.ptr), current.chunk_ptr.code.len, site },
        );
    }
    if (current.ip > current.chunk_ptr.code.len) {
        std.debug.panic(
            "VM invariant: ip {d} past end of code (len={d}) at {s}",
            .{ current.ip, current.chunk_ptr.code.len, site },
        );
    }
}

/// Generic sanity check for VM bookkeeping. Cheap enough to run on every
/// outer dispatch turn when invariants are on.
pub inline fn checkVm(self: *VM, site: []const u8) void {
    if (comptime !enabled) return;
    checkVmSlow(self, site);
}

fn checkVmSlow(self: *VM, site: []const u8) void {
    if (self.frames_len > types.MAX_FRAMES) {
        std.debug.panic(
            "VM invariant: frames_len {d} > MAX_FRAMES {d} at {s}",
            .{ self.frames_len, types.MAX_FRAMES, site },
        );
    }
    if (self.sp > types.VM_STACK_CAP) {
        std.debug.panic(
            "VM invariant: sp {d} > VM_STACK_CAP {d} at {s}",
            .{ self.sp, types.VM_STACK_CAP, site },
        );
    }
    if (self.frames_len > 0) {
        const current = stack.currentFrame(self);
        if (current.frame_base > self.sp) {
            std.debug.panic(
                "VM invariant: frame_base {d} > sp {d} at {s}",
                .{ current.frame_base, self.sp, site },
            );
        }
    }
}

pub inline fn assertOrPanic(cond: bool, comptime fmt: []const u8, args: anytype) void {
    if (comptime !enabled) return;
    if (!cond) std.debug.panic(fmt, args);
}
