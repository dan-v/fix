//! Generic LALR(1) parser-table generator.
//!
//! Given a context-free grammar in integer form (`GrammarDesc`), this produces
//! flat ACTION/GOTO tables. The runtime driver (see `parser.zig`) is a tight
//! shift/reduce loop over those tables — no per-token function-pointer dispatch,
//! one array lookup per action.
//!
//! Construction runs as ORDINARY runtime code (native loops + an arena
//! allocator), invoked once by the `gen-parser-tables` build tool, which emits
//! the resulting arrays as static literals into `parser_tables.zig`. The shipped
//! `fix` binary therefore contains only baked-in tables and does no construction
//! at eval time. (This was previously a `comptime` evaluation, which cost ~70s
//! of compiler time per table regen; running it natively is orders of magnitude
//! faster and produces byte-identical tables.)
//!
//! Algorithm: the canonical LR(0) automaton plus LALR(1) lookaheads computed by
//! the DeRemer/Pennello-style "spontaneous generation + propagation" method
//! (Aho/Sethi/Ullman, Dragon book §4.7). State count therefore equals the LR(0)
//! state count.
//!
//! Symbols are integers:
//!   terminals    : `0 .. num_terminals`            (includes the EOF marker)
//!   nonterminals : `num_terminals .. num_terminals+num_nonterminals`
//!   augmented S' : `num_terminals+num_nonterminals` (added internally)
//!
//! Productions are given without the augmented start rule; `generate` prepends
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

/// Packed action cell kinds (stored in the top 2 bits of a `u16`).
/// A `u16` cell keeps the whole ACTION table half the size it would be as
/// `u32` — the driver does one dependent table load per input token, so
/// the table living in L1 is worth real cycles. 14 bits of arg bound the
/// grammar at 16384 states/productions (asserted in `generate`; the Nix
/// grammar has ~253/205).
pub const action_error: u32 = 0;
pub const action_shift: u32 = 1;
pub const action_reduce: u32 = 2;
pub const action_accept: u32 = 3;

pub const Cell = u16;
const cell_arg_bits = 14;
const cell_arg_mask: u32 = (1 << cell_arg_bits) - 1;

pub inline fn cell(kind: u32, arg: u32) Cell {
    return @intCast((kind << cell_arg_bits) | (arg & cell_arg_mask));
}
pub inline fn cellKind(c: Cell) u32 {
    return @as(u32, c) >> cell_arg_bits;
}
pub inline fn cellArg(c: Cell) u32 {
    return @as(u32, c) & cell_arg_mask;
}

/// Upper bound on the lookahead-set width `lookahead_width = num_terminals + 1`. Each LR(1)
/// closure item carries a fixed-size lookahead bitset of this width; only the
/// first `lookahead_width` slots are ever read, so the cap just has to exceed the grammar's
/// terminal count. The Nix grammar has 55 terminals; 1024 leaves ample room.
const max_terminals = 1024;

const Item = struct { prod: u32, dot: u32 };

/// An LR(1) closure item: an LR(0) item plus a lookahead bitset. Only
/// `la[0..lookahead_width]` is meaningful; the trailing slots are unused padding (never read),
/// which lets the item be a fixed-size value type instead of carrying a slice.
const LItem = struct { prod: u32, dot: u32, la: [max_terminals]bool };

/// The constructed tables. Slices are owned by the allocator passed to
/// `generate` (in practice an arena that outlives the emit).
pub const Built = struct {
    num_states: u32,
    num_terminals: u32,
    /// Includes the augmented start nonterminal S'.
    num_nonterminals: u32,
    num_productions: u32,
    eof: u32,
    start_state: u32,
    /// `action[state * num_terminals + term]` — a packed cell.
    action: []const Cell,
    /// `goto_table[state * num_nonterminals + nt]` — target state, or -1.
    goto_table: []const i16,
    /// Per-production left-hand-side nonterminal index (0-based).
    prod_lhs: []const u32,
    /// Per-production right-hand-side length (symbols popped on reduce).
    prod_rhs_len: []const u32,
};

pub const GenError = error{ OutOfMemory, LRConflict };

const List = std.ArrayListUnmanaged;

// FNV-1a over a kernel's (prod, dot) pairs, used to bucket kernels for O(1)
// average dedup.
fn kernelHash(k: []const Item) u64 {
    var h: u64 = 1469598103934665603;
    for (k) |it| {
        h = (h ^ @as(u64, it.prod)) *% 1099511628211;
        h = (h ^ @as(u64, it.dot)) *% 1099511628211;
    }
    return h;
}

