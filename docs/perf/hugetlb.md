# Huge-page heap backing (`--hugetlb`)

*Explicit 2 MB hugetlb pages under the evaluator's large mappings.*

## What it does

With `--hugetlb` engaged, several large evaluator mappings can use explicit
`MAP_HUGETLB` backing instead of ordinary pages:

- the **flat object store** (`base/segments.zig FlatStore`) — a reserved
  huge-page *prefix* grown chunk-wise (32 MB) ahead of the bump cursor when
  explicit hugetlb is engaged. Otherwise its ordinary `MAP_NORESERVE`
  mapping is advised with `MADV_HUGEPAGE`, allowing transparent huge pages
  with automatic 4 KB fallback;
- the **value/attr/attr-pos segment stores** — their ≥64 MB doubling-tail
  segments are self-mapped with the same chunk-grown prefix scheme
  (`StableSegments` `huge_overlay_min`), so a mostly-empty 128–256 MB tail
  segment no longer bills its full size against the pool up front;
- **block-cache blocks of ≥2 MB** (`base/block_cache.zig`) — the 2–64 MB
  class blocks and >64 MB pass-throughs that back the smaller segments,
  parse/compile arenas, and retained ASTs.

One 2 MB page covers the address range of 512 4 KB pages. Point-in-time
measurements from 2026-07-10 on `test/nixos_toplevel.nix` (ReleaseFast): **w=1 −8.3%**
wall (exact, 3/3 interleaved pairs), w=8 **page faults −57% / dTLB misses
−47%**, and it eliminates a +202 ms bimodal slow mode under memory-pressure
co-load entirely (w=16 co-loaded −20%).
Transparent huge pages do cover the advised, sequentially-grown flat store
(~750 MB `AnonHugePages` on the NixOS workload), but the short-lived block and
segment mappings remain unreliable candidates. Explicit hugetlb also retains
lower fault overhead and deterministic backing under memory pressure.

## Provisioning

The kernel pool is preallocated, system-wide, and *carved out of* general
memory — pages sit in the pool whether or not anything uses them:

```
sudo sysctl vm.nr_hugepages=2048        # 4 GB pool of 2 MB pages
```

(Persist in `/etc/sysctl.d/`; allocate early after boot — a fragmented
machine may not be able to assemble the pages later.) The profiled NixOS
toplevel evaluation used ~1.65 GB of pool at peak. Every accepted hugetlb mapping is
write-prefaulted; chunk-grown prefixes keep its unused grow-ahead slack to
one 32 MB chunk per active store. A 4 GB pool (`2048`) leaves headroom;
undersizing is safe (overflow falls back to normal pages) but gives up
part of the win.

## Modes

| Mode | Behaviour |
|---|---|
| `auto` (default) | engage only if the default huge page size is 2 MB and the pool has ≥256 MB unreserved (`free_hugepages − resv_hugepages`); otherwise behave exactly like `off`. Per-mapping failures after engagement fall back silently. |
| `on` | always attempt hugetlb; warn once if the pool can't serve a mapping, then fall back. |
| `off` | never. |

`--hugetlb MODE` accepts `auto`, `on`, or `off`; when omitted it defaults to
`auto`. It is resolved in `cli/setup.zig:applyMemoryBacking` **before**
`Engine.init` maps the heap
— deliberately not a `nix.conf`/`--option` setting, since config loads after
the flat store already picked its mapping.

## Failure story (no resource-exhaustion SIGBUS)

Before publishing a hugetlb mapping, `fix` applies three safeguards:

1. **non-NORESERVE** `mmap` reserves every pool page up front;
2. `MADV_DONTFORK` keeps the private mapping out of exec-only subprocesses,
   eliminating the unreserved COW-page hazard after `fork`;
3. `MADV_POPULATE_WRITE` instantiates every page under the current
   NUMA/cpuset policy and returns an error instead of delivering the SIGBUS
   that the corresponding later access could have caused.

Failure at any step unmaps the candidate and uses ordinary pages:

- **block cache** — a failed candidate mapping falls back to the backing
  allocator for that block; ownership of live hugetlb blocks is tracked so
  frees/resizes route to `munmap` and never poison the backing allocator.
- **flat store** — the giant virtual reservation stays an ordinary
  `MAP_NORESERVE` mapping, advised for transparent huge pages; only its low
  prefix is overlaid (`MAP_FIXED`) with reserved huge pages, extended under
  the store's write lock *before* the cursor moves past it. A failed extension
  permanently degrades the store's tail to the ordinary advised mapping (THP
  where available, 4 KB pages otherwise). The same invariant guarantees a
  later overlay can never cover handed-out slots. Draining the pool mid-run
  can only stop future extensions.

Shrinking the pool (`vm.nr_hugepages=0`) under a running eval is safe:
accepted mappings are already instantiated; new mappings fail and fall back.
Hardware-poison SIGBUS remains possible, as it does for memory generally.

## Accounting caveat

Hugetlb pages are **invisible to every kernel RSS figure** (`VmRSS`, `VmHWM`,
`ru_maxrss`, `statm`) — a run with 1.6 GB of hugetlb heap reports ~280 MB
VmHWM. `base/hugetlb.zig` tracks mapped/peak bytes internally, and the
diagnostic consumers fold them in:

- `--mem-report` prints the hugetlb peak, a combined footprint line, and
  the kernel-truth faulted figure from smaps (`Private_Hugetlb`).
- the `--timeline` `rss_mb` counter carries a separate `hugetlb` series.
- the **GC budget needs no fix**: it gates on internal
  `totalReservedBytes()` slot counting, not RSS. The default budget is half
  `MemTotal`, with default bounds of 256 MiB–32 GiB, so it is stable and independent of
  hugetlb RSS accounting.

External monitoring that watches `fix`'s RSS will under-read by the hugetlb
share; check `HugetlbPages:` in `/proc/<pid>/status` or the pool counters in
`/proc/meminfo`.
