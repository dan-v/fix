{pkgs ? import (import ./npins).nixpkgs {}}: let
  fix = pkgs.callPackage ./nix/fix.nix {};
in {
  shell = import./shell.nix;
  inherit fix;
  default = fix;
}
