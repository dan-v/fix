#!/usr/bin/env bash
# End-to-end checks for Nix-compatibility details that real-world nixpkgs and
# flake code depends on: the legacy `__`-prefixed global builtin aliases, and
# `builtins.path`'s string-coercion of its `path` argument.
#   test/e2e/compat.sh [FIX]     (default zig-out/bin/fix)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
e2e_init "$@"

# --- legacy `__`-prefixed builtin aliases -----------------------------------
# Nix binds every builtin into the global scope a second time under a `__`
# prefix. It is the pre-`builtins` spelling and is still used by real code
# (haskell.nix alone has ~200 occurrences), so missing it fails whole package
# sets with `undefined variable '__elem'`.
t "__elem is a function" "true" "$($FIX eval -E '__elem 2 [ 1 2 3 ]' 2>&1)"
t "__head" "1" "$($FIX eval -E '__head [ 1 2 ]' 2>&1)"
t "__tail" "[ 2 ]" "$($FIX eval -E '__tail [ 1 2 ]' 2>&1)"
t "__length" "3" "$($FIX eval -E '__length [ 1 2 3 ]' 2>&1)"
t "__add" "3" "$($FIX eval -E '__add 1 2' 2>&1)"
t "__compareVersions" "-1" "$($FIX eval -E '__compareVersions "1.0" "1.1"' 2>&1)"
t "__mapAttrs" "{ a = 2; }" "$($FIX eval --strict -E '__mapAttrs (n: v: v + 1) { a = 1; }' 2>&1)"
t "__attrNames" '[ "a" ]' "$($FIX eval -E '__attrNames { a = 1; }' 2>&1)"
t "__concatLists" "[ 1 2 ]" "$($FIX eval -E '__concatLists [ [ 1 ] [ 2 ] ]' 2>&1)"
t "__tryEval catches" "false" "$($FIX eval -E '(__tryEval (throw "x")).success' 2>&1)"
t "__toJSON" '"[1,2]"' "$($FIX eval -E '__toJSON [ 1 2 ]' 2>&1)"
t "__isString" "true" "$($FIX eval -E '__isString "s"' 2>&1)"
t "__genList" "[ 0 1 ]" "$($FIX eval --strict -E '__genList (i: i) 2' 2>&1)"
t "__filter" "[ 2 ]" "$($FIX eval -E '__filter (x: x > 1) [ 1 2 ]' 2>&1)"

# Prefixed constants resolve to the same value as the `builtins.` spelling.
t "__currentSystem is a string" "true" "$($FIX eval --impure -E '__currentSystem == builtins.currentSystem' 2>&1)"
t "__nixVersion matches" "true" "$($FIX eval -E '__nixVersion == builtins.nixVersion' 2>&1)"
t "__storeDir matches" "true" "$($FIX eval -E '__storeDir == builtins.storeDir' 2>&1)"

# A local binding still shadows the global alias (they are ordinary names).
t "local shadows alias" "9" "$($FIX eval -E 'let __elem = 9; in __elem' 2>&1)"

# An alias with no builtin behind it is still an error, not silently null.
t "unknown alias errors" "undefined variable '__nope'" "$($FIX eval -E '__nope' 2>&1)"

# --- builtins.path coerces its `path` argument -------------------------------
# Nix string-coerces `path`, so a derivation-like attrset (any value carrying
# `outPath`, e.g. a flake input) is accepted. `builtins.path { path =
# flakeInputs.foo; ... }` is a common idiom in package definitions.
src=$(e2e_mktemp)
echo hello >"$src/file.txt"

plain=$($FIX eval --raw -E "builtins.toString (builtins.path { name = \"p\"; path = $src; })" 2>&1)
t "path: bare path works" "/nix/store/" "$plain"

for expr in \
    "{ outPath = \"$src\"; }" \
    "{ outPath = $src; }" \
    "{ __toString = _: \"$src\"; }"; do
    got=$($FIX eval --raw -E "builtins.toString (builtins.path { name = \"p\"; path = $expr; })" 2>&1)
    t "path: coerces $expr" "$plain" "$got"
done

# Coercion must not change the ingested content: same store path as the bare
# path form, and the filter still runs.
filtered=$($FIX eval --raw -E \
    "builtins.toString (builtins.path { name = \"p\"; path = { outPath = \"$src\"; }; filter = p: t: true; })" 2>&1)
t "path: attrset + filter matches bare" "$plain" "$filtered"

