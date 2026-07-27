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
# `TOOLS=fix,lix` selects a parameterized group plus an exact row; `/fix-.*/`
# selects by Bash ERE, and a leading `-` excludes (`TOOLS=fix,-fix-16core`).
# `WORKLOADS=...` selects workload basenames, `OUT=/path` selects the output
# directory, and `BENCH_NIX_PATH=...` overrides the pinned search path.
# Workloads themselves use <nixpkgs> / <home-manager>, so they are directly
# runnable with any suitable NIX_PATH.
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
  fixWorkerCounts = [
    1
    2
    8
    16
  ];
  fixTools = json:
    optionals (fix != null) (
      let
        base = "${fix}/bin/fix eval${
          if json
          then " --json"
          else ""
        } --strict";
      in
        map (
          workers: "fix-${toString workers}core|fix|${base} --workers=${toString workers} --no-progress --file"
        )
        fixWorkerCounts
        ++ ["fix-autocore|fix|${base} --no-progress --file"]
    );

  detsysTools = {
    json ? false,
    scaling ? false,
  }:
    optionals (detsys != null) (
      let
        base =
          if json
          then "${detsys}/bin/nix eval --json"
          else "${detsys}/bin/nix-instantiate --eval --strict";
        suffix =
          if json
          then " --file"
          else "";
        coreCounts =
          if scaling
          then [
            1
            2
            8
            16
          ]
          else [1];
      in
        map (
          cores: "detsys-${toString cores}core|detsys|${base} --eval-cores ${toString cores}${suffix}"
        )
        coreCounts
        ++ ["detsys-autocore|detsys|${base} --eval-cores 0${suffix}"]
    );

  # Scalar suites retain only Determinate's efficiency baseline and automatic
  # mode. JSON adds its wider deep-forcing scaling sweep.
  scalarTools =
    fixTools false
    ++ optional (nix != null) "nix|nix|${nix}/bin/nix-instantiate --eval --strict"
    ++ optional (lix != null) "lix|lix|${lix}/bin/nix-instantiate --eval --strict"
    ++ detsysTools {}
    ++ optional (snix != null) "snix|snix|${snix}/bin/snix-eval -qqqq --no-warnings --strict";

  tortureTools = scalarTools;

  realworldTools = scalarTools;

  # JSON workloads return wide trees of independent values. `nix eval --json`
  # is the path on which Determinate performs parallel deep forcing. Snix is
  # omitted because snix-eval currently has no JSON output mode.
  jsonTools =
    fixTools true
    ++ optional (nix != null) "nix|nix|${nix}/bin/nix eval --json --file"
    ++ optional (lix != null) "lix|lix|${lix}/bin/nix eval --json --file"
    ++ detsysTools {
      json = true;
      scaling = true;
    };

  shellArray = tools: builtins.concatStringsSep " " (map lib.escapeShellArg tools);
  plotPython = pkgs.python3.withPackages (ps: [ps.matplotlib]);
  reclaimMemoryAsRoot = pkgs.writeShellScript "fix-bench-reclaim-memory-root" ''
    set -euo pipefail

    if [[ "$EUID" -ne 0 ]]; then
      echo "fix-bench memory preparation must run as root" >&2
      exit 1
    fi
    if [[ ! -w /proc/sys/vm/drop_caches || ! -w /proc/sys/vm/compact_memory ]]; then
      echo "fix-bench memory preparation requires Linux VM sysctls" >&2
      exit 1
    fi

    # Release clean page-cache/slab pages, then coalesce the resulting free
    # pages so every run starts with the same opportunity to obtain THPs.
    # Explicit hugetlb mappings return to their configured pool at process
    # exit, so deliberately leave vm.nr_hugepages unchanged.
    ${pkgs.coreutils}/bin/sync
    printf '3\n' > /proc/sys/vm/drop_caches
    printf '1\n' > /proc/sys/vm/compact_memory
  '';
  prepareMemory = pkgs.writeShellScript "fix-bench-prepare-memory" ''
    set -euo pipefail
    exec sudo ${reclaimMemoryAsRoot}
  '';
