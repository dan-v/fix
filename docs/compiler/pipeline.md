# Compiler Pipeline

*Single-pass AST → bytecode lowering: node-tag dispatch across domain modules, buffered into an immutable Chunk.*

## Mental model

The compiler is a **recursive tree-walk that emits [bytecode](../vm/dispatch.md) as it descends** — no separate IR, no optimization pass over a built graph. `Compiler.compile()` dispatches on the [AST `Node.tag`](../syntax/parsing.md) and hands each node to the module that owns its shape. Emission is *stack-oriented*: every node lowers to a sequence that leaves exactly one value on the VM operand stack. Sub-expressions are compiled left-to-right; the parent emits its own op after its children.

A `Compiler` instance compiles **one chunk** (one function body / thunk body / file body). Nested bodies (thunks, lambdas, deferred attrs) spawn a **child Compiler** linked by `parent` — the chain drives [name resolution and capture](scopes.md). Scratch state (locals, captures, diagnostics) lives on an arena and dies with the unit; only bytecode, constants, and the source map are duped onto the persistent allocator.

## Dispatch → domain modules

| Node family | Module | Lowers |
| --- | --- | --- |
| int / float / string / path / identifier | `literals` | immediates, interpolation, path resolution, `id → local`/`upvalue`/`with` |
| binary / unary / apply / lambda / let | `ops` | operators, calls, closures, `let` bindings; constant-folds; `call_n` flattening |
| if / assert / with | `control` | branch/join, assertion guard, dynamic-scope push |
| attrset (static/dynamic/rec/inherit) | `attrs` | attr construction, merge, deferred-set gating |
| attr access / `?` has-attr | `access` | static/dynamic/mixed attr paths, `or`-defaults |
| low-level byte emission + fusion | `emit` | opcode + LE operand writes, super-op fusion, jump patching |

`ops.zig` is the high-level node→ops layer; `emit.zig` is the low-level layer. Domain modules call `emit` to write bytes; `emit` never walks the AST.

## ChunkBuilder → Chunk

`ChunkBuilder` accumulates, during the walk:

- **code** — opcode bytes + little-endian operands.
- **constants** — a pool of [`Value`s](../runtime/values.md); ops reference by index. Duplicate literals may be pooled.
- **function_args** — attrset-pattern parameter names, retained for `builtins.functionArgs`.
- **source_map** — `bytecode byte-range → SourceSpan` entries, emitted at `compileNode` exit; runtime stack traces bind a program counter back to file/line/col.
- **fusion_savings** — bytes elided by `_ret` rewrites (see below).

At **finish** (`ChunkBuilder.finish`), in one pass:

1. **Strictness stamp** — [must-force upvalue masks](strictness.md) computed and written into `SchedulingHints`.
2. **Trivial-body classify** — the finished body is matched against ~8 shapes once (see [runtime/thunks.md](../runtime/thunks.md)); safe because thunk bodies have `local_count == 0`.
3. **Register** — `ChunkRegistry.register` assigns a sequential immutable `ChunkId` and (if `-Djit`) installs a native entry point.

The frozen **Chunk** carries: `code`, `constants`, `arity`, `local_count`, per-param strictness, `SchedulingHints` (strictness masks + `body_is_substantial` + `trivial` + `strict_param`), `function_args`, `source_map`, and JIT slots.

```
ChunkBuilder (mutable, arena)                 Chunk (immutable, persistent)
  code[] constants[] function_args[]   finish   code arity local_count
  source_map[] fusion_savings          ──────▶  strict-params SchedulingHints
  + strictness stamp + trivial classify         source_map jit-slots  → ChunkId
```

## Constant folding & call_n flattening

- **Constant folding** — arithmetic/comparison over literal operands is evaluated at compile time in `ops`, emitting a single `constant` instead of the op sequence.
- **`call_n` flattening** — a curried application spine `f a b c` normally lowers to nested `call`s (one frame per argument). When the callee is an **arity-matched uncurried (merged) lambda**, the spine is flattened to a single `call_n K`: K args pushed, body run in **one frame**. Each spine argument compiles as a plain lazy thunk; the saturated `call_n` path then eagerly forces the argument positions the callee's per-param strictness marks must-force. Non-matching applications keep the nested `call` form.