# A `path` that cannot be coerced is an error, as in Nix (which rejects both an
# attrset without outPath/__toString and a non-path scalar).
t "path: attrset without outPath errors" "error" \
    "$($FIX eval -E 'builtins.path { name = "p"; path = { a = 1; }; }' 2>&1)"
t "path: non-coercible still errors" "error" \
    "$($FIX eval -E 'builtins.path { name = "p"; path = 42; }' 2>&1)"

# --- relative imports resolve through symlinks -------------------------------
# Nix resolves an imported file's symlinks before resolving its own relative
# imports, so `nix/package.nix -> ./cpp/package.nix` makes that file's
# `import ./generated.nix` read `nix/cpp/generated.nix`. Resolving against the
# link's directory instead makes the import miss (real nixpkgs inputs do this).
link=$(e2e_mktemp)
mkdir -p "$link/sub"
echo '[ 1 2 3 ]' >"$link/sub/data.nix"
echo 'builtins.length (import ./data.nix)' >"$link/sub/real.nix"
ln -s ./sub/real.nix "$link/via-link.nix"
t "import through symlink uses target dir" "3" "$($FIX eval -E "import $link/via-link.nix" 2>&1)"

# An absolute-target link behaves the same way.
ln -s "$link/sub/real.nix" "$link/abs-link.nix"
t "import through absolute symlink" "3" "$($FIX eval -E "import $link/abs-link.nix" 2>&1)"

# A non-symlink import is unaffected.
t "plain import still uses its own dir" "3" "$($FIX eval -E "import $link/sub/real.nix" 2>&1)"

# A dangling link still reports the failure at the point of use.
ln -s ./nope.nix "$link/dangling.nix"
t "dangling symlink still errors" "error" "$($FIX eval -E "import $link/dangling.nix" 2>&1)"

