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
}: let
  inherit (lib) optional optionals;

  nixpkgs = sources.nixpkgs;
  homeManager = pkgs.home-manager.src;
  workloads = ../bench/workloads;

  # One row per evaluator, each in its best default configuration (fix at its
  # automatic worker count, Determinate at --eval-cores 0 = all cores). fix
  # gets explicit compile-cache lanes so the persistent chunk cache is never
  # silently flattering: the cold lane's cache directory is wiped before
  # every timed run, the warm lane's persists (hyperfine's warmup run
  # populates it). @CACHE_*@ placeholders are substituted at runtime.
  fixTools = json:
    optionals (fix != null) (
      let
        base = "${fix}/bin/fix eval${
          if json
          then " --json"
          else ""
        } --strict --no-progress";
        fileArg =
          if json
          then " --file"
          else "";
      in [
        "fix (warm)|fix|${base} --compile-cache-dir @CACHE_WARM@${fileArg}"
        "fix (cold)|fix|${base} --compile-cache-dir @CACHE_COLD@${fileArg}"
      ]
    );

  detsysTools = {json ? false}:
    optionals (detsys != null) [
      (
        if json
        then "detsys|detsys|${detsys}/bin/nix eval --json --eval-cores 0 --file"
        else "detsys|detsys|${detsys}/bin/nix-instantiate --eval --strict --eval-cores 0"
      )
    ];

  scalarTools =
    fixTools false
    ++ optional (nix != null) "nix|nix|${nix}/bin/nix-instantiate --eval --strict"
    ++ optional (lix != null) "lix|lix|${lix}/bin/nix-instantiate --eval --strict"
    ++ detsysTools {};

  tortureTools = scalarTools;

  realworldTools = scalarTools;

  # JSON workloads return wide trees of independent values. `nix eval --json`
  # is the path on which Determinate performs parallel deep forcing.
  jsonTools =
    fixTools true
    ++ optional (nix != null) "nix|nix|${nix}/bin/nix eval --json --file"
    ++ optional (lix != null) "lix|lix|${lix}/bin/nix eval --json --file"
    ++ detsysTools {json = true;};

  # Human-readable identity of a store path for the provenance record:
  # the name without the 32-char /nix/store hash prefix and its dash.
  strippedName = path: builtins.substring 33 (-1) (baseNameOf (toString path));
  # The npins channel pin carries the nixpkgs release identity in its URL
  # (the fetched store path is just "source").
  nixpkgsPinLabel = let
    pin = (builtins.fromJSON (builtins.readFile ../npins/sources.json)).pins.nixpkgs;
  in
    pin.url or (strippedName nixpkgs);

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

    hugepages_min_available="$1"
    huge_dir=/sys/kernel/mm/hugepages/hugepages-2048kB

    if [[ -r "$huge_dir/nr_hugepages" && -r "$huge_dir/free_hugepages" && -r "$huge_dir/resv_hugepages" ]]; then
      huge_total="$(<"$huge_dir/nr_hugepages")"
      if (( huge_total > 0 )); then
        huge_free="$(<"$huge_dir/free_hugepages")"
        huge_reserved="$(<"$huge_dir/resv_hugepages")"
        huge_available=$((huge_free - huge_reserved))
        if (( huge_available < hugepages_min_available )); then
          echo "fix-bench needs $hugepages_min_available available 2 MB huge pages; found $huge_available ($huge_free free, $huge_reserved reserved)" >&2
          echo "free hugetlb capacity or lower HUGETLB_MIN_AVAILABLE before recording results" >&2
          exit 1
        fi
      fi
    fi

    # Release clean page-cache/slab pages, then coalesce the resulting free
    # pages so every run starts with the same opportunity to obtain THPs.
    # Persistent HugeTLB pages are a shared system pool and remain untouched.
    ${pkgs.coreutils}/bin/sync
    printf '3\n' > /proc/sys/vm/drop_caches
    printf '1\n' > /proc/sys/vm/compact_memory
  '';
  prepareMemory = pkgs.writeShellScript "fix-bench-prepare-memory" ''
    set -euo pipefail
    exec sudo ${reclaimMemoryAsRoot} "$@"
  '';
  # Per-run preparation for the cold compile-cache lane: the usual memory
  # reclaim (when enabled), then wipe the lane's cache directory so every
  # timed run pays the full parse + compile cost.
  prepareCold = pkgs.writeShellScript "fix-bench-prepare-cold" ''
    set -euo pipefail
    reclaim="$1"
    hugetlb_min="$2"
    dir="$3"
    if [[ "$reclaim" == 1 ]]; then
      sudo ${reclaimMemoryAsRoot} "$hugetlb_min"
    fi
    rm -rf -- "$dir"
  '';
