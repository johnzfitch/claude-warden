#!/usr/bin/env bash
# Setup hook — same daemon start logic as session-start
# Setup fires on --init and --maintenance, before SessionStart
set -euo pipefail

WARDEN_DIR="$HOME/.claude/.warden"
DAEMON="$WARDEN_DIR/warden-daemon"
PIDFILE="$WARDEN_DIR/daemon.pid"
PORT="${WARDEN_PORT:-7483}"
URL="http://127.0.0.1:${PORT}"

INPUT="$(cat)"

# Check if daemon already running
if [[ -f "$PIDFILE" ]]; then
    PID=$(cat "$PIDFILE" 2>/dev/null)
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        printf '%s' "$INPUT" | curl -sf --max-time 5 -d @- "${URL}/session/start" >/dev/null 2>&1 || true
        exit 0
    fi
fi

# Start daemon
if [[ ! -x "$DAEMON" ]]; then
    echo "warden: daemon binary not found at $DAEMON" >&2
    exit 0
fi

"$DAEMON" \
    --port "$PORT" \
    --pidfile "$PIDFILE" \
    --db "$WARDEN_DIR/state.db" \
    --config "$WARDEN_DIR/warden.toml" \
    --policy "$WARDEN_DIR/policy.toml" \
    --events-file "$HOME/.claude/.statusline/events.jsonl" \
    &
disown

# Wait for ready (max 1s)
for i in $(seq 1 20); do
    curl -sf --max-time 0.5 "${URL}/health" >/dev/null 2>&1 && break
    sleep 0.05
done

printf '%s' "$INPUT" | curl -sf --max-time 5 -d @- "${URL}/session/start" >/dev/null 2>&1 || true
exit 0
