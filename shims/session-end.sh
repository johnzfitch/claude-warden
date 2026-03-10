#!/usr/bin/env bash
# Session end shim — POSTs session end, optionally stops daemon
set -euo pipefail

PORT="${WARDEN_PORT:-7483}"
URL="http://127.0.0.1:${PORT}"

INPUT="$(cat)"

# POST session end
printf '%s' "$INPUT" | curl -sf --max-time 5 -d @- "${URL}/session/end" >/dev/null 2>&1 || true

# Check if other sessions are active
ACTIVE=$(curl -sf --max-time 1 "${URL}/sessions/active" 2>/dev/null || echo "1")
if [[ "$ACTIVE" == "0" ]]; then
    # Last session — request graceful shutdown
    curl -sf --max-time 1 -X POST "${URL}/shutdown" >/dev/null 2>&1 || true
fi

exit 0