# --- fetching a worktree containing a relative symlink -----------------------
# `fetchGit` on an unpinned local worktree copies tracked files, symlinks
# included. A symlink target is arbitrary text and is normally relative
# (`../x/y`), which `symLinkAbsolute` asserts against — so a repo like nixpkgs
# (or any tree with a relative link) used to abort instead of being fetched.
if command -v git >/dev/null 2>&1; then
    repo=$(e2e_mktemp)
    mkdir -p "$repo/dir"
    echo 'hello' >"$repo/dir/target.txt"
    # A link whose relative target stays inside the tree (as in a real repo);
    # `../dir/x` from the root would escape it and could not resolve anywhere.
    ln -s ./dir/target.txt "$repo/relative-link"
    ln -s ../dir/target.txt "$repo/dir/parent-link"
    ln -s "$repo/dir/target.txt" "$repo/absolute-link"
    (
        cd "$repo" || exit 1
        git init -q . && git add -A &&
            git -c user.email=e2e@fix -c user.name=e2e commit -qm tracked
    ) >/dev/null 2>&1
    # stdout only: progress records go to stderr and would corrupt the path.
    fetch_err="$repo/.fetch.err"
    out=$($FIX eval --raw -E "builtins.toString (builtins.fetchGit { url = \"file://$repo\"; })" 2>"$fetch_err")
    t "fetchGit copies a relative symlink" "/" "$out"
    t_absent "fetchGit does not abort on symlinks" "unreachable" "$(cat "$fetch_err")"
    # The copied link must still point where it did, and still resolve.
    if [[ "$out" == /* && -L "$out/relative-link" ]]; then
        t "relative link kept relative" "./dir/target.txt" "$(readlink "$out/relative-link")"
        t "copied link resolves" "hello" "$(cat "$out/relative-link" 2>&1)"
        t "../ link kept relative" "../dir/target.txt" "$(readlink "$out/dir/parent-link")"
        t "../ link resolves" "hello" "$(cat "$out/dir/parent-link" 2>&1)"
    else
        fail "fetchGit result missing relative-link"
    fi
    # The PINNED-rev path exports from the object database (exportTree), a
    # separate code path from the worktree copy above — it had the same
    # symLinkAbsolute-asserts-on-relative-targets trap.
    rev=$(cd "$repo" && git rev-parse HEAD)
    out2=$($FIX eval --raw -E "builtins.toString (builtins.fetchGit { url = \"file://$repo\"; rev = \"$rev\"; })" 2>"$fetch_err")
    t "pinned-rev export handles relative symlinks" "/" "$out2"
    if [[ "$out2" == /* && -L "$out2/relative-link" ]]; then
        t "pinned export keeps link relative" "./dir/target.txt" "$(readlink "$out2/relative-link")"
        t "pinned export keeps ../ link" "../dir/target.txt" "$(readlink "$out2/dir/parent-link")"
    else
        fail "pinned-rev export missing relative-link"
    fi
else
    skip "fetchGit symlink copy" "git not available"
fi

# --- a store path used as a derivation `src` ---------------------------------
# Nix ingests a store path used as a derivation source like any other source: it
# copies `/nix/store/<h>-x` to a fresh `/nix/store/<h2>-<h>-x`, keeping the whole
# basename (hash included) as the new name. Passing the path through instead
# yields a self-consistent but Nix-incompatible drvPath for every derivation
# whose src is a store path — which happens whenever a flake input's own Nix code
# does `src = ../../.`. The ingest must also be idempotent: applying it again to
# the already-ingested path would nest a second copy (`<h3>-<h2>-<h>-x`).
probe=$(ls -d /nix/store/*-source 2>/dev/null | head -1)
if [[ -n "$probe" && -d "$probe" ]]; then
    drv_expr="(derivation { name = \"probe\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; src = $probe; })"
    src=$($FIX eval --raw -E "$drv_expr.src" 2>/dev/null)
    base=${probe#/nix/store/}
    # Re-ingested: a new hash, with the ORIGINAL basename (hash included) as name.
    t "store path src is re-ingested under its full basename" "-$base" "$src"
    t_absent "store path src is not passed through" "^$probe\$" "$src"
    # Idempotent: exactly one level of nesting, never two.
    nested=$(printf '%s' "$src" | grep -o -- "-$base" | wc -l)
    if [[ "$nested" == 1 ]]; then pass "src ingest is idempotent"; else fail "src ingested $nested times"; fi

    # Interpolating the same path must agree with the recorded src.
    coerced=$($FIX eval --raw -E "\"\${$probe}\"" 2>/dev/null)
    t "string coercion agrees with derivation src" "$src" "$coerced"

    # A subpath and a `..` traversal both normalize to the same ingest.
    plain=$($FIX eval --raw -E "\"\${$probe/.}\"" 2>/dev/null)
    t "trailing /. matches the plain path" "$src" "$plain"
else
    skip "store-path src ingest" "no /nix/store/*-source to probe"
fi

# --- shallow fetchGit ---------------------------------------------------------
# `shallow = true` fetches only the pinned commit, so there is no ancestry to
# count and Nix reports `revCount = 0` (which is why a shallow lock node carries
# no revCount). The tree contents must be identical to a full fetch — only the
# history is absent — so narHash/rev must agree between the two.
# The pinned rev must be fetched by object id: a depth-1 fetch of the branch tip
# cannot reach a rev the branch has since moved past.
if command -v git >/dev/null 2>&1; then
    shrepo=$(e2e_mktemp)
    mkdir -p "$shrepo"
    (
        cd "$shrepo" || exit 1
        git init -q --initial-branch=main . &&
            echo one >a.txt && git add -A &&
            git -c user.email=e2e@fix -c user.name=e2e commit -qm first &&
            echo two >b.txt && git add -A &&
            git -c user.email=e2e@fix -c user.name=e2e commit -qm second
    ) >/dev/null 2>&1
    pinned=$(cd "$shrepo" && git rev-parse HEAD~1)
    tip=$(cd "$shrepo" && git rev-parse HEAD)

    full_expr="builtins.fetchGit { url = \"file://$shrepo\"; ref = \"main\"; rev = \"$pinned\"; }"
    sh_expr="builtins.fetchGit { url = \"file://$shrepo\"; ref = \"main\"; rev = \"$pinned\"; shallow = true; }"

    t "shallow revCount is 0" "0" "$($FIX eval --impure -E "($sh_expr).revCount" 2>&1)"
    # A full fetch counts the pinned commit's own ancestry (here: just itself).
    t "full revCount counts ancestry" "1" "$($FIX eval --impure -E "($full_expr).revCount" 2>&1)"
    # rev is what was asked for, not the branch tip the shallow fetch started from.
    t "shallow keeps the pinned rev" "$pinned" "$($FIX eval --impure --raw -E "($sh_expr).rev" 2>/dev/null)"
    t_absent "shallow did not resolve to the tip" "$tip" "$($FIX eval --impure --raw -E "($sh_expr).rev" 2>/dev/null)"
    # Same tree either way: only history differs.
    full_hash=$($FIX eval --impure --raw -E "($full_expr).narHash" 2>/dev/null)
    sh_hash=$($FIX eval --impure --raw -E "($sh_expr).narHash" 2>/dev/null)
    t "shallow tree matches full tree" "$full_hash" "$sh_hash"

    # Through fetchTree, a shallow git input OMITS revCount entirely (which is
    # why shallow lock nodes carry none); fetchGit reports 0 instead.
    FT="--extra-experimental-features fetch-tree --impure"
    ft_shallow="builtins.fetchTree { type = \"git\"; url = \"file://$shrepo\"; ref = \"main\"; rev = \"$pinned\"; shallow = true; }"
    ft_full="builtins.fetchTree { type = \"git\"; url = \"file://$shrepo\"; ref = \"main\"; rev = \"$pinned\"; }"
    t "fetchTree shallow omits revCount" "false" "$($FIX eval $FT -E "($ft_shallow) ? revCount" 2>&1)"
    t "fetchTree full keeps revCount" "true" "$($FIX eval $FT -E "($ft_full) ? revCount" 2>&1)"

    # A server that rejects fetch-by-object-id (git daemon's upload-pack
    # default: allowReachableSHA1InWant off — the file:// transport never
    # enforces this) must not fail the input: the shallow fetch falls back to
    # a full ref fetch, through which the behind-the-tip rev is reachable.
    daemon_port=$((9418 + RANDOM % 2000))
    git daemon --export-all --base-path="$(dirname "$shrepo")" \
        --port="$daemon_port" --reuseaddr >/dev/null 2>&1 &
    daemon_pid=$!
    daemon_url="git://127.0.0.1:$daemon_port/$(basename "$shrepo")"
    for _ in $(seq 50); do
        git ls-remote "$daemon_url" >/dev/null 2>&1 && break
        sleep 0.2
    done
    if git ls-remote "$daemon_url" >/dev/null 2>&1; then
        gd_expr="builtins.fetchGit { url = \"$daemon_url\"; ref = \"main\"; rev = \"$pinned\"; shallow = true; }"
        gd_hash=$($FIX eval --impure --raw -E "($gd_expr).narHash" 2>/dev/null)
        t "SHA-in-want rejection falls back to a full fetch" "$full_hash" "$gd_hash"
        t "fallback keeps shallow revCount 0" "0" "$($FIX eval --impure -E "($gd_expr).revCount" 2>&1)"
    else
        skip "shallow fallback via git daemon" "git daemon did not start"
    fi
    kill "$daemon_pid" >/dev/null 2>&1 || true
else
    skip "shallow fetchGit" "git not available"
fi

# --- an unpinned local worktree is snapshotted from a cheap index key ---------
# Naming a local snapshot content-addresses it by NAR, which means copying the
# worktree and serializing the copy (~1s for a 5.5k-file repo) before the cache
# can even be consulted. A key derived from the git index skips that — but it
# MUST still see uncommitted changes, or an edit silently evaluates stale code.
if command -v git >/dev/null 2>&1; then
    wt=$(e2e_mktemp)
    mkdir -p "$wt"
    (
        cd "$wt" || exit 1
        git init -q --initial-branch=main . && echo one >a.txt && git add -A &&
            git -c user.email=e2e@fix -c user.name=e2e commit -qm first
    ) >/dev/null 2>&1
    wt_expr="builtins.toString (builtins.fetchGit { url = \"file://$wt\"; }).outPath"
    snap() { $FIX eval --impure --raw -E "$wt_expr" 2>/dev/null; }

    clean1=$(snap)
    clean2=$(snap)
    t "local worktree snapshot is stable when clean" "$clean1" "$clean2"

    # An unstaged edit to a tracked file must produce a different snapshot.
    echo modified >"$wt/a.txt"
    edited=$(snap)
    if [[ -n "$edited" && "$edited" != "$clean1" ]]; then
        pass "unstaged edit invalidates the snapshot"
    else
        fail "unstaged edit served a stale snapshot ($edited)"
    fi

    # Reverting the content returns to the original snapshot.
    echo one >"$wt/a.txt"
    t "revert returns to the original snapshot" "$clean1" "$(snap)"

    # Two unstaged states differing ONLY in intra-line whitespace must get
    # distinct snapshots. Regression: the key once used git_diff_patchid,
    # which ignores whitespace within lines, so the second evaluation was
    # served the first state's snapshot. Same byte length on both sides so
    # nothing but the whitespace can discriminate.
    printf 'a b\n' >"$wt/a.txt"
    ws1=$(snap)
    printf 'a\tb\n' >"$wt/a.txt"
    ws2=$(snap)
    if [[ -n "$ws1" && -n "$ws2" && "$ws1" != "$ws2" ]]; then
        pass "whitespace-only dirty states get distinct snapshots"
    else
        fail "whitespace-only dirty state served a stale snapshot ($ws1 vs $ws2)"
    fi
    echo one >"$wt/a.txt"

    # A staged addition changes it too.
    echo two >"$wt/b.txt"
    (cd "$wt" && git add b.txt) >/dev/null 2>&1
    staged=$(snap)
    if [[ "$staged" != "$clean1" ]]; then
        pass "staged addition invalidates the snapshot"
    else
        fail "staged addition served a stale snapshot"
    fi

    # An untracked file is not part of the snapshot (as in Nix), so it must not
    # change the key.
    echo three >"$wt/untracked.txt"
    t "untracked file does not change the snapshot" "$staged" "$(snap)"
else
    skip "local worktree snapshot key" "git not available"
fi

# --- a locked revCount lets a pinned fetch skip the ancestry -------------------
# `fetchTree` on a locked git input carries the revCount the lock recorded, so the
# history a full clone would download only to count it is dead weight. The fetch
# goes depth-1 and the locked count is reported — the value callers see must be
# the lock's, NOT the 0 a shallow fetch would otherwise produce.
if command -v git >/dev/null 2>&1; then
    hr=$(e2e_mktemp)
    mkdir -p "$hr"
    (
        cd "$hr" || exit 1
        git init -q --initial-branch=main . || exit 1
        for i in 1 2 3 4 5; do
            echo "c$i" >"f$i.txt"
            git add -A && git -c user.email=e2e@fix -c user.name=e2e commit -qm "c$i"
        done
    ) >/dev/null 2>&1
    hrev=$(cd "$hr" && git rev-parse HEAD)

    # With the hint: the locked count is what comes back.
    got=$($FIX eval --impure -E \
        "(builtins.fetchTree { type = \"git\"; url = \"file://$hr\"; rev = \"$hrev\"; revCount = 5; }).revCount" 2>&1)
    t "locked revCount is reported verbatim" "5" "$got"

    # Without a hint the real ancestry is counted, so the number is still right
    # for callers that have no lock.
    got=$($FIX eval --impure -E \
        "(builtins.fetchTree { type = \"git\"; url = \"file://$hr\"; rev = \"$hrev\"; }).revCount" 2>&1)
    t "unhinted fetch counts real ancestry" "5" "$got"

    # An explicit `shallow` still means 0, and must not be overridden by a hint.
    got=$($FIX eval --impure -E \
        "(builtins.fetchTree { type = \"git\"; url = \"file://$hr\"; rev = \"$hrev\"; shallow = true; }).revCount" 2>&1)
    t "explicit shallow still reports 0" "0" "$got"
else
    skip "locked revCount hint" "git not available"
fi

# --- .gitattributes filters are NOT applied (modern Nix semantics) ------------
# Modern Nix (>= 2.20, libgit2 accessor) ingests raw blob bytes: no eol
# conversion, whatever `.gitattributes` says. Nix <= 2.19 / Lix ran `git
# archive` filters and hashed differently; fix supports only the modern
# semantics, so a `text eol=crlf` rule must NOT change the fetched tree.
if command -v git >/dev/null 2>&1; then
    ga=$(e2e_mktemp)
    mkdir -p "$ga"
    (
        cd "$ga" || exit 1
        git init -q --initial-branch=main . || exit 1
        printf '* text=auto eol=lf\n*.ps1 text eol=crlf\n' >.gitattributes
        printf 'one\ntwo\nthree\n' >script.ps1
        printf 'one\ntwo\n' >plain.txt
        git add -A && git -c user.email=e2e@fix -c user.name=e2e commit -qm init
    ) >/dev/null 2>&1
    garev=$(cd "$ga" && git rev-parse HEAD)

    out=$($FIX eval --impure --raw -E \
        "builtins.toString (builtins.fetchGit { url = \"file://$ga\"; rev = \"$garev\"; ref = \"main\"; }).outPath" 2>/dev/null)
    if [[ -n "$out" && -f "$out/script.ps1" ]]; then
        # Raw blob: "one\ntwo\nthree\n" stays 14 bytes, no CR appears.
        t "eol=crlf rule leaves raw LF bytes (modern Nix)" "14" "$(wc -c <"$out/script.ps1" | tr -d ' ')"
        crlf=$(grep -c $'\r' "$out/script.ps1" 2>/dev/null || echo 0)
        t "no CR introduced by attributes" "0" "$crlf"
        t "eol=lf file is raw too" "8" "$(wc -c <"$out/plain.txt" | tr -d ' ')"
    else
        fail "gitattributes: fetchGit produced no tree ($out)"
    fi
else
    skip "gitattributes raw fetch" "git not available"
fi

e2e_finish
