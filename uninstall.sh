#!/usr/bin/env bash
# uninstall.sh - Remove claude-warden hooks from ~/.claude/
#
# Usage:
#   ./uninstall.sh           # Remove hooks and restore settings
#   ./uninstall.sh --dry-run # Show what would be done

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
STATUSLINE_FILE="$CLAUDE_DIR/statusline.sh"

DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $0 [--dry-run]"
            echo ""
            echo "Removes claude-warden hooks and restores settings.json."
            echo "Your most recent settings backup will be restored if available."
            exit 0
            ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

# === Colors ===
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
DIM='\033[2m'
RESET='\033[0m'

info()  { printf "${GREEN}[-]${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${RESET} %s\n" "$*"; }
error() { printf "${RED}[x]${RESET} %s\n" "$*" >&2; }
dim()   { printf "${DIM}    %s${RESET}\n" "$*"; }

run() {
    if $DRY_RUN; then
        dim "(dry-run) $*"
    else
        "$@"
    fi
}

# === Hook files managed by claude-warden ===
HOOK_FILES=(
    pre-tool-use
    post-tool-use
    permission-request
    read-guard
    read-compress
    stop
    session-start
    session-end
    subagent-start
    subagent-stop
    tool-error
)

# === Remove hooks ===
REMOVED=0
if [[ -d "$HOOKS_DIR" ]]; then
    info "Removing warden hooks..."
    for hook in "${HOOK_FILES[@]}"; do
        TARGET="$HOOKS_DIR/$hook"
        if [[ -e "$TARGET" ]] || [[ -L "$TARGET" ]]; then
            run rm -f "$TARGET"
            dim "Removed: $hook"
            REMOVED=$((REMOVED + 1))
        fi
    done
else
    warn "No hooks directory found at $HOOKS_DIR"
fi

# === Remove statusline ===
if [[ -e "$STATUSLINE_FILE" ]] || [[ -L "$STATUSLINE_FILE" ]]; then
    info "Removing statusline..."
    run rm -f "$STATUSLINE_FILE"
    dim "Removed: statusline.sh"
fi

# === Restore settings.json ===
# Find the most recent backup
LATEST_BACKUP=""
shopt -s nullglob
for f in "$SETTINGS_FILE".bak.*; do
    [[ -f "$f" ]] && LATEST_BACKUP="$f"
done
shopt -u nullglob

if [[ -n "$LATEST_BACKUP" ]]; then
    info "Restoring settings.json from backup..."
    dim "Backup: $(basename "$LATEST_BACKUP")"
    run cp "$LATEST_BACKUP" "$SETTINGS_FILE"
elif [[ -f "$SETTINGS_FILE" ]]; then
    # No backup found - just strip hooks and statusLine keys
    info "No backup found. Removing hooks/statusLine keys from settings.json..."
    if ! $DRY_RUN; then
        CLEANED=$(jq 'del(.hooks, .statusLine)' "$SETTINGS_FILE" 2>/dev/null)
        if [[ -n "$CLEANED" ]]; then
            echo "$CLEANED" | jq '.' > "$SETTINGS_FILE.tmp"
            mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
        else
            warn "Could not parse settings.json - leaving as-is"
        fi
    fi
else
    warn "No settings.json found"
fi

# === Summary ===
echo ""
info "Uninstall complete!"
echo ""
echo "  Removed:  $REMOVED hook(s)"
if [[ -n "$LATEST_BACKUP" ]]; then
    echo "  Restored: $SETTINGS_FILE (from $(basename "$LATEST_BACKUP"))"
fi
echo ""
echo "  Start a new Claude Code session for changes to take effect."
echo "  Old hook backups remain in $CLAUDE_DIR/hooks.bak.*/ if needed."
