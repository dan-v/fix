{pkgs ? import (import ./npins).nixpkgs {}}:
pkgs.mkShell {
  packages = [
    pkgs.zig_0_16
    pkgs.pkg-config
  ];
}
