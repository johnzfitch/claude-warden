#!/bin/bash
# Sets up tmux split-screen for the hero scene:
#   Left pane:  Stock npm install (verbose, no hooks)
#   Right pane: Claude + Warden (hooks block verbose, Claude adapts)
# VHS calls this script, then attaches to see both panes.

set -euo pipefail

# Kill any leftover demo session
tmux kill-session -t demo 2>/dev/null || true

# Create detached session
tmux new-session -d -s demo -x 170 -y 45
tmux set-option -t demo -g pane-border-status top >/dev/null
tmux set-option -t demo -g pane-border-format '#{pane_index}: #{pane_title}' >/dev/null
tmux select-pane -t demo:0.0 -T "Stock terminal" >/dev/null

# Left pane: stock behavior
tmux send-keys -t demo:0.0 "echo '=== Stock Claude ==='" Enter
sleep 0.3
tmux send-keys -t demo:0.0 "echo '# No hooks: verbose output eats context'" Enter
sleep 0.3
tmux send-keys -t demo:0.0 "echo '> npm install express' && ./demo/demo-helper.sh simulate_stock_npm" Enter

# Split and set up right pane
tmux split-window -h -t demo
tmux select-layout -t demo even-horizontal >/dev/null
tmux select-pane -t demo:0.1 -T "Claude + Warden" >/dev/null

# Right pane: Warden behavior
tmux send-keys -t demo:0.1 "echo '=== Claude + Warden ==='" Enter
sleep 0.3
tmux send-keys -t demo:0.1 "echo '# Warden blocks verbose, Claude adapts'" Enter
sleep 0.3
tmux send-keys -t demo:0.1 "WARDEN_DEMO_FAKE_CLAUDE=1 ./demo/claude-run.sh 'Run: npm install express' --allowedTools Bash --dangerously-skip-permissions" Enter

# Attach so VHS can record the split screen
exec tmux attach -t demo
