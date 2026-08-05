//! `syntax` module facade: lexing, parsing, and the AST.
//!
//! Self-contained front end: source text → tokens → AST, plus diagnostics.
//! Depends only on generic `base`. Consumers import this module by name
//! (`@import("syntax")`) and reach submodules through it; they must not import
//! `syntax/*` files directly.

pub const token = @import("token.zig");
pub const scanner = @import("scanner.zig");
pub const string_syntax = @import("string_syntax.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");

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
}
