//! `parallel` module facade — the work-stealing scheduler and fiber primitive.
//!
//! `scheduler` distributes evaluation work across worker threads; `fiber` is
//! the stack-switching coroutine they run (its swap routine is the per-arch
//! `fiber/swap_*.S`). Depends on `runtime` and `containers` (the latter for
//! the generic work-stealing `Deque`). Consumers import this module by name
//! and reach submodules through it.

pub const scheduler = @import("parallel/scheduler.zig");
pub const fiber = @import("parallel/fiber.zig");

pub const Scheduler = scheduler.Scheduler;
pub const Fiber = fiber.Fiber;

test {
    _ = scheduler;
    _ = fiber;
}
