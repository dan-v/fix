{
  lib,
  stdenv,
  cpu ? "baseline",
  release ? "fast",
  zig_0_16,
  pkg-config,
  curl,
  libgit2,
  mercurial,
  gnutar,
  makeWrapper,
}: let
  zig = zig_0_16;
in
  stdenv.mkDerivation
  {
    pname = "fix";
    version = "0.0.1";
    # Only the files the build actually consumes (mirrors build.zig.zon's
    # `.paths`), so unrelated churn — .git, .zig-cache, zig-out, result*,
    # bench/, docs/ — does not invalidate the build or bloat the src copy.
    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../build.zig
        ../build.zig.zon
        ../src
      ];
    };

    nativeBuildInputs = [zig.hook pkg-config makeWrapper];
    buildInputs = [curl libgit2];

    # Mercurial and archive extraction remain subprocess adapters. Git source
    # transport and local-worktree plumbing are both provided by libgit2.
    postFixup = ''
      wrapProgram $out/bin/fix \
        --prefix PATH : ${lib.makeBinPath [mercurial gnutar]}
    '';

    zigBuildFlags = (lib.optional (release != null) "--release=${release}") ++ (lib.optional (cpu != null) "-Dcpu=${cpu}");

    dontSetZigCheck = true;
    dontSetZigDefaultFlags = true;

    meta = {
      description = "Blazing fast nix evaluator";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  }
