//! `-Dthunk-census`: size the statically-eliminable thunk set — the decisive
//! measurement for the inlining / demand-directed-compilation question (see
//! docs/plans/inlining-demand-compilation.md).
//!
//! At every executed `apply_arg`, bucket the callee shape × whether the
//! argument's body is *trivial* (already object-free via the trivial-body
//! short-circuit in `makeBytecodeThunkFromCaptures`). The apply_arg that
//! allocate a thunk today are exactly `{lazy callee} × {non-trivial arg}`.
//!
//! The go/no-go number is
//!   E = `unary_strict_builtin` callee × non-trivial arg
//! — the forced-thunk count a sound single-arg-strict-*builtin* eager-arg
//! lever (Stage 2) would eliminate. `calleeForcesArg` returns false for every
//! builtin today, so these all thunk now. GO to Stage 2 iff E ≥ 2% of the
//! ~4.44M forced thunks (see the spec-census line in the same run).
//!
//! Comptime-gated: off ⇒ every hook is a no-op the optimizer deletes, so the
//! shipped eval path and emitted bytecode are unchanged (byte-identical .drv).
//! Run at `--workers=1` for an unraced single-thread picture.

const std = @import("std");
const build_options = @import("build_options");

pub const enabled: bool = build_options.thunk_census;

/// Callee shape at the `apply_arg` site (the value at `stack[sp-1]`).
pub const CalleeBucket = enum(u8) {
    /// A concrete `builtins.<f>` value whose `f` is arity-1 and forces its
    /// sole arg to WHNF on every path (the Stage-2 admissible set).
    unary_strict_builtin = 0,
    /// Any other bare builtin value (multi-arg, non-strict, or catch-shaped).
    other_builtin,
    /// A partially-applied builtin (`builtin_closure`).
    builtin_closure,
    /// A user closure whose chunk must-forces its parameter (`strict_param`)
    /// — already takes the eager-arg path via `calleeForcesArg`.
    strict_closure,
    /// Any other user closure (lazy in its parameter).
    other_closure,
    /// Not callable (shouldn't happen for a well-typed apply_arg; counted for
    /// completeness).
    non_callable,
};

const N = @typeInfo(CalleeBucket).@"enum".fields.len;

// counts[bucket][arg_trivial ? 1 : 0]
var counts: [N][2]u64 = [_][2]u64{[2]u64{ 0, 0 }} ** N;

pub inline fn recordApplyArg(bucket: CalleeBucket, arg_trivial: bool) void {
    if (comptime !enabled) return;
    counts[@intFromEnum(bucket)][@intFromBool(arg_trivial)] += 1;
}

fn bucketName(i: usize) []const u8 {
    return switch (@as(CalleeBucket, @enumFromInt(i))) {
        .unary_strict_builtin => "unary_strict_builtin",
        .other_builtin => "other_builtin",
        .builtin_closure => "builtin_closure",
        .strict_closure => "strict_closure (already eager)",
        .other_closure => "other_closure",
        .non_callable => "non_callable",
    };
}

pub fn report() void {
    if (comptime !enabled) return;
    var total: u64 = 0;
    for (counts) |b| total += b[0] + b[1];
    if (total == 0) return;

    std.debug.print("\n=== THUNK CENSUS (-Dthunk-census) — apply_arg callee × arg shape ===\n", .{});
    std.debug.print("  {s:<32} {s:>12} {s:>12} {s:>12}\n", .{ "callee bucket", "arg=trivial", "arg=thunky", "total" });
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const triv = counts[i][1];
        const thnk = counts[i][0];
        const sub = triv + thnk;
        if (sub == 0) continue;
        std.debug.print("  {s:<32} {d:>12} {d:>12} {d:>12}\n", .{ bucketName(i), triv, thnk, sub });
    }
    std.debug.print("  {s:-<72}\n", .{""});
    std.debug.print("  total apply_arg executed: {d}\n", .{total});

    // Thunk-worthy today = lazy-callee (everything except strict_closure) × non-trivial arg.
    var thunky_now: u64 = 0;
    i = 0;
    while (i < N) : (i += 1) {
        if (@as(CalleeBucket, @enumFromInt(i)) == .strict_closure) continue;
        thunky_now += counts[i][0]; // [0] = non-trivial arg
    }
    // E = the Stage-2 eliminable set: unary-strict builtin callee × non-trivial arg.
    const e = counts[@intFromEnum(CalleeBucket.unary_strict_builtin)][0];
    std.debug.print("  apply_arg thunks allocated now (lazy callee × thunky arg): {d}\n", .{thunky_now});
    std.debug.print("  E (Stage-2 eliminable = unary-strict builtin × thunky arg): {d}\n", .{e});
    std.debug.print("  → compare E to the ~4.44M FORCED thunks in the spec-census line: GO to Stage 2 iff E ≥ 2%% (≈88800).\n", .{});
}
