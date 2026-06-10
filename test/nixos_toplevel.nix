let
  nixpkgs = /nix/store/hjpr2qmr0vgs870lpaiz4m218cxsf65n-source;
in
(import (nixpkgs + "/nixos") {
  system = "x86_64-linux";
  configuration = {
    imports = [ (nixpkgs + "/nixos/modules/profiles/minimal.nix") ];
    boot.loader.grub.enable = false;
    fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
    networking.hostName = "fix-test";
    system.stateVersion = "25.11";
    nixpkgs.config = {
      allowUnfree = true;
      allowBroken = true;
      allowUnsupportedSystem = true;
    };
  };
}).config.system.build.toplevel
