Output demo/build-toplevel.gif
Set Shell "zsh"
Set Theme "Catppuccin Mocha"
Set FontSize 18
Set Width 1200
Set Height 720
Set Padding 18
Set Margin 18
Set MarginFill "#181825"
Set WindowBar Colorful
Set TypingSpeed 30ms
Set Framerate 30

Env TERM "xterm-256color"
Sleep 500ms
Type "fix build --no-out-link test/nixos_toplevel.nix"
Sleep 500ms
Enter
Wait+Screen /nixos-system-fix-test/
Sleep 2s
