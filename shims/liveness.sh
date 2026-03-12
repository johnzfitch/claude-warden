#!/usr/bin/env bash
# asyncRewake liveness check — fail-closed if daemon is dead
PIDFILE="$HOME/.claude/.warden/daemon.pid"
PID=$(cat "$PIDFILE" 2>/dev/null)
if [[ -z "$PID" ]] || ! kill -0 "$PID" 2>/dev/null; then
    echo "warden daemon not running — all tools blocked" >&2
    exit 2
fi
exit 0
