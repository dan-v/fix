# Scopes & Name Resolution

*Resolving every identifier to a local slot, an upvalue capture, or a lazy `with` lookup.*

## Mental model

An identifier reference resolves against a **chain of Compilers** (one per enclosing body, linked by `parent`). Resolution tries, in order (`literals.compileIdent`):

1. **Local** — a binding declared in *this* chunk (`let` name, lambda param, `rec`-attr cell). Emits `get_local`, read directly by frame-base slot.
2. **Upvalue** — a binding in an *enclosing* chunk. Captured through every intervening body as a chunk-relative upvalue index; emits `get_upvalue` (forces on read — the reference is a value being consumed).
3. **`builtins` / ambient builtin** — the bare name `builtins`, or a name the evaluator injects ambiently, lowers to `push_builtins` / the matching builtin.
4. **`with` scope** — no static binding found; falls back to a runtime `lookup_with` over the dynamic-scope chain.
5. **Unbound** → compile error (`UndefinedVariable`).

Locals and captures live on the arena and vanish at unit end; only the **capture descriptors** baked into thunk/closure ops persist.

## Locals & slot allocation

A `Local` is `{ name, name_id, depth, slot }`:

- **slot** — a monotonic frame-base offset from `declareLocal` (linear bump of `slot_count`; the final `slot_count` becomes the Chunk's `local_count`).
- **depth** — the `scope_depth` at declaration.

`beginScope` / `endScope` bump/restore `scope_depth`; `endScope` pops every local whose `depth` exceeds the restored `scope_depth` (a `while`-pop off the tail). Slots are **not** reused within a chunk.

**Resolution** (`resolveLocal` / `resolveLocalId`) scans locals **top-down** (innermost declaration wins → shadowing is free). Id-based resolution compares interned `name_id`s up the chain rather than re-comparing source bytes at every level — the hot path for non-local references.

**Pattern skip slot.** Attrset-pattern parameters (`{ a, b } @ args: …`) reserve a slot that must not shadow the fields it binds during their own compilation. `skip_local_slot` names that slot; `resolveLocal*` skips it, so a field default referencing a sibling resolves to the sibling, not the pattern binder.

## Upvalue capture chain

When a name isn't local, `resolveCapture[Id]` walks the parent chain:

- Found in a **parent's locals** → `addCapture(.local, parent_slot)` — capture the parent's frame slot.
- Found in a **parent's captures** → `addCapture(.upvalue, parent_upvalue)` — re-capture the parent's own upvalue, threading it down one level.

`addCapture[Id]` **dedups** by `(kind, index, name_id)`: a name referenced twice reuses one upvalue index. The returned index is **chunk-relative** (`0..K-1` for a K-capture body).

At a capturing site the compiler emits a **descriptor** per upvalue: `(kind:1 bit, index)`. The runtime reads descriptors to build the closure/thunk environment — slot `index` from the parent frame (`.local`) or upvalue `index` from the parent's environment (`.upvalue`). Descriptor arrays are emitted at:

- **`thunk_captures`** — a lazy thunk's captured environment.
- **`closure_captures`** — a lambda closure's captured environment.
- **`apply_arg`** — an adaptive function-argument thunk.
- **`defer_attr_value`** — a [deferred attr body's](lazy-compile.md) snapshot environment.

## `capture_upvalue` vs `get_upvalue`

Two ways to read an upvalue at runtime, with different force semantics:

| Op | Semantics | Use |
| --- | --- | --- |
| `capture_upvalue` | copies the upvalue **as-is** (thunk stays a thunk) | building a captured environment; laziness preserved |
| `get_upvalue` | **forces on read** — the upvalue is a thunk that gets evaluated | reading a value the op is about to consume |

Rule of thumb: **environment construction must use `capture_upvalue`**, so entries meant to stay lazy are not forced before their cell is published (forcing a binding early blackholes recursive attrset patterns); `get_upvalue` is only for a value being consumed now — which is why a bare identifier reference (section above) emits `get_upvalue`.

## `with`: dynamic scope

`with e; body` introduces a scope resolved **at runtime**, because `e`'s attribute set isn't known statically.

- The scope expr is pushed as a cell onto the compiler's `with_scopes` (LIFO).
- An identifier that fails local+upvalue resolution emits **`lookup_with`**: a scope snapshot (the active `with`-scope cells, as `capture_local` / `capture_upvalue` ops) plus the target `name_id` and scope count. The runtime **walks the `with`-scopes lazily** — innermost first — forcing each only as needed to test membership.
- **Nested `with`.** `collectWithScopes` gathers active scopes from self *and* parents; parent `with`-scopes are **re-captured as upvalues** (via `addCapture` under the reserved `with_capture_name`) so a nested body can still see an outer `with`. Snapshots compose down the chain.

Statically-bound names always win over `with` (Nix scoping): `with` is consulted only after local and upvalue resolution both miss.

## Invariants

- **Thunk bodies have `local_count == 0`** — a thunk captures its free variables as upvalues and declares no locals. (This is what makes the [trivial-body classifier](lazy-compile.md) sound.)
- **Lambda bodies have `local_count ≥ arity`** — parameters are locals; an uncurried arity-K lambda has ≥ K local slots.
- **Upvalue indices are chunk-relative**, dense `0..K-1`, assigned in first-reference order after dedup.
- **Slots are not reused** within a chunk; `endScope` only pops the tail for resolution correctness, it does not compact.
- **Scratch is arena-scoped.** Locals and captures are freed at unit end; only the emitted descriptors persist in bytecode.

Out of scope: how `lookup_with` / `capture_upvalue` / `get_upvalue` execute → [vm/access.md](../vm/access.md) and [vm/calls.md](../vm/calls.md); which upvalues get pre-forced → [strictness.md](strictness.md); node dispatch → [pipeline.md](pipeline.md).

Code: `src/compiler/`
