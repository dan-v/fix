//! The Nix grammar, in the form consumed by the comptime LALR(1) generator
//! (`lr.zig`). This file is pure data: nonterminals, productions, a semantic
//! `action` tag per production, and the operator precedence table. The runtime
//! driver (`parser.zig`) switches on the action tag to build the AST.
//!
//! Structure follows canonical Nix (Bison `parser.y`): an ambiguous
//! `expr_op OP expr_op` operator layer resolved by precedence, a *stratified*
//! application/selection layer (juxtaposition), and simple atoms. The one
//! genuinely non-context-free wrinkle — telling a lambda pattern `{ x }:` from
//! an attribute set `{ x = 1; }` — is removed before the driver runs: the
//! pre-pass retags a pattern's opening brace to the synthetic `pattern_lbrace`
//! terminal, so the grammar sees two distinct tokens and has no conflict.

const std = @import("std");
const lr = @import("lr.zig");
const tok = @import("token.zig");
const TokenType = tok.TokenType;

// ---- terminal symbol ids ---------------------------------------------------
// Real tokens keep their `TokenType` value as their id. Two synthetic
// terminals follow: `pattern_lbrace` (emitted by the pre-pass) and `neg` (a
// precedence-only marker for unary minus, never present in the token stream).

pub const num_tokens = @typeInfo(TokenType).@"enum".fields.len;
pub const t_pattern_lbrace: u32 = num_tokens;
pub const t_neg: u32 = num_tokens + 1;
pub const num_terminals: u32 = num_tokens + 2;
pub const t_eof: u32 = @intFromEnum(TokenType.eof);

inline fn t(tt: TokenType) u32 {
    return @intFromEnum(tt);
}

// ---- nonterminals ----------------------------------------------------------

pub const NT = enum(u32) {
    expr,
    expr_if,
    expr_op,
    expr_app,
    expr_select,
    expr_simple,
    attrpath,
    attr,
    formals,
    formal_list,
    formal,
    binds,
    bind,
    inherit_names,
    list_items,
};

inline fn n(x: NT) u32 {
    return num_terminals + @intFromEnum(x);
}

// ---- semantic action tags --------------------------------------------------

pub const Act = enum {
    augmented, // internal S' -> expr (index 0); never dispatched
    pass, // result = rhs[0]

    // Expr (function level)
    lambda_id, // ID : Expr
    lambda_no_bind, // PATLBRACE Formals RBRACE : Expr
    lambda_bind_before, // ID @ PATLBRACE Formals RBRACE : Expr
    lambda_bind_after, // PATLBRACE Formals RBRACE @ ID : Expr
    assert_, // assert Expr ; Expr
    with_, // with Expr ; Expr
    let_in, // let Binds in Expr

    // ExprIf
    if_else,

    // ExprOp binary
    bin_impl,
    bin_or,
    bin_and,
    bin_eq,
    bin_neq,
    bin_lt,
    bin_lte,
    bin_gt,
    bin_gte,
    bin_update,
    bin_add,
    bin_sub,
    bin_mul,
    bin_div,
    bin_concat,
    has_attr, // ExprOp ? AttrPath
    pipe_fwd, // ExprOp |> ExprOp
    pipe_bwd, // ExprOp <| ExprOp
    not, // ! ExprOp
    negate, // - ExprOp

    // ExprApp
    apply, // ExprApp ExprSelect

    // ExprSelect
    select, // ExprSimple . AttrPath
    select_or, // ExprSimple . AttrPath or ExprSelect

    // ExprSimple atoms
    ident,
    integer,
    float_val,
    string,
    path,
    search_path,
    bool_true,
    bool_false,
    null_lit,
    parens,
    attr_set, // { Binds }
    rec_attr_set, // rec { Binds }
    list, // [ ListItems ]

    // AttrPath / Attr
    attrpath_one,
    attrpath_append,
    attr_static, // ID/STRING/OR/TRUE/FALSE/NULL
    attr_dynamic, // ${ Expr }

    // Formals
    formals_empty,
    formals_ellipsis,
    formals_list,
    formals_list_comma,
    formals_list_ellipsis,
    formal_list_one,
    formal_list_append,
    formal_plain,
    formal_default,

    // Binds
    binds_empty,
    binds_append,
    bind_normal, // AttrPath = Expr
    bind_inherit, // inherit InheritNames
    bind_inherit_from, // inherit ( Expr ) InheritNames
    inherit_names_empty,
    inherit_names_append,

    // List
    list_items_empty,
    list_items_append,
};

