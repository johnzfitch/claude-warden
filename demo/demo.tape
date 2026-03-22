# claude-warden product demo
# Render: vhs demo/demo.tape
# Output: demo/claude-warden-demo.mp4

Output demo/claude-warden-demo.mp4
Set FontSize 16
Set Width 1440
Set Height 810
Set Theme "Catppuccin Mocha"
Set TypingSpeed 20ms
Set Shell bash
Set Padding 18

# Scene 1: Title card
Type "figlet -f small 'claude-warden'"
Enter
Sleep 400ms
Type "echo '  Token-saving hooks + observability for Claude Code'"
Enter
Sleep 400ms
Type "echo '  Rewrites noisy commands, blocks risky reads, trims huge output'"
Enter
Sleep 2200ms

# Scene 2: Hero split screen
Hide
Type "clear"
Enter
Show
Sleep 250ms

Type "echo '=== Stock terminal vs Claude + Warden ==='"
Enter
Sleep 900ms
Type "./demo/tmux-hero.sh"
Enter
Sleep 16s
Ctrl+B
Type "d"
Sleep 500ms
Hide
Type "tmux kill-session -t demo 2>/dev/null"
Enter
Show
Sleep 300ms

# Scene 3: Quiet rewrites and targeted blocking
Hide
Type "clear"
Enter
Show
Sleep 250ms

Type "./demo/demo-helper.sh show_hook_summary pre-tool-use demo/mock-inputs/pre-tool-use-npm.json 'npm install express'"
Enter
Sleep 1800ms
Type "./demo/demo-helper.sh show_hook_summary pre-tool-use demo/mock-inputs/pre-tool-use-cargo.json 'cargo build'"
Enter
Sleep 1800ms
Type "./demo/demo-helper.sh show_hook_summary pre-tool-use demo/mock-inputs/pre-tool-use-curl.json 'curl -v https://api.example.com/v1/data'"
Enter
Sleep 1800ms
Type "./demo/demo-helper.sh show_hook_summary pre-tool-use demo/mock-inputs/pre-tool-use-grep-recursive.json 'grep -r TODO src/'"
Enter
Sleep 2200ms

# Scene 4: Read guards and structural compression
Hide
Type "clear"
Enter
Show
Sleep 250ms

Type "./demo/demo-helper.sh show_hook_summary read-guard demo/mock-inputs/read-guard-bundle.json 'Read bundled file'"
Enter
Sleep 1800ms
Type "./demo/demo-helper.sh show_hook_summary read-guard demo/mock-inputs/read-guard-dist.json 'Read dist artifact'"
Enter
Sleep 1800ms
Type "./demo/demo-helper.sh show_read_compress_preview"
Enter
Sleep 3200ms

# Scene 5: Output truncation and write guard
Hide
Type "clear"
Enter
Show
Sleep 250ms

Type "./demo/demo-helper.sh show_post_tool_summary 30"
Enter
Sleep 2400ms
Type "./demo/demo-helper.sh show_hook_summary pre-tool-use demo/mock-inputs/pre-tool-use-write-large.json 'Write 100KB+'"
Enter
Sleep 2200ms

# Scene 6: Statusline
Hide
Type "clear"
Enter
Show
Sleep 250ms

Type "./demo/demo-helper.sh show_statusline_preview"
Enter
Sleep 3200ms
Enter
Sleep 3s

# ============================================================
# Scene 8: Outro (5s)
# ============================================================
Hide
Type "clear"
Enter
Show
Sleep 200ms

Type "figlet -f small 'claude-warden'"
Enter
Sleep 500ms
Type "echo ''"
Enter
Type "echo '  11 hooks | Pure bash | Zero dependencies beyond jq'"
Enter
Sleep 500ms
Type "echo '  Install in 30 seconds: git clone + ./install.sh'"
Enter
Sleep 500ms
Type "echo ''"
Enter
Type "echo '  github.com/anthropics/claude-code -> Hooks documentation'"
Enter
Sleep 3s
