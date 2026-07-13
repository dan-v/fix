# Differential performance benchmark: fix vs nix vs lix vs snix.
#
# `nix-build -A bench && ./result/bin/fix-bench` runs hyperfine over every
# workload in ../bench/workloads for all four evaluators. The script closes
# over each evaluator and over a store copy of the workloads with the pinned
# nixpkgs / home-manager paths baked in, so it needs no network, build, search
# path, or ambient tooling at run time. It must run outside the sandbox (real
# timing, real cores, store access for instantiation), so it is a runnable
# script rather than a build that benchmarks itself.
#
# Every workload is one Nix file forced to a single value — torture cases to an
# int, real-world cases to the toplevel .drvPath (a string, so `--strict` never
# recurses into the derivation graph) — and each evaluator forces it the same
# way, so hyperfine compares like with like. A one-shot preflight drops any
# evaluator that cannot drive a given workload (printing why) rather than
# recording a misleading fast-failure time. `RUNS=N` overrides the run count.
{
  pkgs,
  lib,
  sources ? import ../npins,
  fix ? pkgs.callPackage ./fix.nix {release = "fast";},
  nix ? pkgs.nixVersions.latest,
  lix ? pkgs.lix,
  snix ? null, #(import sources.snix { }).snix.cli.eval,
}: let
  inherit (lib) optional optionals;
  nixpkgs = sources.nixpkgs;
  hm = pkgs.home-manager.src; # home-manager source, no extra pin needed

  # Store copy of the workloads with the pinned tree paths baked into the
  # real-world fixtures, so every evaluator reads a self-contained file.
  workloads = pkgs.runCommand "fix-bench-workloads" {} ''
    cp -r ${../bench/workloads} $out
    chmod -R +w $out
    for f in $out/realworld/*.nix; do
      substituteInPlace "$f" \
        --replace-quiet '@nixpkgs@'     '${nixpkgs}' \
        --replace-quiet '@homeManager@' '${hm}'
    done
  '';

  tools =
    # name|command-prefix (the workload file is appended to each).
    optional (nix != null) "nix|${nix}/bin/nix-instantiate --eval --strict"
    ++ optional (lix != null) "lix|${lix}/bin/nix-instantiate --eval --strict"
    ++ optional (snix != null) "snix|${snix}/bin/snix-eval -qq --strict"
    ++ optionals (fix != null) [
      "fix|${fix}/bin/fix eval --strict --workers=1 --no-progress --file"
      "fix-par|${fix}/bin/fix eval --strict --no-progress --file"
    ];

  quote = s: "\"${s}\"";
  spaceSep = builtins.concatStringsSep " ";
  toolsStr = spaceSep (map quote tools);
in
  pkgs.writeShellApplication {
    name = "fix-bench";
    runtimeInputs = [pkgs.hyperfine pkgs.coreutils];
    text = ''
      runs="''${RUNS:-10}"
      out="$(mktemp -d /tmp/fix-bench.XXXXXX)"

      tools=( ${toolsStr} )

      for f in ${workloads}/torture/*.nix ${workloads}/realworld/*.nix; do
        name="$(basename "$f" .nix)"
        echo "== $name =="
        args=()
        for t in "''${tools[@]}"; do
          cmd="''${t#*|} $f"
          # shellcheck disable=SC2086  # word-splitting the command is intended
          if timeout 300 $cmd >/dev/null 2>&1; then
            args+=(-n "''${t%%|*}" "$cmd")
          else
            echo "   dropped ''${t%%|*} (could not evaluate this workload)"
          fi
        done
        [ "''${#args[@]}" -gt 0 ] &&
          hyperfine --shell=none --warmup 1 --runs "$runs" \
            --export-markdown "$out/$name.md" "''${args[@]}"
      done

      echo; echo "markdown tables written to $out"
    '';
  }
