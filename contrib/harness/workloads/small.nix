# Synthetic eval-jobs workload: ~500 derivations in a nested tree, plus a
# deliberate error attr and a non-recursed subtree. Pure `derivation` calls —
# no nixpkgs, no network — so it exercises the WALKER (recursion policy,
# error records, output schema), not evaluation breadth. Both nix-eval-jobs
# and `fix eval-jobs` must walk it identically.
{ system ? builtins.currentSystem }:
let
  mkJob = name: derivation {
    inherit name system;
    builder = "/bin/sh";
    args = [ "-c" "echo ${name} > $out" ];
  };
  range = builtins.genList (i: i);
  group = prefix: n:
    builtins.listToAttrs (map (i: rec {
      name = "${prefix}${toString i}";
      value = mkJob name;
    }) (range n))
    // { recurseForDerivations = true; };
in
{
  simple = mkJob "simple";
  groupA = group "a" 200;
  groupB = group "b" 200;
  nested = {
    recurseForDerivations = true;
    inner = group "inner" 100;
    deeper = {
      recurseForDerivations = true;
      leaf = mkJob "leaf";
    };
  };
  failing = throw "deliberate failure for the error-record path";
  notRecursed.hidden = mkJob "hidden"; # no recurseForDerivations: both skip it
}
