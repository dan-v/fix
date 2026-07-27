Output demo/explorer.gif
Output demo/explorer.mp4

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

Type "let square = x: x * x; in { answer = 42; squares = builtins.map square [ 1 2 3 4 ]; nested = { enabled = true; }; }"
Sleep 1s
Enter
Wait+Screen /squares/
Sleep 2s

Type ":vm"
Sleep 800ms
Enter
Wait+Screen /SOURCE/
Sleep 3s

# Inspect the expression's source spans and place a precise breakpoint.
Enter
Wait+Screen /SOURCE · 1\//
Sleep 2s
Type "j"
Sleep 1500ms
Type "j"
Sleep 1500ms
Type "p"
Sleep 3s

# Move to the heap, expand its object store, and inspect a concrete object.
Escape
Sleep 1s
Tab
Sleep 1s
Type "g"
Sleep 1500ms
Enter
Wait+Screen /objects/
Sleep 2s
Type "j"
Enter
Wait+Screen /objects\[0x/
Sleep 2s
Type "j"
Sleep 1s
Enter
Wait+Screen /OUTGOING/
Sleep 4s

Type "q"
Wait+Screen /fix>/
Sleep 1s
Type ":q"
Enter
Sleep 1s
