//! `syntax` module facade — lexing, parsing, and the AST.
//!
//! Self-contained front end: source text → tokens → AST, plus diagnostics.
//! Depends on nothing else in the tree. Consumers import this module by name
//! (`@import("syntax")`) and reach submodules through it; they must not import
//! `syntax/*` files directly.

pub const token = @import("syntax/token.zig");
pub const scanner = @import("syntax/scanner.zig");
pub const string_syntax = @import("syntax/string_syntax.zig");
pub const diagnostic = @import("syntax/diagnostic.zig");
pub const ast = @import("syntax/ast.zig");
pub const parser = @import("syntax/parser.zig");
pub const json = @import("syntax/json.zig");

// Common flat re-exports for the most-used types.
pub const Token = token.Token;
pub const TokenType = token.TokenType;
pub const Diagnostic = diagnostic.Diagnostic;
pub const Node = ast.Node;
pub const NodeTag = ast.NodeTag;
pub const BinaryOp = ast.BinaryOp;
pub const Parser = parser.Parser;

test {
    _ = parser;
    _ = scanner;
    _ = json;
}
