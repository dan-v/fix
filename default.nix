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
  shell = import ./shell.nix;
  inherit fix bench benchFix;
  default = fix;

  # Import into your system/user config to get `programs.fix.enable` (installs
  # the CLI) and `programs.fix.direnv.enable` (auto-enabled with direnv; adds
  # the `use fix` helper). See contrib/direnv/README.md.
  nixosModules.fix = import ./nix/modules/nixos.nix;
  darwinModules.fix = import ./nix/modules/darwin.nix;
  homeManagerModules.fix = import ./nix/modules/home-manager.nix;
}