const P = struct {
    lhs: NT,
    rhs: []const u32,
    act: Act,
    prec: ?u32 = null,
};

// ---- productions -----------------------------------------------------------
// Order matters: the production index (offset by +1 for the augmented rule the
// generator prepends) selects the action in the driver.

const productions = [_]P{
    // Expr
    .{ .lhs = .expr, .rhs = &.{ t(.identifier), t(.colon), n(.expr) }, .act = .lambda_id },
    .{ .lhs = .expr, .rhs = &.{ t_pattern_lbrace, n(.formals), t(.right_brace), t(.colon), n(.expr) }, .act = .lambda_no_bind },
    .{ .lhs = .expr, .rhs = &.{ t(.identifier), t(.at), t_pattern_lbrace, n(.formals), t(.right_brace), t(.colon), n(.expr) }, .act = .lambda_bind_before },
    .{ .lhs = .expr, .rhs = &.{ t_pattern_lbrace, n(.formals), t(.right_brace), t(.at), t(.identifier), t(.colon), n(.expr) }, .act = .lambda_bind_after },
    .{ .lhs = .expr, .rhs = &.{ t(.kw_assert), n(.expr), t(.semicolon), n(.expr) }, .act = .assert_ },
    .{ .lhs = .expr, .rhs = &.{ t(.kw_with), n(.expr), t(.semicolon), n(.expr) }, .act = .with_ },
    .{ .lhs = .expr, .rhs = &.{ t(.kw_let), n(.binds), t(.kw_in), n(.expr) }, .act = .let_in },
    .{ .lhs = .expr, .rhs = &.{n(.expr_if)}, .act = .pass },

    // ExprIf
    .{ .lhs = .expr_if, .rhs = &.{ t(.kw_if), n(.expr), t(.kw_then), n(.expr), t(.kw_else), n(.expr) }, .act = .if_else },
    .{ .lhs = .expr_if, .rhs = &.{n(.expr_op)}, .act = .pass },

    // ExprOp — ambiguous, resolved by precedence
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.arrow), n(.expr_op) }, .act = .bin_impl },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.pipe_pipe), n(.expr_op) }, .act = .bin_or },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.amp_amp), n(.expr_op) }, .act = .bin_and },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.equal_equal), n(.expr_op) }, .act = .bin_eq },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.bang_equal), n(.expr_op) }, .act = .bin_neq },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.less), n(.expr_op) }, .act = .bin_lt },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.less_equal), n(.expr_op) }, .act = .bin_lte },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.greater), n(.expr_op) }, .act = .bin_gt },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.greater_equal), n(.expr_op) }, .act = .bin_gte },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.double_slash), n(.expr_op) }, .act = .bin_update },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.plus), n(.expr_op) }, .act = .bin_add },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.minus), n(.expr_op) }, .act = .bin_sub },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.star), n(.expr_op) }, .act = .bin_mul },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.slash), n(.expr_op) }, .act = .bin_div },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.double_plus), n(.expr_op) }, .act = .bin_concat },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.question_mark), n(.attrpath) }, .act = .has_attr },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.pipe_forward), n(.expr_op) }, .act = .pipe_fwd },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.pipe_backward), n(.expr_op) }, .act = .pipe_bwd },
    .{ .lhs = .expr_op, .rhs = &.{ t(.bang), n(.expr_op) }, .act = .not },
    .{ .lhs = .expr_op, .rhs = &.{ t(.minus), n(.expr_op) }, .act = .negate, .prec = t_neg },
    .{ .lhs = .expr_op, .rhs = &.{n(.expr_app)}, .act = .pass },

    // ExprApp
    .{ .lhs = .expr_app, .rhs = &.{ n(.expr_app), n(.expr_select) }, .act = .apply },
    .{ .lhs = .expr_app, .rhs = &.{n(.expr_select)}, .act = .pass },

    // ExprSelect
    .{ .lhs = .expr_select, .rhs = &.{n(.expr_simple)}, .act = .pass },
    .{ .lhs = .expr_select, .rhs = &.{ n(.expr_simple), t(.dot), n(.attrpath) }, .act = .select },
    .{ .lhs = .expr_select, .rhs = &.{ n(.expr_simple), t(.dot), n(.attrpath), t(.kw_or), n(.expr_select) }, .act = .select_or },

    // ExprSimple
    .{ .lhs = .expr_simple, .rhs = &.{t(.identifier)}, .act = .ident },
    .{ .lhs = .expr_simple, .rhs = &.{t(.integer)}, .act = .integer },
    .{ .lhs = .expr_simple, .rhs = &.{t(.float_val)}, .act = .float_val },
    .{ .lhs = .expr_simple, .rhs = &.{t(.string)}, .act = .string },
    .{ .lhs = .expr_simple, .rhs = &.{t(.path)}, .act = .path },
    .{ .lhs = .expr_simple, .rhs = &.{t(.search_path)}, .act = .search_path },
    .{ .lhs = .expr_simple, .rhs = &.{t(.kw_true)}, .act = .bool_true },
    .{ .lhs = .expr_simple, .rhs = &.{t(.kw_false)}, .act = .bool_false },
    .{ .lhs = .expr_simple, .rhs = &.{t(.kw_null)}, .act = .null_lit },
    .{ .lhs = .expr_simple, .rhs = &.{ t(.left_paren), n(.expr), t(.right_paren) }, .act = .parens },
    .{ .lhs = .expr_simple, .rhs = &.{ t(.left_brace), n(.binds), t(.right_brace) }, .act = .attr_set },
    .{ .lhs = .expr_simple, .rhs = &.{ t(.kw_rec), t(.left_brace), n(.binds), t(.right_brace) }, .act = .rec_attr_set },
    .{ .lhs = .expr_simple, .rhs = &.{ t(.left_bracket), n(.list_items), t(.right_bracket) }, .act = .list },

    // AttrPath
    .{ .lhs = .attrpath, .rhs = &.{n(.attr)}, .act = .attrpath_one },
    .{ .lhs = .attrpath, .rhs = &.{ n(.attrpath), t(.dot), n(.attr) }, .act = .attrpath_append },

    // Attr (segment)
    .{ .lhs = .attr, .rhs = &.{t(.identifier)}, .act = .attr_static },
    .{ .lhs = .attr, .rhs = &.{t(.string)}, .act = .attr_static },
    .{ .lhs = .attr, .rhs = &.{t(.kw_or)}, .act = .attr_static },
    .{ .lhs = .attr, .rhs = &.{t(.kw_true)}, .act = .attr_static },
    .{ .lhs = .attr, .rhs = &.{t(.kw_false)}, .act = .attr_static },
    .{ .lhs = .attr, .rhs = &.{t(.kw_null)}, .act = .attr_static },
    .{ .lhs = .attr, .rhs = &.{ t(.dollar_curly), n(.expr), t(.right_brace) }, .act = .attr_dynamic },

    // Formals
    .{ .lhs = .formals, .rhs = &.{}, .act = .formals_empty },
    .{ .lhs = .formals, .rhs = &.{t(.ellipsis)}, .act = .formals_ellipsis },
    .{ .lhs = .formals, .rhs = &.{n(.formal_list)}, .act = .formals_list },
    .{ .lhs = .formals, .rhs = &.{ n(.formal_list), t(.comma) }, .act = .formals_list_comma },
    .{ .lhs = .formals, .rhs = &.{ n(.formal_list), t(.comma), t(.ellipsis) }, .act = .formals_list_ellipsis },
    .{ .lhs = .formal_list, .rhs = &.{n(.formal)}, .act = .formal_list_one },
    .{ .lhs = .formal_list, .rhs = &.{ n(.formal_list), t(.comma), n(.formal) }, .act = .formal_list_append },
    .{ .lhs = .formal, .rhs = &.{t(.identifier)}, .act = .formal_plain },
    .{ .lhs = .formal, .rhs = &.{t(.kw_or)}, .act = .formal_plain },
    .{ .lhs = .formal, .rhs = &.{ t(.identifier), t(.question_mark), n(.expr) }, .act = .formal_default },
    .{ .lhs = .formal, .rhs = &.{ t(.kw_or), t(.question_mark), n(.expr) }, .act = .formal_default },

    // Binds
    .{ .lhs = .binds, .rhs = &.{}, .act = .binds_empty },
    .{ .lhs = .binds, .rhs = &.{ n(.binds), n(.bind), t(.semicolon) }, .act = .binds_append },
    .{ .lhs = .bind, .rhs = &.{ n(.attrpath), t(.equal), n(.expr) }, .act = .bind_normal },
    .{ .lhs = .bind, .rhs = &.{ t(.kw_inherit), n(.inherit_names) }, .act = .bind_inherit },
    .{ .lhs = .bind, .rhs = &.{ t(.kw_inherit), t(.left_paren), n(.expr), t(.right_paren), n(.inherit_names) }, .act = .bind_inherit_from },
    .{ .lhs = .inherit_names, .rhs = &.{}, .act = .inherit_names_empty },
    .{ .lhs = .inherit_names, .rhs = &.{ n(.inherit_names), t(.identifier) }, .act = .inherit_names_append },
    .{ .lhs = .inherit_names, .rhs = &.{ n(.inherit_names), t(.kw_or) }, .act = .inherit_names_append },
    .{ .lhs = .inherit_names, .rhs = &.{ n(.inherit_names), t(.string) }, .act = .inherit_names_append },
    .{ .lhs = .inherit_names, .rhs = &.{ n(.inherit_names), t(.kw_true) }, .act = .inherit_names_append },
    .{ .lhs = .inherit_names, .rhs = &.{ n(.inherit_names), t(.kw_false) }, .act = .inherit_names_append },
    .{ .lhs = .inherit_names, .rhs = &.{ n(.inherit_names), t(.kw_null) }, .act = .inherit_names_append },

    // List
    .{ .lhs = .list_items, .rhs = &.{}, .act = .list_items_empty },
    .{ .lhs = .list_items, .rhs = &.{ n(.list_items), n(.expr_select) }, .act = .list_items_append },
};

