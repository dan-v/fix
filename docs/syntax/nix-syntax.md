# Nix Surface Syntax

*The Nix-specific grammar the parser handles: strings, paths, `inherit`, patterns, dynamic attrs, operators — what each surface form desugars to.*

This doc covers *what* the parser recognizes and *what tree it produces* for Nix's non-obvious surface constructs. For *how* the parser works — Pratt climbing, Rule dispatch, the arena AST, speculative clones — see [parsing](parsing.md); it is not re-explained here. How these forms *compile and evaluate* is out of scope (see [`compiler/pipeline`](../compiler/pipeline.md)).

## Strings and interpolation

String literal extent-finding lives in `string_syntax`; the [scanner](parsing.md) emits one `string` token per literal and decoding into parts is deferred. A decoded literal is a `ParsedLiteral`: a sequence of `parts`, each either

- **`text`** — a run of literal characters, or
- **`interpolation: Span`** — the byte span of the inner `${ expr }` expression.

`text` parts carry an `owned` flag. When the source bytes are already the final text (no escapes to resolve) the part points directly into `source` with `owned = false`. When escapes had to be decoded, the resolved bytes are heap-allocated and `owned = true`. A `ParsedLiteral` is a rope of literal chunks and holes; the compiler compiles the holes as sub-expressions and concatenates.

**Double-quoted** `"..."` (`scanDoubleQuoted` / `parseLiteral`): escapes `\n \r \t \" \\`. `${` opens an interpolation; the extent scanner tracks nested `{`/`}` depth so `${ f { x = 1; } }` is one hole. A backslash-escaped `\${` is a literal `${`, not an interpolation — an "odd `$`" (a `$` not followed by `{`, or an escaped one) is plain text.

