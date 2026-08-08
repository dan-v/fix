#!/usr/bin/env bash
# Generates a hermetic "many git flake inputs" fixture: local bare repos with
# real history, and a flake whose inputs all point at them via git+file://.
# Models the CI-critical workload where evaluation must first download a pile
# of git inputs — the target of fix's shallow-clone / revCount-cache /
# store-fast-path work. Local URLs keep it network-free while still driving
# the full libgit2 transport (clone, fetch, checkout, export).
#
#   gen_git_fixture.sh <dir> [medium_repos=9] [deep_commits=2000] [medium_commits=100]
#
# Shape: 1 deep-history repo (revCount walks cost something), 1 repo with
# .gitattributes eol rules (filter-on-export paths), 1 input fetched shallow,
# N medium repos. All inputs are flake=false (pure fetch cost, no nested
# evals). Deterministic: fixed committer dates, so repo hashes and the lock
# are stable across regenerations. Prints the flake directory on success.
set -euo pipefail

dir="$1"
medium_n="${2:-9}"
deep_commits="${3:-2000}"
med_commits="${4:-100}"

stamp="$dir/.generated-v1-$medium_n-$deep_commits-$med_commits"
if [[ -e "$stamp" ]]; then
    echo "$dir/flake"
    exit 0
fi
rm -rf "$dir"
mkdir -p "$dir/repos"

gen_repo() { # gen_repo <name> <commits> [gitattributes-content]
    local name="$1" n="$2" attrs="${3:-}"
    local gitdir="$dir/repos/$name.git"
    git init -q --bare -b main "$gitdir"
    {
        for ((i = 1; i <= n; i++)); do
            echo "commit refs/heads/main"
            echo "committer Fixture <fixture@example.com> $((1500000000 + i * 60)) +0000"
            printf 'data <<EOT\ncommit %d\nEOT\n' "$i"
            printf 'M 644 inline shared.txt\ndata <<EOT\npayload %s %d\nEOT\n' "$name" "$i"
            printf 'M 644 inline f%d.txt\ndata <<EOT\nfile %d\nEOT\n' "$i" "$i"
            if [[ -n "$attrs" ]]; then
                printf 'M 644 inline .gitattributes\ndata <<EOT\n%s\nEOT\n' "$attrs"
                printf 'M 644 inline crlf.txt\ndata <<EOT\nline one\nline two\nEOT\n'
            fi
        done
        echo done
    } | git --git-dir="$gitdir" fast-import --quiet --done
}

echo ">> generating git repos (deep=$deep_commits, medium=${medium_n}x$med_commits)" >&2
gen_repo deep "$deep_commits"
gen_repo gitattrs "$med_commits" '*.txt text eol=crlf'
gen_repo shallowy "$med_commits"
for ((r = 1; r <= medium_n; r++)); do
    gen_repo "med$r" "$med_commits"
done

flake="$dir/flake"
mkdir -p "$flake"
{
    echo '{'
    echo '  inputs = {'
    echo "    deep = { url = \"git+file://$dir/repos/deep.git\"; flake = false; };"
    echo "    gitattrs = { url = \"git+file://$dir/repos/gitattrs.git\"; flake = false; };"
    echo "    shallowy = { url = \"git+file://$dir/repos/shallowy.git?shallow=1\"; flake = false; };"
    for ((r = 1; r <= medium_n; r++)); do
        echo "    med$r = { url = \"git+file://$dir/repos/med$r.git\"; flake = false; };"
    done
    echo '  };'
    echo '  outputs = inputs: {'
    echo '    paths = builtins.concatStringsSep "\n"'
    echo '      (map toString (builtins.attrValues (builtins.removeAttrs inputs [ "self" ])));'
    echo '  };'
    echo '}'
} >"$flake/flake.nix"

echo ">> locking (reference nix fetches every input once)" >&2
(cd "$flake" && nix flake lock --extra-experimental-features 'nix-command flakes')

# Input source store paths, one per line — scenario resets delete exactly
# these to simulate a cold store without touching the toolchain.
nix eval --extra-experimental-features 'nix-command flakes' \
    --no-eval-cache --raw "path:$flake#paths" >"$dir/paths.txt"

touch "$stamp"
echo "$flake"
