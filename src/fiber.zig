//! Stackful fiber primitive — the foundation for suspendable thunk evaluation.
//!
//! A fiber is a chunk of computation running on its own stack. The fiber's
//! owner (typically a worker thread) calls `resume_` to switch onto the
//! fiber's stack and run its entry function. The fiber can call `yield`
//! to switch back to whoever resumed it, suspending its state for later
//! resumption.
//!
//! Stack switching is done via a small naked assembly routine
//! (`fix_swap_context`, see src/fiber/swap_x86_64.S) that saves the
//! callee-saved register set + rsp into a `Context` and loads a new one.
//! Caller-saved registers are clobbered on swap — Zig's calling convention
//! lets the compiler handle that around the swap call site.
//!
//! Fibers are pinned to whichever thread first resumed them: a fiber's
//! Context captures a stack pointer into thread-local memory (the stack
//! buffer's own page is fine to share, but the Zig-side `caller_ctx` is
//! valid only while the original resumer's stack frame is live).
//!
//! Lifecycle:
//!   .ready    — initialized, never resumed. `entry` will run on first resume.
//!   .running  — currently executing on its owner's thread.
//!   .suspended — yielded; `ctx` holds the saved state. Resumable.
//!   .finished — `entry` returned. Not resumable.
//!
//! The owner is responsible for not resuming a `.finished` or `.running`
//! fiber. Asserts guard this in debug builds.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .x86_64) {
        @compileError("fiber.zig currently only supports x86_64");
    }
}

/// Callee-saved register set + saved stack pointer.
/// Layout must match src/fiber/swap_x86_64.S exactly.
pub const Context = extern struct {
    rbx: u64 = 0,
    rbp: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rsp: u64 = 0,
};

/// Implemented in src/fiber/swap_x86_64.S.
extern fn fix_swap_context(from: *Context, to: *Context) callconv(.c) void;

pub const State = enum(u8) {
    ready,
    running,
    suspended,
    finished,
};

pub const EntryFn = *const fn (arg: *anyopaque) void;

/// Threadlocal "currently running fiber on this OS thread", or null if
/// the bare OS thread is executing (not inside any fiber's stack).
///
/// Set by `resume_` before swapping in; restored to the previous value
/// when control returns. The trampoline reads this to find its own
/// fiber pointer at entry, since naked stack switching can't pass args
/// through the standard ABI.
threadlocal var current: ?*Fiber = null;

pub fn currentFiber() ?*Fiber {
    return current;
}

