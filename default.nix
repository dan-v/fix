{pkgs ? import (import ./npins).nixpkgs {}}: let
  sources = import ./npins;
  fix = pkgs.callPackage ./nix/fix.nix {};
  vhsDemo = pkgs.callPackage ./nix/vhs-demo.nix {inherit fix;};
  bench = pkgs.callPackage ./nix/bench.nix {inherit fix;};
  benchFix = pkgs.callPackage ./nix/bench.nix {
    inherit fix;
    nix = null;
    detsys = null;
    lix = null;
    snix = null;
  };
  demos = {
    explorer = vhsDemo {tape = ./demo/explorer.tape;};
    debugger = vhsDemo {
      tape = ./demo/debugger.tape;
      fixtures."debug-target.nix" = ./demo/debug-target.nix;
    };
    nixosDebugger = vhsDemo {
      tape = ./demo/nixos-debugger.tape;
      environment.NIX_PATH = "nixpkgs=${sources.nixpkgs}";
      fixtures."debug-target.nix" = ./demo/debug-target.nix;
      fixtures."nixos-system.nix" = ./demo/nixos-system.nix;
    };
  };
in {
  shell = import ./shell.nix;
  inherit fix bench benchFix vhsDemo demos;
  default = fix;

  # Import into your system/user config to get `programs.fix.enable` (installs
  # the CLI) and `programs.direnv.fix.enable` (auto-enabled with direnv; adds
  # the `use fix` helper). See contrib/direnv/README.md.
  nixosModules.fix = import ./nix/modules/nixos.nix;
  darwinModules.fix = import ./nix/modules/darwin.nix;
  homeManagerModules.fix = import ./nix/modules/home-manager.nix;
}
