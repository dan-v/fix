# fix

`fix` is a performance-focused parallel evaluator and command-line tool for the Nix language, written in Zig. It parses and evaluates expressions, fetches sources, computes derivations, and uses `nix-daemon` for store operations and builds. It targets byte-for-byte compatibility with `nix-instantiate`'s `.drv` output and is tested against the Lix and snix language test suites.

![fix evaluator benchmark](demo/benchmark.png)

![Building a NixOS toplevel with fix](demo/build-toplevel.gif)

![Using the fix REPL, VM inspector, and debugger](demo/repl.gif)

Build it with `nix-build`; the executable is `result/bin/fix`.

```sh
./result/bin/fix eval -E '1 + 2'
./result/bin/fix build -f default.nix -A fix
./result/bin/fix repl
```

For development, run `nix-shell --run 'zig build -Doptimize=ReleaseFast'`; the executable is then `zig-out/bin/fix`. Run `fix --help` for commands and see [the developer documentation](docs/README.md) for internals.
