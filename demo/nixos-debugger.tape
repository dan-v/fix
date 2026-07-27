Output demo/nixos-debugger.gif
Output demo/nixos-debugger.mp4

Require fix

Set Shell "zsh"
Set Theme "Catppuccin Mocha"
Set FontFamily "JetBrains Mono"
Set FontSize 16
Set Width 1600
Set Height 900
Set Padding 18
Set Margin 18
Set MarginFill "#181825"
Set WindowBar Colorful
Set TypingSpeed 60ms
Set Framerate 30

Env FIX_REPL_NO_HINT "1"

Sleep 500ms
Type "fix repl"
Sleep 800ms
Enter
Wait+Screen /fix>/
Sleep 1500ms

Type ":vm"
Sleep 800ms
Enter
Wait+Screen /The VM explorer/
Sleep 3s

# Build the large live VM state first.
Type "i"
Type "(import ./nixos-system.nix).config.system.build.toplevel.drvPath"
Sleep 1s
Enter
Sleep 3s
Hide
Wait+Screen@60s /nixos-system-fix-demo/
Show
Sleep 3s
Escape
Wait+Screen /inspector/
Sleep 4s

# Open a new debug session while the NixOS heap remains retained.
Type ":d (import ./debug-target.nix).payload"
Sleep 1s
Enter
Wait+Screen /paused\/entry/
Sleep 4s

Type ":break debug-target.nix:6"
Sleep 1s
Enter
Wait+Screen /breakpoint 1 pending/
Sleep 3s
Type "c"
Wait+Screen /paused\/breakpoint/
Sleep 5s

# The resolved breakpoint and large heap are both visible and interactive.
Type ":breakpoints"
Sleep 800ms
Enter
Wait+Screen /debug-target.nix:6/
Sleep 4s
Type "n"
Wait+Screen /paused\/step/
Sleep 3s
Type "c"
Wait+Screen /answer = 42/
Sleep 3s
Escape
Wait+Screen /inspector/
Sleep 3s

Type "q"
Wait+Screen /fix>/
Type ":q"
Enter
Sleep 1s
