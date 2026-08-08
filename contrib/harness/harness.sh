#!/usr/bin/env bash
# Containerized proof harness: correctness parity and performance for
# `fix eval-jobs` against nix-eval-jobs and reference Nix, with no Nix
# installed on the host. Everything runs inside a Linux container (OrbStack /
# Docker) whose /nix lives in a named volume, so the store and toolchain stay
# warm across runs.
#
#   contrib/harness/harness.sh build [--debug]        # build fix (linux) in-container
#   contrib/harness/harness.sh parity [workload args] # fix vs nix-eval-jobs, field-by-field
#   contrib/harness/harness.sh bench  [workload args] # hyperfine + max-RSS scoreboard
#   contrib/harness/harness.sh ab [REF] [workload args]
#                                                     # working tree vs baseline REF
#   contrib/harness/harness.sh fetch-parity           # many-git-inputs flake: fix vs nix
#   contrib/harness/harness.sh fetch-bench [--runs N] # same, timed cold/warm-store/warm-all
#   contrib/harness/harness.sh nej-tests              # nix-eval-jobs' own pytest suite vs fix
#   contrib/harness/harness.sh nixpkgs-diff [args]    # test/nixpkgs/run.sh in-container
#   contrib/harness/harness.sh shell                  # interactive container shell
#
# Workload args (parity/bench/ab):
#   --workload small                   synthetic tree, no downloads (default)
#   --workload nixpkgs --subtree P     pinned-nixpkgs subtree, e.g. python3Packages
#   --workers N                        worker count for BOTH tools (default 4)
#   --runs N                           bench: hyperfine runs (default 5)
#
# First run downloads the pinned toolchain into the volume; later runs are warm.
# Reset everything with:  docker volume rm fix-harness-nix fix-harness-home
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image="${FIX_HARNESS_IMAGE:-nixos/nix:latest}"

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift

tty_flags=(-i)
[[ -t 0 && -t 1 ]] && tty_flags=(-it)

# fetch-latency shapes the container's loopback with tc netem, which needs
# CAP_NET_ADMIN.
priv_flags=()
if [[ "$cmd" == fetch-latency ]]; then priv_flags=(--privileged); fi

if [[ "$cmd" == ab ]]; then
    # Resolve the baseline ref host-side (git may be absent in the container
    # image) into a detached worktree the container sees at /work/.harness.
    ref="HEAD"
    if [[ $# -gt 0 && "$1" != --* ]]; then
        ref="$1"
        shift
    fi
    base="$repo/.harness/baseline"
    if git -C "$repo" worktree list --porcelain | grep -qF "$base"; then
        git -C "$repo" worktree remove --force "$base"
    fi
    mkdir -p "$repo/.harness"
    git -C "$repo" worktree add --force --detach "$base" "$ref" >/dev/null
    echo ">> baseline: $(git -C "$base" log -1 --format='%h %s')" >&2
fi

# Forward any FIX_* runtime tuning overrides into the container so A/B
# experiments can flip scheduler knobs without a rebuild.
env_flags=()
while IFS='=' read -r name _; do
    case "$name" in
        FIX_HARNESS_*) ;; # host-side harness config, not runtime tuning
        FIX_*) env_flags+=(-e "$name=${!name}") ;;
    esac
done < <(env)

exec docker run --rm ${tty_flags[@]+"${tty_flags[@]}"} ${priv_flags[@]+"${priv_flags[@]}"} \
    -v fix-harness-nix:/nix \
    -v fix-harness-home:/root \
    -v "$repo":/work \
    -w /work \
    -e FIX_HARNESS_BUILD_MODE="${FIX_HARNESS_BUILD_MODE:-}" \
    -e FIX_HARNESS_FETCH_N="${FIX_HARNESS_FETCH_N:-}" \
    ${env_flags[@]+"${env_flags[@]}"} \
    "$image" bash /work/contrib/harness/inside.sh "$cmd" "$@"
