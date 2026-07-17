# Compiler Pipeline

*Single-pass AST → bytecode lowering: node-tag dispatch across domain modules, buffered into an immutable Chunk.*

## Mental model

The compiler is a **recursive tree-walk that emits [bytecode](../vm/dispatch.md) as it descends** — no separate IR, no optimization pass over a built graph. `Compiler.compileNode()` dispatches on the [AST `Node.tag`](../syntax/parsing.md) and hands each node to the module that owns its shape. Emission is *stack-oriented*: every node lowers to a sequence that leaves exactly one value on the VM operand stack. Sub-expressions are compiled left-to-right; the parent emits its own op after its children.

A `Compiler` instance compiles **one chunk** (one function body / thunk body / file body). Nested bodies (thunks, lambdas, deferred attrs) spawn a **child Compiler** linked by `parent` — the chain drives [name resolution and capture](scopes.md). Scratch state (locals, captures, diagnostics, strictness maps) lives on a per-unit arena and dies with the unit; only bytecode, constants, and the source map are duped onto the persistent allocator at `finish`.

## Dispatch → domain modules

`driver.compileNodeImpl` is the recursive dispatch switch; `context.zig` owns compiler state and carries the driver callback used by child compilers. High-level node compilers live in cohesive sibling modules and the driver imports each owner directly.

| Node family | Module | Lowers |
| --- | --- | --- |
| int / float / string / path / search-path / identifier | `literals` | immediates, interpolation (`str_cat`), path resolution, `id → local`/`upvalue`/`with` |
| bool / null | (inline) | a single `push_true`/`push_false`/`push_null` op |
| binary / unary | `fold` | operators; compile-time constant folding |
| apply / lambda / lambda_attrs | `lambda` | calls, value-lambda uncurrying, attrset-pattern lambdas, `call_n`/`call_tail_n` spine flattening |
| let | `let` | `let` binding classification, cell elision, eager elision |
| if / assert / with | `control` | branch/join, assertion guard, dynamic-scope push |
| attrset (static/dynamic/rec/inherit) | `attrs` | attr construction, merge, `inherit`, deferred-set gating |
| attr access / `?` has-attr / list | `access` | static/dynamic/mixed attr paths, `or`-defaults, list building |
| free-variable collection | `refs` | conservative name-set walk shared by `let`/`lambda` classification |
| name resolution & capture | `scope` | local slots, upvalue threading, `with`-scope collection |
| must-force analysis + stamp | `strictness` | strictness masks, per-param must-force, body span |
| low-level byte emission + fusion | `emit` | opcode + LE operand writes, super-op fusion, jump patching |

Domain modules call `emit` to write bytes; `emit` sees only opcodes/operands and never walks the AST.

## ChunkBuilder → Chunk

`ChunkBuilder` accumulates, during the walk:

- **code** — opcode bytes + little-endian operands.
- **constants** — a pool of [`Value`s](../runtime/values.md); ops reference by index.
- **function_args** — attrset-pattern parameter names + a has-default flag, retained for `builtins.functionArgs`.
- **source_map** — sparse `bytecode byte-range → SourceSpan` entries, added at `compileNode` exit; runtime stack traces bind a program counter back to file/line/col.
- **body_span** — a single representative span for the whole body, stamped even when `source_map` is empty (it is sparse). Labels a thunk quantum / demand wait in the timeline.
- **fusion_savings** — bytes elided by fusion rewrites (see below).
- **strictness / strict_param / strict_via_upvalue / arity / strict_params** — scheduling metadata written by the `strictness` stamp and `compileLambda` before `finish`.

The strictness stamp (`strictness.stampOnBuilder`) runs at the **end of body compilation**, before `finish`: it computes the [must-force upvalue masks](strictness.md) and records `body_span`.

At **finish** (`ChunkBuilder.finish`), in one pass, the builder freezes into an immutable **Chunk**:

1. **body_is_substantial** — `code.len + fusion_savings + sideTableWeight() ≥ speculation_min_code_bytes` (256), gating [speculation](../parallel/speculation.md); `sideTableWeight` re-adds the bytes the attr-name/position side tables moved out of the code stream, mirroring their old inline encodings.
2. **Trivial-body classify** — the finished body is classified once into a `TrivialBody` variant, else `none` (see [lazy-compile.md](lazy-compile.md) and [runtime/thunks.md](../runtime/thunks.md)); safe because thunk bodies have `local_count == 0`.
3. The strictness masks, `strict_param`, `strict_via_upvalue`, `arity`, and `strict_params` are copied through into the Chunk.