fn kernelEqual(a: []const Item, b: []const Item) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.prod != y.prod or x.dot != y.dot) return false;
    }
    return true;
}

fn itemLess(a: Item, b: Item) bool {
    if (a.prod != b.prod) return a.prod < b.prod;
    return a.dot < b.dot;
}

// Sort an item list into canonical (prod, dot) order so equal kernels hash and
// compare equal regardless of discovery order. Returns a freshly-allocated,
// persistent slice (the state's kernel).
fn sortKernel(arena: std.mem.Allocator, list: []const Item) ![]const Item {
    const arr = try arena.dupe(Item, list);
    var i: usize = 1;
    while (i < arr.len) : (i += 1) {
        var j = i;
        while (j > 0 and itemLess(arr[j], arr[j - 1])) : (j -= 1) {
            const tmp = arr[j];
            arr[j] = arr[j - 1];
            arr[j - 1] = tmp;
        }
    }
    return arr;
}

// index of kernel item (prod,dot) within a state's kernel
fn kidxFind(kernel: []const Item, prod: u32, dot: u32) u32 {
    for (kernel, 0..) |it, j| {
        if (it.prod == prod and it.dot == dot) return @intCast(j);
    }
    unreachable;
}

fn precOfTerm(g: GrammarDesc, a: u32) RawPrec {
    for (g.precedence) |pr| {
        if (pr.term == a) return pr;
    }
    return .{ .term = a, .level = 0, .assoc = .none };
}

fn precOfProd(g: GrammarDesc, prods: []const RawProd, p: u32) u16 {
    if (prods[p].prec) |pt| return precOfTerm(g, pt).level;
    var i: usize = prods[p].rhs.len;
    while (i > 0) {
        i -= 1;
        const sym = prods[p].rhs[i];
        if (sym < g.num_terminals) return precOfTerm(g, sym).level;
    }
    return 0;
}