## Super-op fusion (in `emit`)

Fusion rewrites the *last emitted op in place* when the next emission completes a known pattern — no peephole pass. It is byte-for-byte behavior-preserving; the fused op is a single [dispatch](../vm/dispatch.md) instead of two.

- `<op> + ret` → `<op>_ret` (`constant_ret`, `get_upvalue_ret`, `get_local_ret`) — the value-producing op returns directly, skipping a standalone `ret`.
- `get_upvalue + get_attr` → `get_upvalue_attr`; `get_local + get_attr` → `get_local_attr` — fuses only when the attr name is a static InternId (not dynamic/interpolated).
- `thunk_captures + set_local` → `*_store_local` / `*_store_cell_local` — fused thunk-create-and-store, for 1-byte (narrow) slots only.

Every rewrite that shrinks the code adds the saved bytes to **`fusion_savings`**, which is added back to `code.len` when deciding `body_is_substantial` — so the [speculation](../parallel/speculation.md) size threshold stays calibrated after `_ret` collapses a body.

## Tail-position lowering

`compileTailExpression` compiles an expression in tail position: instead of computing a value and returning, terminal calls emit **`tail_call`** (reuse the current frame). It routes the terminal branch of each control form to a `_tail` variant so tail position propagates through them:

- `apply` → `tail_call` (or `tail_call_n` for a flattened saturated spine).
- `if` → `compileIfElseTail` (both branches tail).
- `let` → body compiled in tail position.
- `assert` → `compileAssertTail` (body tail, guard unchanged).
- `with` → `compileWithTail` (body tail after scope push).

Lambda and thunk bodies are compiled via `compileTailExpression`, so a body ending in a call becomes a tail call.

## Lowering notes by family

**attrs** — static keys build the attrset directly; dynamic/interpolated keys emit `get_attr_dynamic`-family construction; `rec` sets self-reference via cells so bindings see each other; `inherit` (plain and `inherit (e)`) copies named attrs from the current scope or a source expression. Large file-scope generated sets may defer per-attr compilation — see [lazy-compile.md](lazy-compile.md).

**access** — a static dotted path `a.b.c` lowers to one `get_attr_path` super-op over a packed segment operand; a path containing interpolation lowers to `get_attr_path_mixed`; a single dynamic key lowers to `get_attr_dynamic`. `or`-defaults get `*_or` variants carrying the fallback as a thunk. `?` has-attr mirrors the static/dynamic/mixed split.

**control** — `if` emits jump-if-false + forward jumps patched at join; `assert` emits a guard that raises on false then falls through to the body; `with` pushes the scope expr as a cell onto the dynamic-scope chain, compiles the body, then pops.

**literals** — ints box to inline i48 or a `boxed_int` constant; floats route through canonical-NaN `float()`; string interpolation lowers each part (literal chunk vs interpolated sub-expr thunk) and concatenates; path literals resolve against the compiler's `base_path` at compile time (absolute/relative), preserving trailing-slash semantics; an identifier resolves in order **local slot → upvalue capture → `with` dynamic lookup**, emitting `get_local` / `capture_upvalue` / `lookup_with` respectively (see [scopes.md](scopes.md)).

## Diagnostics

`Compiler.diagnostics` is arena-backed. A `LineIndex` per compile unit binary-searches `offset → line/col`. On a child-compile error, `absorbChildDiagnostics` merges the child's diagnostics into the parent before propagating, so nested-body errors surface with full context.

## Invariants

- **Single value per node.** Every lowered node nets exactly one value on the operand stack.
- **Emit never re-reads the AST.** `emit` sees only opcodes/operands; all tree knowledge is in the domain modules.
- **Classify/stamp run once, at finish**, over the frozen body.
- **Persistent vs scratch.** Bytecode/constants/source-map are duped and outlive the unit; locals/captures/diagnostics die with the arena.
- **ChunkIds are sequential and immutable.** Registration order is stable; a registered Chunk is never mutated.

Out of scope: how opcodes execute → [vm/dispatch.md](../vm/dispatch.md); name resolution → [scopes.md](scopes.md); strictness masks → [strictness.md](strictness.md); deferral/trivial short-circuits → [lazy-compile.md](lazy-compile.md).

Code: `src/compiler/`
