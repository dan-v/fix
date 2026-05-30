{
  lib,
  stdenv,
  cpu ? "baseline",
  release ? "fast",
  zig_0_16,
  pkg-config,
}: let
  zig = zig_0_16;
in
  stdenv.mkDerivation
  {
    pname = "fix";
    version = "0.0.1";
    src = ../.;

    nativeBuildInputs = [zig.hook pkg-config];

    zigBuildFlags = (lib.optional (release != null) "--release=${release}") ++ (lib.optional (cpu != null) "--cpu=${cpu}");

    dontSetZigCheck = true;
    dontSetZigDefaultFlags = true;

    meta = {
      description = "Blazing fast nix evaluator";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  }
