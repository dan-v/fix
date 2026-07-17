# Differential performance benchmark: fix vs Nix implementations.
#
# Build once, then run any suite independently:
#
#   nix-build -A bench
#   RUNS=3 ./result/bin/fix-bench torture
#   RUNS=3 ./result/bin/fix-bench realworld
#   RUNS=3 ./result/bin/fix-bench json
#
# With no suite (or with `all`), all three run into one /tmp/fix-bench.* tree.
# `TOOLS=nix,detsys-1core,fix-1core` selects rows by name, `WORKLOADS=...`
# selects workload basenames, `OUT=/path` selects the output directory, and
# `BENCH_NIX_PATH=...` overrides the pinned search path. Workloads themselves use
# <nixpkgs> / <home-manager>, so they are directly runnable with any suitable
# NIX_PATH.
{
  pkgs,
  lib,
  sources ? import ../npins,
  fix ? pkgs.callPackage ./fix.nix {release = "fast";},
  nix ? pkgs.nixVersions.latest,
  detsys ? (builtins.getFlake (builtins.unsafeDiscardStringContext (toString sources.determinate-nix)))
    .packages.${pkgs.stdenv.hostPlatform.system}.nix-cli,
  lix ? pkgs.lix,
  snix ? (import sources.snix {}).snix.cli.eval,
}: let
  inherit (lib) optional optionals;

  nixpkgs = sources.nixpkgs;
  homeManager = pkgs.home-manager.src;
  workloads = ../bench/workloads;

  # Torture keeps explicit one-core rows for core-efficiency comparisons while
  # also showing whether each parallel evaluator can exploit the workload.
  tortureTools =
    optional (nix != null) "nix|${nix}/bin/nix-instantiate --eval --strict"
    ++ optionals (detsys != null) [
      "detsys-1core|${detsys}/bin/nix-instantiate --eval --strict --eval-cores 1"
      "detsys-2core|${detsys}/bin/nix-instantiate --eval --strict --eval-cores 2"
      "detsys-allcore|${detsys}/bin/nix-instantiate --eval --strict --eval-cores 0"
    ]
    ++ optional (lix != null) "lix|${lix}/bin/nix-instantiate --eval --strict"
    ++ optional (snix != null) "snix|${snix}/bin/snix-eval -qqqq --no-warnings --strict"
    ++ optionals (fix != null) [
      "fix-1core|${fix}/bin/fix eval --strict --workers=1 --no-progress --file"
      "fix-2core|${fix}/bin/fix eval --strict --workers=2 --no-progress --file"
      "fix-autocore|${fix}/bin/fix eval --strict --no-progress --file"
    ];

  # Real-world scalar evaluation includes the scaling rows even though
  # Determinate's evaluator cores primarily help wide/deep result forcing.
  realworldTools =
    optional (nix != null) "nix|${nix}/bin/nix-instantiate --eval --strict"
    ++ optionals (detsys != null) [
      "detsys-1core|${detsys}/bin/nix-instantiate --eval --strict --eval-cores 1"
      "detsys-2core|${detsys}/bin/nix-instantiate --eval --strict --eval-cores 2"
      "detsys-allcore|${detsys}/bin/nix-instantiate --eval --strict --eval-cores 0"
    ]
    ++ optional (lix != null) "lix|${lix}/bin/nix-instantiate --eval --strict"
    ++ optional (snix != null) "snix|${snix}/bin/snix-eval -qqqq --no-warnings --strict"
    ++ optionals (fix != null) [
      "fix-1core|${fix}/bin/fix eval --strict --workers=1 --no-progress --file"
      "fix-2core|${fix}/bin/fix eval --strict --workers=2 --no-progress --file"
      "fix-autocore|${fix}/bin/fix eval --strict --no-progress --file"
    ];

  # JSON workloads return wide trees of independent values. `nix eval --json`
  # is the path on which Determinate performs parallel deep forcing. Snix is
  # omitted because snix-eval currently has no JSON output mode.
  jsonTools =
    optional (nix != null) "nix|${nix}/bin/nix eval --json --file"
    ++ optionals (detsys != null) [
      "detsys-1core|${detsys}/bin/nix eval --json --eval-cores 1 --file"
      "detsys-2core|${detsys}/bin/nix eval --json --eval-cores 2 --file"
      "detsys-allcore|${detsys}/bin/nix eval --json --eval-cores 0 --file"
    ]
    ++ optional (lix != null) "lix|${lix}/bin/nix eval --json --file"
    ++ optionals (fix != null) [
      "fix-1core|${fix}/bin/fix eval --json --strict --workers=1 --no-progress --file"
      "fix-2core|${fix}/bin/fix eval --json --strict --workers=2 --no-progress --file"
      "fix-autocore|${fix}/bin/fix eval --json --strict --no-progress --file"
    ];

  shellArray = tools: builtins.concatStringsSep " " (map lib.escapeShellArg tools);
  plotPython = pkgs.python3.withPackages (ps: [ps.matplotlib]);
