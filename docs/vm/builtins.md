# Builtins

*How the primops — 106 named builtins plus 5 compiler-internal ids (111 `BuiltinId` variants) — are structured, dispatched, and made GC- and parallel-safe.*

## Mental model

A builtin is a native Zig function reachable from Nix as a `BuiltinId`-tagged value. The compiler emits references to builtins by id, not by name; the VM applies them through a single enum-indexed switch. Builtins are the leaves of evaluation — they consume already-forced (or force-on-demand) [values](../runtime/values.md), do native work (arithmetic, string coercion, I/O, hashing, [derivation](../derivation/model.md) assembly), and return a value or a thunk. Each builtin takes a concrete `*VM`; the VM context carries the allocator, [heap](../runtime/heap.md), [interner](../runtime/interning.md), realization services, and scheduler interfaces it may use.

## Dispatch

`applyBuiltin(self, builtin_id, args)` is the sole entry:

1. **Arity check** against `arity(id)`:
   - `args.len < arity` → return a **builtin closure** capturing the partial args (undersupply; see [partial application](calls.md)).
   - `args.len > arity` → `error.TooManyArguments` (oversupply is a hard error — Nix rejects it).
   - exact → dispatch.
2. **`switch (id)`** — one arm per `BuiltinId`, almost all forwarding to a group-module implementation (`.constantValue` returns `args[0]` inline; `.break_` just forces `args[0]`). The switch has no `else` arm, so it is exhaustive over `BuiltinId` — adding a variant without an arm is a compile error.

The one-hop wrapper `access.applyBuiltin` fronts this: it raises the per-thread native depth for the builtin's duration (the GC gate, below) before calling the switch.

Applying a saturated closure (`applyBuiltinClosure`) copies the captured args, appends the final arg, and re-enters `applyBuiltin` at full arity. Curried calls therefore round-trip through the same dispatch; a builtin needing *n* args produces *n−1* intermediate closure values.

## Values: closures vs thunks

Two constructors in `shared.zig`, both keyed off a `BuiltinId` + captured args:

| Constructor | Produces | Used for |
|---|---|---|
| `makeBuiltinClosure` | a **builtin-closure** object (callable) | partial application; a builtin awaiting more args |
| `makeBuiltinThunk` | a **thunk** wrapping that closure | deferring a builtin's *result* (lazy attrs, per-element maps) |

`makeBuiltinThunk` is how lazy machinery re-enters builtins later: `zipAttrsWith` builds a per-group `zipAttrsValue` thunk; `mapAttrs` builds a per-key `mapAttrValue` thunk only on its thunk-function fallback path (when the mapped function is already callable it instead uses the `mapattrs_apply` bytecode-stub chunk — one object per key rather than two; see [access.md](access.md)); and `derivation` seeds a `derivationLazyAttr` thunk for `drvPath`, `outPath`, each declared output, and `all`. Forcing such a thunk runs the internal builtin id on its captured args — invisible to Nix as a distinct primop.

## GC safety

Arguments live in Zig locals / a C-stack slice, never on the VM operand stack, so a force mid-body could otherwise sweep them (and their reachable graph). Two overlapping guards make builtins correct across [collection](../gc.md):

- **Native-depth gate**: `access.applyBuiltin` raises the per-thread native depth for the whole call; collections only fire at depth 0, so no builtin's Zig-local heap refs are observable mid-call. (`import`/`scopedImport` drop back to the caller's depth for the nested eval so it can still collect.) This is why the switch arms need no rooting of their own.
- **Caller-side arg rooting**: the calling convention already roots the arguments before entry — `doCall`/`doTailCall`/`callValue` `rootKeep` their arg, `doCallN` leaves the args on the operand stack, and an in-flight `builtin_closure` force keeps them on the force chain. So a builtin's arguments survive any force it performs, and the arm only has to manage the intermediates *it* freshly produces.

