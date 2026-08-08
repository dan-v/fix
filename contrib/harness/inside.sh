#!/usr/bin/env bash
# Container-side half of the harness (see harness.sh for the interface).
# Assumes: nixos/nix image, repo mounted at /work, /nix and /root on volumes.
# Also runs OUTSIDE the container on any host with nix (e.g. a CI runner):
# override FIX_HARNESS_REPO / FIX_HARNESS_CACHE, and point
# FIX_HARNESS_FIX_BIN at an already-built binary to skip the in-harness
# build.
set -euo pipefail

repo="${FIX_HARNESS_REPO:-/work}"
cache="${FIX_HARNESS_CACHE:-/root/.cache}"
results="$cache/harness-results"
mkdir -p "$cache" "$results"

# Build products live on the /root volume, NOT in the repo mount: the host
# tree keeps its native (darwin) zig-out, and incremental state survives.
out_current="$cache/fix-out-current"
out_baseline="$cache/fix-out-baseline"
export ZIG_GLOBAL_CACHE_DIR="$cache/zig-global"

nixpkgs_pin() {
    # Materialized store path of the npins nixpkgs pin (fetched once).
    nix-instantiate --eval --json -E "(import $repo/npins).nixpkgs.outPath" | tr -d '"'
}

ensure_tools() {
    # Comparison and measurement tools from the SAME pin the repo tests
    # against, resolved once into a buildEnv profile on the volume.
    if [[ ! -e "$cache/tools/bin/hyperfine" || ! -e "$cache/tools/bin/cmp" || ! -e "$cache/tools/bin/awk" || ! -e "$cache/tools/bin/pytest" || ! -e "$cache/tools/bin/tc" || ! -e "$cache/tools/bin/sed" ]]; then
        echo ">> resolving pinned tools (first run only)" >&2
        nix-build --no-out-link -o "$cache/tools" -E "
          with import (import $repo/npins).nixpkgs {};
          buildEnv {
            name = \"fix-harness-tools\";
            paths = [ nix-eval-jobs hyperfine jq time (python3.withPackages (ps: [ ps.pytest ])) git coreutils diffutils gawk gnused iproute2 ];
          }" >/dev/null
    fi
    export PATH="$cache/tools/bin:$PATH"
}

ensure_daemon() {
    # fix speaks only the daemon protocol; the image runs daemon-less by
    # default. Containers are ephemeral but /nix is a volume, so a stale
    # socket file may survive from a previous container — always start a
    # fresh daemon for this container's lifetime. Point BOTH tools at it so
    # store round-trips cost the same on each side.
    local socket=/nix/var/nix/daemon-socket/socket
    rm -f "$socket"
    mkdir -p "$(dirname "$socket")"
    nix-daemon >>"$cache/nix-daemon.log" 2>&1 &
    for _ in $(seq 50); do [[ -S "$socket" ]] && break; sleep 0.2; done
    [[ -S "$socket" ]] || { echo "nix-daemon failed to start (see $cache/nix-daemon.log)" >&2; exit 1; }
    export NIX_REMOTE=daemon
}

build_tree() { # build_tree <src-tree> <out-prefix> [--debug]
    local src="$1" out="$2" mode="${3:-}"
    local rel=(--release=fast)
    [[ "$mode" == --debug ]] && rel=()
    echo ">> building fix from $src -> $out" >&2
    (cd "$src" && nix-shell "$repo/shell.nix" --run \
        "zig build ${rel[*]:-} --cache-dir $out.zig-cache --prefix $out")
    "$out/bin/fix" --version >/dev/null 2>&1 || true
}

# --- workload resolution ------------------------------------------------------
workload=small
subtree=python3Packages
workers=4
runs=5
parse_workload_args() {
    rest=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workload) workload="$2"; shift 2 ;;
            --subtree) subtree="$2"; shift 2 ;;
            --workers) workers="$2"; shift 2 ;;
            --runs) runs="$2"; shift 2 ;;
            *) rest+=("$1"); shift ;;
        esac
    done
}

workload_argv() { # emits: <file> [--arg ...] — identical argv tail for both tools
    case "$workload" in
        small)
            echo "$repo/contrib/harness/workloads/small.nix"
            ;;
        nixpkgs)
            local pin
            pin="$(nixpkgs_pin)"
            printf '%s\n' "$repo/contrib/harness/workloads/nixpkgs-subtree.nix" \
                --arg nixpkgs "$pin" --argstr subtree "$subtree"
            ;;
        *) echo "unknown workload '$workload'" >&2; exit 2 ;;
    esac
}

