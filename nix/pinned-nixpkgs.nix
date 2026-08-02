# The npins nixpkgs pin as a normal, realized store path:
#
#   nix-build nix/pinned-nixpkgs.nix --out-link .pinned-nixpkgs
#
# Interpolating `sources.nixpkgs` (or plucking `.outPath` with nix eval)
# hands out a path that is neither realized (recent Nix leaves builtin-fetcher
# results as lazy trees only the evaluator can read) nor GC-rooted. Copying
# through a derivation makes it a real store object, and the out-link roots
# it — the same trick test/lang's resolvePin uses per pin.
let
  sources = import ../npins;
  pkgs = import sources.nixpkgs { };
in
pkgs.runCommand "pinned-nixpkgs" { } "cp -R ${sources.nixpkgs}/. $out"
