# Heap

*The object store and memory model: flat mmap slots, append-only stable segments, per-worker TLABs, and the layered `//` node.*

Every non-immediate [`Value`](values.md) refers to a boxed runtime object by **`ObjectId`**, never by host pointer. `ObjectHeap` owns four backing stores and hands out ids that name an object for as long as it stays reachable. The heap is **non-moving** — an object's bytes never relocate — so a published `ObjectId` is a stable handle, and its union tag (fixed when the object is created) can be pattern-matched without synchronization.

## Mental model

- **Non-moving, but slots recycle.** The heap never *moves* an object, so an `ObjectId` held by reachable state is never relocated or invalidated, and [Intern](interning.md) ids last the whole run. Object ids, though, are **reused**: when the [GC](../gc.md) collects it frees dead object slots to per-worker free lists, and a later allocation is handed the same id for a different object. (Under `-Dgc=false`, or while the collector stays dormant, the stores are strictly append-only and no id is ever reused.) Collection is stop-the-world and recycles only *unreachable* slots, so no reader sees a live slot change under it; a cache that stashes a bare `ObjectId` across a safepoint guards against reuse by keeping the referent rooted or pairing the id with a heap token.
- **Readers lock-free, writers serialized.** Backing arrays never move, so reads are a single atomic segment-pointer load (or a bare load for the object store). Writers serialize per-store on a `SpinMutex` whose critical section is at most one allocator call.
- **Values are position-independent.** Copying a `Value` copies 8 bytes; the referent lives in the shared heap.

## The object store: `FlatStore`

The `objects` store is a `FlatStore` — a single `mmap` region, **not** geometric segments. `OBJECT_MAX_SLOTS = 2^30` slots are reserved virtually with `MAP_NORESERVE`; only touched pages cost physical memory (a real eval produces ~millions of objects against that reservation for free). The base pointer is immutable after init, so `get(id)` collapses to one load — `base[id]` — with no segment decode and no per-access atomic. This access happens tens of millions of times on the NixOS toplevel, which is why the object store forgoes the segment machinery the range stores use. Allocation is still per-worker TLAB'd (workers reserve chunks of the flat region and fill them lock-free); the flat single-region layout is only about the `get` path, not about how slots are handed out. The `builtins.builtins` self-reference reserves its slot up front (`reserveObjectSlot` → `fillObjectSlot`) so it can embed its own id before the object is filled.

## The range stores: `StableSegments`

`values`, `attrs`, and `attr_positions` are `StableSegments`: append-only storage split into geometrically growing segments (segment *i* has capacity `first_size << i`; ids for segment *i* start at `first_size·(2^i − 1)`). A segment's backing array is **pinned after allocation** and never relocated, so:
- **Reads** resolve `(segment, offset)` via a single atomic segment-pointer load plus CLZ-based index math (`locationOf`); readers may cache segment pointers safely.
- **Writers** serialize on the store's `SpinMutex`.

API: `append(v) → id`, `reserve(len) → Range`, `slice`/`sliceMut`, and tail-only `rollback` (for unwinding a failed multi-step allocation). A `Range` must fit within a single segment.

## Per-worker TLABs (`HeapLocal`)

Each worker (including main, indexed by `worker_id`) owns a `HeapLocal` with a `LocalChunk` cursor per range store (object/value/attr/attr_pos). A worker **reserves a chunk from the global store once under the store mutex**, then hands out slots lock-free (`fits`/`take`) until the chunk is exhausted and it refills. This keeps the allocation fast path off the global mutex on list/attrset/upvalue-heavy workloads. The GC free-list reuse path *is* mutex-guarded, but the common alloc path is not.

## `Object` union

```
list          ValueRange
attrs         AttrsObject { range: AttrRange, positions: AttrPosRange }
merge_attrs   MergeAttrsObject { base, overlay: ObjectId, depth, flattened(atomic) }
closure       { chunk_id: ChunkId, upvalues: ValueRange }
builtin_closure { builtin_id: u16, args: ValueRange }
thunk         Thunk                     // see thunks.md
context_string { text: InternId, context: AttrRange }
boxed_int     i64                       // out-of-i48 escape; see values.md
partial_app   { func: Value, args: ValueRange }
```

Source positions live inside the `attrs` variant rather than in a field on every object: the thunk variant already sizes the union, so hanging positions off attrsets alone costs nothing on the objects that carry none — a ~20% saving across all objects, most of which carry no positions. `positions.len == 0` means "none" and is never sliced.

## Attrsets: sorted, binary-searched, dup-rejecting

An `AttrsObject` holds its `AttrEntry`s **sorted by `InternId`** (name). Lookup (`getAttrValueOpt`/`hasAttr`) is a binary search over the entry slice; construction sorts and **rejects duplicate names**. This ordering is an invariant relied on everywhere — producers that emit already-sorted-unique output (k-way merge, `intersectAttrs`, the compiler's baked positions) skip the re-sort.

## Layered merge (`merge_attrs`) for `//`

The NixOS module/overlay fixpoints `//` a massive accumulator thousands of times; materializing each step copies the whole accumulator (O(N) per step → O(N·K), dominating the attr store). The heap instead records a large `a // b` as an **O(1) `merge_attrs` node** — just `base` + `overlay` ObjectIds + a `depth`. Mechanics:

- **Lookup walks overlay-first without flattening.** `getAttrValueOpt` on a `merge_attrs` checks `overlay` then `base` (`//` is shallow, right-biased); the `(obj, name)` inline cache in the [VM](../vm/access.md) absorbs repeats. `base`/`overlay` may themselves be `merge_attrs`, forming a chain.
- **Small merges stay eager.** Only when the left side is at least `MERGE_LAYER_MIN` (32) entries is a node created; literal `{…} // {…}` stays a flat single-binary-search attrset.
- **Flatten is deferred and atomically memoized.** The plain flattened attrset (`flattened`, sentinel `NO_FLAT` until forced) is produced lazily on first `getAttrs`/iteration via a one-pass right-biased k-way merge, then published with an atomic store so concurrent forcers converge.
- **Chain depth is capped.** Past `MERGE_FLATTEN_DEPTH` (8) a real flatten collapses the chain, bounding both per-lookup overlay walks and the work any single flatten must do.

## Constants

The evaluator-wide limits live in `runtime/types.zig`: `VM_STACK_CAP = 65536`, `MAX_FRAMES = 512`, `MAX_UNCURRY_ARITY = 4`.

Out of scope: the `//` opcode's execution and inline cache → [vm/access.md](../vm/access.md); thunk internals/state machine → [thunks.md](thunks.md); the collection algorithm → [gc.md](../gc.md).

Code: `src/runtime/heap.zig`
