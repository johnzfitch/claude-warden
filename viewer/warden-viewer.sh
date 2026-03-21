#!/usr/bin/env bash
# warden-viewer.sh - Launch the Warden Viewer web UI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/warden-viewer.py" "$@"
