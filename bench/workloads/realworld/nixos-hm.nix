# NixOS system with home-manager integrated as a module — the full system
# fixpoint plus a per-user home-manager fixpoint evaluated together.
# Resolve sources through NIX_PATH so this workload can be run directly.
let
  nixpkgs = <nixpkgs>;
  home-manager = <home-manager>;
in
  ((import (nixpkgs + "/nixos") {
    system = "x86_64-linux";
    configuration = { pkgs, ... }: {
      imports = [
        (nixpkgs + "/nixos/modules/profiles/minimal.nix")
        (home-manager + "/nixos")
      ];
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
      networking.hostName = "fix-bench-nixos-hm";
      system.stateVersion = "25.11";
      nixpkgs.config = {
        allowUnfree = true;
        allowBroken = true;
        allowUnsupportedSystem = true;
      };

      users.users.bench = {
        isNormalUser = true;
        home = "/home/bench";
      };

      home-manager.users.bench = {
        home.stateVersion = "25.11";
        home.packages = with pkgs; [ ripgrep jq fd ];
        programs.bash.enable = true;
        programs.git = {
          enable = true;
          userName = "bench";
          userEmail = "bench@example.com";
        };
      };
    };
  }).config.system.build.toplevel).drvPath
