Output demo/repl.gif

Set Shell "zsh"
Set Theme "Catppuccin Mocha"
Set FontSize 16
Set Width 1600
Set Height 800
Set Padding 18
Set Margin 18
Set MarginFill "#181825"
Set WindowBar Colorful
Set TypingSpeed 50ms
Set Framerate 30

Env FIX_REPL_NO_HINT "1"

Sleep 500ms
Type "fix repl"
Sleep 500ms
Enter
Wait+Screen /fix>/
Sleep 1s

Type "let twice = x: x * 2; in twice 21"
Sleep 500ms
Enter
Wait+Screen /42/
Sleep 1s

Type ":vm"
Sleep 500ms
Enter
Wait+Screen /fix vm/
Sleep 3s
Type "q"
Wait+Screen /fix>/
Sleep 1s

Type ":d let twice = x: x * 2; in twice 21"
Sleep 500ms
Enter
Wait+Screen /fix debug/
Sleep 3s
Type "s"
Wait+Screen /pause 2/
Sleep 2s
Type "c"
Wait+Screen /42/
Sleep 2s

Type ":q"
Enter

Sleep 2s
