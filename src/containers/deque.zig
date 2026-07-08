//! Lock-free Chase-Lev work-stealing deques (fixed `Deque` + growable
//! `GrowableDeque`). Single-owner LIFO push/pop, multi-consumer FIFO steal;
//! the `top`/`bottom` counters, seq_cst last-element CAS, and x86_64
//! `mfence`s are load-bearing. The `top`/`bottom` counters are wrapped in
//! the `Isolated` cache-line pad (see `cache_line.zig`).

const std = @import("std");

const Isolated = @import("cache_line.zig").Isolated;

/// Shared Chase-Lev work-stealing deque protocol, comptime-specialized over
/// payload `T` and `growable`.
///
/// Both the fixed `Deque(T)` and the growable `GrowableDeque(T)` are thin
/// public aliases over this private implementation — the entire owner-only
/// push/pop (LIFO) / multi-consumer FIFO steal protocol (the `top`/`bottom`
/// counters, the `mfence`s, the seq_cst last-element CAS races) is written
/// here EXACTLY ONCE. The two flavors differ in exactly one respect: what
/// happens when `push` finds the deque full.
///
///   - `growable == false` (`Deque(T)`): fixed power-of-two capacity backed
///     by a plain `items: []T` slice + `mask`. Full push returns `false` and
///     the caller drops the item (speculation is best-effort). This is the
///     scheduler's `TaskQueue` — `Deque(Task)` must compile to the same
///     thing it does today, since `growable = false` makes every
///     growable-only branch below comptime-dead. The scheduler also reaches
///     into `items`/`mask`/`top`/`bottom` directly (see
///     `taskQueueGcMark`), so those fields keep their names and plain types
///     for the fixed instantiation.
///
///   - `growable == true` (`GrowableDeque(T)`): backed by an atomically
///     swapped pointer to a `Buffer { items, mask }`. On full, `push` GROWS
///     the buffer to 2x capacity instead of dropping — required by the GC
///     parallel marker, whose worklist must never drop an element (a
///     dropped mark is a swept live object / use-after-free). Superseded
///     buffers are retained until `deinit` (retain-until-deinit
///     reclamation — STW parallel mark has a bounded lifetime, so no
///     epoch/hazard-pointer scheme is needed). See `steal` below for the
///     grow-during-steal safety argument.
///
/// Memory ordering (identical for both flavors, and load-bearing — extracted
/// verbatim from the scheduler's original TaskQueue):
///   - `bottom` writes use release; reads in stealers use acquire.
///   - `top` writes use seq_cst (CAS) so the owner's `pop` race for the last
///     element synchronizes with concurrent steals.
///   - The `mfence` in `pop` (after writing `bottom`) and in `steal` (after
///     loading `top`) prevents reordering across the fence on x86_64 in a
///     way plain `Value` orderings alone don't give us here. x86_64-only —
///     fix's fiber primitive already comptime-asserts the target. `@fence`
///     is gone in Zig 0.16; std.atomic doesn't expose a fence helper.
fn DequeImpl(comptime T: type, comptime growable: bool) type {
    return struct {
        const Self = @This();

        /// One generation of the growable circular backing store.
        /// `mask == capacity - 1` (capacity a power of two); indexing is
        /// always `i & mask`. Unused (zero-sized) when `!growable`.
        const Buffer = struct {
            items: []T,
            mask: u64,

            fn create(allocator: std.mem.Allocator, capacity: u32) !*Buffer {
                std.debug.assert(std.math.isPowerOfTwo(capacity));
                const buf = try allocator.create(Buffer);
                errdefer allocator.destroy(buf);
                const items = try allocator.alloc(T, capacity);
                @memset(items, undefined);
                buf.* = .{ .items = items, .mask = @as(u64, capacity) - 1 };
                return buf;
            }

            fn destroy(self: *Buffer, allocator: std.mem.Allocator) void {
                allocator.free(self.items);
                allocator.destroy(self);
            }
        };

        // Backing-store representation: the ONLY structural fork between
        // the two flavors. Fixed keeps the plain `items`/`mask` fields the
        // scheduler already reaches into directly; growable swaps in an
        // atomically-swapped buffer pointer + a retired-buffers list.
        items: if (!growable) []T else void = if (!growable) undefined else {},
        mask: if (!growable) u64 else void = if (!growable) undefined else {},
        /// Atomically-swapped current backing buffer (growable only).
        /// Owner publishes new generations with `.release`; stealers load
        /// with `.acquire`.
        array: if (growable) std.atomic.Value(*Buffer) else void = if (growable) undefined else {},
        /// Superseded buffers, retained until `deinit` (growable only).
        /// Owner-only (mutated only inside `push`'s grow path, which never
        /// runs concurrently with itself).
        retired: if (growable) std.ArrayListUnmanaged(*Buffer) else void = if (growable) .empty else {},

        /// Owner-only writes (push/pop). Stealers read with acquire.
        ///
        /// `bottom` and `top` each own a full destructive-interference
        /// block (`Isolated`). Un-isolated they sat 8 bytes apart: every
        /// stealer's CAS on `top` (or even its failed empty-probe load)
        /// invalidated the owner's line under `bottom`, and with 40B
        /// deques packed contiguously, ADJACENT WORKERS' deques also
        /// shared lines. Idle workers rescan every peer's deque
        /// top+bottom per drain step, so at w=16 these probes were the
        /// top source of cross-CCX cache fills (24% of
        /// ls_dmnd_fills_from_sys.ext_cache_local landed in drainStep).
        /// The buffer fields (`items`/`mask`/`array`) stay on their own
        /// read-mostly block, shared harmlessly in S-state.
        bottom: Isolated(u64),
        /// CAS by stealers (and the owner's last-element pop).
        top: Isolated(u64),

        comptime {
            // Adjacent array elements (per-worker queues) must not share
            // a block either.
            std.debug.assert(@sizeOf(Self) % std.atomic.cache_line == 0);
        }

        pub fn init(allocator: std.mem.Allocator, capacity: u32) !Self {
            if (growable) {
                const buf = try Buffer.create(allocator, capacity);
                return .{ .array = .init(buf), .bottom = .init(0), .top = .init(0) };
            } else {
                std.debug.assert(std.math.isPowerOfTwo(capacity));
                const items = try allocator.alloc(T, capacity);
                @memset(items, undefined);
                return .{ .items = items, .mask = @as(u64, capacity) - 1, .bottom = .init(0), .top = .init(0) };
            }
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (growable) {
                // Free every retired buffer, then the current one.
                for (self.retired.items) |buf| buf.destroy(allocator);
                self.retired.deinit(allocator);
                self.array.load(.monotonic).destroy(allocator);
            } else {
                allocator.free(self.items);
            }
        }

        /// Resolves the current mask, reading whichever representation this
        /// flavor uses. `ord` is the ordering for the growable buffer-
        /// pointer load; unused (and comptime-dead) when `!growable`.
        inline fn currentMask(self: *const Self, comptime ord: std.builtin.AtomicOrder) u64 {
            return if (growable) self.array.load(ord).mask else self.mask;
        }

        /// Resolves slot `i` for reading/writing, in whichever backing
        /// buffer this flavor uses. `ord` is the ordering for the growable
        /// buffer-pointer load; unused (and comptime-dead) when
        /// `!growable`.
        inline fn bufferSlot(self: *Self, i: u64, comptime ord: std.builtin.AtomicOrder) *T {
            if (growable) {
                const buf = self.array.load(ord);
                return &buf.items[@intCast(i & buf.mask)];
            } else {
                return &self.items[@intCast(i & self.mask)];
            }
        }

        /// Allocate a 2x buffer, copy `[top, bottom)` preserving each
        /// element at `i & mask`, publish it, and retire the old one.
        /// Owner-only. Growable-only — never called when `!growable`.
        fn grow(self: *Self, allocator: std.mem.Allocator, old: *Buffer, t: u64, b: u64) !*Buffer {
            comptime std.debug.assert(growable);
            const new_capacity = std.math.mul(u32, @intCast(old.items.len), 2) catch return error.OutOfMemory;
            const new = try Buffer.create(allocator, new_capacity);
            errdefer new.destroy(allocator);
            // Copy each live element to the SAME logical index in the new buffer.
            // A stealer reading `old.items[i & old.mask]` and one reading
            // `new.items[i & new.mask]` therefore observe the same value.
            var i = t;
            while (i != b) : (i +%= 1) {
                new.items[@intCast(i & new.mask)] = old.items[@intCast(i & old.mask)];
            }
            // Retain the old buffer (a concurrent stealer may still read it),
            // reserving the slot before publishing so a post-store OOM can't
            // strand the old pointer.
            try self.retired.append(allocator, old);
            errdefer _ = self.retired.pop();
            // Publish: the copied slots must be visible before stealers can load
            // the new pointer.
            self.array.store(new, .release);
            return new;
        }

        // `push` is the ONE place the two flavors' public signature itself
        // differs (fixed: no allocator, returns `bool`; growable: threads
        // an allocator, returns `!void`, and never drops) — Zig has no way
        // to comptime-branch a single declaration's parameter list/return
        // type while keeping both call shapes source-compatible, so it's
        // two small private bodies aliased to the one public `push` name
        // below. Each mirrors the shared protocol exactly (load `b`/`t`,
        // check full, write the slot, release-store `bottom`); the only
        // real difference between them is the full-branch behavior (return
        // false vs. grow-then-write), per the shared protocol doc comment
        // on `DequeImpl`.

        /// Fixed-capacity push body. Owner-only. Returns `false` on full
        /// (caller drops the item — speculation is best-effort).
        fn pushFixed(self: *Self, item: T) bool {
            comptime std.debug.assert(!growable);
            const b = self.bottom.v.load(.monotonic);
            const t = self.top.v.load(.acquire);
            if (b -% t > self.mask) return false; // full
            self.items[@intCast(b & self.mask)] = item;
            // Release: the slot write must be visible before stealers
            // see the updated bottom.
            self.bottom.v.store(b + 1, .release);
            return true;
        }

        /// Growable push body. Owner-only. Grows to 2x capacity on full
        /// instead of dropping, so it always succeeds (returns
        /// `error.OutOfMemory` only if a grow's allocation fails).
        fn pushGrowable(self: *Self, allocator: std.mem.Allocator, item: T) !void {
            comptime std.debug.assert(growable);
            const b = self.bottom.v.load(.monotonic);
            const t = self.top.v.load(.acquire);
            var buf = self.array.load(.monotonic);
            if (b -% t > buf.mask) {
                // Full — grow to 2x and copy live elements at their logical index.
                buf = try self.grow(allocator, buf, t, b);
            }
            buf.items[@intCast(b & buf.mask)] = item;
            // Release: the slot write must be visible before stealers see the
            // updated bottom.
            self.bottom.v.store(b + 1, .release);
        }

        /// Owner-only. Fixed: `push(item) bool`. Growable: `push(allocator,
        /// item) !void`. See the comment above `pushFixed`/`pushGrowable`
        /// for why this is a conditional alias rather than one function.
        pub const push = if (growable) pushGrowable else pushFixed;

        /// Owner-only LIFO pop.
        pub fn pop(self: *Self) ?T {
            const b = self.bottom.v.load(.monotonic) -% 1;
            self.bottom.v.store(b, .monotonic);
            // seq_cst fence: prevents reordering of the bottom write
            // above with the top load below. Without it, the owner
            // could observe a stale `top` and dequeue a slot a stealer
            // is concurrently taking.
            asm volatile ("mfence" ::: .{ .memory = true });
            const t = self.top.v.load(.monotonic);
            if (@as(i64, @bitCast(b -% t)) < 0) {
                // Empty — restore bottom.
                self.bottom.v.store(t, .monotonic);
                return null;
            }
            const item = self.bufferSlot(b, .monotonic).*;
            if (b != t) return item; // not the last element, no race
            // Last element: race a concurrent steal for it.
            if (self.top.v.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) != null) {
                // Lost the race — stealer took it. Restore bottom.
                self.bottom.v.store(t + 1, .monotonic);
                return null;
            }
            self.bottom.v.store(t + 1, .monotonic);
            return item;
        }

        /// Multi-consumer FIFO steal.
        ///
        /// Grow-during-steal safety (growable only): this may load an OLD
        /// `array` pointer (the owner concurrently published a new one).
        /// That is safe because (1) old buffers are retained until
        /// `deinit`, so the read hits valid memory, and (2) `grow` copied
        /// every element to the same logical index, so
        /// `old.items[t & old.mask]` and `new.items[t & new.mask]` hold the
        /// SAME value. The seq_cst CAS on `top` is what serializes who
        /// takes index `t`; the value is returned only if the CAS wins.
        /// Thus a stale `array` read never yields a wrong or double-taken
        /// element.
        pub fn steal(self: *Self) ?T {
            const t = self.top.v.load(.acquire);
            // Acquire-acquire fence: see `bottom` after `top`. Without
            // this we could observe a `bottom` from before `top` was
            // bumped by another stealer, leading to phantom reads of
            // already-claimed slots.
            asm volatile ("mfence" ::: .{ .memory = true });
            const b = self.bottom.v.load(.acquire);
            if (@as(i64, @bitCast(b -% t)) <= 0) return null;
            // Acquire (growable only): pair with the owner's release store
            // in `grow` so the copied slots are visible before we index
            // into a freshly-published buffer.
            const item = self.bufferSlot(t, .acquire).*;
            if (self.top.v.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) != null) {
                return null; // lost the race
            }
            return item;
        }

        /// Reset to empty, retaining the (possibly grown) backing buffer.
        /// NOT thread-safe — call only when no stealer can be running (e.g. a
        /// GC marker roster reused across stop-the-world collections).
        pub fn clear(self: *Self) void {
            self.bottom.v.store(0, .monotonic);
            self.top.v.store(0, .monotonic);
        }

        pub fn approxLen(self: *const Self) u64 {
            const b = self.bottom.v.load(.monotonic);
            const t = self.top.v.load(.monotonic);
            const cap = self.currentMask(.monotonic) + 1;
            // NOTE: the bound test intentionally differs between flavors,
            // matching each one's pre-collapse behavior exactly — fixed
            // used `<`, growable used `<=`. `growable` is a comptime bool
            // so only one arm survives per instantiation.
            const len = b -% t;
            return if (growable) (if (len > 0 and len <= cap) len else 0) else (if (len > 0 and len < cap) len else 0);
        }
    };
}

