# Persistent Chunk Cache

*A per-unit on-disk cache of compiled bytecode: an unchanged source file skips
parse + compile entirely on the next run, loading its registered chunks (and
deferred-compilation entries) from a sha256-keyed blob.*

## Mental model

Compilation is deterministic: the same source bytes, under the same language
policy and codegen flags, through the same binary, produce the same chunks.
So the unit of caching is the **compile unit** — one source file's whole
chunk graph plus its deferred-table entries — serialized at
`ChunkBuilder.finish` time and reloaded in place of `parseAndCompile` (see
[pipeline.md](pipeline.md)).

The hard part is not the bytes, it's the **ids**. A chunk's operands embed
`InternId`s (string table), `ChunkId`s (registry), deferred-table ids, and
`NameId`s (name tree) — all session-relative: the same file compiled after
different predecessors gets different ids. The cache never tries to make ids
stable; it **normalizes** every reference to a unit-local ordinal at write
time and **remaps** it to a fresh id at load time (below).

Every failure mode — missing file, corrupt blob, version drift, an id that
no longer fits its operand width — falls back to a fresh compile. The cache
can never change what a program evaluates to; it can only skip work.

## Key and layout

`chunk_cache.computeKey` is a sha256 over everything identity-relevant to
the *compile*, each variable-length piece length-prefixed:

- the blob `format_version`,
- the **policy fingerprint** — a field-generic hash of every
  `LanguagePolicy` field, so a newly added policy knob invalidates by value
  with no maintenance,
- whether [let-float](let-float.md) is enabled (`FIX_NO_LET_FLOAT` changes
  codegen),
- `$HOME` — it affects `~/…` path-literal resolution at compile time,
- the source path and the source bytes.

Units live at `<root>/<build-id>/<keyhex>.unit`, where `<root>` is
`$FIX_CHUNK_CACHE_DIR`, else `$XDG_CACHE_HOME/fix/chunks`, else
`~/.cache/fix/chunks`.

**The binary's identity is deliberately absent from the key** — the
directory layout carries it. `<build-id>` is the linker GNU build-id
(`exe.build_id = .sha1` in `build.zig`), read at runtime from the
already-mapped program headers via `dl_iterate_phdr` — no file IO, and
content-derived, so it survives reproducible rebuilds and nix-store copies
whose mtimes are epoch. Platforms without a phdr walk or a build-id note
fall back to a hash of the executable's size + mtime. On startup
(`resolveChunkCache`), sibling generation directories — caches written by
*other* builds of fix — are swept, best-effort. A rebuilt compiler therefore
starts from an empty directory automatically: **no manual format-version
bump is needed for binary changes**. `format_version` remains only as a
same-binary schema guard (a blob written by the same build through an older
cache layout rejects as `Stale`).

## Id normalization and remapping

At write time (`chunk_cache.serialize`), every id-carrying reference becomes
a unit-local ordinal:

- **Strings** — a write-time string table, deduped by `InternId`, stores the
  actual text; operands index into it.
- **Chunks** — the unit's chunk ids in registration order (children before
  parents, the unit's top-level chunk last); a `chunk_id` operand becomes
  its ordinal.
- **Deferred entries** and **name-tree nodes** get the same treatment
  (name nodes serialize their parent chain, parent-before-child).

At load time the mapping inverts: strings re-intern into the fresh session's
table, chunks/deferred entries register fresh ids, and a generic **operand
scanner** walks each chunk's code rewriting ordinals back to real ids in
place. The scanner is driven entirely by `opcode.layout` — the same
exhaustive per-opcode operand table the disassembler uses — so a new operand
shape is a compile-time-safe extension point, not a silent gap. Comptime
field-count guards on `Chunk`, `SchedulingHints`, and `deferred_table.Entry`
turn a shape change into a build error pointing at the (de)serializer.

Deferred records precede chunk records in the blob: the loader registers
deferred entries first, so `thunk_defer` operands can remap while chunks
stream in.

## The Unfit tail

Some opcodes encode an `InternId` (or `ChunkId`) in a narrow **u16**
operand. Normalized ordinals always fit at write time (a unit rarely has 65k
distinct strings), but the *remapped* fresh id at load time can exceed
`0xFFFF` once the loading session has interned past 65k strings — common
deep into a nixpkgs evaluation. Such a unit rejects with `Unfit` and
recompiles from source. Correctness is unaffected; the census (below) counts
it as a reject.

A second remap casualty is **sortedness**: the compiler bakes ascending
interned-name order into `attrs_new_named_srt` / `attrs_new_named_pos_srt`
side-table ranges, but ascending order under the writer's intern ids is not
ascending under the remapped ids. The loader checks each site and, when the
order broke, rewrites the opcode to its unsorted twin (`attrs_new_named` /
`attrs_new_named_pos`), which sorts at build time — the values were emitted
positionally, so the name range itself cannot be re-sorted. Self-contained
(name, …) pair ranges — the `_pos` variant's `attr_pos` slice and
`attr_bind`'s operand pairs — are simply re-sorted in place.

## Deferred compilation

Deferred (force-time) per-attr bodies (see [lazy-compile.md](lazy-compile.md))
serialize as their **elided spans** — an (offset, len) into the unit's
source, plus the entry's captured scope. Only parser-elided bodies qualify:
their span was chosen by `scanElidableBody` to re-parse standalone, whereas
a regular node's span excludes leading keywords (`with lib; …` spans start
at `lib`), so re-parsing it would fail or change meaning. A unit with a
non-elided deferred body is `Uncacheable` and just never writes.

