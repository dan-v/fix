# Changelog

All notable changes to `fix` are documented in this file.

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
