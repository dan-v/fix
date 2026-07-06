//! Generic, comptime LALR(1) parser-table generator.
//!
//! Given a context-free grammar in integer form (`GrammarDesc`), this produces
//! flat ACTION/GOTO tables *at compile time*. The runtime driver (see
//! `parser.zig`) is a tight shift/reduce loop over those tables — no per-token
//! function-pointer dispatch, one array lookup per action.
//!
//! Algorithm: the canonical LR(0) automaton plus LALR(1) lookaheads computed by
//! the DeRemer/Pennello-style "spontaneous generation + propagation" method
//! (Aho/Sethi/Ullman, Dragon book §4.7). State count therefore equals the LR(0)
//! state count, keeping comptime work bounded.
//!
//! Symbols are integers:
//!   terminals    : `0 .. num_terminals`            (includes the EOF marker)
//!   nonterminals : `num_terminals .. num_terminals+num_nonterminals`
//!   augmented S' : `num_terminals+num_nonterminals` (added internally)
//!
//! Productions are given without the augmented start rule; `Generate` prepends
//! `S' -> start` as production index 0. The runtime driver switches on the
//! production index to run the matching semantic action, so the *order* of
//! `productions` is part of the grammar's contract.

const std = @import("std");

pub const Assoc = enum { none, left, right, nonassoc };

/// One production, in integer-symbol form. `rhs` holds symbol ids (terminals
/// and nonterminals share the id space described above). `prec`, when set,
/// overrides the production's precedence terminal (yacc `%prec`); otherwise the
/// rightmost terminal in `rhs` supplies precedence.
pub const RawProd = struct {
    lhs: u32,
    rhs: []const u32,
    prec: ?u32 = null,
};

/// Precedence/associativity for a terminal. Higher `level` binds tighter.
pub const RawPrec = struct {
    term: u32,
    level: u16,
    assoc: Assoc,
};

pub const GrammarDesc = struct {
    /// Number of terminals, including the EOF marker.
    num_terminals: u32,
    /// Number of user nonterminals (excludes the augmented start symbol).
    num_nonterminals: u32,
    /// Terminal id of the EOF marker.
    eof: u32,
    /// Nonterminal *index* (0-based, not symbol id) of the start symbol.
    start: u32,
    productions: []const RawProd,
    precedence: []const RawPrec = &.{},
};

/// Packed action cell kinds (stored in the top 4 bits of a `u32`).
pub const ACT_ERROR: u32 = 0;
pub const ACT_SHIFT: u32 = 1;
pub const ACT_REDUCE: u32 = 2;
pub const ACT_ACCEPT: u32 = 3;

pub inline fn cell(kind: u32, arg: u32) u32 {
    return (kind << 28) | (arg & 0x0FFF_FFFF);
}
pub inline fn cellKind(c: u32) u32 {
    return c >> 28;
}
pub inline fn cellArg(c: u32) u32 {
    return c & 0x0FFF_FFFF;
}

const Item = struct {
    prod: u32,
    dot: u32,
};

/// Build the LALR(1) tables for `g`. Returns a type exposing flat comptime
/// arrays the runtime driver indexes with the current state and lookahead.
pub fn Generate(comptime g: GrammarDesc) type {
    @setEvalBranchQuota(200_000_000);
    const built = comptime buildAll(g);
    return struct {
        pub const num_states: u32 = built.num_states;
        pub const num_terminals: u32 = g.num_terminals;
        /// Includes the augmented start nonterminal S'.
        pub const num_nonterminals: u32 = g.num_nonterminals + 1;
        pub const num_productions: u32 = built.num_productions;
        pub const eof: u32 = g.eof;
        pub const start_state: u32 = 0;

        /// `action[state * num_terminals + term]` — a packed cell.
        pub const action: []const u32 = built.action;
        /// `goto_table[state * num_nonterminals + nt]` — target state, or -1.
        pub const goto_table: []const i32 = built.goto_table;
        /// Per-production left-hand-side nonterminal index (0-based).
        pub const prod_lhs: []const u32 = built.prod_lhs;
        /// Per-production right-hand-side length (symbols popped on reduce).
        pub const prod_rhs_len: []const u32 = built.prod_rhs_len;
    };
}

