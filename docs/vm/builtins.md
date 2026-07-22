# Builtins

*How the primops — 107 named builtins plus 7 compiler-internal ids (114 `BuiltinId` variants) — are structured, dispatched, and made GC- and parallel-safe.*

## Mental model

A builtin is a native Zig function reachable from Nix as a `BuiltinId`-tagged value. The compiler emits references to builtins by id, not by name; the VM applies them through a single enum-indexed switch. Builtins are the leaves of evaluation — they consume already-forced (or force-on-demand) [values](../runtime/values.md), do native work (arithmetic, string coercion, I/O, hashing, [derivation](../derivation/model.md) assembly), and return a value or a thunk. Each builtin takes a concrete `*VM`; the VM context carries the allocator, [heap](../runtime/heap.md), [interner](../runtime/interning.md), realization services, and scheduler interfaces it may use.

## Dispatch

`applyBuiltin(self, builtin_id, args)` is the sole entry:

1. **Arity check** against `arity(id)`:
   - `args.len < arity` → return a **builtin closure** capturing the partial args (undersupply; see [partial application](calls.md)).
   - `args.len > arity` → `error.TooManyArguments` (oversupply is a hard error — Nix rejects it).
   - exact → dispatch.
2. **`switch (id)`** — one arm per `BuiltinId`, almost all forwarding to a group-module implementation (`.constantValue` returns `args[0]` inline). The switch has no `else` arm, so it is exhaustive over `BuiltinId` — adding a variant without an arm is a compile error.

The one-hop wrapper `access.applyBuiltin` fronts this: it raises the fiber-local native depth for the builtin's duration (the GC gate, below) before calling the switch.

Applying a saturated closure (`applyBuiltinClosure`) copies the captured args, appends the final arg, and re-enters `applyBuiltin` at full arity. Curried calls therefore round-trip through the same dispatch; a builtin needing *n* args produces *n−1* intermediate closure values.

## Values: closures vs thunks

Two constructors in `shared.zig`, both keyed off a `BuiltinId` + captured args:

| Constructor | Produces | Used for |
|---|---|---|
| `makeBuiltinClosure` | a **builtin-closure** object (callable) | partial application; a builtin awaiting more args |
| `makeBuiltinThunk` | a **thunk** wrapping that closure | deferring a builtin's *result* (lazy attrs, per-element maps) |

`makeBuiltinThunk` is how lazy machinery re-enters builtins later: `zipAttrsWith` builds a per-group `zipAttrsValue` thunk; `mapAttrs` builds a per-key `mapAttrValue` thunk only on its thunk-function fallback path (when the mapped function is already callable it instead uses the `mapattrs_apply` bytecode-stub chunk — one object per key rather than two; see [access.md](access.md)); and `derivation` seeds a `derivationLazyAttr` thunk for `drvPath`, `outPath`, each declared output, and `all`. Forcing such a thunk runs the internal builtin id on its captured args — invisible to Nix as a distinct primop.

## GC safety

Arguments live in Zig locals / a C-stack slice, never on the VM operand stack, so a force mid-body could otherwise sweep them (and their reachable graph). Two overlapping rules make builtins correct across [collection](../gc.md):

- **Native-depth gate**: `access.applyBuiltin` raises the fiber-local native depth for the whole call. This prevents a peer fiber from parking for collection while it holds unrooted native locals; it does **not** prevent the current demand fiber from initiating a collection at a nested force boundary. (`import`/`scopedImport` lower the inherited depth for the nested evaluation.)
- **Explicit roots**: the calling convention roots arguments before entry — `doCall`/`doTailCall`/`callValue` use `rootKeep`, `doCallN` leaves args on the operand stack, and an in-flight `builtin_closure` stays on the force chain. A builtin must also `rootKeep` every fresh heap intermediate that remains live across a force or nested call.

Builtins that merge [string context](../derivation/context.md) or build large intermediates (`toJSON` in `serial`, `derivationStrict` in `derivation`, the `fetch*` family, string ops in `strings`/`string_context`) open their own `rootsBegin`/`rootKeep`/`rootsEnd` scope around those intermediates.

## File-group split (`src/expr/vm/builtins/`)

