# Scopes & Name Resolution

*Resolving every identifier to a local slot, an upvalue capture, or a lazy `with` lookup.*

## Mental model

An identifier reference resolves against a **chain of Compilers** (one per enclosing body, linked by `parent`), driven by `literals.compileIdent`. The bare word `__curPos` is intercepted first: it lowers to a `{ file; line; column; }` attrset (`compileCurPos`), or `push_null` when the compiler has no source path. Otherwise resolution tries, in order:

1. **Local** — a binding declared in *this* chunk (`let` name, lambda param, `rec`-attr cell). Emits `loc_get` (`loc_get_w` when the slot exceeds 255), which reads the value at `frame_base + slot` **and forces it**.
2. **Upvalue** — a binding in an *enclosing* chunk. Captured through every intervening body as a chunk-relative upvalue index; emits `up_get`, which reads the closure upvalue **and forces it**. Both reads force because a bare identifier is a value being consumed now — the non-forcing `*_grab` reads (below) exist only for building environments.
3. **`builtins` / ambient builtin** — the bare name `builtins` emits `push_builtins`; an ambient builtin name (`emitAmbientBuiltin`) emits either a builtin-value constant (`builtins.ambientIdForName`) or `push_builtins` + `attr_get` (`builtins.hasConstant`).
4. **`with` scope** — no static binding found; falls back to a runtime `with_lookup` over the dynamic-scope chain.
5. **Unbound** → compile error (`error.UndefinedVariable`).

Locals and captures live on the arena and vanish at unit end; only the **capture descriptors** baked into thunk/closure ops persist.

## Locals & slot allocation

A `Local` is `{ name, name_id, depth, slot }`:

- **slot** — a monotonic frame-base offset from `declareLocal` (linear bump of `slot_count`; the final `slot_count` becomes the Chunk's `local_count`).
- **depth** — the `scope_depth` at declaration.

`beginScope` / `endScope` bump/restore `scope_depth`; `endScope` pops every local whose `depth` exceeds the restored `scope_depth` (a `while`-pop off the tail). Slots are **not** reused within a chunk.

**Resolution** (`resolveLocal` / `resolveLocalId`) scans locals **top-down** (innermost declaration wins → shadowing is free). Id-based resolution compares interned `name_id`s up the chain rather than re-comparing source bytes at every level — the hot path for non-local references.

**Inherit skip slot.** A plain `inherit name;` in a `let` or `rec` attrset binds `name` to the value of `name` from the *enclosing* scope, but `name` is simultaneously being declared as a local cell in this chunk. While compiling that binding's RHS (the reference to the outer `name`), `skip_local_slot` holds the slot being written; `resolveLocal` / `resolveLocalId` skip it, so the reference resolves to the enclosing binding (parent local / upvalue / `with`) rather than to the self-referential cell it is being stored into. Set only for `inherit_outer` bindings — `inherit name;` with no source — because `inherit (e) name;` compiles as `e.name` and needs no skip (`let.zig`, `attrs.zig`).

## Upvalue capture chain

When a name isn't local, `resolveCapture[Id]` walks the parent chain:

- Found in a **parent's locals** → `addCapture(.local, parent_slot)` — capture the parent's frame slot.
- Found in a **parent's captures** → `addCapture(.upvalue, parent_upvalue)` — re-capture the parent's own upvalue, threading it down one level.

`addCapture[Id]` **dedups** by `(kind, index, name_id)`: a name referenced twice reuses one upvalue index. The returned index is **chunk-relative** (`0..K-1` for a K-capture body).

At a capturing site the compiler emits a **descriptor** per upvalue: a 3-byte `(1-byte kind {0=local, 1=upvalue}, 2-byte index)`. The runtime reads descriptors to build the closure/thunk environment — slot `index` from the parent frame (`.local`) or upvalue `index` from the parent's environment (`.upvalue`). Descriptor arrays are emitted at:

- **`thunk`** — a lazy thunk's captured environment.
- **`closure_cap`** — a lambda closure's captured environment.
- **`thunk_arg`** — an adaptive function-argument thunk.
- **`thunk_defer`** — a [deferred attr body's](lazy-compile.md) snapshot environment.

## `up_grab` vs `up_get`

Two ways to read an upvalue at runtime, with different force semantics:

| Op | Semantics | Use |
| --- | --- | --- |
| `up_grab` | copies the upvalue **as-is** (thunk stays a thunk) | building a captured environment; laziness preserved |
| `up_get` | **forces on read** — the upvalue is a thunk that gets evaluated | reading a value the op is about to consume |

Rule of thumb: **environment construction must use `up_grab`**, so entries meant to stay lazy are not forced before their cell is published (forcing a binding early blackholes recursive attrset patterns); `up_get` is only for a value being consumed now — which is why a bare identifier reference (section above) emits `up_get`.

## `with`: dynamic scope

`with e; body` introduces a scope resolved **at runtime**, because `e`'s attribute set isn't known statically.

- The scope expr is pushed as a cell onto the compiler's `with_scopes` (LIFO).
- An identifier that fails local+upvalue resolution emits **`with_lookup`**: a scope snapshot (the active `with`-scope cells, as `loc_grab` / `up_grab` ops) plus the target `name_id` and scope count. The runtime **walks the `with`-scopes lazily** — innermost first — forcing each only as needed to test membership.
- **Nested `with`.** `collectWithScopes` gathers active scopes from self *and* parents; parent `with`-scopes are **re-captured as upvalues** (via `addCapture` under the reserved `with_capture_name`) so a nested body can still see an outer `with`. Snapshots compose down the chain.

Statically-bound names always win over `with` (Nix scoping): `with` is consulted only after local and upvalue resolution both miss.

## Invariants

- **Thunk bodies have `local_count == 0`** — a thunk captures its free variables as upvalues and declares no locals. (This is what makes the [trivial-body classifier](lazy-compile.md) sound.)
- **Lambda bodies have `local_count ≥ arity`** — parameters are locals; an uncurried arity-K lambda has ≥ K local slots.
- **Upvalue indices are chunk-relative**, dense `0..K-1`, assigned in first-reference order after dedup.
- **Slots are not reused** within a chunk; `endScope` only pops the tail for resolution correctness, it does not compact.
- **Scratch is arena-scoped.** Locals and captures are freed at unit end; only the emitted descriptors persist in bytecode.

Out of scope: how `with_lookup` / `up_grab` / `up_get` execute → [vm/access.md](../vm/access.md) and [vm/calls.md](../vm/calls.md); which upvalues get pre-forced → [strictness.md](strictness.md); node dispatch → [pipeline.md](pipeline.md).

Code: `src/expr/compiler/`