// ---- operator precedence (Nix; higher level binds tighter) -----------------

const prec = [_]lr.RawPrec{
    .{ .term = t(.pipe_forward), .level = 1, .assoc = .left },
    .{ .term = t(.pipe_backward), .level = 1, .assoc = .right },
    .{ .term = t(.arrow), .level = 2, .assoc = .right },
    .{ .term = t(.pipe_pipe), .level = 3, .assoc = .left },
    .{ .term = t(.amp_amp), .level = 4, .assoc = .left },
    .{ .term = t(.equal_equal), .level = 5, .assoc = .nonassoc },
    .{ .term = t(.bang_equal), .level = 5, .assoc = .nonassoc },
    .{ .term = t(.less), .level = 6, .assoc = .nonassoc },
    .{ .term = t(.less_equal), .level = 6, .assoc = .nonassoc },
    .{ .term = t(.greater), .level = 6, .assoc = .nonassoc },
    .{ .term = t(.greater_equal), .level = 6, .assoc = .nonassoc },
    // Canonical Nix associativity: `//` and `++` are right-associative.
    .{ .term = t(.double_slash), .level = 7, .assoc = .right },
    .{ .term = t(.bang), .level = 8, .assoc = .left },
    .{ .term = t(.plus), .level = 9, .assoc = .left },
    .{ .term = t(.minus), .level = 9, .assoc = .left },
    .{ .term = t(.star), .level = 10, .assoc = .left },
    .{ .term = t(.slash), .level = 10, .assoc = .left },
    .{ .term = t(.double_plus), .level = 11, .assoc = .right },
    .{ .term = t(.question_mark), .level = 12, .assoc = .nonassoc },
    .{ .term = t_neg, .level = 13, .assoc = .right },
};

// ---- assembled grammar description + generated tables ----------------------

const raw_productions = blk: {
    var r: [productions.len]lr.RawProd = undefined;
    for (productions, 0..) |p, i| r[i] = .{ .lhs = @intFromEnum(p.lhs), .rhs = p.rhs, .prec = p.prec };
    break :blk r;
};

const desc = lr.GrammarDesc{
    .num_terminals = num_terminals,
    .num_nonterminals = @typeInfo(NT).@"enum".fields.len,
    .eof = t_eof,
    .start = @intFromEnum(NT.expr),
    .productions = &raw_productions,
    .precedence = &prec,
};

pub const Tables = lr.Generate(desc);

/// Action tag per production index (index 0 is the augmented rule).
pub const act_of_prod = blk: {
    var a: [productions.len + 1]Act = undefined;
    a[0] = .augmented;
    for (productions, 0..) |p, i| a[i + 1] = p.act;
    break :blk a;
};

test "grammar tables build without conflicts" {
    // Reaching this test at all means `lr.Generate` produced a conflict-free
    // table (conflicts are `@compileError`s).
    try std.testing.expect(Tables.num_states > 0);
    try std.testing.expect(Tables.num_productions == productions.len + 1);
}
