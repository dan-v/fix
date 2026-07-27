# String Context

*How strings carry dependency information, and why mistracking it corrupts a `.drv`.*

## Mental model

In Nix, a string is not just text — it may carry a **context**: the set of store paths that must exist before the string is meaningful, each tagged with *which* dependency it induces. When you interpolate `drv.outPath` into a build script, the resulting string remembers "this text mentions `/nix/store/…-foo.drv`, and I depend on its `out` output." When that string later lands in a `derivation`'s env, the [derivation builder](./model.md) reads the context back out to populate `input_drvs` / `input_srcs`.

Context is therefore **load-bearing for correctness**: the derivation
normalizer derives `input_drvs` and `input_srcs` from the contexts of its
string-coerced attributes. Dropping or mis-merging an entry produces the wrong
dependency set.

## What a context is

A context is a map **store-path → descriptor**, one of:

| Descriptor | Meaning |
|---|---|
| `{ path = true; }` | plain dependency on this store path (a source path, or an output path referenced as data) |
| `{ allOutputs = true; }` | depend on **all** outputs of this `.drv` (the path is a `.drv`) |
| `{ outputs = [ "out" "bin" ]; }` | depend on these specific outputs of this `.drv` |

Concretely the context is stored as a sorted attrset (keys = interned store paths, values = descriptor attrsets). `builtins.getContext` exposes exactly this shape.

## The `ContextString` value

Strings come in three [value](../runtime/values.md) forms:

- **plain string** — `Value.string(InternId)`, no context.
- **path** — `Value.path(InternId)`; treated as carrying the implicit context `{ <path> = { path = true; }; }` when its context is queried (coercing a path into a store path is what materializes that entry).
- **context string** — `Value.contextString(ObjectId)` → heap `ContextString{ text: InternId, context: []const AttrEntry }`: interned text plus the explicit sorted context entries.

`contextEntriesForValue(value)` unifies them: `[]` for a plain string, the synthesized `{path=true}` entry for a path, the stored slice for a context string, `TypeError` otherwise.

## Propagation and merging through string ops

Context-preserving string operations carry the dependencies of the values they
use. The explicit `unsafeDiscard*` builtins below are the exceptions. See
[string ops](../vm/access.md) for the operations themselves; the main rules are:

- **Concatenation** (`+` on strings, `builtins.concatStringsSep`, interpolation): the result's context is the union of the operands' contexts. If no operand had context the result is a plain string; otherwise a context string.
- **`substring`** keeps the source string's entire context, including when the selected text is empty. **`replaceStrings`** keeps the source context and adds the contexts of replacements that actually match.
- **path + string** (`concatPathLike`): the result is **path-typed** (the concatenated, absolute-resolved path), carrying the right operand's context; a bare path is treated as its implicit `{path=true}` when the result's context is later queried. Appending a string that carries **store-path** context onto a path is rejected (`InvalidPathConcatenation`) — a filesystem path cannot be turned into a store dependency this way.

**Merge algorithm.** Unioning happens at two levels.

*Across store paths* (`appendStringContext` → `appendContextEntry`): the union is accumulated into a plain list. Each incoming entry is added by a **linear scan** of the accumulated entries for a matching store-path key — found → merge the two descriptors; not found → append. The result list is handed to `addContextString`, which **sorts it by interned key and rejects duplicate keys**, so every stored context string is sorted even though the merge itself is scan-and-append. An empty merge result collapses back to a plain `Value.string`.

*Within a store path's descriptor* (`mergeContextValues` → `mergeContextAttrs`): if both descriptors are attrsets, they are combined by a **two-pointer sorted merge** over their keys (descriptor attrsets are themselves stored sorted). Per key:

- Most keys (`path`, `allOutputs`) take the **right** value.
- The **`outputs` list is special-cased** (`mergeContextOutputs`): the two lists are **unioned, appending only names not already present** (order-preserving dedup), so `outputs=["out"]` merged with `outputs=["bin"]` → `["out","bin"]`.

If either descriptor is not an attrset, the merge just takes the right value.

## The context builtins

| Builtin | Effect |
|---|---|
| `getContext s` | return the context as an attrset (the map above) |
| `hasContext s` | true iff the string's context is non-empty |
| `appendContext s ctx` | attach/merge an explicit context attrset onto `s`'s text (each entry merged via the same union rules) |
| `unsafeDiscardStringContext s` | return the bare text as a **plain string**, dropping all context |
| `unsafeDiscardOutputDependency s` | keep entries but rewrite each descriptor to `{ path = true; }` (demote drv-output deps to plain path deps) |
| `addDrvOutputDependencies s` | rewrite every `.drv`-path entry's descriptor to `{ allOutputs = true; }`; if `s` has no context but its text ends in `.drv`, add a `{ <text> = { allOutputs = true; }; }` entry. It yields the same all-outputs descriptor that `drv.drvPath` already carries (built directly in `value.zig`, not via this builtin), letting Nix code turn a bare `.drv`-path string into an all-outputs dependency. |

`appendContext` and `addDrvOutputDependencies` reject non-string-like arguments with `TypeError`; `appendContext` also rejects a non-attrs context. These are the [builtins](../vm/builtins.md) surface for context.

## Why it matters: context → `.drv` deps

When [`derivation`](./model.md) normalizes its argument, each attribute value is string-coerced and its context is walked (`normalizeDerivationString`):

- A context entry whose path **ends in `.drv`** becomes an **`input_drvs`** edge — the requested output names come straight from the descriptor (`allOutputs` → the input drv's recorded output names; `outputs=[…]` → those names; bare → `["out"]`). Duplicate input paths are **merged by union of output names**, matching the [hashing](./hashing.md) `hashModuloInputs` invariant.
- A context entry whose path is **not** a `.drv` becomes an **`input_srcs`** edge, and — for source paths — the referenced path text is rewritten to its computed store path (NAR-hashed via [source-path hashing](./hashing.md)).

The store-path strings a derivation *hands out* are themselves context strings that seed this: `drvPath` carries `{ <drv> = { allOutputs = true; }; }`, and each `outPath` carries `{ <drv> = { outputs = [ <thatOutput> ]; }; }`. So the moment one derivation's `outPath` flows into another's env, the consumer records the exact input-drv edge and output name. This closed loop — context in the produced strings, context read back at consumption — is how dependency information survives composition across derivations.

Code: `src/runtime/heap.zig` (`ContextString`, `addContextString`), `src/expr/vm/strings.zig` (concat / path-concat context union), `src/expr/vm/builtins/string_context.zig` (context builtins), `src/expr/vm/builtins/derivation.zig` (`normalizeDerivationString`: context → `.drv`/src deps)
