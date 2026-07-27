{
  lib,
  runCommand,
  fix,
  jetbrains-mono,
  makeFontsConf,
  vhs,
  zsh,
}: let
  fontsConf = makeFontsConf {
    fontDirectories = [jetbrains-mono];
  };
in
{
  environment ? {},
  fixtures ? {},
  tape,
  name ? lib.removeSuffix ".tape" (baseNameOf tape),
}:
runCommand "${name}-media"
{
  nativeBuildInputs = [
    fix
    vhs
    zsh
  ];
  preferLocalBuild = true;
}
''
  export FONTCONFIG_FILE=${fontsConf}
  export HOME="$TMPDIR/home"
  export VHS_NO_SANDBOX=true
  mkdir -p "$HOME" work

  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
      variable: value:
        "export ${variable}=${lib.escapeShellArg (toString value)}"
    )
    environment)}

  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
      destination: source:
        "install -Dm444 ${source} ${lib.escapeShellArg "work/${destination}"}"
    )
    fixtures)}

  # Keep source tapes directly runnable while making their output paths a property of
  # the derivation. Render both formats in one VHS pass.
  {
    echo 'Output render.gif'
    echo 'Output render.mp4'
    sed -E '/^Output /d' ${tape}
  } > work/demo.tape
  grep -q '^Output render.gif$' work/demo.tape
  grep -q '^Output render.mp4$' work/demo.tape

  cd work
  vhs demo.tape
  test -s render.gif
  test -s render.mp4
  install -Dm444 render.gif "$out/${name}.gif"
  install -Dm444 render.mp4 "$out/${name}.mp4"
''
