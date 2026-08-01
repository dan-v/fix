let
  sources = import ./npins;
in
  {pkgs ? import sources.nixpkgs {}}:
    pkgs.mkShell {
      NIX_PATH = "nixpkgs=${sources.nixpkgs}:home-manager=${pkgs.home-manager.src}";

      packages = [
        pkgs.zig_0_16
        pkgs.tlaplus
        pkgs.coreutils
        pkgs.pkg-config
        pkgs.ripgrep
        pkgs.hyperfine
        pkgs.vhs
        pkgs.curl
        pkgs.libgit2
        pkgs.mercurial
        pkgs.gnutar
      ]
      ++ pkgs.lib.optionals pkgs.stdenv.isLinux [pkgs.perf];
    }