The caller then registers the frozen Chunk: `ChunkRegistry.register` assigns a **sequential, immutable `ChunkId`** (a lock-free `appendAtomic` cursor bump) and caches the hot scheduling metadata (`trivial`, `body_is_substantial`, `strict_param`, `strict_via_upvalue`) in a dense per-chunk `ChunkSlot` so the thunk-creation path reads it without chasing the Chunk pointer.

The frozen **Chunk** carries: `code`, `constants`, `local_count`, `arity`, `strict_params` (per-param must-force bitmask for uncurried chunks), `SchedulingHints` (`strictness` masks + `body_is_substantial` + `trivial` + `strict_param` + `strict_via_upvalue`), `function_args`, `source_map`, and `body_span`.

```
ChunkBuilder (mutable, arena)                 Chunk (immutable, persistent)
  code[] constants[] function_args[]  stamp   code arity local_count
  source_map[] fusion_savings         ─────▶   strict_params SchedulingHints
  + strictness masks + body_span      finish    source_map body_span  → ChunkId
```

## Constant folding & call_n flattening

- **Constant folding** (`fold.zig`) — arithmetic, comparison, and unary (`!`, negation) operators over fully-literal operands are evaluated at compile time, emitting a single `push_const` instead of the op sequence; nested `&&`/`||`/`->` fold too when both sides are literal, but a top-level `&&`/`||`/`->` compiles to short-circuit branch code. Division and any i64-overflowing arithmetic are never folded: `{ x = 1/0; }` is valid Nix and must throw only when `.x` is forced, so folding stays conservative.
- **`call_n` flattening** (`lambda.zig`) — a curried application spine `f a b c` normally lowers to nested `call`s (one frame per argument). For `K ≥ 2` the spine is flattened to a single `call_n K`: the callee is compiled, then K args pushed, then `call_n K`. When the callee is an **arity-matched uncurried (merged) lambda** the body runs in **one frame** with no intermediate closure/PAP allocation; a non-matching callee folds one arg at a time (same result). Each spine argument compiles as an immediate container value or a plain lazy thunk (not the runtime-adaptive `thunk_arg`, whose callee probe is only valid for the first arg); the saturated `call_n` path then eagerly forces the argument positions the callee's `strict_params` mark must-force. `K == 1` keeps the single-arg path (eager-strict-arg + tail-call frame reuse).

## Super-op fusion (in `emit`)

Fusion rewrites the *last emitted op in place* when the next emission completes a known pattern — no peephole pass. It is byte-for-byte behavior-preserving; the fused op is a single [dispatch](../vm/dispatch.md) instead of two.

- `<op> + ret` → `<op>_ret` (`push_const_ret`, `up_get_ret`, `loc_get_ret`, `loc_get_ret_w`) — the value-producing op returns directly, skipping a standalone `ret`.
- `up_get + attr_get` → `up_get_attr`; `loc_get + attr_get` → `loc_get_attr` / `loc_get_attr_w` — fuses only when the attr name is a static InternId that fits in `u16`.
- `thunk(_eag)(_w) + loc_set`/`cell_set` → `*_st` / `*_st_cell` — fused thunk-create-and-store (the destination slot byte is appended at the end of the operand). Fuses for 1-byte (narrow) slots only, but for **both** chunk-id widths — past 65,536 registered chunks the wide encoding is the dominant form.

A branch fixup (`patchJump`) that lands at the current write position drops the `last_op_offset` fusion hint, so a multi-predecessor join never fuses across control flow.

The `*_get_attr` and `*_st(_cell)` rewrites each add their one saved byte to **`fusion_savings`** (the `<op>_ret` rewrite does not); `fusion_savings` is added back to `code.len` when deciding `body_is_substantial`, so the [speculation](../parallel/speculation.md) size threshold measures the pre-fusion body size. String-interpolation lowering (`literals.zig`) also adjusts `fusion_savings` so a `str_cat` body keeps the scheduling weight of its unfused encoding.

## Tail-position lowering

`compileTailExpression` compiles an expression in tail position: instead of computing a value and returning, terminal calls emit **`call_tail`** (reuse the current frame). It routes the terminal branch of each control form to a `_tail` variant so tail position propagates through them:

