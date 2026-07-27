Output demo/debugger.gif
Output demo/debugger.mp4

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
Enter
Wait+Screen /fix>/
Sleep 800ms

Type ":d (import ./debug-target.nix).payload"
Sleep 1s
Enter
Wait+Screen /paused\/entry/
Sleep 3s

# Set a source breakpoint before the imported file has been compiled.
Type ":break debug-target.nix:6"
Sleep 1s
Enter
Wait+Screen /breakpoint 1 pending/
Sleep 3s

Type ":breakpoints"
Sleep 800ms
Enter
Wait+Screen /debug-target.nix:6 \(pending\)/
Sleep 3s

# Continue to the real breakpoint, then step over and into the call.
Type "c"
Wait+Screen /paused\/breakpoint/
Sleep 4s
Type "n"
Wait+Screen /paused\/step/
Sleep 3s
Type "s"
Wait+Screen /⇒ objects\[0x/
Sleep 4s

# Follow the return value into the normal heap/reference inspector.
Enter
Wait+Screen /MEMBERS · 2/
Sleep 4s

# Finish the frame and return the result to the ordinary REPL transcript.
Type "f"
Wait+Screen /answer = 42/
Sleep 3s
Type ":q"
Enter
Sleep 1s
