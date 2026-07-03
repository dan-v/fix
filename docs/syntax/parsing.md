# Parsing

*Scanner → Pratt parser → arena AST: how source text becomes the tree the compiler walks.*

The `syntax` module (`@import("syntax")`) is the self-contained front end. It takes immutable source bytes and produces a pointer-linked, arena-allocated AST plus a list of `Diagnostic`s. Everything below the module facade — `Scanner`, `Parser`, `AstArena`, `string_syntax` — is internal. The compiler ([`compiler/pipeline`](../compiler/pipeline.md)) consumes the AST; it never sees tokens.

Two hard rules shape the whole design:
- **Source outlives everything.** Tokens and AST nodes store byte offsets into the original source buffer, never owned slices. The caller must keep `source` alive for the entire lifetime of the tree.
- **No throwing control flow for recoverable errors.** Parse errors accumulate as diagnostics and the parser resynchronizes; it does not unwind or backtrack the token stream.

## Scanner

Single-pass, streaming, allocation-free. `next()` returns exactly one `Token` per call — there is no token array. A `Token` is `{ type: TokenType, offset, len, line }`: a byte offset and length into `source` plus a 1-based line number for diagnostics. No token carries a string slice; consumers that need the lexeme reslice `source[offset..offset+len]`.

Before each token the scanner skips layout — whitespace, `#` line comments, and `/* */` block comments — so comments never reach the parser. It recognizes the fixed keyword and punctuation set directly (e.g. `pipe_pipe` for `||`, `double_slash` for `//`, `arrow` for `->`, `dollar_curly` for `${`); identifiers that match a keyword are retagged to the keyword token.

Strings and paths are where the scanner stops being trivial. Their extent cannot be found by a simple character class because `"..."` and `''...''` embed arbitrary nested `${ expr }` interpolations. The scanner delegates extent-finding to [`string_syntax`](nix-syntax.md), which tracks brace depth through nested interpolations and returns where the literal ends; the scanner emits one `string`/`path`/`search_path` token spanning the whole thing. Decoding the literal's parts happens later, on demand, not during scanning.

## Parser

Recursive descent for statement-like forms, **Pratt precedence-climbing** for expressions. Parser state is deliberately small:

```
Parser {
  scanner, source,
  current, previous,      // exactly 1-token lookahead
  arena,                  // *AstArena, bump allocation
  diagnostics, had_error,
}
```

`advance()` slides `current → previous` and pulls the next token; `check`/`match`/`expect` are the standard one-token predicates. There is no multi-token buffer.

### Precedence ladder and Rule dispatch

Every token maps to a `Rule { prefix, infix, prec }` returned from a **static `switch`** — there is no precedence table array; the switch *is* the table, so it inlines and needs no initialization. `prefix` parses a token appearing in operand position (a literal, a keyword form, an opening bracket, a unary operator). `infix` parses a token appearing after a completed left operand (a binary operator, `.`, `?`, or `or`). `prec` is the binding power used by the climb.

The `Precedence` enum, low → high:

```
none
assignment   // = inside let/attr bindings
pipe         // |> <|         (pipe operators, behind --pipe-operators)
impl         // ->            (right-associative)
or_          // ||
and_         // &&
eq           // == !=
cmp          // < > <= >=
update       // //
not          // !
sum          // + -
prod         // * /
concat       // ++
unary        // prefix -
apply        // function application (juxtaposition)
primary
```

`parsePrecedence(min_prec)` parses a prefix, then loops: while the current token's infix `prec` is `>= min_prec`, consume it and recurse. Standard climbing. Two Nix-specific wrinkles:

- **Right-associativity of `->`** (and `//`) is achieved without a separate code path: the infix handler recurses with the operator's *own, non-incremented* precedence instead of `prec+1`. Left-associative operators recurse at `prec+1`. So `a -> b -> c` parses as `a -> (b -> c)`.
- **Application is juxtaposition**, not an operator token. At `apply` precedence, if the current token *can start an expression* (`canStartExpr`) the parser treats it as an argument: it builds an `apply` node `{ func, arg }` and keeps folding arguments left-to-right, so `f a b` is `((f a) b)`. `parsePrecedenceWithApply(min, allow_apply)` gates this; contexts where a bare juxtaposition would be ambiguous (list elements — see [nix-syntax](nix-syntax.md)) pass `allow_apply = false`.

### One-token lookahead + speculative clone

The grammar has one genuinely ambiguous prefix: an opening `{` may begin an attribute set (`{ a = 1; }`) or a lambda parameter pattern (`{ a, b ? d, ... }@args:`). One token of lookahead cannot distinguish them — the pattern is only confirmed by a `:` or `@` *after* the matching `}`, arbitrarily far ahead.

