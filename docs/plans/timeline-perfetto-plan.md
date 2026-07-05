# Timeline → maximal Perfetto traces

Goal: the timeline probe emits maximally-useful Perfetto traces for four lenses —
**serial critical path, work-stealing/work-first extraction, speculation & RSS, GC
pauses** — runtime-enabled (no rebuild). Lands on `main` as the common base.
Branch: `feat/timeline-perfetto` (off main, which has FIX_MEM_REPORT + FIX_SPEC_BACKLOG).

Format stays Chrome-trace JSON (supports slices/instants/counters/**flows**/**async**/args
= ~90% of the ceiling). Perfetto protobuf (interning) only if trace *size* bites.

Emitter is a lock-free atomic-append event buffer + name arena + per-worker span
stacks (src/probe/timeline.zig). Nesting constraint (spans mustn't straddle a fiber
yield) is solved for new fine-grained work by using **async events** (don't nest).

## Status (branch feat/timeline-perfetto, off main)
A/B/C/D DONE + verified (byte-identical off-path, valid Perfetto JSON via
`--timeline=path` on a NORMAL build). All four lenses live in one trace.
Commits: 697ed5e (A foundation), b921deb (B steal flows), 2b72a58 (C spec/RSS
counters), 5d77357 (--timeline trigger), e2ff910 (D source labels), ab4e099
(critical-path track).

DONE since: rich label coverage (attrset thunks, file-id fix, deferred via cached
line index, mapAttrs/map-genList apply-glue by applied fn); #1 unified quantum +
crit-wait labels (shared `thunkLabel`); #2 source labels as interned (file_id,line)
refs resolved at dump (no arena dup → dropped-names eliminated). Commits 215ab38
(#1), 2881d51 (#2) + the label batch.

Remaining, with ROI assessment:
- **crit-wait labels for non-bytecode waits** (imports/derivation builtins show
  as bare "wait") — worthwhile follow-up (label with builtin name).
- **GC coarse STW spans** (-Dgc-only; fine minor/conc ride from gc-concurrent).
- **async fibers** — LOW ROI: per-fiber tracks explode; a single stacked async
  band adds little over the source-labelled quanta + fiber args (already show
  per-fiber activity, filterable via Perfetto SQL). Skipped.
- **wake arrows** — the demand-chain subset is already the crit-wait track;
  full graph is too dense (millions of resolves). Skipped.
- **stall markers** — redundant: the pre-park spin already avoids parking with
  work pending; idle-because-no-work is shown by park spans + the crit track.
- **flamegraph naming** — effectively DONE: quanta named `run: file:line` let
  Perfetto's slice aggregation / pivot table produce a source-level breakdown.

## Stages

- **A — Foundation (runtime gating + richer emitter). DONE.** DONE-criteria: `FIX_TIMELINE`
  env (and `--timeline`) activate on a NORMAL build (timeline always compiled in,
  `active` is the runtime gate, `on()` accessor; ~free when off — predictable branch
  at quantum granularity). Adopt the richer emitter (counter tracks, rich args,
  per-quantum task labels). Verify: valid JSON, richer trace.
- **B — Work-stealing flows.** Flow arrows (ph:s/f) from a push to its steal, for
  work-first continuations + tasks + ready fibers (payload-derived flow ids, no new
  struct fields where possible). Cont/task/ready queue-depth counters. Verify: arrows
  render push→run across worker tracks.
- **C — Speculation & RSS + GC.** Counter tracks: spec-backlog, cont-pending,
  pending-tasks, RSS, alloc-rate, live-set. Markers: spec submit/reject/bail. GC phase
  spans (STW mark/sweep on main; minor/conc stay on gc-concurrent) + gc_wait across
  workers + reclaim args. Verify: spec-flood-vs-RSS correlation chart.
- **D — Serial critical path.** Source-location labels on quanta (chunk_id → file:line
  via source map). Stall markers (parked while ≥N helpers idle). Stretch:
  reconstructed critical-path track (park→resolve→park chain).
- **E — Ceiling extras.** Fibers as migrating async slices + wake arrows. SQL-friendly
  typed args + consistent source-location slice names (→ Perfetto flamegraph / pivot).

## Notes
- `worker.zig`'s `runFiber`/`parkAndAccount` hold the only HOT instrumentation →
  everything else is cold (per-file/collection/steal). Runtime branch is enough.
- Flow ids: derive from payload (continuation list_id<<32|lo, task thunk_id, fiber_id)
  to avoid threading new fields; rare collisions only draw an extra arrow.
- GC-phase spans for minor/concurrent-major live in gc-concurrent-only collectors;
  they ride along when that branch merges. Main gets STW mark/sweep spans.
