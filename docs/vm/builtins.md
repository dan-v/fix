# Builtins

*How the ~120 primops are structured, dispatched, and made GC- and parallel-safe.*

## Mental model

A builtin is a native Zig function reachable from Nix as a `BuiltinId`-tagged value. The compiler emits references to builtins by id, not by name; the VM applies them through a single enum-indexed switch. Builtins are the leaves of evaluation — they consume already-forced (or force-on-demand) [values](../runtime/values.md), do native work (arithmetic, string coercion, I/O, hashing, [derivation](../derivation/model.md) assembly), and return a value or a thunk. Everything a builtin can touch — allocator, [heap](../runtime/heap.md), [interner](../runtime/interning.md), derivations store, [worker pool](../parallel/workers.md) — comes from the closed-over evaluator `self`.

## Dispatch

`applyBuiltin(self, builtin_id, args)` is the sole entry:

1. **Arity check** against `arity(id)`:
   - `args.len < arity` → return a **builtin closure** capturing the partial args (undersupply; see [partial application](calls.md)).
   - `args.len > arity` → `error.TooManyArguments` (oversupply is a hard error — Nix rejects it).
   - exact → dispatch.
2. **GC rooting** of every argument for the call's duration (below).
3. **`switch (id)`** — one arm per `BuiltinId`, each forwarding to a group module's implementation. The switch is exhaustive; unknown ids are a compile error.

Applying a saturated closure (`applyBuiltinClosure`) copies the captured args, appends the final arg, and re-enters `applyBuiltin` at full arity. Curried calls therefore round-trip through the same dispatch; a builtin needing *n* args produces *n−1* intermediate closure values.

## Values: closures vs thunks

Two constructors in `shared.zig`, both keyed off a `BuiltinId` + captured args:

| Constructor | Produces | Used for |
|---|---|---|
| `makeBuiltinClosure` | a **builtin-closure** object (callable) | partial application; a builtin awaiting more args |
| `makeBuiltinThunk` | a **thunk** wrapping that closure | deferring a builtin's *result* (lazy attrs, per-element maps) |

`makeBuiltinThunk` is how lazy machinery re-enters builtins later: `mapAttrs`/`zipAttrsWith` build per-key thunks (`mapAttrValue`, `zipAttrsValue`), and `derivation` seeds a `derivationLazyAttr` thunk per output/`drvPath`/`outPath`. Forcing such a thunk runs the internal builtin id on its captured args — invisible to Nix as a distinct primop.

## GC safety

Arguments live in Zig locals / a C-stack slice, never on the VM operand stack, so a force mid-body could otherwise sweep them (and their reachable graph). Two overlapping guards make builtins correct-by-default under [`-Dgc`](../gc.md):

- **Native-depth gate**: entering any builtin raises the per-thread native depth; collections only fire at depth 0, so no builtin's Zig-local heap refs are observable mid-call. (`import`/`scopedImport` drop back to caller depth for the nested eval.)
- **Per-arg rooting**: `rootsBegin`/`rootKeep`/`rootsEnd` root every argument uniformly, so individual builtins only manage their own freshly-produced intermediates.

Builtins that merge [string context](../derivation/context.md) or build large intermediates (`toJSON`, `derivationStrict`, `zipAttrsWith`) open their own `rootsBegin`/`rootsEnd` scope around the intermediates. All of this compiles away without `-Dgc`.

## File-group split (`src/vm/builtins/`)

| Group | Holds |
|---|---|
| `shared` | closure/thunk value construction (`makeBuiltinClosure`, `makeBuiltinThunk`) |
| `strings` | `toString`, `stringLength`, `substring`, `concatStringsSep`, `replaceStrings`; coercion & interning |
| `collections` | attrset ops (`hasAttr`, `getAttr`, `attrNames`, `mapAttrs`, `zipAttrsWith`) + functional list ops (`map`, `filter`, `foldl'`, `any`, `all`, `sort`, `partition`) |
| `lists` | list structure: `length`, `head`, `tail`, `elemAt`, `concatLists`, `listToAttrs` |
| `paths` | `baseNameOf`, `dirOf`, `path`, `storePath`, `placeholder` |
| `hash` | `hashString`, `hashFile` |
| `io` | `readFile`, `readDir`, `readFileType`, `pathExists`, `import`/`scopedImport`, path/`filterSource` source materialization |
| `fetch` | `fetchGit`, `fetchurl`, `fetchTarball`, `getEnv`, `toPath`, `toFile` |
| `arithmetic` | `add`, `sub`, `mul`, `div`, `lessThan`, bitwise ops, `floor`, `ceil` |
| `predicates` | `typeOf`, `isString`/`isInt`/`isBool`/`isList`/`isAttrs`/`isNull`/`isFloat`/`isPath`/`isFunction` |
| `serial` | `toJSON`/`fromJSON`, `toXML`, `fromTOML`, `parseFlakeRef`, `compareVersions`, `split`, `match` |
| `errors` | `throw`, `abort`, `tryEval`, `trace`, `traceVerbose`, `addErrorContext` |
| `string_context` | context tracking (`getContext`, `appendContext`, `unsafeDiscardStringContext`, …) — see [derivation/context.md](../derivation/context.md) |
| `derivation` | `derivation`/`derivationStrict`, `derivationLazyAttr` — see [derivation/model.md](../derivation/model.md) |

## Concurrency stance

Builtins are **logically sequential**. The evaluator is bytecode-threaded, not data-parallel: a builtin runs to completion on one fiber, and nothing inside a builtin fans work out to other threads. Parallelism lives one level up, at [thunk-force granularity](../parallel/speculation.md) — [helper workers](../parallel/workers.md) force *independent* thunks while main drives the serial critical path. A builtin that produces per-element thunks (`mapAttrs`, `genList`) is thus a parallelism *source*: it hands the scheduler independent work without itself becoming concurrent.

Some builtins do internal I/O within their one frame — `readFile`/`readDir`, the `fetch*` family, `import`. Import results are cached and deduplicated so concurrent importers of the same path converge (see [imports.md](../parallel/imports.md)); other I/O runs inline in the calling fiber.

## Hot builtins

- **`derivationLazyAttr`** — computes `drvPath`/`outPath` via input-modulo sha256 [hashing](../derivation/hashing.md); memoized through the derivations store, so repeated attr access is a lookup. A w=32 serial-critical-path lever.
- **`mapAttrs`/`mapAttrValue`** — recurse the module/option trees; inherent work, no speculative waste (results are consumed).
- **`length`/`any`/`all`** — short-circuit; `any`/`all` stop at the first decisive element.
- **`toString`** — coercion + string-context propagation on a very hot path.

## Invariants

- Dispatch is exhaustive over `BuiltinId`; a builtin is reachable *only* by id, never by name lookup at call time.
- Undersupply ⇒ closure; oversupply ⇒ error. Never silently drop or ignore extra args.
- Every argument is GC-rooted for the whole call; a builtin may force args and allocate freely without losing them to a sweep.
- A builtin never forks work to another thread; concurrency is expressed by *returning thunks*, not by internal parallelism.
- Result parity is byte-identical `.drv`; the interpreter path is canonical.

Code: `src/vm/builtins/`
