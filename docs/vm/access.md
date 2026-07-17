# VM Access & Value Operations

*Reading structured data fast, and the value operators: merge, concat, deep equality, string composition.*

Attribute selection is one of the most frequent operations in NixOS module evaluation (`config.foo`, `lib.bar`, attrset-pattern lookups everywhere). This doc covers how the VM reads attrsets and lists cheaply, and how the structural operators (`//`, `++`, `==`, string `+`) execute. The data *layouts* live in [runtime/heap.md](../runtime/heap.md); this is about the operations over them.

## Attribute access

Attrsets are stored as arrays of `(InternId, Value)` entries kept **sorted by name id**, so a lookup is a **binary search** (`heap.getAttrValue`). Names are interned ([runtime/interning.md](../runtime/interning.md)), so comparison is an integer compare. Access opcodes:

| op | stack / operand | behavior |
|---|---|---|
| `attr_get` (`_w`) | `[attrs]`, name id operand | force attrs, binary-search name, force + push the value. |
| `attr_get_dyn` | `[attrs, name]` | name is a runtime string; force it to an `InternId`, then as `attr_get`. |
| `attr_get_dyn_or` | `[attrs, name, default]` | dynamic select with a lazy default if missing / non-attrs. |
| `attr_get_path_or` (`_w`) | `[attrs, default]`, N static ids | walk N segments; any missing segment ⇒ force+return the default. |
| `attr_get_path_dyn_or` (`_w`) | `[attrs, name, default]` | static prefix + one trailing runtime-string segment. |
| `attr_get_path_mix_or` | `[attrs, dyn…, default]` | mixed static/runtime path; a per-segment tag byte says static (inline id) or dynamic (next stack value). |
| `attr_has_path` (`_w`) / `attr_has_path_mix` | `[attrs, …]` | existence test (`?`) **without forcing** the final value; a single-segment `attr_has_path` covers the plain `attrs ? name` case. |
| `attr_bind` (`_w`) | `[attrs]`, sorted `(formal id, local slot)` pairs | merge-walk an attrset-pattern argument once, reject missing/unexpected names, and bind required values without per-formal lookup thunks. |
| `with_lookup` (`_w`) | `[scope1…scopeN]`, name id | resolve a name through active `with`-scopes, nearest first; `UndefinedVariable` if none has it. |

Each path walk keeps the root attrs value (and the default) on the operand stack for the whole helper (`getAttrPathOrValue` and siblings); intermediate path nodes are not separately rooted — they are transitively reachable from that on-stack root (attr thunks memoise in place), which is what keeps the walk correct across a [collection](../gc.md). The walk itself goes through `cachedAttrLookup`, not the forcing `getAttrValue` wrapper: it forces each intermediate node explicitly between segments.

### Attr inline cache

`cachedAttrLookup` fronts every lookup with a thread-local IC (8192 slots): `(heap_token, obj_id, name_id) → raw Value` (pre-force). A hit returns the raw attr value and skips the binary search; the caller forces it if it needs WHNF. The index mixes `obj_id` and `name_id` so `x.a` and `x.b` on the same object land in different slots. `heap_token`-guarded — the cache is per-worker and object ids are not stable across evaluators, so a token mismatch invalidates the slot. STW GC walks each registered worker's live (token-matching) slots as roots.

A cache **miss** is also the trigger point for the **demand-sibling prefetch** (`maybeSiblingSweep`): the first touch of a member on a demand fiber, when that member is still an unresolved thunk, can submit one speculative whole-set sweep task that forces the set's *other* members ahead of demand (size-gated and deduped once per set). The sweep forces speculatively, so it stays demand-invisible. See [parallel/speculation.md](../parallel/speculation.md).

## Fused super-ops

The compiler collapses pervasive read chains into single opcodes, saving a dispatch and the intermediate push/pop (fusion is chosen at emit time; see [compiler/pipeline.md](../compiler/pipeline.md)):

- **`up_get_attr`** (upvalue idx + name): force upvalue, select attr, push. Profiling puts `up_get` at 10% of all executed ops and `attr_get` at 3%, much of the latter being the same upvalue→attr chain (`lib.foo`, `config.bar`).
- **`loc_get_attr`** / **`loc_get_attr_w`**: same for a local slot (narrow / wide).
- **Value-returning `_ret` fusions** — `push_const_ret`, `loc_get_ret` (`_w`), `up_get_ret`: load-and-return in one op, collapsing the two dispatches that dominate per-thunk overhead. These also drive the trivial-body thunk short-circuit (see [runtime/thunks.md](../runtime/thunks.md)).

**Well-known stub chunks** are the same idea at the builtin level: `genlist_apply` (`[func, index]` → `func index`) and `mapattrs_apply` (`[func, name, value]` → `(func name) value`) are shared 1-/2-arg-application bodies reused by `genList`/`map`/`mapAttrs` instead of allocating a per-element closure object. They call the user function on their captured element value **unforced** so the function decides laziness — forcing eagerly here would blackhole when the lambda captures the surrounding recursive attrset (the typical module pattern). `mapAttrs` uses `mapattrs_apply` only when its function argument is already callable; when the function is itself still a thunk it falls back to a per-key `mapAttrValue` builtin thunk (see [builtins.md](builtins.md)).