// Shared grammar data + the two closure helpers that read it. Groups what the
// old comptime nested-struct methods captured from their enclosing scope.
const Ctx = struct {
    terminal_count: u32,
    lookahead_width: u32,
    num_nt_total: u32,
    prods: []const RawProd,
    prods_of: []const []const u32,
    first: []const bool, // [num_nt_total][terminal_count], flattened as [b*terminal_count + a]
    nullable: []const bool,

    // FIRST of the sequence `seq` followed by lookahead set `la` (width lookahead_width),
    // written into `out[0..lookahead_width]`.
    fn firstSeq(self: *const Ctx, out: []bool, seq: []const u32, la: []const bool) void {
        const terminal_count = self.terminal_count;
        const lookahead_width = self.lookahead_width;
        for (0..lookahead_width) |k| out[k] = false;
        var all_null = true;
        for (seq) |sym| {
            if (sym < terminal_count) {
                out[sym] = true;
                all_null = false;
                break;
            } else {
                const b = sym - terminal_count;
                for (0..terminal_count) |a| {
                    if (self.first[b * terminal_count + a]) out[a] = true;
                }
                if (!self.nullable[b]) {
                    all_null = false;
                    break;
                }
            }
        }
        if (all_null) {
            for (0..lookahead_width) |a| {
                if (la[a]) out[a] = true;
            }
        }
    }

    // LR(1) closure of `seeds` into `buf`; returns its length. `pos` is caller
    // scratch of length `prods.len` (reset internally). Closure only adds dot-0
    // items, so "find existing" is O(1) via `pos[p]` and the rule lookup uses
    // the by-LHS index.
    fn clo1(self: *const Ctx, seeds: []const LItem, buf: []LItem, pos: []i32) usize {
        const terminal_count = self.terminal_count;
        const lookahead_width = self.lookahead_width;
        var n: usize = 0;
        @memset(pos, -1);
        for (seeds) |it| {
            buf[n] = it;
            if (it.dot == 0) pos[it.prod] = @intCast(n);
            n += 1;
        }
        var fs: [max_terminals]bool = undefined;
        var changed = true;
        while (changed) {
            changed = false;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const it = buf[i];
                const rhs = self.prods[it.prod].rhs;
                if (it.dot >= rhs.len) continue;
                const sym = rhs[it.dot];
                if (sym < terminal_count) continue;
                const beta = rhs[it.dot + 1 ..];
                self.firstSeq(fs[0..lookahead_width], beta, it.la[0..lookahead_width]);
                for (self.prods_of[sym - terminal_count]) |p| {
                    if (pos[p] < 0) {
                        buf[n] = .{ .prod = p, .dot = 0, .la = undefined };
                        @memcpy(buf[n].la[0..lookahead_width], fs[0..lookahead_width]);
                        pos[p] = @intCast(n);
                        n += 1;
                        changed = true;
                    } else {
                        const qi: usize = @intCast(pos[p]);
                        for (0..lookahead_width) |a| {
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

/// Build the LALR(1) tables for `g`. Runs as ordinary native code; all working
/// state and the returned arrays are allocated from `arena`.
pub fn generate(arena: std.mem.Allocator, g: GrammarDesc) GenError!Built {
    const terminal_count = g.num_terminals;
    const nonterminal_count = g.num_nonterminals;
    const start_sym: u32 = terminal_count + g.start;
    const num_nt_total = nonterminal_count + 1; // includes S'
    const lookahead_width = terminal_count + 1; // lookahead-set width: real terminals + the '#' marker
    const propagation_marker = terminal_count; // bit index of the '#' propagation marker
    std.debug.assert(lookahead_width <= max_terminals);

    // Productions with the augmented rule S' -> start prepended at index 0.
    const prods = try arena.alloc(RawProd, g.productions.len + 1);
    prods[0] = .{ .lhs = nonterminal_count, .rhs = try arena.dupe(u32, &[_]u32{start_sym}) };
    for (g.productions, 0..) |p, i| prods[i + 1] = p;
    const production_count = prods.len;

    // Productions grouped by left-hand-side nonterminal.
    const prods_of = try arena.alloc([]const u32, num_nt_total);
    {
        const lists = try arena.alloc(List(u32), num_nt_total);
        for (lists) |*l| l.* = .empty;
        for (prods, 0..) |p, i| try lists[p.lhs].append(arena, @intCast(i));
        for (0..num_nt_total) |k| prods_of[k] = lists[k].items;
    }

    // ---- FIRST sets and nullability (indexed by nonterminal index 0..nonterminal_count) ----
    const nullable = try arena.alloc(bool, num_nt_total);
    @memset(nullable, false);
    const first = try arena.alloc(bool, num_nt_total * terminal_count);
    @memset(first, false);
    {
        var changed = true;
        while (changed) {
            changed = false;
            for (prods) |p| {
                const lhs = p.lhs;
                var all_null = true;
                for (p.rhs) |sym| {
                    if (sym < terminal_count) {
                        if (!first[lhs * terminal_count + sym]) {
                            first[lhs * terminal_count + sym] = true;
                            changed = true;
                        }
                        all_null = false;
                        break;
                    } else {
                        const b = sym - terminal_count;
                        for (0..terminal_count) |a| {
                            if (first[b * terminal_count + a] and !first[lhs * terminal_count + a]) {
                                first[lhs * terminal_count + a] = true;
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
    }

    const ctx = Ctx{
        .terminal_count = terminal_count,
        .lookahead_width = lookahead_width,
        .num_nt_total = num_nt_total,
        .prods = prods,
        .prods_of = prods_of,
        .first = first,
        .nullable = nullable,
    };

    // ---- build the canonical LR(0) collection ----
    const symbol_count = terminal_count + nonterminal_count;
    const kernel_bucket_count = 8192;
    const start_kernel = try arena.dupe(Item, &[_]Item{.{ .prod = 0, .dot = 0 }});
    var kernels: List([]const Item) = .empty;
    try kernels.append(arena, start_kernel);
    const Trans = struct { from: u32, sym: u32, to: u32 };
    var trans: List(Trans) = .empty;
    // buckets maps a kernel's FNV hash (masked) to the state indices in it.
    const buckets = try arena.alloc(List(u32), kernel_bucket_count);
    for (buckets) |*bk| bk.* = .empty;
    try buckets[kernelHash(start_kernel) & (kernel_bucket_count - 1)].append(arena, 0);

    // scratch reused across states
    const clo0_buf = try arena.alloc(Item, 2 * production_count + 64);
    const seen = try arena.alloc(bool, production_count);
    const g_items = try arena.alloc(List(Item), symbol_count);
    for (g_items) |*gi| gi.* = .empty;

    {
        var s: usize = 0;
        while (s < kernels.items.len) : (s += 1) {
            // LR(0) closure over the kernel: worklist with an O(1) "seen"
            // (closure only ever adds dot-0 items).
            var nclo: usize = 0;
            @memset(seen, false);
            for (kernels.items[s]) |it| {
                clo0_buf[nclo] = it;
                nclo += 1;
                if (it.dot == 0) seen[it.prod] = true;
            }
            var i: usize = 0;
            while (i < nclo) : (i += 1) {
                const it = clo0_buf[i];
                const rhs = prods[it.prod].rhs;
                if (it.dot >= rhs.len) continue;
                const sym = rhs[it.dot];
                if (sym < terminal_count) continue;
                for (prods_of[sym - terminal_count]) |p| {
                    if (!seen[p]) {
                        seen[p] = true;
                        clo0_buf[nclo] = .{ .prod = p, .dot = 0 };
                        nclo += 1;
                    }
                }
            }
            // Bucket each advanced closure item by its next symbol.
            for (0..symbol_count) |x| g_items[x].clearRetainingCapacity();
            for (clo0_buf[0..nclo]) |it| {
                const rhs = prods[it.prod].rhs;
                if (it.dot >= rhs.len) continue;
                const sym = rhs[it.dot];
                try g_items[sym].append(arena, .{ .prod = it.prod, .dot = it.dot + 1 });
            }
            var x: usize = 0;
            while (x < symbol_count) : (x += 1) { // never GOTO on S'
                if (g_items[x].items.len == 0) continue;
                const gk = try sortKernel(arena, g_items[x].items);
                const h = kernelHash(gk);
                const b = h & (kernel_bucket_count - 1);
                var target: i64 = -1;
                for (buckets[b].items) |ki| {
                    if (kernelEqual(kernels.items[ki], gk)) {
                        target = @intCast(ki);
                        break;
                    }
                }
                if (target < 0) {
                    const ni: u32 = @intCast(kernels.items.len);
                    try kernels.append(arena, gk);
                    try buckets[b].append(arena, ni);
                    target = ni;
                }
                try trans.append(arena, .{ .from = @intCast(s), .sym = @intCast(x), .to = @intCast(target) });
            }
        }
    }

    const num_states = kernels.items.len;

    // Dense transition table (state,sym) -> target state or -1.
    const trans_dense = try arena.alloc(i32, num_states * symbol_count);
    @memset(trans_dense, -1);
    for (trans.items) |e| trans_dense[e.from * symbol_count + e.sym] = @intCast(e.to);

    // ---- global ids for kernel items: offset[s] + j ----
    const offset = try arena.alloc(u32, num_states + 1);
    offset[0] = 0;
    for (0..num_states) |s| offset[s + 1] = offset[s] + @as(u32, @intCast(kernels.items[s].len));
    const kernel_item_count = offset[num_states];

    // ---- spontaneous lookaheads + propagation links ----
    const la_sets = try arena.alloc(bool, kernel_item_count * terminal_count); // [kernel_item_count][terminal_count], flattened
    @memset(la_sets, false);
    const prop = try arena.alloc(List(u32), kernel_item_count); // prop[src] -> dst kernel-item ids
    for (prop) |*pl| pl.* = .empty;

    const cbuf = try arena.alloc(LItem, 2 * production_count + 64);
    const pos = try arena.alloc(i32, production_count);

    {
        var s: usize = 0;
        while (s < num_states) : (s += 1) {
            var j: usize = 0;
            while (j < kernels.items[s].len) : (j += 1) {
                const kit = kernels.items[s][j];
                var seed: LItem = .{ .prod = kit.prod, .dot = kit.dot, .la = undefined };
                for (0..lookahead_width) |a| seed.la[a] = false;
                seed.la[propagation_marker] = true;
                const seeds = [_]LItem{seed};
                const nc = ctx.clo1(&seeds, cbuf, pos);
                const src_id = offset[s] + @as(u32, @intCast(j));
                for (cbuf[0..nc]) |ci| {
                    const rhs = prods[ci.prod].rhs;
                    if (ci.dot >= rhs.len) continue;
                    const xsym = rhs[ci.dot];
                    const t = trans_dense[s * symbol_count + xsym];
                    if (t < 0) continue;
                    const ts: usize = @intCast(t);
                    const dst_j = kidxFind(kernels.items[ts], ci.prod, ci.dot + 1);
                    const dst_id = offset[ts] + dst_j;
                    for (0..terminal_count) |a| {
                        if (ci.la[a]) la_sets[dst_id * terminal_count + a] = true;
                    }
                    if (ci.la[propagation_marker]) try prop[src_id].append(arena, dst_id);
                }
            }
        }
    }

    // start item S'->.S in state 0 has lookahead {eof}
    la_sets[(offset[0] + kidxFind(kernels.items[0], 0, 0)) * terminal_count + g.eof] = true;

    // propagate to fixpoint
    {
        var changed = true;
        while (changed) {
            changed = false;
            var src: usize = 0;
            while (src < kernel_item_count) : (src += 1) {
                for (prop[src].items) |dst| {
                    for (0..terminal_count) |a| {
                        if (la_sets[src * terminal_count + a] and !la_sets[dst * terminal_count + a]) {
                            la_sets[dst * terminal_count + a] = true;
                            changed = true;
                        }
                    }
                }
            }
        }
    }

    // ---- build ACTION / GOTO ----
    const action = try arena.alloc(Cell, num_states * terminal_count);
    @memset(action, cell(action_error, 0));
    const goto_table = try arena.alloc(i16, num_states * num_nt_total);
    @memset(goto_table, -1);

    var max_kernel: usize = 0;
    for (0..num_states) |s| max_kernel = @max(max_kernel, kernels.items[s].len);
    const seeds_buf = try arena.alloc(LItem, max_kernel);

    {
        var s: usize = 0;
        while (s < num_states) : (s += 1) {
            // seed LR(1) closure with kernel items + their propagated lookaheads
            var ns: usize = 0;
            var j: usize = 0;
            while (j < kernels.items[s].len) : (j += 1) {
                var seed: LItem = .{ .prod = kernels.items[s][j].prod, .dot = kernels.items[s][j].dot, .la = undefined };
                for (0..lookahead_width) |a| seed.la[a] = false;
                const gid = offset[s] + @as(u32, @intCast(j));
                for (0..terminal_count) |a| seed.la[a] = la_sets[gid * terminal_count + a];
                seeds_buf[ns] = seed;
                ns += 1;
            }
            const nc = ctx.clo1(seeds_buf[0..ns], cbuf, pos);
            for (cbuf[0..nc]) |ci| {
                const rhs = prods[ci.prod].rhs;
                if (ci.dot < rhs.len) {
                    const xsym = rhs[ci.dot];
                    const t = trans_dense[s * symbol_count + xsym];
                    if (t < 0) continue;
                    if (xsym < terminal_count) {
                        try setAction(g, prods, action, s * terminal_count + xsym, cell(action_shift, @intCast(t)), xsym, s);
                    } else {
                        goto_table[s * num_nt_total + (xsym - terminal_count)] = @intCast(t);
                    }
                } else {
                    if (ci.prod == 0) {
                        // S' -> start .  : accept on its lookahead (eof)
                        for (0..terminal_count) |a| {
                            if (ci.la[a]) action[s * terminal_count + a] = cell(action_accept, 0);
                        }
                    } else {
                        for (0..terminal_count) |a| {
                            if (ci.la[a]) {
                                try setAction(g, prods, action, s * terminal_count + a, cell(action_reduce, ci.prod), @intCast(a), s);
                            }
                        }
                    }
                }
            }
        }
    }

    const prod_lhs = try arena.alloc(u32, production_count);
    const prod_rhs_len = try arena.alloc(u32, production_count);
    for (0..production_count) |p| {
        prod_lhs[p] = prods[p].lhs;
        prod_rhs_len[p] = @intCast(prods[p].rhs.len);
    }

    std.debug.assert(num_states <= cell_arg_mask + 1);
    std.debug.assert(production_count <= cell_arg_mask + 1);
    std.debug.assert(num_states <= std.math.maxInt(i16));

    return .{
        .num_states = @intCast(num_states),
        .num_terminals = terminal_count,
        .num_nonterminals = num_nt_total,
        .num_productions = @intCast(production_count),
        .eof = g.eof,
        .start_state = 0,
        .action = action,
        .goto_table = goto_table,
        .prod_lhs = prod_lhs,
        .prod_rhs_len = prod_rhs_len,
    };
}

/// Install `new_cell` at `action[idx]`, resolving shift/reduce conflicts with
/// precedence. Unresolved conflicts return `error.LRConflict` — a stratified
/// grammar should be conflict-free, so a conflict means the grammar is wrong.
fn setAction(
    g: GrammarDesc,
    prods: []const RawProd,
    action: []Cell,
    idx: usize,
    new_cell: Cell,
    term: u32,
    state: usize,
) GenError!void {
    const cur = action[idx];
    if (cellKind(cur) == action_error) {
        action[idx] = new_cell;
        return;
    }
    if (cur == new_cell) return;

    const cur_kind = cellKind(cur);
    const new_kind = cellKind(new_cell);

    // shift/reduce (in either arrival order)
    var shift_target: ?u32 = null;
    var reduce_prod: ?u32 = null;
    if (cur_kind == action_shift) shift_target = cellArg(cur);
    if (cur_kind == action_reduce) reduce_prod = cellArg(cur);
    if (new_kind == action_shift) shift_target = cellArg(new_cell);
    if (new_kind == action_reduce) reduce_prod = cellArg(new_cell);

    if (shift_target != null and reduce_prod != null) {
        const rlevel = precOfProd(g, prods, reduce_prod.?);
        const tp = precOfTerm(g, term);
        if (rlevel > 0 and tp.level > 0) {
            if (rlevel > tp.level) {
                action[idx] = cell(action_reduce, reduce_prod.?);
                return;
            } else if (rlevel < tp.level) {
                action[idx] = cell(action_shift, shift_target.?);
                return;
            } else {
                switch (tp.assoc) {
                    .left => action[idx] = cell(action_reduce, reduce_prod.?),
                    .right => action[idx] = cell(action_shift, shift_target.?),
                    .nonassoc => action[idx] = cell(action_error, 0),
                    .none => return conflictError(state, term, cur, new_cell),
                }
                return;
            }
        }
        return conflictError(state, term, cur, new_cell);
    }

    // reduce/reduce or anything else unresolved
    return conflictError(state, term, cur, new_cell);
}

fn conflictError(state: usize, term: u32, cur: Cell, new_cell: Cell) GenError {
    std.debug.print(
        "LR conflict in state {d} on terminal {d}: existing cell kind={d} arg={d} vs new kind={d} arg={d}. Fix the grammar (add precedence or restructure).\n",
        .{ state, term, cellKind(cur), cellArg(cur), cellKind(new_cell), cellArg(new_cell) },
    );
    return error.LRConflict;
}

// ---------------------------------------------------------------------------
// Standalone validation: the classic grammar that is LALR(1) but not SLR(1),
// plus a small operator grammar exercising left/right recursion.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A minimal driver used only by the tests here to validate the tables.
fn driveAccepts(tab: Built, terms: []const u32) bool {
    var stack: [256]u32 = undefined; // state stack
    var sp: usize = 0;
    stack[sp] = tab.start_state;
    var ip: usize = 0;
    while (true) {
        const state = stack[sp];
        const la = terms[ip];
        const c = tab.action[state * tab.num_terminals + la];
        switch (cellKind(c)) {
            action_shift => {
                sp += 1;
                stack[sp] = cellArg(c);
                ip += 1;
            },
            action_reduce => {
                const p = cellArg(c);
                const n = tab.prod_rhs_len[p];
                sp -= n;
                const lhs = tab.prod_lhs[p];
                const gt = tab.goto_table[stack[sp] * tab.num_nonterminals + lhs];
                if (gt < 0) return false;
                sp += 1;
                stack[sp] = @intCast(gt);
            },
            action_accept => return true,
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tab = try generate(arena.allocator(), g);

    try testing.expect(driveAccepts(tab, &[_]u32{ 2, 3 })); // id
    try testing.expect(driveAccepts(tab, &[_]u32{ 2, 0, 2, 3 })); // id = id
    try testing.expect(driveAccepts(tab, &[_]u32{ 1, 2, 0, 2, 3 })); // * id = id
    try testing.expect(driveAccepts(tab, &[_]u32{ 1, 1, 2, 3 })); // * * id
    try testing.expect(!driveAccepts(tab, &[_]u32{ 2, 0, 3 })); // id =  (incomplete)
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tab = try generate(arena.allocator(), g);

    try testing.expect(driveAccepts(tab, &[_]u32{ 2, 3 })); // id
    try testing.expect(driveAccepts(tab, &[_]u32{ 2, 0, 2, 0, 2, 3 })); // id + id + id
    try testing.expect(driveAccepts(tab, &[_]u32{ 2, 1, 2, 1, 2, 3 })); // id ^ id ^ id
    try testing.expect(!driveAccepts(tab, &[_]u32{ 2, 0, 3 })); // id +
}