pub const Fiber = struct {
    ctx: Context,
    /// Owned heap-allocated stack buffer.
    stack: []u8,
    state: State,
    /// User-supplied entry function and argument. Cleared once `entry`
    /// returns so a finished fiber doesn't hold a dangling capture.
    entry: ?EntryFn,
    entry_arg: ?*anyopaque,
    /// Where to switch back to on yield/finish. Valid only while
    /// `state == .running`. Pointer into the resumer's stack — must
    /// not outlive the `resume_` call.
    caller_ctx: ?*Context,

    /// Default fiber stack size. The watermark probe on a representative
    /// NixOS toplevel evaluation tops out at ~1.7 MiB; we round up to
    /// 3 MiB so we have nearly 2× headroom for evaluations with deeper
    /// import chains or builtins. If profiling later shows a workload
    /// pushing past this, bump the constant (or expose a runtime knob
    /// — `Fiber.init` already takes `stack_bytes` as a parameter).
    pub const min_stack_bytes: usize = 3 * 1024 * 1024;

    /// Sentinel byte pattern written to a freshly-allocated stack so
    /// `maxStackUsedBytes` can find the deepest byte the fiber ever
    /// touched. 0xAA chosen because it's distinctive in hex dumps and
    /// doesn't match common ASCII or zero-initialised data.
    pub const stack_sentinel: u8 = 0xAA;

    /// Scan the stack for the first non-sentinel byte starting from the
    /// low (deep) end. Returns the number of bytes between that byte and
    /// the high (top) end — the high-water mark across every task the
    /// fiber has run on this stack. Use this to size production
    /// stacks: pick a value comfortably above the max observed across a
    /// representative workload.
    pub fn maxStackUsedBytes(self: *const Fiber) usize {
        for (self.stack, 0..) |b, i| {
            if (b != stack_sentinel) return self.stack.len - i;
        }
        return 0;
    }

    /// Allocate a fiber with its own stack and prepare it to invoke
    /// `entry(arg)` on first resume.
    ///
    /// The fiber owns the stack allocation; `deinit` frees it.
    pub fn init(allocator: std.mem.Allocator, stack_bytes: usize, entry: EntryFn, arg: *anyopaque) !Fiber {
        const stack = try allocator.alignedAlloc(u8, .@"16", stack_bytes);
        errdefer allocator.free(stack);
        // Sentinel-fill the stack so `maxStackUsedBytes` can find the
        // deepest byte the fiber ever touched. The probe is cheap to
        // read once per worker shutdown; the one-time memset cost is
        // amortised across every task the fiber ever runs.
        @memset(stack, stack_sentinel);

        var fiber: Fiber = .{
            .ctx = .{},
            .stack = stack,
            .state = .ready,
            .entry = entry,
            .entry_arg = arg,
            .caller_ctx = null,
        };

        // Set up the new stack so the first `ret` inside `fix_swap_context`
        // jumps into `trampoline`. We reserve the topmost 16-byte aligned
        // slot for the return address; trampoline will see rsp pointing
        // just past it (i.e. 16-byte aligned on function entry — matches
        // the ABI convention where the caller pushed the return address).
        const top = @intFromPtr(stack.ptr) + stack.len;
        // sp_start must satisfy (sp_start) % 16 == 0 so that AFTER `ret`
        // pops the return address, the trampoline sees rsp ≡ 8 (mod 16),
        // which is what SysV expects at function entry. Round down.
        const sp_start = (top - 8) & ~@as(usize, 15);
        const trampoline_addr_slot: *usize = @ptrFromInt(sp_start);
        trampoline_addr_slot.* = @intFromPtr(&trampoline);
        fiber.ctx.rsp = sp_start;

        return fiber;
    }

    pub fn deinit(self: *Fiber, allocator: std.mem.Allocator) void {
        // A live fiber whose stack is freed will crash on resume; the
        // caller must arrange shutdown semantics.
        allocator.free(self.stack);
        self.* = undefined;
    }

    /// Rewind the fiber so the next `resume_` starts a fresh invocation
    /// of `entry(arg)` on the same stack buffer. Used by Worker to
    /// recycle a `.finished` fiber for a new task without allocating a
    /// new stack.
    ///
    /// Must NOT be called on a fiber in `.running` or `.suspended` —
    /// that would leak the fiber's call frames and break any waiters
    /// enrolled on thunks via its slot.
    pub fn reset(self: *Fiber, entry: EntryFn, arg: *anyopaque) void {
        std.debug.assert(self.state == .finished or self.state == .ready);
        const top = @intFromPtr(self.stack.ptr) + self.stack.len;
        const sp_start = (top - 8) & ~@as(usize, 15);
        const trampoline_addr_slot: *usize = @ptrFromInt(sp_start);
        trampoline_addr_slot.* = @intFromPtr(&trampoline);
        self.ctx = .{ .rsp = sp_start };
        self.entry = entry;
        self.entry_arg = arg;
        self.caller_ctx = null;
        self.state = .ready;
    }

    /// Switch onto this fiber's stack and run until it yields or finishes.
    /// Returns when the fiber yields or returns from `entry`.
    pub fn resume_(self: *Fiber) void {
        std.debug.assert(self.state == .ready or self.state == .suspended);
        var here: Context = .{};
        const prev = current;
        current = self;
        self.caller_ctx = &here;
        self.state = .running;
        fix_swap_context(&here, &self.ctx);
        // Back from the swap: the fiber either yielded (state == .suspended)
        // or completed (state == .finished). Either way, current resumer
        // is no longer in the picture.
        self.caller_ctx = null;
        current = prev;
    }

    /// Yield from the *currently running* fiber back to whoever resumed it.
    /// Call only from inside a fiber's `entry` (directly or transitively).
    pub fn yield() void {
        const self = current orelse @panic("Fiber.yield called outside a fiber");
        const back = self.caller_ctx orelse @panic("running fiber has no caller_ctx");
        self.state = .suspended;
        fix_swap_context(&self.ctx, back);
        // Resumed: caller_ctx has been set to the new resumer.
        self.state = .running;
    }
};

/// Entry point that the new fiber's stack is bootstrapped to. The first
/// `fix_swap_context` "returns" into here on the fiber's own stack. We
/// pull the fiber pointer from the threadlocal `current` (set by
/// `resume_` before the swap), invoke the user entry, and then swap
/// back permanently — `entry` returning means the fiber is done.
fn trampoline() callconv(.c) void {
    const self = current orelse @panic("trampoline started with no current fiber");
    const arg = self.entry_arg orelse unreachable;
    const entry = self.entry orelse unreachable;
    entry(arg);
    self.state = .finished;
    // Hold onto the back-ctx pointer before we (effectively) leave the
    // fiber. After `fix_swap_context` we never resume — caller_ctx may be
    // gone by the time anyone else might read it.
    const back = self.caller_ctx orelse @panic("finished fiber has no caller_ctx");
    self.entry = null;
    self.entry_arg = null;
    fix_swap_context(&self.ctx, back);
    // Should never get here — resuming a `.finished` fiber would re-run
    // the swap, which would land on whatever junk is below this point.
    @panic("trampoline reached unreachable after finish swap");
}

// ---- tests ----

const testing = std.testing;

test "fiber basic spawn / resume / finish" {
    const Ctx = struct {
        ran: bool = false,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.ran = true;
        }
    };
    var ctx: Ctx = .{};
    var fiber = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, Ctx.entry, &ctx);
    defer fiber.deinit(testing.allocator);

    try testing.expectEqual(State.ready, fiber.state);
    fiber.resume_();
    try testing.expect(ctx.ran);
    try testing.expectEqual(State.finished, fiber.state);
}