run_fix() { # run_fix <fix-bin> <out.jsonl>
    local fix="$1" out="$2"
    mapfile -t wl < <(workload_argv)
    "$fix" eval-jobs --workers "$workers" "${wl[@]}" >"$out"
}

run_nej() { # run_nej <out.jsonl>
    local out="$1"
    mapfile -t wl < <(workload_argv)
    nix-eval-jobs --workers "$workers" "${wl[@]}" >"$out"
}

max_rss_kb() { # max_rss_kb <logfile from GNU time -v>
    awk -F': ' '/Maximum resident set size/ {print $2}' "$1"
}

# --- git-fetch workload -------------------------------------------------------
fetch_fixture() { # emits the fixture flake dir; generates on first use
    # FIX_HARNESS_FETCH_N scales the medium-repo count (default 9 ≈ 12
    # inputs) toward the thousands-of-git-inputs CI shape; each size gets
    # its own fixture dir so they coexist.
    local n="${FIX_HARNESS_FETCH_N:-9}" d="$cache/git-fixture"
    if [[ "$n" != 9 ]]; then d="$cache/git-fixture-$n"; fi
    FETCH_FIXTURE_DIR="$d"
    bash "$repo/contrib/harness/workloads/gen_git_fixture.sh" "$d" "$n" | tail -1
}

# Scenarios: cold = fetch caches AND fetched store paths gone (a genuinely
# cold evaluation-with-downloads); warm-store = caches gone, store valid
# (exercises the lock-narHash -> store-path fast paths); warm-all = nothing
# reset. Delegates to inside-reset.sh, which hyperfine --prepare also calls.
fetch_reset() {
    [[ "$1" == warm-all ]] || bash "$repo/contrib/harness/inside-reset.sh" "$1"
}

fetch_wrappers() { # writes $cache/bin/fetch-{fix,nix,fix-baseline}; args: <flake-dir>
    local flake="$1"
    mkdir -p "$cache/bin"
    cat >"$cache/bin/fetch-fix" <<EOF
#!/usr/bin/env bash
exec "$out_current/bin/fix" eval --extra-experimental-features flakes --impure \
    --read-write-mode --json --flake "$flake#paths"
EOF
    cat >"$cache/bin/fetch-fix-baseline" <<EOF
#!/usr/bin/env bash
exec "$out_baseline/bin/fix" eval --extra-experimental-features flakes --impure \
    --read-write-mode --json --flake "$flake#paths"
EOF
    cat >"$cache/bin/fetch-nix" <<EOF
#!/usr/bin/env bash
exec nix eval --extra-experimental-features "nix-command flakes" \
    --no-eval-cache --json "path:$flake#paths"
EOF
    chmod +x "$cache/bin/fetch-fix" "$cache/bin/fetch-fix-baseline" "$cache/bin/fetch-nix"
}