On load, each deferred entry synthesizes a fresh `.elided` node in an AST
arena the engine retains for its lifetime — the same lifetime rule an eager
compile's retained arena follows.

## Debugger and tooling bypass

`chunkCacheKey` returns null — no read, no write — for:

- **`preserve_bindings`** (set by `--debugger`): debug sessions compile
  source-shaped, unoptimized bindings so breakpoints and scope inspection
  resolve locals exactly as written. They must neither load an optimized
  cached unit nor poison the cache with a debug-shaped one.
- **`capture_names`** (`fix disasm`, the REPL's VM explorer): these sessions
  carry per-chunk name sidecars the blob doesn't round-trip.
- **Scoped or pathless units** (repl overlays, `scopedImport`, plain
  expression strings): only file-backed compiles are keyed.

## Knobs and census

- **`FIX_NO_CHUNK_CACHE=1`** disables the cache wholesale (any value other
  than `0`).
- **`FIX_CHUNK_CACHE_DIR`** overrides the cache root.
- **`FIX_LET_FLOAT_STATS=1`** prints a chunk-cache census at engine teardown
  alongside the let-float one: **hits** (unit loaded), **misses** (no blob
  for the key), **writes** (unit published), **rejects** (blob present but
  refused — `Unfit`, `Corrupt`, `Stale`, or an `Uncacheable` write). Rejects
  also print their error name and path under this flag.
- **`FIX_CC_DEBUG`** prints the source location of a `Corrupt` rejection
  inside the (de)serializer.

## Concurrency and the writer lane

Serialization runs inline in `writeCachedUnit` — it reads live
compiler/registry state — but the file IO goes to a single-worker background
lane (`base.BlockingPool`, started with the cache state), so a cold run's
demand path never waits on the disk. The lane drains in
`Engine.flushChunkCacheWrites` (called by `deinit`, and explicitly on
`fix eval`'s fast-exit path, which skips `deinit` by design — without that
flush, queued blobs would be dropped at process exit). The census `writes`
counter is bumped by the lane, so it is only final after the flush. If the
lane fails to start, writes fall back to synchronous.

Writes are atomic: the blob lands in a randomly-suffixed `.tmp-` sibling and
renames into place; a failed rename deletes the staging file. Concurrent
workers (or concurrent fix processes) may race to write the same unit — both
serialize equivalent bytes for their own session, last rename wins, and
either result is a valid blob for every future reader. Loads read whole
files, so a reader never observes a partial write.

## Crash safety

A process killed mid-write cannot corrupt the cache: the final path only
ever appears via rename, so a reader sees either nothing or a complete blob.
A kill between write and rename leaks the staging file; `resolveChunkCache`
sweeps `.tmp-*` files older than an hour from the current generation (the
age gate spares a concurrently-running fix's in-flight staging files — and
even a wrongly-swept one only fails that writer's best-effort rename).

Writes are deliberately not fsynced, so a *system* crash can rename a blob
whose data never hit disk. The header therefore carries a whole-payload
Wyhash checksum, verified before any deserialization: torn writes, external
truncation, and bit rot inside operand bytes all reject as `Corrupt` and the
unit recompiles from source — and the rewrite heals the cache file in the
same run.

## Measured

Warm nixos-minimal evaluation at `w=1`: **1.740s** with the cache vs
**2.149s** with `FIX_NO_CHUNK_CACHE=1` — **1.23× faster**, the parse +
compile share of the run.

At high worker counts on evaluation-bound workloads the cache is neutral:
warm full-universe at `w=8` is 52.4s vs 52.0s without — compilation
parallelizes off the critical path there, so there is nothing left to skip.
The win is serial and startup latency, which is exactly where interactive
`fix eval` / `fix build` invocations live. A full-universe cache generation
is ~250MB on disk (40,786 units).

## Invariants

- **The cache only skips work.** Every failure mode — missing, `Stale`,
  `Corrupt`, `Unfit`, an `Uncacheable` unit — falls back to compiling from
  source; evaluation results are identical either way.
- **Binary identity lives in the directory, not the key.** One generation
  directory per build-id; siblings are swept at startup. Binary changes
  never require a `format_version` bump.
- **No session-relative id is ever stored raw.** Every `InternId`,
  `ChunkId`, deferred id, and `NameId` round-trips through unit-local
  ordinals; the operand walk is `opcode.layout`-driven and exhaustive.
- **Sorted invariants are restored under the remapped ids** — by opcode
  rewrite where the pairing is positional, by in-place re-sort where the
  range is self-contained.
- **Debug sessions see fresh compiles**, in both directions.
- **Writes are atomic**; racing writers converge on a valid blob.

Out of scope: how a unit's residual `let` compiles → [pipeline.md](pipeline.md);
deferred per-attr compilation itself → [lazy-compile.md](lazy-compile.md);
the codegen flags folded into the key → [let-float.md](let-float.md).

Code: `src/expr/bytecode/chunk/cache.zig` (serialize/load, key, build-id);
`src/expr/evaluator.zig` (`resolveChunkCache`, `chunkCacheKey`,
`tryLoadCachedUnit`, `writeCachedUnit`)