const Built = struct {
    num_states: u32,
    num_productions: u32,
    action: []const u32,
    goto_table: []const i32,
    prod_lhs: []const u32,
    prod_rhs_len: []const u32,
};

fn buildAll(comptime g: GrammarDesc) Built {
    @setEvalBranchQuota(200_000_000);

    const NT = g.num_terminals;
    const NN = g.num_nonterminals;
    const start_sym: u32 = NT + g.start;
    const num_nt_total = NN + 1; // includes S'
    const W = NT + 1; // lookahead-set width: real terminals + the '#' marker
    const HASH = NT; // bit index of the '#' propagation marker

    // Productions with the augmented rule S' -> start prepended at index 0.
    const prods = [_]RawProd{.{ .lhs = NN, .rhs = &[_]u32{start_sym} }} ++ g.productions;
    const P = prods.len;

    // Productions grouped by left-hand-side nonterminal, so closure steps
    // iterate only the relevant rules instead of scanning all P every time.
    const prods_of = blk: {
        var lists = [_][]const u32{&[_]u32{}} ** num_nt_total;
        for (prods, 0..) |p, i| lists[p.lhs] = lists[p.lhs] ++ &[_]u32{@intCast(i)};
        break :blk lists;
    };

    // ---- helpers over the integer symbol space ----
    const H = struct {
        fn isTerm(s: u32) bool {
            return s < NT;
        }
        fn ntIndexOf(s: u32) u32 {
            return s - NT; // s is a nonterminal symbol id
        }
        fn rhsOf(p: u32) []const u32 {
            return prods[p].rhs;
        }
    };

    // ---- FIRST sets and nullability (indexed by nonterminal index 0..NN) ----
    // Computed into consts so the nested closure helpers below can reference
    // them (nested struct methods may read outer consts, not outer vars).
    const fn_sets = blk: {
        var nullable = [_]bool{false} ** num_nt_total;
        var first = [_][NT]bool{[_]bool{false} ** NT} ** num_nt_total;
        var changed = true;
        while (changed) {
            changed = false;
            for (prods) |p| {
                const lhs = p.lhs;
                var all_null = true;
                for (p.rhs) |sym| {
                    if (H.isTerm(sym)) {
                        if (!first[lhs][sym]) {
                            first[lhs][sym] = true;
                            changed = true;
                        }
                        all_null = false;
                        break;
                    } else {
                        const b = H.ntIndexOf(sym);
                        var a: u32 = 0;
                        while (a < NT) : (a += 1) {
                            if (first[b][a] and !first[lhs][a]) {
                                first[lhs][a] = true;
                                changed = true;
                            }
                        }
                        if (!nullable[b]) {
                            all_null = false;
                            break;
                        }
                    }
                }
                if (all_null and !nullable[lhs]) {
                    nullable[lhs] = true;
                    changed = true;
                }
            }
        }
        break :blk .{ .first = first, .nullable = nullable };
    };
    const first = fn_sets.first;
    const nullable = fn_sets.nullable;

    // FIRST of the sequence `seq` followed by lookahead set `la` (width W).
    const FIRST = struct {
        fn seq(comptime_first: *const [num_nt_total][NT]bool, comptime_nullable: *const [num_nt_total]bool, s: []const u32, la: [W]bool) [W]bool {
            var res = [_]bool{false} ** W;
            var all_null = true;
            for (s) |sym| {
                if (sym < NT) {
                    res[sym] = true;
                    all_null = false;
                    break;
                } else {
                    const b = sym - NT;
                    var a: u32 = 0;
                    while (a < NT) : (a += 1) {
                        if (comptime_first[b][a]) res[a] = true;
                    }
                    if (!comptime_nullable[b]) {
                        all_null = false;
                        break;
                    }
                }
            }
            if (all_null) {
                var a: u32 = 0;
                while (a < W) : (a += 1) {
                    if (la[a]) res[a] = true;
                }
            }
            return res;
        }
    };

    // ---- LR(0) closure over a kernel item list ----
    const Clo0 = struct {
        fn run(kernel: []const Item) []const Item {
            // Worklist over a fixed buffer; `seen[p]` tracks whether the closure
            // item (p, 0) is already present (closure only ever adds dot-0
            // items), so both the "already there?" check and the rule lookup are
            // O(1) instead of scanning every item / every production.
            var buf: [2 * P + 64]Item = undefined;
            var n: usize = 0;
            var seen = [_]bool{false} ** P;
            for (kernel) |it| {
                buf[n] = it;
                n += 1;
                if (it.dot == 0) seen[it.prod] = true;
            }
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const it = buf[i];
                const rhs = prods[it.prod].rhs;
                if (it.dot >= rhs.len) continue;
                const sym = rhs[it.dot];
                if (sym < NT) continue; // terminal
                for (prods_of[sym - NT]) |p| {
                    if (!seen[p]) {
                        seen[p] = true;
                        buf[n] = .{ .prod = p, .dot = 0 };
                        n += 1;
                    }
                }
            }
            var out: [n]Item = undefined;
            for (buf[0..n], 0..) |it, k| out[k] = it;
            const frozen = out;
            return &frozen;
        }
    };

    // Sort an item list into canonical (prod, dot) order so equal kernels hash
    // and compare equal regardless of discovery order.
    const sortKernel = struct {
        fn run(list: []const Item) []const Item {
            var arr: [list.len]Item = undefined;
            for (list, 0..) |v, ix| arr[ix] = v;
            var i: usize = 1;
            while (i < arr.len) : (i += 1) {
                var j = i;
                while (j > 0 and less(arr[j], arr[j - 1])) : (j -= 1) {
                    const tmp = arr[j];
                    arr[j] = arr[j - 1];
                    arr[j - 1] = tmp;
                }
            }
            const final = arr;
            return &final;
        }
        fn less(a: Item, b: Item) bool {
            if (a.prod != b.prod) return a.prod < b.prod;
            return a.dot < b.dot;
        }
    }.run;

    const kernelEq = struct {
        fn eq(a: []const Item, b: []const Item) bool {
            if (a.len != b.len) return false;
            for (a, b) |x, y| {
                if (x.prod != y.prod or x.dot != y.dot) return false;
            }
            return true;
        }
        fn hash(k: []const Item) u64 {
            var h: u64 = 1469598103934665603; // FNV-1a
            for (k) |it| {
                h = (h ^ it.prod) *% 1099511628211;
                h = (h ^ it.dot) *% 1099511628211;
            }
            return h;
        }
    };

    // ---- build the canonical LR(0) collection ----
    // Kernels are deduplicated through a hash table (`buckets` maps a kernel's
    // FNV hash to the state indices in that bucket), so finding whether a GOTO
    // target already exists is O(1) average rather than a scan of every state.
    const NB = 8192;
    const NSYM = NT + NN;
    const start_kernel = &[_]Item{.{ .prod = 0, .dot = 0 }};
    var kernels: []const []const Item = &[_][]const Item{start_kernel};
    const Trans = struct { from: u32, sym: u32, to: u32 };
    var trans: []const Trans = &[_]Trans{};
    var buckets = [_][]const u32{&[_]u32{}} ** NB;
    buckets[kernelEq.hash(start_kernel) & (NB - 1)] = &[_]u32{0};

    {
        var s: usize = 0;
        while (s < kernels.len) : (s += 1) {
            const clos = Clo0.run(kernels[s]);
            // One pass over the closure: bucket each advanced item by its next
            // symbol (closure items are distinct, so advanced items are too — no
            // dedup needed). Replaces NSYM full re-scans of the closure.
            var g_items = [_][]const Item{&[_]Item{}} ** NSYM;
            for (clos) |it| {
                const rhs = prods[it.prod].rhs;
                if (it.dot >= rhs.len) continue;
                const sym = rhs[it.dot];
                g_items[sym] = g_items[sym] ++ &[_]Item{.{ .prod = it.prod, .dot = it.dot + 1 }};
            }
            var x: u32 = 0;
            while (x < NSYM) : (x += 1) { // never GOTO on S'
                if (g_items[x].len == 0) continue;
                const gk = sortKernel(g_items[x]);
                const h = kernelEq.hash(gk);
                const b = h & (NB - 1);
                var target: i64 = -1;
                for (buckets[b]) |ki| {
                    if (kernelEq.eq(kernels[ki], gk)) {
                        target = @intCast(ki);
                        break;
                    }
                }
                if (target < 0) {
                    const ni: u32 = @intCast(kernels.len);
                    kernels = kernels ++ &[_][]const Item{gk};
                    buckets[b] = buckets[b] ++ &[_]u32{ni};
                    target = ni;
                }
                trans = trans ++ &[_]Trans{.{ .from = @intCast(s), .sym = x, .to = @intCast(target) }};
            }
        }
    }

    const num_states = kernels.len;

    // Dense transition table (state,sym) -> target state or -1, for O(1) lookup.
    const trans_dense = blk: {
        var td = [_]i32{-1} ** (num_states * NSYM);
        for (trans) |e| td[e.from * NSYM + e.sym] = @intCast(e.to);
        break :blk td;
    };
    const Tr = struct {
        fn find(from: u32, sym: u32) i64 {
            return trans_dense[from * NSYM + sym];
        }
    };

    // ---- global ids for kernel items: offset[s] + j ----
    var offset = [_]u32{0} ** (num_states + 1);
    {
        var s: usize = 0;
        while (s < num_states) : (s += 1) offset[s + 1] = offset[s] + @as(u32, @intCast(kernels[s].len));
    }
    const K = offset[num_states];

    // ---- LR(1)-carrying closure (width-W lookaheads), used for both the
    //      propagation pass and final table construction ----
    const LItem = struct { prod: u32, dot: u32, la: [W]bool };
    const Clo1 = struct {
        // Fills `buf` with the LR(1) closure of `seeds` and returns its length.
        // The caller owns/reuses `buf`, so there is no per-call result copy.
        // `pos[p]` = buffer index of the closure item (p, 0), or -1. Closure only
        // adds dot-0 items, so "find existing" is O(1) and the rule lookup uses
        // the by-LHS index — both were O(P·n) linear scans.
        fn run(seeds: []const LItem, buf: *[2 * P + 64]LItem) usize {
            var n: usize = 0;
            var pos = [_]i32{-1} ** P;
            for (seeds) |it| {
                buf[n] = it;
                if (it.dot == 0) pos[it.prod] = @intCast(n);
                n += 1;
            }
            var changed = true;
            while (changed) {
                changed = false;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const it = buf[i];
                    const rhs = prods[it.prod].rhs;
                    if (it.dot >= rhs.len) continue;
                    const sym = rhs[it.dot];
                    if (sym < NT) continue;
                    const beta = rhs[it.dot + 1 ..];
                    const fs = FIRST.seq(&first, &nullable, beta, it.la);
                    for (prods_of[sym - NT]) |p| {
                        if (pos[p] < 0) {
                            buf[n] = .{ .prod = p, .dot = 0, .la = fs };
                            pos[p] = @intCast(n);
                            n += 1;
                            changed = true;
                        } else {
                            const qi: usize = @intCast(pos[p]);
                            var a: u32 = 0;
                            while (a < W) : (a += 1) {
                                if (fs[a] and !buf[qi].la[a]) {
                                    buf[qi].la[a] = true;
                                    changed = true;
                                }
                            }
                        }
                    }
                }
            }
            return n;
        }
    };

    // index of kernel item (prod,dot) within a state's kernel
    const kidx = struct {
        fn find(kernel: []const Item, prod: u32, dot: u32) u32 {
            for (kernel, 0..) |it, j| {
                if (it.prod == prod and it.dot == dot) return @intCast(j);
            }
            unreachable;
        }
    };

    // ---- spontaneous lookaheads + propagation links ----
    // `prop[src]` = the kernel-item ids that `src` propagates lookaheads to
    // (per-source lists, so building them is O(links) not O(links²) via `++`).
    var la_sets = [_][NT]bool{[_]bool{false} ** NT} ** K;
    var prop = [_][]const u32{&[_]u32{}} ** K;

    {
        var cbuf: [2 * P + 64]LItem = undefined;
        var s: usize = 0;
        while (s < num_states) : (s += 1) {
            var j: usize = 0;
            while (j < kernels[s].len) : (j += 1) {
                const kit = kernels[s][j];
                var seed_la = [_]bool{false} ** W;
                seed_la[HASH] = true;
                const seeds = [_]LItem{.{ .prod = kit.prod, .dot = kit.dot, .la = seed_la }};
                const nc = Clo1.run(&seeds, &cbuf);
                const src_id = offset[s] + @as(u32, @intCast(j));
                for (cbuf[0..nc]) |ci| {
                    const rhs = prods[ci.prod].rhs;
                    if (ci.dot >= rhs.len) continue;
                    const x = rhs[ci.dot];
                    const t = Tr.find(@intCast(s), x);
                    if (t < 0) continue;
                    const ts: u32 = @intCast(t);
                    const dst_j = kidx.find(kernels[ts], ci.prod, ci.dot + 1);
                    const dst_id = offset[ts] + dst_j;
                    var a: u32 = 0;
                    while (a < NT) : (a += 1) {
                        if (ci.la[a]) la_sets[dst_id][a] = true;
                    }
                    if (ci.la[HASH]) prop[src_id] = prop[src_id] ++ &[_]u32{dst_id};
                }
            }
        }
    }

    // start item S'->.S in state 0 has lookahead {eof}
    la_sets[offset[0] + kidx.find(kernels[0], 0, 0)][g.eof] = true;

    // propagate to fixpoint
    {
        var changed = true;
        while (changed) {
            changed = false;
            var src: usize = 0;
            while (src < K) : (src += 1) {
                for (prop[src]) |dst| {
                    var a: u32 = 0;
                    while (a < NT) : (a += 1) {
                        if (la_sets[src][a] and !la_sets[dst][a]) {
                            la_sets[dst][a] = true;
                            changed = true;
                        }
                    }
                }
            }
        }
    }

    // ---- precedence helpers ----
    const Prec = struct {
        fn ofTerm(a: u32) RawPrec {
            for (g.precedence) |pr| {
                if (pr.term == a) return pr;
            }
            return .{ .term = a, .level = 0, .assoc = .none };
        }
        fn ofProd(p: u32) u16 {
            if (prods[p].prec) |pt| return ofTerm(pt).level;
            var i: usize = prods[p].rhs.len;
            while (i > 0) {
                i -= 1;
                const sym = prods[p].rhs[i];
                if (sym < NT) return ofTerm(sym).level;
            }
            return 0;
        }
    };

    // ---- build ACTION / GOTO ----
    var action = [_]u32{cell(ACT_ERROR, 0)} ** (num_states * NT);
    var goto_table = [_]i32{-1} ** (num_states * num_nt_total);

    {
        var cbuf: [2 * P + 64]LItem = undefined;
        var s: usize = 0;
        while (s < num_states) : (s += 1) {
            // seed LR(1) closure with kernel items + their propagated lookaheads
            var seeds: [256]LItem = undefined;
            var ns: usize = 0;
            var j: usize = 0;
            while (j < kernels[s].len) : (j += 1) {
                var la = [_]bool{false} ** W;
                const gid = offset[s] + @as(u32, @intCast(j));
                var a: u32 = 0;
                while (a < NT) : (a += 1) la[a] = la_sets[gid][a];
                seeds[ns] = .{ .prod = kernels[s][j].prod, .dot = kernels[s][j].dot, .la = la };
                ns += 1;
            }
            const nc = Clo1.run(seeds[0..ns], &cbuf);
            const clos = cbuf[0..nc];

            for (clos) |ci| {
                const rhs = prods[ci.prod].rhs;
                if (ci.dot < rhs.len) {
                    const x = rhs[ci.dot];
                    const t = Tr.find(@intCast(s), x);
                    if (t < 0) continue;
                    if (x < NT) {
                        setAction(&action, s * NT + x, cell(ACT_SHIFT, @intCast(t)), x, g, Prec.ofProd, Prec.ofTerm, s);
                    } else {
                        goto_table[s * num_nt_total + (x - NT)] = @intCast(t);
                    }
                } else {
                    if (ci.prod == 0) {
                        // S' -> start .  : accept on its lookahead (eof)
                        var a: u32 = 0;
                        while (a < NT) : (a += 1) {
                            if (ci.la[a]) action[s * NT + a] = cell(ACT_ACCEPT, 0);
                        }
                    } else {
                        var a: u32 = 0;
                        while (a < NT) : (a += 1) {
                            if (ci.la[a]) {
                                setAction(&action, s * NT + a, cell(ACT_REDUCE, ci.prod), a, g, Prec.ofProd, Prec.ofTerm, s);
                            }
                        }
                    }
                }
            }
        }
    }

    // materialize into static const slices
    const num_prods = P;
    var prod_lhs = [_]u32{0} ** num_prods;
    var prod_rhs_len = [_]u32{0} ** num_prods;
    {
        var p: usize = 0;
        while (p < num_prods) : (p += 1) {
            prod_lhs[p] = prods[p].lhs;
            prod_rhs_len[p] = @intCast(prods[p].rhs.len);
        }
    }

    const action_final = action;
    const goto_final = goto_table;
    const lhs_final = prod_lhs;
    const rlen_final = prod_rhs_len;
    return .{
        .num_states = @intCast(num_states),
        .num_productions = @intCast(num_prods),
        .action = &action_final,
        .goto_table = &goto_final,
        .prod_lhs = &lhs_final,
        .prod_rhs_len = &rlen_final,
    };
}