test "fiber yields and resumes mid-execution" {
    const Ctx = struct {
        steps: u32 = 0,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.steps = 1;
            Fiber.yield();
            ctx.steps = 2;
            Fiber.yield();
            ctx.steps = 3;
        }
    };
    var ctx: Ctx = .{};
    var fiber = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, Ctx.entry, &ctx);
    defer fiber.deinit(testing.allocator);

    fiber.resume_();
    try testing.expectEqual(@as(u32, 1), ctx.steps);
    try testing.expectEqual(State.suspended, fiber.state);

    fiber.resume_();
    try testing.expectEqual(@as(u32, 2), ctx.steps);
    try testing.expectEqual(State.suspended, fiber.state);

    fiber.resume_();
    try testing.expectEqual(@as(u32, 3), ctx.steps);
    try testing.expectEqual(State.finished, fiber.state);
}

test "fiber threadlocal `current` is set during run, cleared after" {
    const Ctx = struct {
        saw_self: ?*Fiber = null,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.saw_self = current;
        }
    };
    var ctx: Ctx = .{};
    var fiber = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, Ctx.entry, &ctx);
    defer fiber.deinit(testing.allocator);

    try testing.expect(current == null);
    fiber.resume_();
    try testing.expectEqual(@as(?*Fiber, &fiber), ctx.saw_self);
    try testing.expect(current == null);
}

test "two fibers multiplex on one thread" {
    // A simple ping-pong: each fiber writes its tag, yields, comes back.
    // We resume them alternately from the outer scope.
    const Ctx = struct {
        log: std.ArrayListUnmanaged(u8) = .empty,
        tag: u8 = 0,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            // Append three tag bytes interleaved with yields.
            var i: u8 = 0;
            while (i < 3) : (i += 1) {
                ctx.log.append(testing.allocator, ctx.tag) catch unreachable;
                Fiber.yield();
            }
        }
    };
    var ctx_a: Ctx = .{ .tag = 'A' };
    var ctx_b: Ctx = .{ .tag = 'B' };
    defer ctx_a.log.deinit(testing.allocator);
    defer ctx_b.log.deinit(testing.allocator);

    var fa = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, Ctx.entry, &ctx_a);
    var fb = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, Ctx.entry, &ctx_b);
    defer fa.deinit(testing.allocator);
    defer fb.deinit(testing.allocator);

    // Drive each fiber to completion. The entry body appends then
    // yields, so we need 4 resumes per fiber: three to append+yield
    // (states 'A', 'A', 'A' plus a trailing yield), and a fourth to
    // resume past the yield, fall out of the loop, and let entry return.
    var step: u32 = 0;
    while (step < 4) : (step += 1) {
        fa.resume_();
        fb.resume_();
    }

    try testing.expectEqualSlices(u8, "AAA", ctx_a.log.items);
    try testing.expectEqualSlices(u8, "BBB", ctx_b.log.items);
    try testing.expectEqual(State.finished, fa.state);
    try testing.expectEqual(State.finished, fb.state);
}

test "nested fiber call" {
    // An outer fiber resumes an inner fiber, which yields, then is resumed
    // by the outer fiber again. Validates that `current` is restored correctly
    // when control returns to an outer fiber after running an inner one.
    const InnerCtx = struct {
        ran_before_yield: bool = false,
        ran_after_yield: bool = false,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.ran_before_yield = true;
            Fiber.yield();
            ctx.ran_after_yield = true;
        }
    };
    const OuterCtx = struct {
        inner_fiber: *Fiber,
        observed_inner_current_before_resume: ?*Fiber = null,
        observed_self_current_between_resumes: ?*Fiber = null,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.observed_inner_current_before_resume = current;
            ctx.inner_fiber.resume_();
            // Now we're back in outer fiber. `current` must point at the
            // outer fiber itself, NOT at the inner one we just resumed.
            ctx.observed_self_current_between_resumes = current;
            ctx.inner_fiber.resume_();
        }
    };

    var inner_ctx: InnerCtx = .{};
    var inner = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, InnerCtx.entry, &inner_ctx);
    defer inner.deinit(testing.allocator);

    var outer_ctx: OuterCtx = .{ .inner_fiber = &inner };
    var outer = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, OuterCtx.entry, &outer_ctx);
    defer outer.deinit(testing.allocator);

    outer.resume_();

    try testing.expect(inner_ctx.ran_before_yield);
    try testing.expect(inner_ctx.ran_after_yield);
    try testing.expectEqual(@as(?*Fiber, &outer), outer_ctx.observed_inner_current_before_resume);
    try testing.expectEqual(@as(?*Fiber, &outer), outer_ctx.observed_self_current_between_resumes);
    try testing.expectEqual(State.finished, inner.state);
    try testing.expectEqual(State.finished, outer.state);
}