The parser resolves this with a **speculative state clone**, `looksLikeAttrLambdaPattern`: it copies the entire `Parser` by value (`probe = self.*`) with an empty diagnostics list, then scans forward tracking bracket depth (`{ [ ( ${` open, `} ] )` close) until depth returns to zero. It peeks the token past the closing `}`: a `:` or `@` means lambda pattern, anything else means attribute set. The probe is discarded — the real parser has not advanced — and the correct prefix routine runs from scratch. Because the AST is arena-allocated and the probe never emits diagnostics, the clone is cheap and side-effect-free.

## AST

An `AstArena` wraps a Zig `ArenaAllocator`: nodes are bump-allocated and freed all-at-once when the arena is dropped. There is no per-node destructor and no reference counting; the tree is immutable once built.

A `Node` is a tagged union: `tag: NodeTag` + `data: Data`. Consumers dispatch on `tag` and read the matching `data` variant. Spans are byte `Atom { offset, len }` into `source` — the same offsets-not-strings discipline as tokens. For compound nodes the span is derived at construction (`nodeSourceSpan` spans from the first child to the last), so any node can report its own source extent for diagnostics without storing extra bookkeeping.

Roughly the tag families (~38 tags):

- **Atoms** (`data = Atom`): `integer, float, string, path, search_path, identifier, bool_true, bool_false, null`. The atom's bytes still live in `source`; string/path *decoding* is deferred to the compiler via [`string_syntax`](nix-syntax.md) `ParsedLiteral`s.
- **Operators**: `unary_op` (`Unary { op, expr }`), `binary_op` (`Binary { op, left, right }`, 14 ops: add/sub/mul/div, eq/neq, lt/lte/gt/gte, and/or, impl, update, concat).
- **Functions & binding forms**: `lambda` (`Lambda { param, body }`), `lambda_attrs` (`LambdaAttrs { bind_name?, params[], allow_extra, body }`), `let_in` (`LetIn { bindings[], body }`), `with_expr`, `if_else`, `assert`.
- **Attribute access & sets**: `attr_path` (`AttrPath { root, segments[] }`), `attr_dynamic`, `attr_or`, `has_attr` / `has_attr_dynamic` / `has_attr_mixed`, `attr_set` (`AttrSet { entries[], recursive }`), `list`, `parens`.

Two shared records recur: `Binding { name, path[], expr, inherit_outer }` for each attr-set/let binding, and `LambdaAttrParam { name, default? }` for each formal in a pattern. The Nix-surface meaning of these — `inherit` desugaring, dynamic attr paths, pattern semantics — is documented in [nix-syntax](nix-syntax.md); this doc covers only how the tree is shaped and walked.

## Diagnostics and recovery

Errors are values, not exceptions. `expect()` on a mismatch calls `reportError`, pushes a `Diagnostic` onto the list, sets `had_error`, and returns `error.ParseError` up the local call chain — but the parser catches it at a recovery boundary and **synchronizes** rather than aborting the whole parse. Synchronization advances past the current construct to a stable anchor (`;`, `}`, or the `in` keyword, depending on context — e.g. `synchronizeAttrSetEntry`) so one bad binding doesn't cascade into a flood of spurious errors. `parse()` returns the root node but reports `error.ParseError` overall if `had_error` is set, so callers get both the partial tree and a hard failure signal.

A `Diagnostic` carries `{ severity, kind (parse|compile), line, column, offset, len, token_type?, message, source?, source_path? }` — the same struct serves compile-phase errors. Rendering (`writeAll`) prints line/column, a source snippet, and a caret under `offset..len`, optionally ANSI-colored. Column and snippet resolution use a **`LineIndex`**: it caches line-start offsets and maps a byte offset to `(line, column)` by binary search, with an O(1) sequential-access fast path for the common case of rendering diagnostics in source order.

## Gotchas

- **Keep `source` alive.** Every span is an offset into it; the AST and tokens are dangling without it.
- **Arena is all-or-nothing.** No node is freed individually; drop the arena to reclaim the tree.
- **`inherit` and other sugar are not stored literally** — they are rewritten at parse time (see [nix-syntax](nix-syntax.md)). Don't expect an `inherit` node in the tree.
- **Right-associativity is encoded as non-incremented precedence**, not a distinct node or flag; reading the tree, `->`/`//` simply nest right.
- **The speculative clone must stay side-effect-free** — it mutates only its private copy and emits no diagnostics; anything that gave it observable effects would double-report or mis-advance.

Code: `src/syntax/`
