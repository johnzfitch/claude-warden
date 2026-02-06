#!/usr/bin/env bash
# install.sh - Install claude-warden hooks into ~/.claude/
#
# Usage:
#   ./install.sh           # Symlink mode (default, edits take effect immediately)
#   ./install.sh --copy    # Copy mode (decoupled from repo)
#   ./install.sh --dry-run # Show what would be done without making changes

set -euo pipefail

# === Configuration ===
WARDEN_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
TEMPLATE_FILE="$WARDEN_DIR/settings.hooks.json"

MODE="symlink"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --copy) MODE="copy" ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $0 [--copy] [--dry-run]"
            echo ""
            echo "Options:"
            echo "  --copy     Copy files instead of symlinking (default: symlink)"
            echo "  --dry-run  Show what would be done without making changes"
            echo ""
            echo "Symlink mode: edits to the repo take effect immediately."
            echo "Copy mode: files are independent of the repo after install."
            exit 0
            ;;
        *) echo "Unknown option: $arg. Use --help for usage." >&2; exit 1 ;;
    esac
done

# === Colors ===
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
DIM='\033[2m'
RESET='\033[0m'

info()  { printf "${GREEN}[+]${RESET} %s\n" "$*"; }
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

# === Prerequisites ===
info "Checking prerequisites..."

if ! command -v jq &>/dev/null; then
    error "jq is required but not installed."
    echo "  Install: brew install jq (macOS) | sudo apt install jq (Debian) | sudo pacman -S jq (Arch)"
    exit 1
fi

for tool in rg fd; do
    if ! command -v "$tool" &>/dev/null; then
        warn "$tool not found (recommended but not required)"
    fi
done

# === Platform detection ===
PLATFORM="unknown"
case "$(uname -s)" in
    Linux*)
        if grep -qi microsoft /proc/version 2>/dev/null; then
            PLATFORM="wsl"
        else
            PLATFORM="linux"
        fi
        ;;
    Darwin*) PLATFORM="macos" ;;
esac
info "Platform: $PLATFORM"

# === Backup existing hooks ===
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

if [[ -d "$HOOKS_DIR" ]] && [[ "$(ls -A "$HOOKS_DIR" 2>/dev/null)" ]]; then
    BACKUP_DIR="$CLAUDE_DIR/hooks.bak.$TIMESTAMP"
    info "Backing up existing hooks -> $(basename "$BACKUP_DIR")/"
    run cp -a "$HOOKS_DIR" "$BACKUP_DIR"
fi

if [[ -f "$SETTINGS_FILE" ]]; then
    SETTINGS_BACKUP="$SETTINGS_FILE.bak.$TIMESTAMP"
    info "Backing up settings.json -> $(basename "$SETTINGS_BACKUP")"
    run cp "$SETTINGS_FILE" "$SETTINGS_BACKUP"
fi

# === Install hooks ===
run mkdir -p "$HOOKS_DIR"

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

info "Installing hooks ($MODE mode)..."
for hook in "${HOOK_FILES[@]}"; do
    SRC="$WARDEN_DIR/hooks/$hook"
    DST="$HOOKS_DIR/$hook"

    if [[ ! -f "$SRC" ]]; then
        warn "Source hook not found: $SRC (skipping)"
        continue
    fi

    # Remove existing file/symlink
    if [[ -e "$DST" ]] || [[ -L "$DST" ]]; then
        run rm -f "$DST"
    fi

    if [[ "$MODE" == "symlink" ]]; then
        run ln -s "$SRC" "$DST"
        dim "$hook -> $SRC"
    else
        run cp "$SRC" "$DST"
        dim "$hook (copied)"
    fi
done

# === Install statusline ===
STATUSLINE_SRC="$WARDEN_DIR/statusline.sh"
STATUSLINE_DST="$CLAUDE_DIR/statusline.sh"

