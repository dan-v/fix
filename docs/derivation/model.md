# Derivation Model

*What a derivation is in this evaluator, and how the `derivation` builtin turns an attrset into store paths.*

## Mental model

A derivation is a **build recipe** produced by expression evaluation.
Evaluating `derivation { ... }` (or the primitive
[`derivationStrict`](../vm/builtins.md)) does two things without invoking the
recipe's builder:

1. Computes a `.drv` **store path** and one **output store path** per output — deterministically, from the recipe's contents. See [hashing](./hashing.md) for the path pipeline; derivation hashing appeared on the critical path of the dated NixOS profile in the [performance model](../perf/model.md).
2. Returns an **attrset value** that looks like a derivation to Nix code: `type = "derivation"`, `outPath`, `drvPath`, the output attrs, etc. Store-path [strings carry context](./context.md) so that a downstream `derivation` referencing this one records it as an input.

Path computation is deterministic from the normalized recipe and its resolved
input derivations. It does not run the builder. Writing recipes to the store
and realizing outputs are separate operations handled through the store layer.

## The `Drv` data model

The normalized build recipe, hashed to produce paths. Every leaf is a byte string (`[]const u8`); `outputs`/`input_drvs`/`env` are slices of small structs whose fields are all byte strings:

| Field | Meaning |
|---|---|
| `name` | derivation name; the `-name` suffix of every store path |
| `outputs[]` | `DrvOutput{ name, path, hash_algo, hash }` — one per output |
| `input_drvs[]` | `DrvInput{ path, outputs[] }` — a dependency `.drv` + the output names needed from it |
| `input_srcs[]` | source store paths depended on directly (no `.drv`) |
| `system` | e.g. `x86_64-linux` |
| `builder` | builder executable path |
| `args[]` | builder arguments |
| `env[]` | `EnvVar{ name, value }` — the builder's environment |

`DrvOutput.hash_algo`/`hash` are empty for the normal **input-addressed** case and set for **fixed-output** derivations (`outputHash`/`outputHashAlgo`/`outputHashMode` attrs). `input_drvs` and `input_srcs` are **not written by the user** — they are derived from the [string context](./context.md) of the recipe's attribute values (a store-path reference in any `env` value, arg, or `builder` becomes a dependency). Losing that context = wrong `.drv` deps.

### Normalization (attrset → `Drv`)

`derivation`'s argument is an ordinary attrset; normalization projects it onto `Drv`:

- `name`, `system`, `builder` are required strings (a missing one is an error); `args` is optional and defaults to an empty list, but must be a list when present, each element string-coerced.
- Every other attr — excluding `args`, `__ignoreNulls`, `outputs` (handled specially below), and any attr named after an output — becomes an `env` entry, its value **string-coerced** (lists space-joined, `true`→`"1"`, `false`/`null`→`""`, etc.). `__ignoreNulls = true` drops null-valued attrs instead of emitting `""`. When `outputs` is given explicitly, the space-joined output names become the `outputs` env entry.
- Each output name is seeded as an empty `env` entry (`out = ""`), later overwritten with the computed output path (below).
- `__structuredAttrs = true` switches the env model: instead of per-attr string coercion, the whole attrset is serialized to JSON under a single `__json` env var.
- Fixed-output attrs (`outputHash*`) populate `outputs[0].hash_algo`/`hash`; `outputHashMode = "recursive"` prefixes the algo with `r:` (NAR hashing, see [hashing](./hashing.md)).

Path computation then runs (`computePaths`): fixed-output paths first, then the input-addressed output path from the derivation's hash-modulo, then each output-named `env` entry is back-patched to its computed path, then the `.drv` text path. See [hashing](./hashing.md).

## Lazy vs strict construction

`derivation` is lazy; `derivationStrict` is strict. Both ultimately run the same normalize→`computePaths` core (`buildForcedDerivationValue`); they differ in **what value shape they return** and **when the core runs**.

**Strict** (`derivationStrict`): forces and computes everything immediately, returns a minimal attrs value:

```
{ drvPath = <drv-path-string>; <out> = <output-path-string>; <out2> = ...; }
```

one attr per output plus `drvPath`. This is the primitive the Nix `derivation` lambda in the prelude is built on.

**Lazy** (`derivation`): returns a full derivation attrs value **without** forcing the recipe up front. The value has:

- `type = "derivation"`, `outputName` (the default/first output name), `drvAttrs` (the original attrset), and — only when `outputs` was given explicitly — an `outputs` list of output names.
- `drvPath`, `outPath`, `all`, and each named output — **each a [thunk](../runtime/thunks.md)** (`makeBuiltinThunk(.derivationLazyAttr, ...)`), so nothing is hashed until one of those attrs is actually demanded.
- The user's original attrs, minus any that collide with the synthetic names (`type`, `outputName`, `outPath`, `drvPath`, `drvAttrs`, `outputs`, `all`) or with an output name.

Forcing any one of the thunked attrs triggers the full build (via the fast path below) and yields that attr's value.

### The `derivationLazyAttr` fast path

Each lazy derivation attr is a thunk over the `derivationLazyAttr(attrs_id, name)` builtin. Naively, forcing *N* of a derivation's attrs would rebuild the entire derivation *N* times — and the build (normalize + hash) is the bulk of the cost. The fast path deduplicates:

- `derivationLazyAttr` builds the **full lazy value** (`buildForcedDerivationValue(.lazy)`) and tries to cache it through `RealizationStore`'s evaluation memo, keyed by the input `attrs` [ObjectId](../runtime/heap.md).
- When that memo insertion succeeds, subsequent per-attr accesses to the thunked attrs (`drvPath`, `outPath`, `all`, and each named output) select from the cached value. `type`/`outputName`/`drvAttrs`/`outputs` are plain values in the lazy attrs, so reading them never routes through `derivationLazyAttr`.
- The cache is **token-guarded**: the key is a raw ObjectId, and after a GC that id may be reused for a different attrs; a per-collection token bumps so a stale entry misses rather than returning another derivation's value. Caching is best-effort (an OOM on insert is ignored — correctness never depends on it).

The fully-built lazy value produced here is the same shape as `derivation`'s eager form (below).

### The built lazy value shape

The value returned by the lazy build (`buildValue`) is an attrs with:

- carried-over `original_attrs` (minus synthetic/output-name collisions),
- `type = "derivation"`, `outputName`, `drvPath`, `drvAttrs`,
- `outputs` (only if outputs were explicit),
- `outPath` = the selected (default) output's path,
- one attr per output, **each itself a derivation-shaped attrs** (`type`/`outputName`/`drvPath`/`outPath`) so `drv.bin.outPath` works,
- `all` = a list of those per-output values.

## Value-layer `ValueOutput`

At the [value](../runtime/values.md) layer each output is a `ValueOutput{ name: InternId, out_path: InternId }` — both [interned](../runtime/interning.md) strings. In the built value every output appears **twice**: once as a **direct attr** (`drv.out`, `drv.bin`) and once as an element of the **`all` list**. `drvPath` and every `outPath` are [context strings](./context.md), not plain strings: `drvPath`'s context maps the `.drv` path → `{ allOutputs = true }`; each `outPath`'s context maps the `.drv` path → `{ outputs = [ <thisOutput> ]; }`. That embedded context is exactly what makes a *consuming* derivation record this one as an input.

Code: `src/store/derivation/`
