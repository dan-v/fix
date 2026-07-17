let
  sources = import ./npins;
in
  {pkgs ? import sources.nixpkgs {}}:
    pkgs.mkShell {
      NIX_PATH = "nixpkgs=${sources.nixpkgs}";

      packages = [
        pkgs.zig_0_16
        pkgs.pkg-config
        pkgs.perf
        pkgs.hyperfine
        pkgs.curl
        pkgs.libgit2
        pkgs.mercurial
        pkgs.gnutar
      ];
    }
