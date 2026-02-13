# claude-warden demo video (hybrid: real claude -p + mock JSON)
# Render: vhs demo/demo.tape
# Output: demo/claude-warden-demo.mp4

Output demo/claude-warden-demo.mp4
Set FontSize 16
Set Width 1400
Set Height 800
Set Theme "Catppuccin Mocha"
Set TypingSpeed 25ms
Set Shell bash
Set Padding 15

# ============================================================
# Scene 1: Title Card (5s)
# ============================================================
Type "figlet -f small 'claude-warden'"
Enter
Sleep 500ms
Type "echo '  Token-saving hooks for Claude Code'"
Enter
Sleep 500ms
Type "echo '  Blocks verbose commands, compresses reads, enforces budgets'"
Enter
Sleep 2s

# ============================================================
# Scene 2: One-Command Install (10s)
# ============================================================
Hide
Type "clear"
Enter
Show
Sleep 200ms

Type "echo '=== One-Command Install ==='"
Enter
Sleep 500ms
Type "echo '# git clone + ./install.sh -- symlinks 11 hooks in seconds'"
Enter
Sleep 500ms

Type "./install.sh --dry-run 2>&1 | head -15"
Enter
Sleep 3s

Type "echo '... (11 hooks + statusline + settings merge)'"
Enter
Sleep 2s

# ============================================================
# Scene 3: Split Screen -- Stock vs Warden (hero scene)
# ============================================================
Hide
Type "clear"
Enter
Show
Sleep 200ms

Type "echo '=== Split Screen: Stock Claude vs Claude + Warden ==='"
Enter
Sleep 1s

# Launch tmux hero scene (sets up split panes and attaches)
Type "./demo/tmux-hero.sh"
Enter
Sleep 30s

# Detach from tmux
Ctrl+B
Type "d"
Sleep 500ms

# Kill tmux session and clean up
Hide
Type "tmux kill-session -t demo 2>/dev/null; rm -rf node_modules package.json package-lock.json 2>/dev/null"
Enter
Show
Sleep 200ms

# ============================================================
# Scene 4: Rapid-fire hook demos (mock JSON)
# ============================================================
Hide
Type "clear"
Enter
Show
Sleep 200ms

Type "echo '=== Verbose Command Blocking ==='"
Enter
Sleep 500ms

Type "echo '# npm install -> BLOCKED'"
Enter
Sleep 200ms
Type "cat demo/mock-inputs/pre-tool-use-npm.json | ./hooks/pre-tool-use 2>&1"
Enter
Sleep 1500ms

Type "echo '# cargo build -> BLOCKED'"
Enter
Sleep 200ms
Type "cat demo/mock-inputs/pre-tool-use-cargo.json | ./hooks/pre-tool-use 2>&1"
Enter
Sleep 1500ms

Type "echo '# curl without -s -> BLOCKED'"
Enter
Sleep 200ms
Type "cat demo/mock-inputs/pre-tool-use-curl.json | ./hooks/pre-tool-use 2>&1"
Enter
Sleep 1500ms

Type "echo '# docker build -> BLOCKED'"
Enter
Sleep 200ms
Type "cat demo/mock-inputs/pre-tool-use-docker.json | ./hooks/pre-tool-use 2>&1"
Enter
Sleep 1500ms

Type "echo '# grep -r without -l -> BLOCKED'"
Enter
Sleep 200ms
Type "cat demo/mock-inputs/pre-tool-use-grep-recursive.json | ./hooks/pre-tool-use 2>&1"
Enter
Sleep 1500ms

Type "echo '# ffmpeg without -nostats -> BLOCKED'"
Enter
Sleep 200ms
Type "cat demo/mock-inputs/pre-tool-use-ffmpeg.json | ./hooks/pre-tool-use 2>&1"
Enter
Sleep 2s

# ============================================================
# Scene 5: Bundled File + Read Compression
# ============================================================
Hide
Type "clear"
Enter
Show
Sleep 200ms

Type "echo '=== Read Guards ==='"
Enter
Sleep 500ms

Type "echo '# Reading node_modules/ -> BLOCKED'"
Enter
Sleep 200ms
Type "cat demo/mock-inputs/read-guard-bundle.json | ./hooks/read-guard 2>&1"
Enter
Sleep 1500ms

Type "echo '# Reading dist/ -> BLOCKED'"
Enter
Sleep 200ms
Type "cat demo/mock-inputs/read-guard-dist.json | ./hooks/read-guard 2>&1"
Enter
Sleep 1500ms

Type "echo ''"
Enter
Type "echo '=== Read Compression ==='"
Enter
Sleep 500ms
Type "echo '# 206-line Python file -> 36 structural signatures'"
Enter
Sleep 300ms

Type "./demo/demo-helper.sh build_read_compress_input | ./hooks/read-compress | jq -r '.modifyOutput' 2>/dev/null | tail -10"
Enter
Sleep 3s

# ============================================================
# Scene 6: Output Truncation + Write Guard
# ============================================================
Hide
Type "clear"
Enter
Show
Sleep 200ms

Type "echo '=== Smart Output Truncation ==='"
Enter
Sleep 500ms

Type "echo '# 30KB bash output -> truncated to 10KB (8KB head + 2KB tail)'"
Enter
Sleep 300ms
Type "./demo/demo-helper.sh generate_large_output 30 | ./hooks/post-tool-use 2>/dev/null | grep -oP 'truncated to 10KB'"
Enter
Sleep 1500ms

Type "echo '# Write >100KB -> BLOCKED'"
Enter
Sleep 200ms
Type "cat demo/mock-inputs/pre-tool-use-write-large.json | ./hooks/pre-tool-use 2>&1"
Enter
Sleep 2s

# ============================================================
# Scene 7: Rich Statusline
# ============================================================
Hide
Type "clear"
Enter
Show
Sleep 200ms

Type "echo '=== Rich Statusline ==='"
Enter
Sleep 500ms

Type "echo '# Model, context %, tokens, cache stats, tool count -- all live'"
Enter
Sleep 500ms

Type "cat demo/mock-inputs/statusline.json | ./statusline.sh"
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
