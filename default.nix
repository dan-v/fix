{pkgs ? import (import ./npins).nixpkgs {}}: let
  fix = pkgs.callPackage ./nix/fix.nix {};
  bench = pkgs.callPackage ./nix/bench.nix {inherit fix;};
  benchFix = pkgs.callPackage ./nix/bench.nix {
    inherit fix;
    nix = null;
    detsys = null;
    lix = null;
    snix = null;
  };
in {
  shell = import./shell.nix;
  inherit fix bench benchFix;
  default = fix;
}