/// Install `new_cell` at `action[idx]`, resolving shift/reduce conflicts with
/// precedence. Unresolved conflicts are a compile error — a stratified grammar
/// should be conflict-free, so a conflict means the grammar is wrong.
fn setAction(
    action: anytype,
    idx: usize,
    new_cell: u32,
    term: u32,
    comptime g: GrammarDesc,
    comptime prodPrec: anytype,
    comptime termPrec: anytype,
    state: usize,
) void {
    const cur = action[idx];
    if (cellKind(cur) == ACT_ERROR) {
        action[idx] = new_cell;
        return;
    }
    if (cur == new_cell) return;

    const cur_kind = cellKind(cur);
    const new_kind = cellKind(new_cell);

    // shift/reduce (in either arrival order)
    var shift_target: ?u32 = null;
    var reduce_prod: ?u32 = null;
    if (cur_kind == ACT_SHIFT) shift_target = cellArg(cur);
    if (cur_kind == ACT_REDUCE) reduce_prod = cellArg(cur);
    if (new_kind == ACT_SHIFT) shift_target = cellArg(new_cell);
    if (new_kind == ACT_REDUCE) reduce_prod = cellArg(new_cell);

    if (shift_target != null and reduce_prod != null) {
        const rlevel = prodPrec(reduce_prod.?);
        const tp = termPrec(term);
        if (rlevel > 0 and tp.level > 0) {
            if (rlevel > tp.level) {
                action[idx] = cell(ACT_REDUCE, reduce_prod.?);
                return;
            } else if (rlevel < tp.level) {
                action[idx] = cell(ACT_SHIFT, shift_target.?);
                return;
            } else {
                switch (tp.assoc) {
                    .left => action[idx] = cell(ACT_REDUCE, reduce_prod.?),
                    .right => action[idx] = cell(ACT_SHIFT, shift_target.?),
                    .nonassoc => action[idx] = cell(ACT_ERROR, 0),
                    .none => conflictError(g, state, term, cur, new_cell),
                }
                return;
            }
        }
        conflictError(g, state, term, cur, new_cell);
    }

    // reduce/reduce or anything else unresolved
    conflictError(g, state, term, cur, new_cell);
}

