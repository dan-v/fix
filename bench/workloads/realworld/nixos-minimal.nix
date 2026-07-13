# Minimal NixOS system closure (drvPath of the toplevel).
#
# `@nixpkgs@` is substituted with the pinned nixpkgs store path by nix/bench.nix
# so the file is self-contained — every evaluator reads the same tree with no
# search-path / NIX_PATH setup. Returning `.drvPath` forces the full module
# fixpoint plus instantiation of the toplevel derivation (but not a build), and
# yields a string, so `--strict` does not recurse into the derivation graph.
let
  nixpkgs = @nixpkgs@;
in
  ((import (nixpkgs + "/nixos") {
    system = "x86_64-linux";
    configuration = {
      imports = [ (nixpkgs + "/nixos/modules/profiles/minimal.nix") ];
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
      networking.hostName = "fix-bench-minimal";
      system.stateVersion = "25.11";
      nixpkgs.config = {
        allowUnfree = true;
        allowBroken = true;
        allowUnsupportedSystem = true;
      };
    };
  }).config.system.build.toplevel).drvPath