in
  pkgs.writeShellApplication {
    name = "fix-bench";
    runtimeInputs = [
      pkgs.hyperfine
      pkgs.coreutils
      plotPython
    ];
    text = ''
      usage() {
        cat <<'EOF'
      usage: fix-bench [all|torture|realworld|json ...]

      environment:
        RUNS=N              measured runs per command (default: 10)
        WARMUP=N            warmup runs per command (default: 1)
        RECLAIM_MEMORY=0    skip per-run cache reclaim and memory compaction
        OUT=DIR             output directory (default: /tmp/fix-bench.XXXXXX)
        TOOLS=RULE,...      select evaluator rows: group, exact name, or /Bash ERE/;
                            prefix a rule with - to exclude it. If every rule
                            is negative, all tools start included.
                            Groups: fix, detsys (for parameterized profiles)
                            Examples: TOOLS=fix,lix
                                      TOOLS=fix,-fix-16core
                                      TOOLS='/fix-.*/,-/fix-..core/'
                                      TOOLS=-snix
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
      reclaim_memory="''${RECLAIM_MEMORY:-1}"
      prepare_args=()
      case "$reclaim_memory" in
        1|true|yes)
          if ! command -v sudo >/dev/null; then
            echo "RECLAIM_MEMORY requires sudo in PATH (or set RECLAIM_MEMORY=0)" >&2
            exit 1
          fi
          echo "authorizing per-run memory reclaim with sudo"
          sudo -v
          prepare_args=(--prepare ${prepareMemory})
          ;;
        0|false|no)
          ;;
        *)
          echo "invalid RECLAIM_MEMORY value: $reclaim_memory (expected 0 or 1)" >&2
          exit 2
          ;;
      esac
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

      tool_rules=()
      tool_has_include=0

      trim_tool_rule() {
        trimmed_tool_rule="$1"
        trimmed_tool_rule="''${trimmed_tool_rule#"''${trimmed_tool_rule%%[![:space:]]*}"}"
        trimmed_tool_rule="''${trimmed_tool_rule%"''${trimmed_tool_rule##*[![:space:]]}"}"
      }

      tool_rule_is_regex() {
        local selector="$1"
        [[ "''${#selector}" -ge 2 && "$selector" == /*/ ]]
      }

      tool_rule_regex() {
        local selector="$1"
        selector="''${selector#/}"
        printf '%s' "''${selector%/}"
      }

      validate_tool_rule() {
        local selector="$1"
        if [[ "$selector" == /* || "$selector" == */ ]]; then
          if ! tool_rule_is_regex "$selector"; then
            echo "invalid TOOLS regex rule (expected /ERE/): $selector" >&2
            exit 2
          fi
          local regex
          regex="$(tool_rule_regex "$selector")"
          set +e
          [[ "" =~ $regex ]]
          local status=$?
          set -e
          if [[ "$status" -eq 2 ]]; then
            echo "invalid TOOLS regular expression: $selector" >&2
            exit 2
          fi
        fi
      }

      if [[ -n "''${TOOLS:-}" ]]; then
        IFS=',' read -r -a tool_rules <<< "$TOOLS"
        for i in "''${!tool_rules[@]}"; do
          trim_tool_rule "''${tool_rules[$i]}"
          rule="$trimmed_tool_rule"
          if [[ -z "$rule" ]]; then
            echo "TOOLS contains an empty rule" >&2
            exit 2
          fi
          tool_rules[i]="$rule"
          selector="''${rule#-}"
          if [[ -z "$selector" ]]; then
            echo "TOOLS contains an empty exclusion rule" >&2
            exit 2
          fi
          if [[ "$rule" != -* ]]; then
            tool_has_include=1
          fi
          validate_tool_rule "$selector"
        done
      fi

      tool_rule_matches() {
        local name="$1"
        local group="$2"
        local selector="$3"
        if tool_rule_is_regex "$selector"; then
          local regex
          regex="$(tool_rule_regex "$selector")"
          [[ "$name" =~ $regex || "$group" =~ $regex ]]
        else
          [[ "$name" == "$selector" || "$group" == "$selector" ]]
        fi
      }

      tool_selected() {
        local name="$1"
        local group="$2"
        local rule selector
        local included=1
        if [[ "$tool_has_include" -eq 1 ]]; then
          included=0
        fi
        for rule in "''${tool_rules[@]}"; do
          selector="''${rule#-}"
          if tool_rule_matches "$name" "$group" "$selector"; then
            if [[ "$rule" == -* ]]; then
              return 1
            fi
            included=1
          fi
        done
        [[ "$included" -eq 1 ]]
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
            tool_fields="''${tool#*|}"
            group="''${tool_fields%%|*}"
            tool_selected "$label" "$group" || continue
            cmd="''${tool_fields#*|} $f"
            args+=(-n "$label" "$cmd")
          done

          if [[ "''${#args[@]}" -eq 0 ]]; then
            echo "no tools selected for $suite" >&2
            exit 2
          fi

          hyperfine --shell=none --warmup "$warmup" --runs "$runs" --sort command \
            "''${prepare_args[@]}" \
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
