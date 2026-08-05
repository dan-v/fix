# Heap

*The object store and memory model: flat mmap slots, append-only stable segments, per-worker TLABs, and the layered `//` node.*

Every non-immediate [`Value`](values.md) refers to a boxed runtime object by **`ObjectId`**, never by host pointer. `ObjectHeap` owns five backing stores and hands out ids that name an object for as long as it stays reachable. The heap is **non-moving** — an object's bytes never relocate — so a published `ObjectId` is a stable handle, and its union tag (fixed when the object is created) can be pattern-matched without synchronization.

## Mental model

- **Non-moving, but slots recycle.** The heap never *moves* an object, so an `ObjectId` held by reachable state is never relocated or invalidated, and [Intern](interning.md) ids last the whole run. Object ids, though, are **reused**: when the [GC](../gc.md) collects it frees dead object slots to per-worker free lists, and a later allocation is handed the same id for a different object. While the collector stays dormant the stores are strictly append-only and no id is reused. Collection is stop-the-world and recycles only *unreachable* slots, so no reader sees a live slot change under it; a cache that stashes a bare `ObjectId` across a safepoint guards against reuse by keeping the referent rooted or pairing the id with a heap token.
- **Readers lock-free, writers serialized.** Backing arrays never move, so reads are a single atomic segment-pointer load (or a bare load for the object store). Reservations that extend a backing store serialize on that store's `SpinMutex`; per-worker allocation normally consumes an already-reserved local chunk.
- **Values are position-independent.** Copying a `Value` copies 8 bytes; the referent lives in the shared heap.

## The object store: `FlatStore`

The `objects` store is a `FlatStore` — a single `mmap` region, **not** geometric segments. `object_max_slots = 2^30` slots are reserved virtually with `MAP_NORESERVE`; only touched pages cost physical memory. The base pointer is immutable after init, so `get(id)` is `base[id]` with no segment decode or per-access atomic. Allocation remains per-worker TLAB-based; the flat layout only governs lookup. The `builtins.builtins` self-reference begins a pending slot and commits it after constructing the self-referential entry (`beginObjectSlot` → `commitObjectSlot`).

## The range stores: `StableSegments`

`values`, `attrs`, `attr_positions`, and GC-able string `bytes` are `StableSegments`: append-only storage split into geometrically growing segments (segment *i* has capacity `first_size << i`; ids for segment *i* start at `first_size·(2^i − 1)`). A segment's backing array is **pinned after allocation** and never relocated, so:
- **Reads** resolve `(segment, offset)` via a single atomic segment-pointer load plus CLZ-based index math (`locationOf`); readers may cache segment pointers safely.
- **Writers** serialize on the store's `SpinMutex`.

API: `append(v) → id`, `reserve(len) → Range`, `slice`/`sliceMut`, and tail-only `rollback` (for unwinding a failed multi-step allocation). A `Range` must fit within a single segment.

## Per-worker TLABs (`HeapLocal`)

Each worker (including main, indexed by `worker_id`) owns a `HeapLocal` with a `LocalChunk` cursor per store (object/value/attr/attr_pos/bytes). A worker **reserves a chunk from the global store once under the store mutex** (8192 objects / 8192 values / 8192 attrs / 4096 attr-positions / 65,536 bytes per refill), then hands out slots lock-free (`fits`/`take`) until the chunk is exhausted and it refills. The larger batches keep parallel allocation bursts from contending on the refill mutex; unused suffixes remain bounded to one chunk per worker.

Reclaimed storage uses **per-worker** free lists (`HeapLocal.gc_free_*`). Sweep
returns dead slots and ranges to worker-local lists. At a stop-the-world
boundary, unused local entries are moved to shared overflow; a worker refills
its local list from that overflow in batches.

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
heap_string   { bytes: ByteRange, text_len: u32 }
heap_string_inline { len: u8, text: [30]u8 }
```

Source positions live inside the `attrs` variant rather than in every object. `positions.len == 0` means "none" and is never sliced.

## Attrsets: sorted, binary-searched, dup-rejecting

An `AttrsObject` holds its `AttrEntry`s **sorted by `InternId`** (name). Lookup (`getAttrValueOpt` → `binarySearchAttr`) is a binary search over the entry slice; sets of up to four entries use the equivalent fixed decision tree to avoid loop and midpoint bookkeeping. Construction (`prepareAttrsRange`) sorts with `std.mem.sort` and **rejects duplicate names** (`rejectDuplicateAttrs`). This ordering is an invariant relied on everywhere — producers that emit already-sorted-unique output take `addAttrsSorted` / `addAttrsFromStackPairsSorted`, which skip the re-sort and dup-check (the k-way flatten, `intersectAttrs`, and the compiler's sorted attrset literals (`attrs_new_srt` / `attrs_new_named*`)).

## Layered merge (`merge_attrs`) for `//`

The NixOS module/overlay fixpoints `//` a massive accumulator thousands of times; materializing each step copies the whole accumulator (O(N) per step → O(N·K), dominating the attr store). The heap instead records a large `a // b` as an **O(1) `merge_attrs` node** — just `base` + `overlay` ObjectIds + a `depth`. Mechanics:

- **Lookup walks overlay-first without flattening.** `getAttrValueOpt` on a `merge_attrs` checks `overlay` then `base` (`//` is shallow, right-biased); the `(obj, name)` inline cache in the [VM](../vm/access.md) absorbs repeats. `base`/`overlay` may themselves be `merge_attrs`, forming a chain.
- **Small merges stay eager.** Only when the left side is at least
  `merge_layer_min_size` (32) entries is a node created; smaller merges produce
  a flat attrset.
- **Flatten is deferred and atomically memoized.** The plain flattened attrset (`flattened`, sentinel `no_flattened_attrs` until forced) is produced when `materializeAttrs` needs a flat entry slice. `flattenMerge` collects the whole chain's leaves in precedence order and runs *one* right-biased k-way merge (`kwayMergeLeaves`), avoiding the O(depth·N) intermediates a pairwise flatten would allocate, then installs the id with a `cmpxchgStrong` so concurrent callers converge on the CAS winner's result.
- **Chain depth is capped.** Construction (`mergeAttrsLayered`) stops extending the chain once a node's `depth` would exceed `merge_flatten_depth` (8): it eagerly merges (`addMergedAttrs`) instead, which forces the left chain flat and collapses it, bounding both per-lookup overlay walks and the work any single flatten must do.

## Constants

The evaluator-wide limits live in `src/runtime/types.zig`: `vm_stack_capacity = 524,288`, `max_frames = 65,536`, `default_max_call_depth = 10,000`, and `max_uncurry_arity = 4`.

Out of scope: the `//` opcode's execution and inline cache → [vm/access.md](../vm/access.md); thunk internals/state machine → [thunks.md](thunks.md); the collection algorithm → [gc.md](../gc.md).

Code: `src/runtime/heap.zig`; read-only tooling projections and censuses:
`src/runtime/heap/inspection.zig`; edge traversal and collector mechanics:
`src/runtime/heap/edges.zig`, `src/runtime/heap/collector.zig`.