fn conflictError(comptime g: GrammarDesc, state: usize, term: u32, cur: u32, new_cell: u32) void {
    _ = g;
    @compileError(std.fmt.comptimePrint(
        "LR conflict in state {d} on terminal {d}: existing cell kind={d} arg={d} vs new kind={d} arg={d}. Fix the grammar (add precedence or restructure).",
        .{ state, term, cellKind(cur), cellArg(cur), cellKind(new_cell), cellArg(new_cell) },
    ));
}

// ---------------------------------------------------------------------------
// Standalone validation: the classic grammar that is LALR(1) but not SLR(1),
// plus a small operator grammar exercising left/right recursion.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A minimal runtime driver used only by the tests here to validate the tables.
fn driveAccepts(comptime Tab: type, terms: []const u32) bool {
    var stack: [256]u32 = undefined; // state stack
    var sp: usize = 0;
    stack[sp] = Tab.start_state;
    var ip: usize = 0;
    while (true) {
        const state = stack[sp];
        const la = terms[ip];
        const c = Tab.action[state * Tab.num_terminals + la];
        switch (cellKind(c)) {
            ACT_SHIFT => {
                sp += 1;
                stack[sp] = cellArg(c);
                ip += 1;
            },
            ACT_REDUCE => {
                const p = cellArg(c);
                const n = Tab.prod_rhs_len[p];
                sp -= n;
                const lhs = Tab.prod_lhs[p];
                const g = Tab.goto_table[stack[sp] * Tab.num_nonterminals + lhs];
                if (g < 0) return false;
                sp += 1;
                stack[sp] = @intCast(g);
            },
            ACT_ACCEPT => return true,
            else => return false,
        }
    }
}