/// Lock-free Chase-Lev work-stealing deque, generic over payload `T`.
/// Owner-only push/pop (LIFO); multi-consumer FIFO steal. Orderings and the
/// `mfence` are load-bearing — extracted verbatim from the scheduler's
/// TaskQueue. Fixed power-of-two capacity; full push returns false.
pub fn Deque(comptime T: type) type {
    return DequeImpl(T, false);
}

/// Lock-free **growable** Chase-Lev work-stealing deque (Chase & Lev 2005,
/// "Dynamic Circular Work-Stealing Deque"), generic over payload `T`.
///
/// Same owner-only push/pop (LIFO) / multi-consumer FIFO steal protocol as
/// the fixed `Deque(T)` above (both are generated from the same
/// `DequeImpl`) — same `bottom`/`top` `u64` wraparound counters, the same
/// `mfence` in `pop`/`steal`, the same acquire/release/seq_cst orderings.
/// The ONE difference: instead of dropping on full, `push` GROWS the
/// backing buffer to 2x capacity. This is required by the GC parallel
/// marker, whose worklist must NEVER drop an element — a dropped mark is a
/// swept live object (use-after-free).
pub fn GrowableDeque(comptime T: type) type {
    return DequeImpl(T, true);
}

test "Deque push/pop/steal work for a single owner" {
    var q = try Deque(u64).init(std.testing.allocator, 4);
    defer q.deinit(std.testing.allocator);

    try std.testing.expect(q.push(7));
    try std.testing.expect(q.push(13));

    // LIFO from owner.
    const popped = q.pop().?;
    try std.testing.expectEqual(@as(u64, 13), popped);

    // Steal sees the older one.
    const stolen = q.steal().?;
    try std.testing.expectEqual(@as(u64, 7), stolen);

    try std.testing.expectEqual(@as(?u64, null), q.pop());
}