## The `//` update operator

Both ops take `[left, right] → [merged]`. The operands arrive in WHNF (whatever produced them forced them; the helpers only `isAttrs`-check, they do not re-force) and stay on the operand stack across the call because the merge **allocates** a heap object — a GC safepoint — with both operands dropped only after. They use **different strategies** for two different sources of `//`:

- **`attrs_merge`** — runtime `//` (`a // b` where either side is dynamic). It does *not* eagerly merge: it builds a **lazy layered node** (`heap.mergeAttrsLayered`), a `base // overlay` structure whose lookups consult the overlay first, so **RHS wins**. Deferring the merge is what keeps the NixOS fixpoint's thousands of stacked `//`s cheap; the layered-node representation, its k-way flatten, and the depth cap that stops the stack from degenerating are a data-structure concern documented in [runtime/heap.md](../runtime/heap.md).
- **`attrs_merge_strict`** — merging the sorted sub-groups of a *single* attrset literal (e.g. `{ a.b = 1; a.c = 2; }`). It performs an eager **reserve-then-flush sorted merge** (`mergeAttrLiteralObjects`): reserve the worst-case union directly in heap attr storage, then walk both sorted, deduped entry arrays in lockstep (O(n+m)), writing entries in place. Because both inputs are sorted+unique, the output is too, by construction. A name present on only one side copies through; on a **name collision** the two values are **recursively merged** iff both are attrsets (`mergeAttrLiteralValue`) — otherwise it raises `DuplicateAttribute`. A leaf collision inside a single literal is rejected, unlike runtime `//`'s silent override.

## List concatenation

`list_cat` (`[left, right] → [result]`, from `++`) type-checks both operands as lists (they arrive forced) and allocates the concatenation (`heap.addConcatenatedLists`), keeping both on the stack as roots across the allocation. Elements are carried across unforced — `++` does not force list contents.

## Deep equality

`==`/`!=` compile to `cmp_eq`/`cmp_ne`, which run a recursive, **cycle-tracking** structural comparison (`valuesEqual`). When exactly one side is a literal `null` the compiler instead emits the monomorphic `cmp_eq_null`/`cmp_ne_null`, which force the single operand and test `kind() == .null` directly — bypassing `valuesEqual` entirely. The structural comparison:

- **Numeric coercion**: two ints compare as ints; any int/float mix compares as floats (`int ↔ float`).
- **String-like coercion**: `string`, `path`, and `string_context` are mutually comparable **by their text** (interned id), ignoring context.
- **Containers**: lists compare elementwise; attrsets compare by matching sorted `(name, value)` pairs. A **`seen` pair list** breaks cycles — a pair already being compared is treated as equal, so recursive structures terminate.
- **Reference shortcut**: identical `ObjectId`s (same list/attrset object) are equal without recursing.
- **Derivation shortcut**: two attrsets that both have `type == "derivation"` are equal iff their `.outPath` strings are equal — Nix's derivation identity, avoiding a full deep walk of the derivation attrs. (See [derivation/model.md](../derivation/model.md).)
- Closures/builtins/PAPs compare by identity (`ObjectId` / builtin id).

`compareValues` (`<`, `<=`, `>`, `>=`) is the ordered sibling: numeric with int/float coercion, and lexicographic `std.mem.order` over string-like text — but ordering, unlike equality, does **not** coerce across string-like kinds (comparing a `string` to a `path` is a `TypeError`). Any other kind (lists, attrsets, bools) is a `TypeError`.

## String operations

String concatenation (`+` on strings, and interpolation) **interns** the pieces, composes their text ids, and **merges string context** — the set of store-path/derivation-output dependencies a string carries. Context merge deduplicates by entry name and unions derivation `outputs` lists; the full context model (why a string carries dependencies, how `.drv` inputs are derived from it) is in [derivation/context.md](../derivation/context.md).

Operand **coercion to a string** (`coerceLanguageStringValue`): `string`/`string_context` pass through; a `path` becomes a store-path context string; an **attrset** coerces via `__toString` (called on the attrset) if present, else via `.outPath` — otherwise a `TypeError`. Path concatenation (`path + …`) normalizes an absolute result and rejects mixing in a string that already carries store-path context (`InvalidPathConcatenation`). All coercion helpers root their operands across the forces (`__toString`/`.outPath` invoke user code — GC safepoints).

## Invariants

- **Operands stay on the operand stack across the operation**: attr select and equality **force** (deeply), merge and concat **allocate** — both are GC safepoints. Dropped or overwritten in place only after. Never `forceValue(pop())`.
- **Attrs are sorted by interned name**; lookup is binary search over integer ids.
- **Existence tests don't force** the final value; selection does.
- **Attr IC is per-thread and `heap_token`-guarded**; entries are GC roots while the token matches.
- **Equality/order coerce** across int↔float and string/path/context, and short-circuit derivations by `.outPath`.

Code: `src/expr/vm/`, `src/expr/bytecode/`