test "LALR(1) grammar that is not SLR(1)" {
    // Terminals: 0='=', 1='*', 2=id, 3=eof
    // Nonterminals (index): 0=S, 1=L, 2=R
    // S -> L = R | R ; L -> * R | id ; R -> L
    const g = GrammarDesc{
        .num_terminals = 4,
        .num_nonterminals = 3,
        .eof = 3,
        .start = 0,
        .productions = &[_]RawProd{
            .{ .lhs = 0, .rhs = &[_]u32{ 4 + 1, 0, 4 + 2 } }, // S -> L = R
            .{ .lhs = 0, .rhs = &[_]u32{4 + 2} }, // S -> R
            .{ .lhs = 1, .rhs = &[_]u32{ 1, 4 + 2 } }, // L -> * R
            .{ .lhs = 1, .rhs = &[_]u32{2} }, // L -> id
            .{ .lhs = 2, .rhs = &[_]u32{4 + 1} }, // R -> L
        },
    };
    const Tab = Generate(g);

    try testing.expect(driveAccepts(Tab, &[_]u32{ 2, 3 })); // id
    try testing.expect(driveAccepts(Tab, &[_]u32{ 2, 0, 2, 3 })); // id = id
    try testing.expect(driveAccepts(Tab, &[_]u32{ 1, 2, 0, 2, 3 })); // * id = id
    try testing.expect(driveAccepts(Tab, &[_]u32{ 1, 1, 2, 3 })); // * * id
    try testing.expect(!driveAccepts(Tab, &[_]u32{ 2, 0, 3 })); // id =  (incomplete)
}

