# Minimal NixOS system closure (drvPath of the toplevel).
#
# Resolve nixpkgs through NIX_PATH so this workload can be run directly.
# Returning `.drvPath` forces the full module fixpoint plus instantiation of the
# toplevel derivation (but not a build), and yields a string, so `--strict` does
# not recurse into the derivation graph.
let
  nixpkgs = <nixpkgs>;
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
