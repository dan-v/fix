//! `containers` module facade — generic data structures shared across
//! subsystems that otherwise cannot import each other.
//!
//! Sits at the bottom of the module dependency graph (depends only on
//! `std`) so both `runtime` and `parallel` can import it without creating
//! a cycle: the GC Tracer (in `runtime`) and the scheduler (in `parallel`)
//! both need the same lock-free work-stealing `Deque`. The GC parallel
//! marker additionally needs the never-drop `GrowableDeque` for its
//! worklist (a dropped element is a swept live object).

pub const deque = @import("containers/deque.zig");

pub const Deque = deque.Deque;
pub const GrowableDeque = deque.GrowableDeque;
pub const Isolated = deque.Isolated;

test {
    _ = deque;
}