in
  pkgs.writeShellApplication {
    name = "fix-bench";
    runtimeInputs = [
      pkgs.hyperfine
      pkgs.coreutils
      pkgs.gawk
      plotPython
    ];
    text = ''
      usage() {
        cat <<'EOF'
      usage: fix-bench [all|torture|realworld|json ...]

      environment:
        RUNS=N              measured runs per command (default: 5)
        WARMUP=N            warmup runs per command (default: 1)
        RECLAIM_MEMORY=0    skip per-run cache reclaim and memory compaction
        HUGETLB_MIN_AVAILABLE=N
                            minimum unreserved free 2 MB pages when a pool is
                            configured (default: 1024; 0 disables the check)
        OUT=DIR             output directory (default: /tmp/fix-bench.XXXXXX)
        TOOLS=RULE,...      select evaluator rows: group, exact name, or /Bash ERE/;
                            prefix a rule with - to exclude it. If every rule
                            is negative, all tools start included.
                            Default rows: fix (warm), fix (cold), nix, lix,
                            detsys — every tool in its best configuration; the
                            fix rows make the compile cache explicit (cold is
                            wiped before every timed run).
                            Groups: fix, detsys
                            Examples: TOOLS=fix,lix
                                      TOOLS='fix (warm)',detsys
                                      TOOLS=-lix
        WORKLOADS=a,b,c     include only these workload names
                            (realworld adds all-configs: every config on one
                            command line)
        BENCH_NIX_PATH=...  override the pinned benchmark NIX_PATH
      EOF
      }

      if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
        usage
        exit 0
      fi

      runs="''${RUNS:-5}"
      warmup="''${WARMUP:-1}"
      reclaim_memory="''${RECLAIM_MEMORY:-1}"
      hugetlb_min_available="''${HUGETLB_MIN_AVAILABLE:-1024}"
      if [[ ! "$hugetlb_min_available" =~ ^[0-9]+$ ]]; then
        echo "invalid HUGETLB_MIN_AVAILABLE value: $hugetlb_min_available (expected a non-negative page count)" >&2
        exit 2
      fi
      # Preparation before every timed run: memory reclaim for all rows, plus
      # a cache wipe for the cold compile-cache lane. hyperfine takes one
      # --prepare per command, so these are built per row in the suite loop.
      reclaim_flag=0
      base_prepare=true
      case "$reclaim_memory" in
        1|true|yes)
          if ! command -v sudo >/dev/null; then
            echo "RECLAIM_MEMORY requires sudo in PATH (or set RECLAIM_MEMORY=0)" >&2
            exit 1
          fi
          echo "authorizing per-run memory reclaim with sudo"
          sudo -v
          reclaim_flag=1
          base_prepare="${prepareMemory} $hugetlb_min_available"
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
      warm_cache_dir="$out/compile-cache-warm"
      cold_cache_dir="$out/compile-cache-cold"
      cold_prepare="${prepareCold} $reclaim_flag $hugetlb_min_available $cold_cache_dir"

      pinned_nix_path=${lib.escapeShellArg "nixpkgs=${nixpkgs}:home-manager=${homeManager}"}
      export NIX_PATH="''${BENCH_NIX_PATH:-$pinned_nix_path}"

      # Every result tree records when, on what, and against which inputs it
      # was measured — numbers without provenance are not publishable.
      if [[ -r /proc/cpuinfo ]]; then
        cpu_model="$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)"
      else
        cpu_model="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
      fi
      if [[ -r /proc/meminfo ]]; then
        mem_total="$(awk '/^MemTotal/ {printf "%.0f GiB", $2 / 1048576}' /proc/meminfo)"
      else
        mem_total="$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f GiB", $1 / 1073741824}' || echo unknown)"
      fi
      {
        echo "# Benchmark provenance"
        echo
        echo "- date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "- fix commit: ''${FIX_BENCH_COMMIT:-unknown (run via ./bench.sh to record it)}"
        echo "- cpu: $cpu_model ($(nproc) cores)"
        echo "- memory: $mem_total"
        echo "- kernel: $(uname -srm)"
        echo "- runs: $runs measured, $warmup warmup, memory reclaim: $reclaim_memory"
        echo "- fix: ${strippedName fix}"
        ${lib.optionalString (nix != null) ''echo "- nix: ${strippedName nix}"''}
        ${lib.optionalString (lix != null) ''echo "- lix: ${strippedName lix}"''}
        ${lib.optionalString (detsys != null) ''echo "- detsys: ${strippedName detsys}"''}
        echo "- nixpkgs pin: ${nixpkgsPinLabel}"
        echo "- home-manager pin: ${strippedName homeManager}"
      } > "$out/provenance.md"
      echo "provenance: $out/provenance.md"

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

        run_workload() {
          local name="$1"
          shift
          echo "-- $name --"
          local args=() prepare_flags=() tool label tool_fields group cmd
          for tool in "''${tools[@]}"; do
            label="''${tool%%|*}"
            tool_fields="''${tool#*|}"
            group="''${tool_fields%%|*}"
            tool_selected "$label" "$group" || continue
            cmd="''${tool_fields#*|} $*"
            cmd="''${cmd//@CACHE_WARM@/$warm_cache_dir}"
            if [[ "$cmd" == *@CACHE_COLD@* ]]; then
              cmd="''${cmd//@CACHE_COLD@/$cold_cache_dir}"
              prepare_flags+=(--prepare "$cold_prepare")
            else
              prepare_flags+=(--prepare "$base_prepare")
            fi
            args+=(-n "$label" "$cmd")
          done

          if [[ "''${#args[@]}" -eq 0 ]]; then
            echo "no tools selected for $suite" >&2
            exit 2
          fi

          hyperfine --shell=none --warmup "$warmup" --runs "$runs" --sort command \
            "''${prepare_flags[@]}" \
            --export-json "$suite_out/$name.json" \
            --export-markdown "$suite_out/$name.md" \
            "''${args[@]}"
          json_files+=("$suite_out/$name.json")
          all_json_files+=("$suite_out/$name.json")
          ran=1
        }

        suite_files=()
        for f in "$workload_dir"/*.nix; do
          suite_files+=("$f")
          name="$(basename "$f" .nix)"
          workload_selected "$name" || continue
          run_workload "$name" "$f"
        done

        # The whole suite passed on ONE command line: independent top-level
        # evaluations that a parallel evaluator can overlap. Scalar rows
        # only — the json rows take exactly one --file argument.
        if [[ "$suite" == realworld ]] && workload_selected all-configs; then
          run_workload all-configs "''${suite_files[@]}"
        fi

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
      find "$out" -mindepth 1 -maxdepth 1 -name 'summary*' -print | sort
      echo "suite charts:"
      find "$out" -mindepth 2 -maxdepth 2 -name 'summary*' -print | sort
    '';
  }
