# Renders docs/media/statusline.gif with VHS: `vhs docs/media/statusline.tape` from the repo root. Two Codex requests.
Output docs/media/statusline.gif
Set Shell bash
Set FontFamily "JetBrains Mono"
Set FontSize 16
Set Width 1100
Set Height 420
Set Theme { "background": "#0b0b0c", "foreground": "#f3f0e8", "cursor": "#d4ff3f" }
Set Padding 24
Hide
Type "export PS1='$ '; clear"
Enter
Show
Type "bash docs/media/statusline-demo.sh"
Sleep 500ms
Enter
Wait+Screen@120s /both agents finished/
Sleep 3s