in
  pkgs.writeShellApplication {
    name = "fix-bench";
    runtimeInputs = [pkgs.hyperfine pkgs.coreutils plotPython];
    text = ''
      usage() {
        cat <<'EOF'
      usage: fix-bench [all|torture|realworld|json ...]

      environment:
        RUNS=N              measured runs per command (default: 10)
        WARMUP=N            warmup runs per command (default: 1)
        OUT=DIR             output directory (default: /tmp/fix-bench.XXXXXX)
        TOOLS=a,b,c         include only these evaluator rows
        WORKLOADS=a,b,c     include only these workload names
        BENCH_NIX_PATH=...  override the pinned benchmark NIX_PATH
      EOF
      }

      if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
        usage
        exit 0
      fi

      runs="''${RUNS:-10}"
      warmup="''${WARMUP:-1}"
      if [[ -n "''${OUT:-}" ]]; then
        out="$OUT"
        mkdir -p "$out"
      else
        out="$(mktemp -d /tmp/fix-bench.XXXXXX)"
      fi

      pinned_nix_path=${lib.escapeShellArg "nixpkgs=${nixpkgs}:home-manager=${homeManager}"}
      export NIX_PATH="''${BENCH_NIX_PATH:-$pinned_nix_path}"

      if [[ "$#" -eq 0 || "''${1:-}" == "all" ]]; then
        suites=(torture realworld json)
      else
        suites=("$@")
      fi
      all_json_files=()

      tool_selected() {
        local name="$1"
        [[ -z "''${TOOLS:-}" ]] || [[ ",''${TOOLS}," == *",$name,"* ]]
      }

      workload_selected() {
        local name="$1"
        [[ -z "''${WORKLOADS:-}" ]] || [[ ",''${WORKLOADS}," == *",$name,"* ]]
      }

      for suite in "''${suites[@]}"; do
        case "$suite" in
          torture)
            workload_dir=${workloads}/torture
            tools=( ${shellArray tortureTools} )
            ;;
          realworld)
            workload_dir=${workloads}/realworld
            tools=( ${shellArray realworldTools} )
            ;;
          json)
            workload_dir=${workloads}/json
            tools=( ${shellArray jsonTools} )
            ;;
          *)
            echo "unknown benchmark suite: $suite" >&2
            usage >&2
            exit 2
            ;;
        esac

        suite_out="$out/$suite"
        mkdir -p "$suite_out"
        echo "== suite: $suite =="

        ran=0
        json_files=()
        for f in "$workload_dir"/*.nix; do
          name="$(basename "$f" .nix)"
          workload_selected "$name" || continue
          echo "-- $name --"
          args=()
          for tool in "''${tools[@]}"; do
            label="''${tool%%|*}"
            tool_selected "$label" || continue
            cmd="''${tool#*|} $f"
            args+=(-n "$label" "$cmd")
          done

          if [[ "''${#args[@]}" -eq 0 ]]; then
            echo "no tools selected for $suite" >&2
            exit 2
          fi

          hyperfine --shell=none --warmup "$warmup" --runs "$runs" --sort command \
            --export-json "$suite_out/$name.json" \
            --export-markdown "$suite_out/$name.md" \
            "''${args[@]}"
          json_files+=("$suite_out/$name.json")
          all_json_files+=("$suite_out/$name.json")
          ran=1
        done

        if [[ "$ran" -eq 1 ]]; then
          python3 ${../tools/render_bench.py} \
            --suite "$suite" \
            --output-dir "$suite_out" \
            "''${json_files[@]}"
        else
          echo "no workloads selected for $suite" >&2
          exit 2
        fi
        echo
      done

      python3 ${../tools/render_bench.py} \
        --suite "all selected suites" \
        --unified \
        --output-dir "$out" \
        "''${all_json_files[@]}"

      echo "benchmark results: $out"
      echo "unified charts:"
      find "$out" -mindepth 1 -maxdepth 1 -name 'summary.*' -print | sort
      echo "suite charts:"
      find "$out" -mindepth 2 -maxdepth 2 -name 'summary.*' -print | sort
    '';
  }
