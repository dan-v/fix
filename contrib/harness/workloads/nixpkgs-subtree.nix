# Real-world eval-jobs workload: a subtree of the pinned nixpkgs (the same
# pin every other differential in this repo uses). Unlike
# test/nixpkgs/outpaths.nix — which flattens to drvPath strings for strict
# JSON comparison — this returns the actual attrset of derivations so
# eval-jobs walkers (nix-eval-jobs, `fix eval-jobs`) drive their own
# recursion over it.
{
  nixpkgs,
  subtree ? "python3Packages",
  system ? builtins.currentSystem,
}:
let
  pkgs = import nixpkgs {
    inherit system;
    config = { allowUnfree = false; allowAliases = false; };
  };
in
# Nixpkgs scopes (python3Packages, haskellPackages) carry an explicit
# `recurseForDerivations = false`, which both walkers honor even at the
# root — override it so the workload actually walks.
pkgs.lib.getAttrFromPath (pkgs.lib.splitString "." subtree) pkgs
// { recurseForDerivations = true; }
