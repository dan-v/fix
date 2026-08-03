# Changelog

All notable changes to `fix` are documented in this file.

## [0.3.0] - 2026-08-02

### Added

- A whole-nixpkgs differential harness (`test/nixpkgs/`, `zig build
  test-nixpkgs`): evaluates the entire nixpkgs CI job universe (about 80,000
  derivations) with `fix` and a reference Nix and compares every `.drv` store
  path. The pinned universe currently evaluates to identical derivation paths
  (80,586 of 80,586 attributes, including agreement on which attributes fail
  to evaluate). CI runs it as a sharded chunk matrix.
- Channel resolution: when neither `-I` nor `$NIX_PATH` provides a lookup
  path, `<nixpkgs>` and friends resolve from the user and root channel
  profiles, as Nix does.
- GC detector builds: swept thunk state is poisoned so a stale reference
  traps at the point of use instead of silently reading recycled memory. CI
  runs a tight-budget detector lane on a nixpkgs chunk.

### Fixed

- `builtins.toXML` forces its argument strictly, as Nix does. A
  speculatively resolved but undemanded thunk could previously bake
  `<unevaluated />` into a cached string; the demand-sensitive rendering is
  now exclusive to the CLI's lazy `--xml` output.
- Two parallel-evaluation GC rooting bugs found by the detector: evaluation
  results are rooted across the native handoff, and a speculative force
  task's thunk is rooted for the task's whole duration.
- Merged dotted `let` groups (`let a.b = …; a.c = …;`) get their own binding
  cells instead of miscompiling.
- `fromTOML` handles escape sequences in multi-line strings.
- Type predicates (`isInt` and friends) recognize boxed integers.
- The strict attribute-literal merge carries attribute positions, so
  `unsafeGetAttrPos` and error messages keep their locations.
- Selecting a derivation output (`drv.out`) no longer computes the
  derivation eagerly.
- `FileCache` records lstat-accurate file kinds, fixing NAR hashes for
  symlinks.
- Discarded output dependencies (`builtins.unsafeDiscardOutputDependency`)
  are honored in derivation contexts.
- The VM value and frame stacks are sized so call chains that are legal
  under `max-call-depth` no longer overflow (deep nixpkgs
  `lib.recursiveUpdate` spines evaluate where Nix and Lix already did).

## [0.2.0] - 2026-08-02

### Added

- Local and modern Lix store selectors: `unix://` sockets with
  `protocol=legacy`, `any`, and `legacy-combined`, explicit `ssh-ng://` stores
  with `port`, `ssh-key`, and `compress` settings, and bare daemon-socket
  paths. CI now exercises live CppNix and Lix daemons.
- Retained failure diagnostics: cached evaluation failures keep their full
  message, origin, and deep stack trace across parallel evaluation and replay.
- Debugger: a garbage-collection command at the paused prompt, and paused
  sessions now root their heaps so exploration survives collection.
- A concurrency verification stack: TLA+ models of the future-wait,
  fiber-dispatch, shutdown, and GC-barrier protocols (checked for safety,
  deadlock freedom, and liveness, with a mutation check per model);
  ThreadSanitizer instrumentation with fiber-aware stack attribution;
  deterministic adversarial protocol tests; seeded stress lanes with
  serial/parallel differentials; and a nightly real-eval differential against
  reference Nix at eight workers, including a ThreadSanitizer lane.
- MIT license.

### Changed

- `fix` never delegates to an installed Nix or Lix: unsupported store
  selectors (`local`, `auto`, chroot roots, `lix-xp-1`) fail with specific
  diagnostics instead of falling back to a binary on `PATH`.
- The benchmark harness drops its snix timing row; the snix
  language-conformance suite remains.

### Fixed

- Data races found by the new verification lanes: growable-deque slot reuse,
  mutable state embedded in copied heap unions (the sibling-sweep mark and the
  merge-flatten memo), and the thunk speculation peek.
- Speculative failure propagation: failures computed on helper workers replay
  with the same error, message, and trace as serial evaluation.
- Contended future waiters park instead of spinning, and worker and scheduler
  teardown waits for in-flight external callbacks.
- SSH daemon invocation is hardened: validated destination, batch mode, and
  explicit rejection of unsupported settings.

## [0.1.0] - 2026-07-27

First public release.

### Added

- A from-scratch Nix parser, bytecode compiler, lazy evaluator, and command-line
  interface.
- Parallel evaluation with worker scheduling, fibers, speculative forcing, and
  a parallel garbage collector.
- Evaluation, instantiation, builds, flakes, development shells, program
  execution, configuration activation, and Nix daemon store operations.
- An interactive REPL, VM and heap explorer, source debugger, evaluation
  statistics, and Perfetto-compatible traces.
- Differential language, derivation, store-path, and benchmark-fixture
  compatibility tests.
- Nix packaging, shell completions, direnv integration, and modules for NixOS,
  nix-darwin, and Home Manager.
- Release builds for x86_64 Linux, aarch64 Linux, and aarch64 macOS.