Builtins that merge [string context](../derivation/context.md) or build large intermediates (`toJSON` in `serial`, `derivationStrict` in `derivation`, the `fetch*` family, string ops in `strings`/`string_context`) open their own `rootsBegin`/`rootKeep`/`rootsEnd` scope around those intermediates.

## File-group split (`src/nix/vm/builtins/`)

| Group | Holds |
|---|---|
| `shared` | builtin closure/thunk value construction (`makeBuiltinClosure`, `makeBuiltinThunk`), the JSON cycle guard, and the adaptive `NameIndex` used by accumulate-by-name builtins |
| `strings` | `toString`, `stringLength`, `substring`, `concatStringsSep`, `replaceStrings`; coercion & interning |
| `attrsets` | attrset ops: `hasAttr`, `getAttr`, `attrNames`, `attrValues`, `mapAttrs`, `zipAttrsWith`, `catAttrs`, `intersectAttrs`, `removeAttrs`, `functionArgs`, plus the internal per-key thunk bodies `mapAttrValue`/`zipAttrsValue` |
| `lists` | list structure (`length`, `head`, `tail`, `elemAt`, `concatLists`, `listToAttrs`, `elem`, `seq`, `deepSeq`) and the functional list ops (`map`, `filter`, `foldl'`, `any`, `all`, `sort`, `partition`, `groupBy`, `genList`, `concatMap`, `genericClosure`) |
| `paths` | `baseNameOf`, `dirOf`, `path`, `storePath`, `placeholder` |
| `hash` | `hashString`, `hashFile` |
| `io` | `readFile`, `readDir`, `readFileType`, `pathExists`, `import`/`scopedImport` |
| `fetch` | `fetchGit`, `fetchurl`, `fetchTarball`, `fetchTree`, `fetchMercurial`, `getFlake`, `filterSource`, `getEnv`, `toPath`, `toFile` |
| `arithmetic` | `add`, `sub`, `mul`, `div`, `lessThan`, bitwise ops, `floor`, `ceil` |
| `predicates` | `typeOf`, `isString`/`isInt`/`isBool`/`isList`/`isAttrs`/`isNull`/`isFloat`/`isPath`/`isFunction` |
| `serial` | `toJSON`/`fromJSON`, `toXML`, `fromTOML`, `compareVersions`, `splitVersion`, `parseDrvName`, `split`, `match` |
| `errors` | `throw`, `abort`, `tryEval`, `trace`, `traceVerbose`, `addErrorContext` |
| `string_context` | context tracking (`getContext`, `hasContext`, `appendContext`, `unsafeDiscardStringContext`, …) — see [derivation/context.md](../derivation/context.md) |
| `derivation` | `derivation`/`derivationStrict`, `derivationLazyAttr` — see [derivation/model.md](../derivation/model.md) |

## Concurrency stance

Builtins are **logically sequential**: a builtin's own logic runs to completion on one fiber and never blocks on, nor forks its computation across, other threads. It may, however, *submit* independent per-element thunks to the [scheduler](../parallel/scheduler.md) — `map`, `genList`, and `mapAttrs` speculatively enqueue `force_thunk` tasks for their elements when the per-element function is substantial enough to speculate on (`isSpeculatableUserFunc`) — so [helper workers](../parallel/workers.md) force those thunks ahead of demand while main drives the serial critical path. Such a builtin is thus a parallelism *source*: it hands the scheduler independent work without itself becoming concurrent.

Some builtins do internal I/O within their one frame — `readFile`/`readDir`, the `fetch*` family, `import`. Import results are cached and deduplicated so concurrent importers of the same path converge (see [imports.md](../parallel/imports.md)); other I/O runs inline in the calling fiber.

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
- A builtin's own logic never runs across threads; parallelism is expressed by producing independent per-element thunks (and optionally submitting them to the scheduler for speculative forcing), not by the builtin computing concurrently.
- Result parity is byte-identical `.drv`; the interpreter path is canonical.

Code: `src/nix/vm/builtins/`
