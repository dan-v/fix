(import <nixpkgs/nixos> {
  system = "x86_64-linux";
  configuration = {
    imports = [<nixpkgs/nixos/modules/profiles/minimal.nix>];
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
    };
    networking.hostName = "fix-demo";
    system.stateVersion = "25.11";
  };
})