| Group | Holds |
|---|---|
| `arguments` | shared argument coercion and validation helpers |
| `shared` | builtin closure/thunk value construction (`makeBuiltinClosure`, `makeBuiltinThunk`), the JSON cycle guard, and the adaptive `NameIndex` used by accumulate-by-name builtins |
| `strings` | `toString`, `stringLength`, `substring`, `concatStringsSep`, `replaceStrings`; coercion & interning. `concatStringsSep` coerces and roots every part, computes the exact output length, then fills one buffer before interning while merging string context in language order. |
| `attrsets` | attrset ops: `hasAttr`, `getAttr`, `attrNames`, `attrValues`, `mapAttrs`, `zipAttrsWith`, `catAttrs`, `intersectAttrs`, `removeAttrs`, `functionArgs`, plus the internal per-key thunk bodies `mapAttrValue`/`zipAttrsValue` |
| `lists` | list structure (`length`, `head`, `tail`, `elemAt`, `concatLists`, `listToAttrs`, `elem`, `seq`, `deepSeq`) and the functional list ops (`map`, `filter`, `foldl'`, `any`, `all`, `sort`, `partition`, `groupBy`, `genList`, `concatMap`, `genericClosure`). `concatLists` and `concatMap` retain their produced sublists as roots, total their lengths, and fill one exact heap range directly instead of staging and recopying every element. |
| `paths` | `baseNameOf`, `dirOf`, `path`, `storePath`, `placeholder` |
| `hash` | `hashString`, `hashFile` |
| `io` | `readFile`, `readDir`, `readFileType`, `pathExists`, `import`/`scopedImport` |
| `fetch` | transport-backed `fetchGit`, `fetchurl`, `fetchTarball`, `fetchMercurial`, and fetched-tree NAR hashing |
| `flakes` / `flake_registry` | `fetchTree`, `getFlake`, flake-ref conversion, lazy flake-input resolution, registry lookup |
| `source_store` | `filterSource`, `getEnv`, `toPath`, `toFile` and source-store ingestion |
| `arithmetic` | `add`, `sub`, `mul`, `div`, `lessThan`, bitwise ops, `floor`, `ceil` |
| `predicates` | `typeOf`, `isString`/`isInt`/`isBool`/`isList`/`isAttrs`/`isNull`/`isFloat`/`isPath`/`isFunction` |
| `serial` | `toJSON`/`fromJSON`, `toXML`, `fromTOML`, `compareVersions`, `splitVersion`, `parseDrvName`, `split`, `match` |
| `errors` | `throw`, `abort`, `tryEval`, `trace`, `traceVerbose`, `warn`, `addErrorContext` |
| `string_context` | context tracking (`getContext`, `hasContext`, `appendContext`, `unsafeDiscardStringContext`, …) — see [derivation/context.md](../derivation/context.md) |
| `derivation` | `derivation`/`derivationStrict`, `derivationLazyAttr` — see [derivation/model.md](../derivation/model.md) |

## Concurrency stance

Builtin evaluation is **fiber-sequential**: language-visible logic resumes on one fiber. A builtin may submit independent per-element thunks to the [scheduler](../parallel/scheduler.md) — `map`, `genList`, and `mapAttrs` enqueue eligible element work — so helpers can force them ahead of demand. Blocking fetch and nix-daemon work instead runs on dedicated I/O threads while the calling fiber parks; those threads are separate from the `--workers` compute pool.

Local filesystem operations (`readFile`, `readDir`, import discovery) use the shared file cache on the calling fiber. Import results are cached and deduplicated so concurrent importers of the same path converge (see [imports.md](../parallel/imports.md)); network/subprocess fetches and daemon store operations use the blocking executors above.

`trace`, enabled `traceVerbose`, and `warn` stream synchronized, flushed stderr
records on the demand path. Messages are stripped of ANSI/terminal control
sequences before they reach the sink. Speculative fibers journal these effects
and publish them with their thunk or import result, so unused work stays silent
without losing an effect that is demanded later. Disabled `traceVerbose` does
not force its message; the `trace-verbose` Nix setting enables it.

## Hot builtins

- **`derivationLazyAttr`** — computes `drvPath`/`outPath` via input-modulo sha256 [hashing](../derivation/hashing.md); memoized through the derivations store, so repeated attr access is a lookup. A w=32 serial-critical-path lever.
- **`mapAttrs`/`mapAttrValue`** — recurse the module/option trees; inherent work, no speculative waste (results are consumed).
- **`length`** — O(1): returns the list's stored length without touching elements.
- **`any`/`all`** — short-circuit: they force predicates left-to-right and stop at the first decisive element (`any` at the first `true`, `all` at the first `false`).
- **`toString`** — coercion + string-context propagation on a very hot path.

## Invariants

- Dispatch is exhaustive over `BuiltinId`; a builtin is reachable *only* by id, never by name lookup at call time.
- Undersupply ⇒ closure; oversupply ⇒ error. Never silently drop or ignore extra args.
- Every argument is GC-rooted for the whole call; a builtin may force args and allocate freely without losing them to a sweep.
- Language-visible builtin logic is fiber-sequential; parallelism comes from submitted thunks, and blocking fetch/store work is isolated on dedicated I/O threads while the fiber parks.
- Result parity is byte-identical `.drv`; the interpreter path is canonical.

Code: `src/expr/vm/builtins/`