if [[ -f "$STATUSLINE_SRC" ]]; then
    info "Installing statusline ($MODE mode)..."
    if [[ -e "$STATUSLINE_DST" ]] || [[ -L "$STATUSLINE_DST" ]]; then
        run rm -f "$STATUSLINE_DST"
    fi

    if [[ "$MODE" == "symlink" ]]; then
        run ln -s "$STATUSLINE_SRC" "$STATUSLINE_DST"
        dim "statusline.sh -> $STATUSLINE_SRC"
    else
        run cp "$STATUSLINE_SRC" "$STATUSLINE_DST"
        dim "statusline.sh (copied)"
    fi
fi

# === Set executable permissions ===
if ! $DRY_RUN; then
    chmod +x "$HOOKS_DIR"/* 2>/dev/null || true
    [[ -f "$STATUSLINE_DST" ]] && chmod +x "$STATUSLINE_DST"
fi

# === Merge settings.json ===
info "Merging hook config into settings.json..."

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    error "Template not found: $TEMPLATE_FILE"
    exit 1
fi

if $DRY_RUN; then
    dim "(dry-run) Would merge hooks and statusLine into $SETTINGS_FILE"
else
    if [[ -f "$SETTINGS_FILE" ]]; then
        # Merge: add/replace hooks + statusLine, preserve everything else
        MERGED=$(jq -s '.[0] * {hooks: .[1].hooks, statusLine: .[1].statusLine}' \
            "$SETTINGS_FILE" "$TEMPLATE_FILE")
    else
        # No existing settings - create from template
        MERGED=$(jq '.' "$TEMPLATE_FILE")
    fi

    echo "$MERGED" | jq '.' > "$SETTINGS_FILE.tmp"
    mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
fi

# === Validate ===
info "Validating..."
ERRORS=0

if ! $DRY_RUN; then
    # Validate JSON
    if ! jq '.' "$SETTINGS_FILE" >/dev/null 2>&1; then
        error "settings.json is invalid JSON!"
        ERRORS=$((ERRORS + 1))
    else
        dim "settings.json: valid JSON"
    fi

    # Validate hook scripts
    for hook in "${HOOK_FILES[@]}"; do
        TARGET="$HOOKS_DIR/$hook"
        # Resolve symlink for validation
        if [[ -L "$TARGET" ]]; then
            TARGET=$(readlink -f "$TARGET" 2>/dev/null || readlink "$TARGET")
        fi
        if [[ -f "$TARGET" ]]; then
            if bash -n "$TARGET" 2>/dev/null; then
                dim "$hook: syntax OK"
            else
                error "$hook: syntax error!"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    done

    # Validate statusline
    if [[ -f "$STATUSLINE_DST" ]]; then
        SL_TARGET="$STATUSLINE_DST"
        [[ -L "$SL_TARGET" ]] && SL_TARGET=$(readlink -f "$SL_TARGET" 2>/dev/null || readlink "$SL_TARGET")
        if bash -n "$SL_TARGET" 2>/dev/null; then
            dim "statusline.sh: syntax OK"
        else
            error "statusline.sh: syntax error!"
            ERRORS=$((ERRORS + 1))
        fi
    fi
fi

# === Summary ===
echo ""
if (( ERRORS > 0 )); then
    error "Installation completed with $ERRORS error(s). Check output above."
    exit 1
fi

info "Installation complete!"
echo ""
echo "  Hooks:      $HOOKS_DIR/ (${#HOOK_FILES[@]} hooks, $MODE mode)"
echo "  Statusline: $STATUSLINE_DST"
echo "  Settings:   $SETTINGS_FILE"
if [[ -n "${BACKUP_DIR:-}" ]]; then
    echo "  Backup:     $BACKUP_DIR/"
fi
if [[ -n "${SETTINGS_BACKUP:-}" ]]; then
    echo "  Backup:     $SETTINGS_BACKUP"
fi
echo ""
echo "  Start a new Claude Code session to activate hooks."
if [[ "$MODE" == "symlink" ]]; then
    echo "  Edits to $WARDEN_DIR/ take effect immediately."
    echo "  Run 'git pull' in the repo to update hooks."
fi