test "GrowableDeque single-thread grow: push past capacity then LIFO drain" {
    const allocator = std.testing.allocator;
    const initial_capacity: u32 = 4;
    var q = try GrowableDeque(u64).init(allocator, initial_capacity);
    defer q.deinit(allocator);

    // Push 10× the initial capacity — forces several grows (4 -> 8 -> 16 -> ...).
    const n: u64 = 10 * initial_capacity;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        try q.push(allocator, i);
    }

    // Owner drains LIFO: values come back n-1, n-2, ..., 0.
    var expected: u64 = n;
    while (expected > 0) {
        expected -= 1;
        const got = q.pop() orelse return error.UnexpectedEmpty;
        try std.testing.expectEqual(expected, got);
    }
    // Empty after the exact count.
    try std.testing.expectEqual(@as(?u64, null), q.pop());
}

test "GrowableDeque multi-thread grow-during-steal: no loss, no duplication" {
    const allocator = std.testing.allocator;
    const n: u64 = 200_000; // large enough to force many grows from cap 4
    const num_stealers = 4;
    const iterations = 50; // repeat so a rare race surfaces

    const Worker = struct {
        // A stealer: drains via FIFO steal until it observes `done` set AND the
        // deque is empty. Collects every stolen value into its own list (no
        // shared mutation).
        fn stealLoop(
            q: *GrowableDeque(u64),
            done: *std.atomic.Value(bool),
            out: *std.ArrayListUnmanaged(u64),
            out_alloc: std.mem.Allocator,
        ) void {
            while (true) {
                if (q.steal()) |v| {
                    out.append(out_alloc, v) catch @panic("OOM in stealer");
                } else if (done.load(.acquire)) {
                    // Owner finished pushing. One more sweep to be sure nothing
                    // was left between our failed steal and the `done` load.
                    if (q.steal()) |v| {
                        out.append(out_alloc, v) catch @panic("OOM in stealer");
                    } else {
                        break;
                    }
                }
            }
        }
    };

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        var q = try GrowableDeque(u64).init(allocator, 4);
        defer q.deinit(allocator);

        var done = std.atomic.Value(bool).init(false);

        // Per-thread output lists — owner's plus one per stealer. No list is
        // touched by more than one thread until after join.
        var owner_out: std.ArrayListUnmanaged(u64) = .empty;
        defer owner_out.deinit(allocator);
        var stealer_out: [num_stealers]std.ArrayListUnmanaged(u64) = undefined;
        for (&stealer_out) |*s| s.* = .empty;
        defer for (&stealer_out) |*s| s.deinit(allocator);

        var threads: [num_stealers]std.Thread = undefined;
        for (&threads, 0..) |*th, k| {
            th.* = try std.Thread.spawn(.{}, Worker.stealLoop, .{
                &q, &done, &stealer_out[k], allocator,
            });
        }

        // Owner: push distinct values 1..=n (values are unique so we can detect
        // loss/duplication), interleaving pops of what it can grab back.
        var v: u64 = 1;
        while (v <= n) : (v += 1) {
            try q.push(allocator, v);
            // Occasionally pop back the most-recent element the owner still owns.
            if (v % 3 == 0) {
                if (q.pop()) |popped| try owner_out.append(allocator, popped);
            }
        }
        // Owner drains whatever remains that stealers haven't taken.
        while (q.pop()) |popped| try owner_out.append(allocator, popped);

        // Signal completion; stealers will finish their final sweeps and exit.
        done.store(true, .release);
        for (&threads) |th| th.join();

        // Verify: the union of all returned values is EXACTLY {1..n} — every
        // value exactly once (no loss, no duplication). Done single-threaded
        // after join, so `seen` needs no synchronization.
        const seen = try allocator.alloc(bool, n + 1);
        defer allocator.free(seen);
        @memset(seen, false);

        var total: u64 = 0;
        const check = struct {
            fn one(seen_: []bool, total_: *u64, val: u64) !void {
                try std.testing.expect(val >= 1 and val <= n);
                // No duplication: a value must not have been returned before.
                try std.testing.expect(!seen_[@intCast(val)]);
                seen_[@intCast(val)] = true;
                total_.* += 1;
            }
        }.one;

        for (owner_out.items) |val| try check(seen, &total, val);
        for (&stealer_out) |*s| {
            for (s.items) |val| try check(seen, &total, val);
        }

        // No loss: exactly n distinct values returned, and every 1..=n is set.
        try std.testing.expectEqual(n, total);
        for (seen[1 .. n + 1]) |bit| try std.testing.expect(bit);
    }
}
