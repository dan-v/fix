# Changelog

All notable changes to `fix` are documented in this file.

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