test "left/right recursive operator grammar" {
    // Terminals: 0='+', 1='^', 2=id, 3=eof
    // Nonterminals: 0=E, 1=T, 2=F
    // E -> E + T | T   (left assoc +)
    // T -> F ^ T | F   (right assoc ^)
    // F -> id
    const g = GrammarDesc{
        .num_terminals = 4,
        .num_nonterminals = 3,
        .eof = 3,
        .start = 0,
        .productions = &[_]RawProd{
            .{ .lhs = 0, .rhs = &[_]u32{ 4 + 0, 0, 4 + 1 } }, // E -> E + T
            .{ .lhs = 0, .rhs = &[_]u32{4 + 1} }, // E -> T
            .{ .lhs = 1, .rhs = &[_]u32{ 4 + 2, 1, 4 + 1 } }, // T -> F ^ T
            .{ .lhs = 1, .rhs = &[_]u32{4 + 2} }, // T -> F
            .{ .lhs = 2, .rhs = &[_]u32{2} }, // F -> id
        },
    };
    const Tab = Generate(g);

    try testing.expect(driveAccepts(Tab, &[_]u32{ 2, 3 })); // id
    try testing.expect(driveAccepts(Tab, &[_]u32{ 2, 0, 2, 0, 2, 3 })); // id + id + id
    try testing.expect(driveAccepts(Tab, &[_]u32{ 2, 1, 2, 1, 2, 3 })); // id ^ id ^ id
    try testing.expect(!driveAccepts(Tab, &[_]u32{ 2, 0, 3 })); // id +
}
