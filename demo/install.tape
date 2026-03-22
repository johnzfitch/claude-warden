# claude-warden install walkthrough
# Render: vhs demo/install.tape
# Output: demo/install.mp4

Output demo/install.mp4

Set Shell "bash"
Set FontSize 16
Set Width 1440
Set Height 900
Set Padding 18
Set Theme "Catppuccin Mocha"
Set TypingSpeed 24ms

# Scene 1: Title
Type "echo '  claude-warden - install walkthrough'"
Enter
Sleep 450ms
Type "echo ''"
Enter
Type "echo '  Hooks, statusline, collector, and dry-run walkthrough'"
Enter
Sleep 2200ms

# Scene 2: Dry-run install summary
Hide
Type "clear"
Enter
Show
Sleep 250ms
Type "./install.sh --profile standard --no-monitoring --dry-run 2>&1 | tee /tmp/warden-install-demo.log"
Enter
Sleep 9s

# Scene 3: Clean architecture replay
Hide
Type "clear"
Enter
Show
Sleep 250ms
Type "sed -n '/CORE/,/Stops when idle/p' /tmp/warden-install-demo.log"
Enter
Sleep 4200ms

# Scene 4: Completion summary
Hide
Type "clear"
Enter
Show
Sleep 250ms
Type "sed -n '/Installation complete!/,/To customize/p' /tmp/warden-install-demo.log"
Enter
Sleep 4200ms

# Scene 5: CLI surface
Hide
Type "clear"
Enter
Show
Sleep 250ms
Type "./install.sh --help | sed -n '1,24p'"
Enter
Sleep 4s