# --- subcommands --------------------------------------------------------------
cmd="${1:-help}"
[[ $# -gt 0 ]] && shift

case "$cmd" in
    shell)
        ensure_tools
        ensure_daemon
        exec bash
        ;;

    build)
        build_tree "$repo" "$out_current" "${1:-}"
        ;;

    parity)
        parse_workload_args "$@"
        ensure_tools
        ensure_daemon
        build_tree "$repo" "$out_current" ${FIX_HARNESS_BUILD_MODE:-}
        ts="$(date +%Y%m%d-%H%M%S)"
        echo ">> nix-eval-jobs ($workload)" >&2
        nej_status=0; run_nej "$results/$ts-nej.jsonl" || nej_status=$?
        echo ">> fix eval-jobs ($workload)" >&2
        fix_status=0; run_fix "$out_current/bin/fix" "$results/$ts-fix.jsonl" || fix_status=$?
        fail=0
        # Exit codes are part of the contract consumers depend on (NEJ: 0
        # with per-line error records; nonzero only for fatal errors).
        if [[ "$nej_status" == "$fix_status" ]]; then
            echo "OK   exit status agrees: $nej_status"
        else
            echo "FAIL exit status: nix-eval-jobs=$nej_status fix=$fix_status"
            fail=1
        fi
        python3 "$repo/contrib/harness/eval_jobs_diff.py" \
            "$results/$ts-nej.jsonl" "$results/$ts-fix.jsonl" || fail=1
        exit "$fail"
        ;;

    bench)
        parse_workload_args "$@"
        ensure_tools
        ensure_daemon
        build_tree "$repo" "$out_current" ${FIX_HARNESS_BUILD_MODE:-}
        mapfile -t wl < <(workload_argv)
        ts="$(date +%Y%m%d-%H%M%S)"

        echo ">> max-RSS probe (single run each, GNU time)" >&2
        command time -v nix-eval-jobs --workers "$workers" "${wl[@]}" \
            >/dev/null 2>"$results/$ts-nej-time.log" || true
        command time -v "$out_current/bin/fix" eval-jobs --workers "$workers" "${wl[@]}" \
            >/dev/null 2>"$results/$ts-fix-time.log" || true

        echo ">> hyperfine ($runs runs, warm store)" >&2
        hyperfine --warmup 1 --runs "$runs" \
            --export-json "$results/$ts-bench.json" \
            --export-markdown "$results/$ts-bench.md" \
            -n nix-eval-jobs "nix-eval-jobs --workers $workers $(printf '%q ' "${wl[@]}") > /dev/null" \
            -n fix-eval-jobs "$out_current/bin/fix eval-jobs --workers $workers $(printf '%q ' "${wl[@]}") > /dev/null"

        echo
        echo "== scoreboard ($workload, workers=$workers) =="
        echo "max RSS  nix-eval-jobs: $(max_rss_kb "$results/$ts-nej-time.log") kB (parent; forked workers excluded from peak accounting)"
        echo "max RSS  fix eval-jobs: $(max_rss_kb "$results/$ts-fix-time.log") kB"
        cat "$results/$ts-bench.md"
        echo "results saved under $results/$ts-*"
        ;;

    ab)
        parse_workload_args "$@"
        ensure_tools
        ensure_daemon
        [[ -d "$repo/.harness/baseline" ]] || { echo "run via harness.sh ab REF (host side prepares the worktree)" >&2; exit 2; }
        build_tree "$repo" "$out_current"
        build_tree "$repo/.harness/baseline" "$out_baseline"
        mapfile -t wl < <(workload_argv)
        ts="$(date +%Y%m%d-%H%M%S)"

        echo ">> parity: baseline vs current output must agree" >&2
        run_fix "$out_baseline/bin/fix" "$results/$ts-ab-baseline.jsonl"
        run_fix "$out_current/bin/fix" "$results/$ts-ab-current.jsonl"
        python3 "$repo/contrib/harness/eval_jobs_diff.py" --ab \
            "$results/$ts-ab-baseline.jsonl" "$results/$ts-ab-current.jsonl"

        echo ">> max-RSS probe" >&2
        command time -v "$out_baseline/bin/fix" eval-jobs --workers "$workers" "${wl[@]}" \
            >/dev/null 2>"$results/$ts-ab-baseline-time.log" || true
        command time -v "$out_current/bin/fix" eval-jobs --workers "$workers" "${wl[@]}" \
            >/dev/null 2>"$results/$ts-ab-current-time.log" || true

        hyperfine --warmup 1 --runs "$runs" \
            --export-markdown "$results/$ts-ab.md" \
            -n baseline "$out_baseline/bin/fix eval-jobs --workers $workers $(printf '%q ' "${wl[@]}") > /dev/null" \
            -n current "$out_current/bin/fix eval-jobs --workers $workers $(printf '%q ' "${wl[@]}") > /dev/null"

        echo
        echo "== A/B ($workload, workers=$workers) =="
        echo "max RSS  baseline: $(max_rss_kb "$results/$ts-ab-baseline-time.log") kB"
        echo "max RSS  current:  $(max_rss_kb "$results/$ts-ab-current-time.log") kB"
        cat "$results/$ts-ab.md"
        ;;

    fetch-parity)
        # Correctness oracle for the many-git-inputs workload: fix and nix
        # must produce IDENTICAL input store paths (i.e. agree on the narHash
        # of every fetched git input) from cold, and fix must reproduce them
        # again via its store fast path and via its warm caches.
        ensure_tools
        ensure_daemon
        build_tree "$repo" "$out_current" ${FIX_HARNESS_BUILD_MODE:-}
        flake="$(fetch_fixture)"
        fetch_wrappers "$flake"
        ts="$(date +%Y%m%d-%H%M%S)"

        echo ">> nix, cold" >&2
        fetch_reset cold
        "$cache/bin/fetch-nix" >"$results/$ts-fetch-nix.json"
        echo ">> fix, cold" >&2
        fetch_reset cold
        "$cache/bin/fetch-fix" >"$results/$ts-fetch-fix-cold.json"
        echo ">> fix, warm store (fetch caches wiped)" >&2
        fetch_reset warm-store
        "$cache/bin/fetch-fix" >"$results/$ts-fetch-fix-warmstore.json"
        echo ">> fix, warm caches" >&2
        "$cache/bin/fetch-fix" >"$results/$ts-fetch-fix-warmall.json"

        fail=0
        for scenario in cold warmstore warmall; do
            if cmp -s "$results/$ts-fetch-nix.json" "$results/$ts-fetch-fix-$scenario.json"; then
                echo "OK   fix($scenario) == nix: input store paths identical"
            else
                echo "FAIL fix($scenario) != nix:"
                diff <(jq -r . "$results/$ts-fetch-nix.json") \
                    <(jq -r . "$results/$ts-fetch-fix-$scenario.json") | head -20 || true
                fail=1
            fi
        done
        exit "$fail"
        ;;

    fetch-bench)
        # Wall-time of evaluation-with-git-downloads across cache states,
        # fix vs reference nix. --prepare runs before EVERY timed run, so
        # each measurement sees exactly its scenario's cache state.
        parse_workload_args "$@"
        ensure_tools
        ensure_daemon
        build_tree "$repo" "$out_current" ${FIX_HARNESS_BUILD_MODE:-}
        flake="$(fetch_fixture)"
        fetch_wrappers "$flake"
        ts="$(date +%Y%m%d-%H%M%S)"

        for scenario in cold warm-store warm-all; do
            echo ">> scenario: $scenario" >&2
            prep=":"
            case "$scenario" in
                cold) prep="bash $repo/contrib/harness/inside-reset.sh cold" ;;
                warm-store) prep="bash $repo/contrib/harness/inside-reset.sh warm-store" ;;
            esac
            hyperfine --warmup 0 --runs "$runs" --prepare "$prep" \
                --export-markdown "$results/$ts-fetch-$scenario.md" \
                -n "nix ($scenario)" "$cache/bin/fetch-nix > /dev/null" \
                -n "fix ($scenario)" "$cache/bin/fetch-fix > /dev/null"
        done
        echo
        echo "== git-fetch scoreboard =="
        cat "$results/$ts-fetch-cold.md" "$results/$ts-fetch-warm-store.md" "$results/$ts-fetch-warm-all.md"
        echo "results saved under $results/$ts-fetch-*"
        ;;

    fetch-latency)
        # Cold-fetch wall time under REAL network latency: the file:// fixture
        # has ~0 RTT, so it cannot expose demand-serialization — this serves
        # the same repos over git:// behind a netem delay (privileged
        # container; harness.sh adds --privileged for this subcommand) and
        # times fix cold with and without FIX_PREFETCH_INPUTS. Usage:
        #   harness.sh fetch-latency [--delay-ms 25] (FIX_HARNESS_FETCH_N sizes it)
        delay_ms=25
        while [[ $# -gt 0 ]]; do case "$1" in
            --delay-ms) delay_ms="$2"; shift 2 ;;
            *) shift ;;
        esac; done
        ensure_tools
        ensure_daemon
        build_tree "$repo" "$out_current" ${FIX_HARNESS_BUILD_MODE:-}
        flake="$(fetch_fixture)"
        fixture_dir="$(dirname "$flake")"

        # Serve the bare repos over the git protocol and shape lo.
        tc qdisc replace dev lo root netem delay "${delay_ms}ms" || {
            echo "tc netem unavailable (need --privileged); aborting" >&2; exit 2; }
        git daemon --base-path="$fixture_dir/repos" --export-all --reuseaddr \
            --port=9418 --detach 2>/dev/null || true
        sleep 1

        # A URL-rewritten copy of the flake: same revs and narHashes (the
        # lock pins content, not transport), git:// instead of file://.
        netflake="$fixture_dir/flake-git-proto"
        rm -rf "$netflake"; cp -r "$flake" "$netflake"
        sed -i "s|git+file://$fixture_dir/repos/|git+git://127.0.0.1/|g" "$netflake/flake.nix" "$netflake/flake.lock"
        sed -i "s|\"file://$fixture_dir/repos/|\"git://127.0.0.1/|g" "$netflake/flake.lock"

        run_cold() { # run_cold <label> [env overrides...]
            local label="$1"; shift
            bash "$repo/contrib/harness/inside-reset.sh" cold
            local s e
            s=$(date +%s.%N)
            env "$@" "$out_current/bin/fix" eval --extra-experimental-features flakes --impure \
                --read-write-mode --json --flake "$netflake#paths" >/dev/null 2>&1 || true
            e=$(date +%s.%N)
            echo "$label: $(echo "$e $s" | awk '{printf "%.1f", $1-$2}')s"
        }
        echo "== fetch-latency (delay ${delay_ms}ms each way, N=${FIX_HARNESS_FETCH_N:-9})"
        run_cold "cold no-prefetch      " FIX_PREFETCH_INPUTS=0
        run_cold "cold prefetch lim 8   " FIX_PREFETCH_INPUTS=1
        run_cold "cold prefetch lim 25  " FIX_PREFETCH_INPUTS=1 FIX_PREFETCH_LIMIT=25
        run_cold "cold no-prefetch again" FIX_PREFETCH_INPUTS=0
        tc qdisc del dev lo root 2>/dev/null || true
        ;;

    nej-tests)
        # Run nix-eval-jobs' OWN pytest suite (hermetic fixtures, binary
        # selected via NIX_EVAL_JOBS_BIN) against fix — parity proven by the
        # upstream project's assertions, not ours. The oracle leg runs the
        # pinned nix-eval-jobs against the same suite first, so a fixture or
        # environment problem cannot masquerade as a fix regression.
        ensure_tools
        ensure_daemon
        fix_bin="${FIX_HARNESS_FIX_BIN:-}"
        if [[ -z "$fix_bin" ]]; then
            build_tree "$repo" "$out_current" ${FIX_HARNESS_BUILD_MODE:-}
            fix_bin="$out_current/bin/fix"
        fi
        src=$(nix-build --no-out-link -E "with import (import $repo/npins).nixpkgs {}; nix-eval-jobs.src")
        tests_dir=""
        for cand in tests-functional tests; do
            [[ -d "$src/$cand" ]] && tests_dir="$src/$cand" && break
        done
        [[ -n "$tests_dir" ]] || { echo "no test dir found in $src" >&2; exit 1; }
        work="$cache/nej-tests"
        rm -rf "$work" && cp -r "$tests_dir" "$work" && chmod -R u+w "$work"
        mkdir -p "$cache/bin"
        printf '#!/usr/bin/env bash\nexec %s eval-jobs "$@"\n' "$fix_bin" >"$cache/bin/nej-fix"
        chmod +x "$cache/bin/nej-fix"

        # Deselected: the cross-system cache-status closure test (fix's
        # neededBuilds is a documented subset) and the FOD tests (need build
        # sandboxing the container lacks). Everything else must pass.
        skip_k="not empty_needed and not fod"

        # A non-world-writable TMPDIR (the FOD tests build into a store under
        # tmp, which nix refuses at /tmp's permissions), and a single-user
        # oracle (our exported NIX_REMOTE=daemon makes nix-eval-jobs warn
        # about daemon-only settings, failing its clean-stderr test).
        mkdir -p -m 0755 "$cache/nej-tmp"
        echo ">> oracle: nix-eval-jobs against its own suite" >&2
        oracle_status=0
        # Environment-limited deselects, oracle leg only: the FOD tests BUILD
        # derivations, which an unprivileged container cannot sandbox, and the
        # same missing mount-namespace capability makes every nix invocation
        # warn, failing the clean-stderr assertion (fix emits no such warning
        # and keeps that test in its own leg).
        (cd "$work" && TMPDIR="$cache/nej-tmp" NIX_REMOTE= NIX_EVAL_JOBS_BIN="$(command -v nix-eval-jobs)" pytest -q test_eval.py \
            --deselect 'test_eval.py::test_fod_with_uncached_input_issue413[file]' \
            --deselect 'test_eval.py::test_fod_with_uncached_input_issue413[http]' \
            --deselect 'test_eval.py::test_daemon_only_settings_do_not_warn') || oracle_status=$?
        echo ">> candidate: fix eval-jobs (unsupported features deselected)" >&2
        fix_status=0
        (cd "$work" && TMPDIR="$cache/nej-tmp" NIX_EVAL_JOBS_BIN="$cache/bin/nej-fix" pytest -q test_eval.py -k "$skip_k") || fix_status=$?
        echo
        echo "== nej-tests: oracle exit=$oracle_status candidate(fix) exit=$fix_status =="
        exit "$fix_status"
        ;;

    nixpkgs-diff)
        ensure_tools
        ensure_daemon
        build_tree "$repo" "$out_current" ${FIX_HARNESS_BUILD_MODE:-}
        exec nix-shell "$repo/shell.nix" --run \
            "$repo/test/nixpkgs/run.sh --fix $out_current/bin/fix $(printf '%q ' "$@")"
        ;;

    *)
        sed -n '2,30p' "$repo/contrib/harness/harness.sh"
        exit 2
        ;;
esac