**Indented** `''...''` strings: same interpolation machinery, plus two extra transforms.
- **Dedentation**: every line's common leading indentation is stripped. The minimum indent across all non-blank lines is computed and removed from each line, so the literal's text is relative to its least-indented line — the standard Nix indented-string behavior.
- **Escapes are `''`-prefixed**: `''$` is a literal `$` (suppressing interpolation), `'' ` (two apostrophes + space form) escapes to a literal, and `''\` introduces a character escape. Ordinary `\` is *not* an escape inside `''...''`.

## Paths

Three path forms, all emitted as single tokens:

- **Literal path** — `./foo`, `/abs/path`, `../x`. The scanner extends the token with `isPathContinue` over the allowed path characters; a path must contain a `/`.
- **Interpolated path** — `./${v}/f`. Despite the embedded `${...}`, this is *one* `path` token: `findInterpolationEnd` skips over the interpolation while continuing the path scan, so the whole thing is a single literal with holes (like a string).
- **Search path** — `<nixpkgs>`, `<nixpkgs/lib>`. Emitted as a distinct `search_path` token/atom; resolution against the search path happens later.

## `inherit` desugaring

`inherit` is **rewritten at parse time** — there is no `inherit` node in the AST. Both forms lower to ordinary `Binding`s inside the enclosing attr-set or `let`:

- **Outer-scope** `{ inherit a b; }` → bindings `a = a; b = b;` where each `Binding` has `inherit_outer = true` and its expr references the same-named variable in the enclosing scope.
- **From-expr** `{ inherit (src) a b; }` → bindings `a = src.a; b = src.b;` (via `inheritSourceAttr`), with `inherit_outer = false` and the expr an attr access on the source expression.

The discriminator is exactly `inherit_outer = (source == null)`. `inherit` is valid in both attr-set bodies and `let` bindings, with the same lowering (`inheritAttrs` / `inheritLetBindings`). A missing `;` after an `inherit` triggers synchronization (see [parsing](parsing.md)), not a cascade.

## Lambda parameter patterns

Beyond the simple `x: body` (`lambda` node, `Lambda { param, body }`), Nix has attribute-set patterns, produced as `lambda_attrs` (`LambdaAttrs { bind_name?, params[], allow_extra, body }`):

- `{ a, b }:` — required formals; each formal is a `LambdaAttrParam { name, default? }`.
- `{ a, b ? d }:` — `b` has a default expression `d`.
- `{ a, ... }:` — trailing ellipsis sets `allow_extra = true` (accept and ignore surplus attrs).
- `args @ { a }:` and `{ a } @ args:` — an `@`-binding names the whole argument set; it may appear before or after the brace group. That name becomes `bind_name`.

Disambiguating a leading `{` between this pattern and an attribute-set expression requires the speculative lookahead described in [parsing](parsing.md) (`looksLikeAttrLambdaPattern`): the confirming `:` or `@` sits past the matching `}`.

## Dynamic attribute names and access

**Dynamic names in construction** — `{ ${k} = v; }` — a binding whose key is a computed expression rather than a static identifier. Mixed static/dynamic paths like `a.${k}.c = v;` are supported; the parser flattens what would otherwise be nested `attr_set` nodes into a single binding path carrying the dynamic segment(s) (`AttrDeclaration` tracks the static prefix length and the dynamic suffix), rather than materializing intermediate one-key attr sets.

**Access and membership** distinguish static vs dynamic segments:

- `attr_path` (`AttrPath { root, segments[] }`) — `a.b.c`, fully static access.
- `attr_dynamic` — access whose path includes a `${expr}` segment (`a.${k}`).
- `attr_or` — `x.y or default`: attribute access with a fallback expression parsed as an infix `or` after the path. (`or` here is the fallback keyword, distinct from the `||` boolean-or operator.)
- `has_attr` (`?`) — membership test `x ? a.b`. Variants `has_attr_dynamic` and `has_attr_mixed` cover paths whose segments are all-dynamic or a static/dynamic mix, respectively.

## Operator set

**14 binary operators**, mapped from tokens to `binary_op` (`Binary { op, left, right }`) via Rule dispatch with the precedences in the [parsing](parsing.md) ladder:

```
add +   sub -   mul *   div /
eq ==   neq !=
lt <    lte <=  gt >    gte >=
and &&  or ||   impl ->
update //   concat ++
```

`->` (`impl`) and `//` (`update`) are **right-associative** (encoded via non-incremented recursion precedence — see [parsing](parsing.md)); the rest are left-associative.

### Pipe operators (`|>` / `<|`)

`|>` and `<|` occupy the `pipe` rung (looser than everything above — even `->`). They are **not** in the 14 above: a pipe is pure sugar for function application, so instead of a `binary_op` node it lowers to an ordinary `apply` tagged with its surface form (`Apply.pipe` = `.forward`/`.backward`), which reuses the whole application path in the compiler and evaluator and lets a printer spell the node back faithfully. Operands are stored in evaluation order (`func`, `arg`):

- `x |> f` == `f x` — **left**-associative → `apply(func=f, arg=x, .forward)`
- `f <| x` == `f x` — **right**-associative → `apply(func=f, arg=x, .backward)`

Both always parse, but compiling one requires the `--pipe-operators` feature; otherwise the compile chokepoint rejects the file *on presence* (like Nix — an unused/deferred binding still fails), pointing the diagnostic at the operator. The gate lives in `Evaluator.parseAndCompile`; the flag is documented in [cli](../cli.md).

**Unary operators** (`unary_op`, `Unary { op, expr }`): logical `!` and arithmetic negation `-`.

## List juxtaposition restriction

Inside `[ ... ]`, elements are parsed with function application **disabled** (`allow_apply = false`): adjacent expressions are separate list elements, not an application. Consequently a bare `if`/`let`/lambda/`!`/`-` — anything that would greedily consume following tokens as an application argument or extend ambiguously — is **not** permitted as an unparenthesized list element; it must be wrapped in `( ... )`. This matches Nix, where `[ f x ]` is a two-element list, not `[ (f x) ]`.

Code: `src/syntax/`
