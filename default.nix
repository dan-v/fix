{pkgs ? import (import ./npins).nixpkgs {}}: let
  fix = pkgs.callPackage ./nix/fix.nix {};
  bench = pkgs.callPackage ./nix/bench.nix {inherit fix;};
in {
  shell = import./shell.nix;
  inherit fix bench;
  default = fix;
}