- `apply` → `call_tail` (or `call_tail_n` for a flattened saturated spine).
- `if` → `compileIfElseTail` (both branches tail).
- `let` → body compiled in tail position.
- `assert` → `compileAssertTail` (body tail, guard unchanged).
- `with` → `compileWithTail` (body tail after scope push).

Lambda bodies (`compileLambda` / `compileLambdaAttrs`) enter `compileTailExpression`, so a lambda body ending in a call becomes a tail call and tail position then propagates through the forms above. Thunk bodies and the file body compile through `compileNode` (not tail position), so a trailing call there is a plain `call`.

## Lowering notes by family

**attrs** — static keys build the attrset directly, with entries emitted in ascending interned-name order so the runtime skips the sort + dedup: the attr names (plus source positions when the unit is file-attributed) ride the chunk's side tables rather than the code stream (`attrs_new_named_srt` / `attrs_new_named_pos_srt`; the empty literal is a bare `attrs_new_srt 0`); dynamic/interpolated keys emit runtime construction (`attrs_new`); `rec` sets self-reference via cells so bindings see each other; `inherit` (plain and `inherit (e)`) copies named attrs from the current scope or a source expression. A multi-name `inherit (e)` clause creates one hidden lazy source local and frameless member-access thunks, so `e` is compiled and evaluated once for the whole clause. Large file-scope generated sets may defer per-attr compilation — see [lazy-compile.md](lazy-compile.md).

**access** — a static dotted path `a.b.c` compiles the root then emits one `attr_get` per segment (the first fusing into `loc_get_attr` / `up_get_attr`); an interpolated segment emits `attr_get_dyn`. Before emitting those ops, a path rooted at a simple non-recursive static attr literal is resolved in the compiler: only the selected RHS is compiled, nested literals recurse, and `literal ? name` becomes a boolean constant without compiling or forcing any member. Dynamic keys, nested-path merging, recursion, and missing selections fall back to the general path. `or`-defaults use packed segment super-ops carrying the fallback as a thunk: `attr_get_path_or` (all-static path), `attr_get_path_mix_or` (interpolated), `attr_get_dyn_or` / `attr_get_path_dyn_or` (dynamic key). `?` has-attr mirrors the split with `attr_has_path` / `attr_has_path_mix` over a packed segment operand. Lists build via `list_new`.

**control** — `if` emits `jump_false` + a forward `jump` patched at join; `assert` compiles the condition then `jump_false` over the body to a `fail` tail, falling through to the body when the condition holds; `with` compiles the scope subject as a thunk bound to an anonymous frame-local slot, registers that slot on the `with_scopes` chain, compiles the body, then pops the scope.

**literals** — ints box to inline i48 or a `boxed_int` constant; floats route through canonical-NaN `float()`; string interpolation lowers each part (literal chunk vs interpolated sub-expr thunk) and concatenates via `str_cat`; path literals resolve against the compiler's `base_path` at compile time (absolute paths via `std.fs.path.resolve`, relative paths joined onto `base_path`); `__curPos` lowers to a `{ file; line; column; }` attrset built at the current source position (or `push_null` when the unit has no `source_path`). An identifier resolves in order **local slot → upvalue capture → the literal `builtins` → ambient builtin → `with` lookup**, emitting `loc_get` / `up_get` / `push_builtins` / (a `builtin` constant or `push_builtins` + `attr_get`) / `with_lookup`; an unresolved name is a compile error (see [scopes.md](scopes.md)).

## Diagnostics

`Compiler.diagnostics` is arena-backed. A `LineIndex` per compile unit binary-searches `offset → line/col`. On a child-compile error, `absorbChildDiagnostics` merges the child's diagnostics into the parent before propagating, so nested-body errors surface with full context.

## Invariants

- **Single value per node.** Every lowered node nets exactly one value on the operand stack.
- **Emit never re-reads the AST.** `emit` sees only opcodes/operands; all tree knowledge is in the domain modules.
- **Stamp before finish; classify at finish**, both over the frozen straight-line body.
- **Persistent vs scratch.** Bytecode/constants/source-map are duped and outlive the unit; locals/captures/diagnostics/strictness maps die with the arena.
- **ChunkIds are sequential and immutable.** Registration order is stable; a registered Chunk is never mutated.

Out of scope: how opcodes execute → [vm/dispatch.md](../vm/dispatch.md); name resolution → [scopes.md](scopes.md); strictness masks → [strictness.md](strictness.md); deferral/trivial short-circuits → [lazy-compile.md](lazy-compile.md).

Code: `src/expr/compiler/`
