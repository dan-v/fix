//! Thin facade over the node-kind compilers that were split out of this
//! (formerly god-) file. The bodies now live in four cohesive siblings —
//! one file per responsibility — and this module re-exports the externally
//! called entry points so `compiler.zig`, `compiler/access.zig` and
//! `compiler/control.zig` keep dispatching through `ops.X` unchanged. The
//! split is pure code motion; behaviour is byte-identical.
//!
//!   - `fold.zig`   — operator compilation + compile-time const-folding
//!                    (compileBinary / compileUnary and the fold cluster).
//!   - `lambda.zig` — the lambda / apply cluster (compileApply,
//!                    compileTailExpression, compileLambda,
//!                    compileLambdaAttrs, ...).
//!   - `let.zig`    — the let-in cluster (compileLetIn and binding
//!                    classification / eager-elision helpers).
//!   - `refs.zig`   — the shared free-variable collector used by both the
//!                    lambda and let clusters.

const fold = @import("fold.zig");
const lambda = @import("lambda.zig");
const let = @import("let.zig");

// Externally-dispatched entry points (see `compiler.zig`,
// `compiler/access.zig`, `compiler/control.zig`).
pub const compileBinary = fold.compileBinary;
pub const compileUnary = fold.compileUnary;
pub const compileApply = lambda.compileApply;
pub const compileTailExpression = lambda.compileTailExpression;
pub const compileLambda = lambda.compileLambda;
pub const compileLambdaAttrs = lambda.compileLambdaAttrs;
pub const compileLetIn = let.compileLetIn;
