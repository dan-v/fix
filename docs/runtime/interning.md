# Interning

*String and symbol interning: the sharded global table behind every `InternId`.*

Strings and attr names are interned to dense `u32` `InternId`s so that comparison is an integer compare and [`Value`](values.md) can carry a `string`/`path` as a 48-bit payload. An `InternTable` is owned by the `Engine` (one per evaluation) and is thread-safe: interning is sharded for concurrency, and `get(id)` is lock-free once an id exists.

## Mental model

- **Intern once, compare by id.** Equal bytes ⇒ equal `InternId` (`eql` is `a == b`); attr-name lookup and symbol comparison never touch bytes on the hot path.
- **Ids are dense and permanent.** An id is the slot index `entries.append` returns, so ids are handed out sequentially and are never reused or relocated within a table's lifetime (the backing stores are [`StableSegments`](heap.md)). A slice returned by `get(id)` stays valid for the table's lifetime.
- **Empty string is `id 0`** — a reserved "no string" sentinel that `get` resolves without touching the segments.

## Storage

Two `StableSegments` hold the data globally (so ids stay dense and `get` needn't know the shard):
- `entries` — one `Entry { segment, offset, len }` per `InternId`, id-indexed.
- `data` — the concatenated bytes.

`get(id)` reads `entries[id]` and slices `data` — a single atomic segment-pointer load per store, no lock. Out-of-range or zero-length ids return `""`.

## Sharded intern

`intern(s)` is thread-safe and concurrency-friendly:

1. `h = Wyhash(s)`.
2. Shard = `h & (SHARD_COUNT-1)`; there are **64 shards** (`SHARD_COUNT = 64`), each a `std.HashMapUnmanaged(InternId, void)` open-addressing set guarded by its own `SpinMutex`. Interns of strings hashing to different shards proceed fully in parallel.
3. Under the shard lock, `getOrPutContextAdapted` looks up by the caller's `[]const u8` (a `StringAdapter` compares input bytes against `table.get(id)`) while storing `InternId` keys. The precomputed `h` is threaded in so the map doesn't re-Wyhash the same bytes.
4. Miss → append bytes to `data` (with `rollback` on mid-allocation failure), append the `Entry`, publish the new id.

**Hash collisions coexist.** The map keys on `InternId` and compares bytes on lookup, so two distinct strings sharing a Wyhash output live as separate entries in the same shard. Interning is insert-only (nothing ever calls `remove`), so the open-addressing set never accumulates tombstones, and it rehashes on crossing `std.hash_map.default_max_load_percentage`; those two together keep probe sequences short — there is no tombstone-driven probe-length blowup.

## Per-thread cache

A `threadlocal` **direct-mapped cache** (`cache_size = 512` slots, indexed by `h % 512`) short-circuits the shard lock + HashMap probe + segment slice for hot short identifiers (attr names, builtin args, path components). Each slot stores `hash`, `table_token`, `id`, `len`, and an **inlined copy of the bytes** (`len ≤ cache_max_len = 24`) so the comparison stays branch-local to one cache line — no `data` indirection. Strings longer than 24 bytes skip the cache. Hits require all of `hash`, `table_token`, `len`, and bytes to match; the slot is also populated on a shard-lock miss (both the found-existing and freshly-interned paths write it back).

**Token invalidation.** Each `InternTable` init takes a unique monotonic `token`. Because the thread-local cache outlives an `Engine` and the allocator may reuse the same heap address for a fresh table, a stale slot could match by pointer identity alone; the `table_token` check defeats that. A new table (`init`/reinit after `deinit`) bumps the token, invalidating every stale slot lazily.

## Concurrency summary

| Operation | Synchronization |
|-----------|-----------------|
| `get(id)` | lock-free (stable-segment atomic load) |
| `intern(s)` hit in thread cache | none (thread-local) |
| `intern(s)` reaching the table | per-shard `SpinMutex` |

Out of scope: string *values* and NaN-boxing of `string`/`path` → [values.md](values.md); string context / derivation string provenance → [derivation/context.md](../derivation/context.md).

Code: `src/runtime/intern.zig`
