#!/usr/bin/env bash
# install.sh - Install claude-warden hooks + configuration into ~/.claude/
#
# Usage:
#   ./install.sh                       # Interactive profile selection (default)
#   ./install.sh --profile standard    # Use a specific profile
#   ./install.sh --copy                # Copy mode (decoupled from repo)
#   ./install.sh --dry-run             # Show what would be done
#   ./install.sh --profile minimal     # Hooks only, no env/permission changes

set -euo pipefail

# === Configuration ===
WARDEN_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
HOOKS_TEMPLATE="$WARDEN_DIR/settings.hooks.json"
CONFIG_DIR="$WARDEN_DIR/config"
WARDEN_ENV_DIR="$CLAUDE_DIR/.warden"

WARDEN_VERSION="unknown"
[[ -f "$WARDEN_DIR/VERSION" ]] && WARDEN_VERSION=$(head -1 "$WARDEN_DIR/VERSION" | tr -d '[:space:]')

MODE="symlink"
DRY_RUN=false
PROFILE=""
MONITORING=""

for arg in "$@"; do
    case "$arg" in
        --copy) MODE="copy" ;;
        --dry-run) DRY_RUN=true ;;
        --monitoring) MONITORING="yes" ;;
        --no-monitoring) MONITORING="no" ;;
        --profile=*) PROFILE="${arg#--profile=}" ;;
        --profile)
            # Next arg is the profile name (handled below)
            _NEXT_IS_PROFILE=true
            continue
            ;;
        --help|-h)
            echo "Usage: $0 [--copy] [--dry-run] [--profile NAME] [--monitoring|--no-monitoring]"
            echo ""
            echo "Options:"
            echo "  --copy            Copy files instead of symlinking (default: symlink)"
            echo "  --dry-run         Show what would be done without making changes"
            echo "  --monitoring      Start optional Docker monitoring stack (Grafana, Loki, Prometheus, OTEL)"
            echo "  --no-monitoring   Skip monitoring stack setup"
            echo "  --profile NAME    Use a configuration profile:"
            echo "                      minimal   - Hooks only (no env/permission changes)"
            echo "                      standard  - Token limits + OTEL + safe permissions"
            echo "                      strict    - Aggressive limits, tight budgets"
            echo ""
            echo "If --profile is not specified, you'll be prompted to choose."
            echo ""
            echo "The Go collector is always built (requires Go 1.23+)."
            exit 0
            ;;
        *)
            if [[ "${_NEXT_IS_PROFILE:-}" == true ]]; then
                PROFILE="$arg"
                _NEXT_IS_PROFILE=""
            else
                echo "Unknown option: $arg. Use --help for usage." >&2; exit 1
            fi
            ;;
    esac
done

# Validate --profile was given a value if the flag was used
if [[ "${_NEXT_IS_PROFILE:-}" == true ]]; then
    echo "Error: --profile requires a value (minimal, standard, strict)" >&2
    exit 1
fi

# === Colors ===
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
BOLD='\033[1m'
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

# === Security: verify ~/.claude/ ownership ===
if [[ -d "$CLAUDE_DIR" ]]; then
    CLAUDE_OWNER=$(stat -c %u "$CLAUDE_DIR" 2>/dev/null || stat -f %u "$CLAUDE_DIR" 2>/dev/null || echo "")
    if [[ -n "$CLAUDE_OWNER" && "$CLAUDE_OWNER" != "$(id -u)" ]]; then
        error "$CLAUDE_DIR is owned by uid $CLAUDE_OWNER, not current user ($(id -u))."
        error "This could indicate tampering. Aborting."
        exit 1
    fi
fi

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

LEGACY_BUDGET_STATE="$CLAUDE_DIR/.budget/budget.json"
if [[ -f "$LEGACY_BUDGET_STATE" ]]; then
    warn "Legacy budget-cli state detected at $LEGACY_BUDGET_STATE"
    dim "claude-warden uses inline state at $CLAUDE_DIR/.warden/budget.state; remove the legacy file if other tooling still reads it"
fi

# === Profile selection ===
AVAILABLE_PROFILES=()
for pf in "$CONFIG_DIR/profiles"/*.json; do
    [[ -f "$pf" ]] || continue
    AVAILABLE_PROFILES+=("$(basename "$pf" .json)")
done

if [[ -z "$PROFILE" ]]; then
    if [[ -t 0 ]]; then
        # Interactive: prompt for selection
        echo ""
        printf "${BOLD}Choose a configuration profile:${RESET}\n"
        echo ""
        printf "  ${CYAN}1)${RESET} ${BOLD}minimal${RESET}   - Hooks only (no env or permission changes)\n"
        printf "  ${CYAN}2)${RESET} ${BOLD}standard${RESET}  - Token limits + OTEL + safe tool permissions ${GREEN}(recommended)${RESET}\n"
        printf "  ${CYAN}3)${RESET} ${BOLD}strict${RESET}    - Aggressive limits, tight subagent budgets\n"
        echo ""
        printf "  Enter 1-3 or profile name [standard]: "
        read -r CHOICE
        case "${CHOICE:-2}" in
            1|minimal)  PROFILE="minimal" ;;
            2|standard) PROFILE="standard" ;;
            3|strict)   PROFILE="strict" ;;
            *) PROFILE="$CHOICE" ;;
        esac
    else
        # Non-interactive (piped, install-remote.sh): default to standard
        PROFILE="standard"
        info "Non-interactive mode: using standard profile (override with --profile)"
    fi
fi

PROFILE_FILE="$CONFIG_DIR/profiles/$PROFILE.json"
if [[ ! -f "$PROFILE_FILE" ]]; then
    error "Profile not found: $PROFILE"
    echo "  Available: ${AVAILABLE_PROFILES[*]}"
    exit 1
fi
info "Profile: $PROFILE"

# === Collector paths ===
COLLECTOR_BIN_PATH="$HOME/.local/bin/warden-collector"
COLLECTOR_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-warden"

# === Monitoring stack prompt ===
MONITORING_DIR="$WARDEN_DIR/monitoring"

if [[ -z "$MONITORING" ]]; then
    if [[ -t 0 ]]; then
        echo ""
        printf "${BOLD}Start Docker monitoring stack?${RESET}\n"
        echo ""
        printf "  ${DIM}================================================${RESET}\n"
        printf "  ${YELLOW}Requires: Docker + Docker Compose${RESET}\n"
        printf "  ${DIM}================================================${RESET}\n"
        echo ""
        echo "  events.jsonl --> OTEL Collector --> Loki (logs)"
        echo "                                 --> Prometheus (metrics)"
        echo "                                 --> Tempo --> Grafana (:3000)"
        echo ""
        printf "  ${DIM}Ports: Grafana 3000, Prometheus 9090, Loki 3100, OTEL 4317/4318${RESET}\n"
        echo ""
        printf "  Start monitoring stack? [y/N]: "
        read -r _MON_CHOICE
        case "${_MON_CHOICE:-n}" in
            [yY]*) MONITORING="yes" ;;
            *)     MONITORING="no" ;;
        esac
    else
        MONITORING="no"
    fi
fi

if [[ "$MONITORING" == "yes" ]]; then
    info "Monitoring: will start after installation"
else
    info "Monitoring: skipped"
fi

# === Build merged warden config ===
# Merge order: defaults < profile < user overrides
# - env: shallow merge (last value wins)
# - permissions.allow/deny: array union (unique)
# - warden: shallow merge (last value wins per key, deep merge for nested objects)
info "Building configuration..."

DEFAULTS_FILE="$CONFIG_DIR/defaults.json"
USER_FILE="$CONFIG_DIR/user.json"

# Build jq input array: always defaults + profile, optionally user
# Minimal profile: skip defaults env/permissions (hooks only)
if [[ "$PROFILE" == "minimal" ]]; then
    MERGE_FILES=("$PROFILE_FILE")
    dim "Merging: $PROFILE only (hooks only, no defaults env/permissions)"
else
    MERGE_FILES=("$DEFAULTS_FILE" "$PROFILE_FILE")
fi
if [[ -f "$USER_FILE" ]]; then
    MERGE_FILES+=("$USER_FILE")
    dim "Merging: ${MERGE_FILES[*]##*/} + user overrides"
else
    dim "Merging: ${MERGE_FILES[*]##*/} (no user.json found)"
fi

WARDEN_MERGED=$(jq -s '
  def deepmerge_obj:
    reduce .[] as $item ({};
      . as $base |
      $item | to_entries | reduce .[] as $e ($base;
        if ($e.value | type) == "object" and (.[$e.key] | type) == "object"
        then .[$e.key] = ([.[$e.key], $e.value] | deepmerge_obj)
        else .[$e.key] = $e.value
        end
      )
    );

  # Extract sections
  (map(.env // {}) | deepmerge_obj) as $env |
  (map(.permissions.allow // []) | add | unique) as $allow |
  (map(.permissions.deny // []) | add | unique) as $deny |
  (map(.warden // {}) | deepmerge_obj) as $warden |

  {
    env: $env,
    permissions: { allow: $allow, deny: $deny },
    warden: $warden
  }
' "${MERGE_FILES[@]}")

# Remove _comment fields from merged config
WARDEN_MERGED=$(printf '%s' "$WARDEN_MERGED" | jq 'del(._comment) | .env |= del(._comment) | .warden |= del(._comment)')

# Extract sections for use below
WARDEN_ENV_JSON=$(printf '%s' "$WARDEN_MERGED" | jq '.env')
WARDEN_ALLOW_JSON=$(printf '%s' "$WARDEN_MERGED" | jq '.permissions.allow')
WARDEN_DENY_JSON=$(printf '%s' "$WARDEN_MERGED" | jq '.permissions.deny')
WARDEN_THRESHOLDS_JSON=$(printf '%s' "$WARDEN_MERGED" | jq '.warden')

ENV_COUNT=$(printf '%s' "$WARDEN_ENV_JSON" | jq 'length')
ALLOW_COUNT=$(printf '%s' "$WARDEN_ALLOW_JSON" | jq 'length')
dim "$ENV_COUNT env vars, $ALLOW_COUNT permission rules"

# === Backup ===
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
    pre-compact
    config-change
    mcp-output-compress
    observe
    elicitation
    elicitation-result
    instructions-loaded
)

# Remove deprecated hooks from previous installs
DEPRECATED_HOOKS=(session-lifecycle)
for hook in "${DEPRECATED_HOOKS[@]}"; do
    DST="$HOOKS_DIR/$hook"
    if [[ -e "$DST" ]] || [[ -L "$DST" ]]; then
        warn "Removing deprecated hook: $hook"
        run rm -f "$DST"
    fi
done

info "Installing hooks ($MODE mode)..."
for hook in "${HOOK_FILES[@]}"; do
    SRC="$WARDEN_DIR/hooks/$hook"
    DST="$HOOKS_DIR/$hook"

    if [[ ! -f "$SRC" ]]; then
        warn "Source hook not found: $SRC (skipping)"
        continue
    fi

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

# === Install lib directory ===
LIB_SRC="$WARDEN_DIR/hooks/lib"
LIB_DST="$HOOKS_DIR/lib"
if [[ -d "$LIB_SRC" ]]; then
    info "Installing hooks/lib ($MODE mode)..."
    [[ -e "$LIB_DST" || -L "$LIB_DST" ]] && run rm -rf "$LIB_DST"
    if [[ "$MODE" == "symlink" ]]; then
        run ln -s "$LIB_SRC" "$LIB_DST"
        dim "lib/ -> $LIB_SRC"
    else
        run cp -a "$LIB_SRC" "$LIB_DST"
        dim "lib/ (copied)"
    fi
fi

# === Install bin directory (aurl, etc.) ===
BIN_SRC="$WARDEN_DIR/hooks/bin"
BIN_DST="$HOOKS_DIR/bin"
if [[ -d "$BIN_SRC" ]]; then
    info "Installing hooks/bin ($MODE mode)..."
    [[ -e "$BIN_DST" || -L "$BIN_DST" ]] && run rm -rf "$BIN_DST"
    if [[ "$MODE" == "symlink" ]]; then
        run ln -s "$BIN_SRC" "$BIN_DST"
        dim "bin/ -> $BIN_SRC"
    else
        run cp -a "$BIN_SRC" "$BIN_DST"
        dim "bin/ (copied)"
    fi
fi

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
    [[ -d "$HOOKS_DIR/lib" ]] && chmod +x "$HOOKS_DIR/lib"/*.sh 2>/dev/null || true
    [[ -d "$HOOKS_DIR/bin" ]] && chmod +x "$HOOKS_DIR/bin"/* 2>/dev/null || true
    [[ -f "$STATUSLINE_DST" ]] && chmod +x "$STATUSLINE_DST"
fi

# === Build and install Go collector (required) ===
info "Building Go collector..."

COLLECTOR_SRC="$WARDEN_DIR/collector"
COLLECTOR_INSTALLED=false

if [[ ! -f "$COLLECTOR_SRC/main.go" ]]; then
    error "Collector source not found at $COLLECTOR_SRC/"
    error "Clone the full repo to install claude-warden."
    exit 1
fi

if ! command -v go &>/dev/null; then
    error "Go not found. Go 1.23+ is required to build the collector."
    dim "  Arch: sudo pacman -S go"
    dim "  macOS: brew install go"
    dim "  Or download from https://go.dev/dl/"
    exit 1
fi

GO_VERSION=$(go version | sed -n 's/.*go\([0-9]*\.[0-9]*\).*/\1/p')
GO_MAJOR=${GO_VERSION%%.*}
GO_MINOR=${GO_VERSION#*.}
if (( GO_MAJOR < 1 || (GO_MAJOR == 1 && GO_MINOR < 23) )); then
    error "Go $GO_VERSION found, but Go 1.23+ is required."
    exit 1
fi
dim "Found Go $GO_VERSION"

if $DRY_RUN; then
    dim "(dry-run) Would build collector and install to $COLLECTOR_BIN_PATH"
    COLLECTOR_INSTALLED=true
else
    dim "Building warden-collector..."
    if (cd "$COLLECTOR_SRC" && go build -o warden-collector . 2>&1); then
        mkdir -p "$(dirname "$COLLECTOR_BIN_PATH")"

        # Handle "text file busy" (binary currently running)
        if [[ -f "$COLLECTOR_BIN_PATH" ]]; then
            RUNNING_PID=""
            PIDFILE="$COLLECTOR_STATE_DIR/collector.pid"
            if [[ -f "$PIDFILE" ]]; then
                RUNNING_PID=$(<"$PIDFILE")
                if [[ "$RUNNING_PID" =~ ^[0-9]+$ ]] && kill -0 "$RUNNING_PID" 2>/dev/null; then
                    dim "Stopping running collector (pid $RUNNING_PID)..."
                    kill "$RUNNING_PID" 2>/dev/null || true
                    sleep 0.3
                fi
            fi
            rm -f "$COLLECTOR_BIN_PATH" 2>/dev/null || true
        fi

        cp "$COLLECTOR_SRC/warden-collector" "$COLLECTOR_BIN_PATH"
        chmod +x "$COLLECTOR_BIN_PATH"
        COLLECTOR_INSTALLED=true
        dim "Installed $COLLECTOR_BIN_PATH"

        mkdir -p "$COLLECTOR_STATE_DIR"
    else
        error "Collector build failed."
        exit 1
    fi
fi

# === Start monitoring stack (if selected) ===
MONITORING_STARTED=false
if [[ "$MONITORING" == "yes" ]]; then
    info "Starting monitoring stack..."

    if ! command -v docker &>/dev/null; then
        error "Docker not found. Install Docker to use the monitoring stack."
        dim "  Arch: sudo pacman -S docker docker-compose"
        dim "  macOS: brew install --cask docker"
    elif ! docker info &>/dev/null 2>&1; then
        error "Docker daemon not running. Start it first:"
        dim "  sudo systemctl start docker"
    else
        COMPOSE_CMD="docker compose"
        # Fall back to docker-compose if compose plugin not available
        if ! docker compose version &>/dev/null 2>&1; then
            if command -v docker-compose &>/dev/null; then
                COMPOSE_CMD="docker-compose"
            else
                error "Neither 'docker compose' nor 'docker-compose' found."
            fi
        fi

        if [[ -n "$COMPOSE_CMD" ]]; then
            COMPOSE_FILE="$MONITORING_DIR/docker-compose.yml"
            COMPOSE_ARGS=(-f "$COMPOSE_FILE")

            # macOS needs the override file for port mappings instead of host networking
            if [[ "$PLATFORM" == "macos" ]] && [[ -f "$MONITORING_DIR/docker-compose.macos.yml" ]]; then
                COMPOSE_ARGS+=(-f "$MONITORING_DIR/docker-compose.macos.yml")
                dim "Using macOS compose override (bridge networking)"
            fi

            # Ensure events.jsonl exists for the bind mount
            mkdir -p "$HOME/.claude/.statusline"
            touch "$HOME/.claude/.statusline/events.jsonl"
            # Ensure textfile dir exists for node-exporter
            mkdir -p "$HOME/.claude/.monitoring/textfile"

            if $DRY_RUN; then
                dim "(dry-run) Would run: $COMPOSE_CMD ${COMPOSE_ARGS[*]} up -d"
                    MONITORING_STARTED=true
            else
                dim "Running: $COMPOSE_CMD ${COMPOSE_ARGS[*]} up -d"
                if $COMPOSE_CMD "${COMPOSE_ARGS[@]}" up -d 2>&1 | while IFS= read -r line; do dim "$line"; done; then
                    MONITORING_STARTED=true
                    dim "Monitoring stack started"
                else
                    error "Failed to start monitoring stack. Check Docker logs."
                fi
            fi
        fi
    fi
fi

# === Generate warden.env (hook thresholds from merged config) ===
info "Generating warden.env..."

if $DRY_RUN; then
    dim "(dry-run) Would write warden.env to $WARDEN_ENV_DIR/"
else
    mkdir -p "$WARDEN_ENV_DIR"

    # Generate bash env file from warden thresholds JSON
    {
        printf '# Generated by claude-warden install.sh - do not edit\n'
        printf '# Profile: %s | Generated: %s\n\n' "$PROFILE" "$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"

        # Scalar thresholds
        printf '%s' "$WARDEN_THRESHOLDS_JSON" | jq -r '
            to_entries[] |
            select(.value | type == "number") |
            "export WARDEN_\(.key | ascii_upcase)=\(.value)"
        '

        # Subagent call limits (individual vars for Bash 3.2 compat)
        echo ""
        echo "# Subagent call limits"
        printf '%s' "$WARDEN_THRESHOLDS_JSON" | jq -r '
            .subagent_call_limits // {} | to_entries[] |
            "export WARDEN_CALL_LIMIT_\(.key | gsub("-";"_"))=\(.value)"
        '

        # Subagent byte limits (individual vars for Bash 3.2 compat)
        echo ""
        echo "# Subagent byte limits"
        printf '%s' "$WARDEN_THRESHOLDS_JSON" | jq -r '
            .subagent_byte_limits // {} | to_entries[] |
            "export WARDEN_BYTE_LIMIT_\(.key | gsub("-";"_"))=\(.value)"
        '
    } > "$WARDEN_ENV_DIR/warden.env"

    # Record which profile was used
    printf '%s\n' "$PROFILE" > "$WARDEN_ENV_DIR/profile"

    dim "Wrote $WARDEN_ENV_DIR/warden.env (profile: $PROFILE)"
fi

# === Merge into settings.json ===
info "Merging configuration into settings.json..."

if [[ ! -f "$HOOKS_TEMPLATE" ]]; then
    error "Hooks template not found: $HOOKS_TEMPLATE"
    exit 1
fi

HOOKS_JSON=$(jq '.hooks' "$HOOKS_TEMPLATE")
STATUSLINE_JSON=$(jq '.statusLine' "$HOOKS_TEMPLATE")

if $DRY_RUN; then
    dim "(dry-run) Would merge env ($ENV_COUNT vars), permissions ($ALLOW_COUNT allow rules), hooks, and statusLine into $SETTINGS_FILE"
else
    if [[ -f "$SETTINGS_FILE" ]]; then
        # Merge into existing settings:
        # - env: warden values added/overridden, user's non-warden keys preserved
        # - permissions.allow: union (unique)
        # - permissions.deny: union (unique)
        # - hooks: replaced with warden hooks
        # - statusLine: replaced with warden statusLine
        # - everything else: preserved
        MERGED=$(jq \
            --argjson warden_env "$WARDEN_ENV_JSON" \
            --argjson warden_allow "$WARDEN_ALLOW_JSON" \
            --argjson warden_deny "$WARDEN_DENY_JSON" \
            --argjson hooks "$HOOKS_JSON" \
            --argjson statusLine "$STATUSLINE_JSON" \
            '
            .env = ((.env // {}) * $warden_env) |
            .permissions.allow = (((.permissions.allow // []) + $warden_allow) | unique) |
            .permissions.deny = (((.permissions.deny // []) + $warden_deny) | unique) |
            .hooks = $hooks |
            .statusLine = $statusLine
            ' "$SETTINGS_FILE")
    else
        # No existing settings - create from warden config + hooks
        MERGED=$(jq -n \
            --argjson warden_env "$WARDEN_ENV_JSON" \
            --argjson warden_allow "$WARDEN_ALLOW_JSON" \
            --argjson warden_deny "$WARDEN_DENY_JSON" \
            --argjson hooks "$HOOKS_JSON" \
            --argjson statusLine "$STATUSLINE_JSON" \
            '{
                env: $warden_env,
                permissions: {
                    allow: $warden_allow,
                    deny: $warden_deny,
                    defaultMode: "default"
                },
                hooks: $hooks,
                statusLine: $statusLine
            }')
    fi

    printf '%s' "$MERGED" | jq '.' > "$SETTINGS_FILE.tmp"
    mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"

    # Count what changed
    FINAL_ENV=$(jq '.env | length' "$SETTINGS_FILE")
    FINAL_ALLOW=$(jq '.permissions.allow | length' "$SETTINGS_FILE")
    dim "settings.json: $FINAL_ENV env vars, $FINAL_ALLOW allow rules"
fi

# === Generate shell env (optional helper for .zshrc/.bashrc) ===
if ! $DRY_RUN; then
    SHELL_ENV_FILE="$WARDEN_ENV_DIR/warden.env.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Generated by claude-warden install.sh - source from .zshrc/.bashrc\n'
        printf '# Replaces manual Claude Code env vars in your shell config.\n'
        printf '# Profile: %s | Generated: %s\n\n' "$PROFILE" "$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"

        printf '# OTEL / Monitoring\n'
        printf '%s' "$WARDEN_ENV_JSON" | jq -r '
            to_entries[] |
            select(.key | test("^(OTEL_|DO_NOT_TRACK|DISABLE_TELEMETRY|DISABLE_ERROR_REPORTING|CLAUDE_CODE_ENABLE_TELEMETRY)")) |
            "export \(.key)=\"\(.value)\""
        '

        echo ""
        printf '# Token / Output Limits\n'
        printf '%s' "$WARDEN_ENV_JSON" | jq -r '
            to_entries[] |
            select(.key | test("^(CLAUDE_CODE_MAX_OUTPUT|CLAUDE_CODE_FILE_READ|MAX_THINKING|MAX_MCP_OUTPUT|BASH_MAX_OUTPUT|TASK_MAX_OUTPUT|DISABLE_NON_ESSENTIAL|DISABLE_COST|MCP_TIMEOUT|MCP_TOOL_TIMEOUT|CLAUDE_CODE_GLOB_TIMEOUT)")) |
            "export \(.key)=\"\(.value)\""
        '

        echo ""
        printf '# Sandbox / Behavior\n'
        printf '%s' "$WARDEN_ENV_JSON" | jq -r '
            to_entries[] |
            select(.key | test("^(CLAUDE_CODE_BUBBLEWRAP|CLAUDE_BASH_MAINTAIN|CLAUDE_CODE_GLOB_HIDDEN)")) |
            "export \(.key)=\"\(.value)\""
        '

        echo ""
        printf '# Warden internal\n'
        printf 'export WARDEN_STATE_DIR="${WARDEN_STATE_DIR:-$HOME/.claude/.statusline}"\n'

        echo ""
        printf '# API capture (NODE_OPTIONS preload — no proxy required)\n'
        printf '# Patches globalThis.fetch + https.request to capture Anthropic API traffic.\n'
        printf '# Logs land in ~/claude-captures/YYYY-MM-DD/capture-HHMMSS.jsonl\n'
        printf '# Set WARDEN_CAPTURE_BODIES=1 for full body logging (system/messages still redacted).\n'
        printf 'export NODE_OPTIONS="${NODE_OPTIONS:+${NODE_OPTIONS} }--require %s/capture/interceptor.js"\n' "$WARDEN_DIR"
    } > "$SHELL_ENV_FILE"

    dim "Wrote $SHELL_ENV_FILE"
fi

# === Detect shell RC status (for summary) ===
SHELL_RC_NEEDED=()
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [[ -f "$rc" ]] || continue
    if ! grep -qF "warden.env.sh" "$rc" 2>/dev/null; then
        SHELL_RC_NEEDED+=("$rc")
    fi
done
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

    # Validate warden.env
    if [[ -f "$WARDEN_ENV_DIR/warden.env" ]]; then
        if bash -n "$WARDEN_ENV_DIR/warden.env" 2>/dev/null; then
            dim "warden.env: syntax OK"
        else
            error "warden.env: syntax error!"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # Validate hook scripts
    for hook in "${HOOK_FILES[@]}"; do
        TARGET="$HOOKS_DIR/$hook"
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

    # Validate lib scripts
    if [[ -d "$HOOKS_DIR/lib" ]]; then
        for lib_script in "$HOOKS_DIR/lib"/*.sh; do
            [[ -f "$lib_script" ]] || continue
            LIB_TARGET="$lib_script"
            if [[ -L "$lib_script" ]]; then
                LIB_TARGET=$(readlink -f "$lib_script" 2>/dev/null || readlink "$lib_script")
            fi
            if bash -n "$LIB_TARGET" 2>/dev/null; then
                dim "$(basename "$lib_script"): syntax OK"
            else
                error "$(basename "$lib_script"): syntax error!"
                ERRORS=$((ERRORS + 1))
            fi
        done
    fi

    # Validate bin scripts (aurl, etc.)
    if [[ -d "$HOOKS_DIR/bin" ]]; then
        for bin_script in "$HOOKS_DIR/bin"/*; do
            [[ -f "$bin_script" ]] || continue
            BIN_TARGET="$bin_script"
            if [[ -L "$bin_script" ]]; then
                BIN_TARGET=$(readlink -f "$bin_script" 2>/dev/null || readlink "$bin_script")
            fi
            if bash -n "$BIN_TARGET" 2>/dev/null; then
                dim "$(basename "$bin_script"): syntax OK"
            else
                error "$(basename "$bin_script"): syntax error!"
                ERRORS=$((ERRORS + 1))
            fi
        done
    fi

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

info "Installation complete! (v$WARDEN_VERSION)"
echo ""
echo "  Version:    $WARDEN_VERSION"
echo "  Profile:    $PROFILE"
echo "  Hooks:      $HOOKS_DIR/ (${#HOOK_FILES[@]} hooks + lib, $MODE mode)"
echo "  Config:     $WARDEN_ENV_DIR/warden.env"
echo "  Settings:   $SETTINGS_FILE"
if [[ -n "${BACKUP_DIR:-}" ]]; then
    echo "  Backup:     $BACKUP_DIR/"
fi
if [[ -n "${SETTINGS_BACKUP:-}" ]]; then
    echo "  Backup:     $SETTINGS_BACKUP"
fi

# === Architecture diagram ===
echo ""
printf "  ${BOLD}CORE${RESET} ${DIM}(always installed, no Docker required)${RESET}\n"
echo ""
printf "  ${BOLD}${CYAN}Claude Code${RESET}\n"
echo "      |"
echo "      |--OTLP (HTTP/JSON)-----------------------------------."
echo "      |                                                      |"
echo "      |  SessionStart -----> session-start hook              |"
echo "      |       |                   |                          |"
echo "      |       v                   v                          v"
printf "      |  PreToolUse          ${BOLD}${CYAN}warden-collector${RESET}          :4319 OTLP\n"
echo "      |       |               (Go binary)              receiver"
echo "      |       v                   |                          |"
echo "      |  [tool runs]              v                          |"
echo "      |       |           collector.sock (UDS)               |"
echo "      |       v                   |                          |"
echo "      |  PostToolUse              v                          |"
printf "      |       |          .---${BOLD}${YELLOW}collector.db${RESET} (SQLite)-----.     |\n"
echo "      |       v          |                             |     |"
echo "      |  SessionEnd      |  sessions      hook_events  |<---'"
echo "      |                  |  spans          subagent_budgets"
echo "      |                  |  token counts   budget-deny files"
echo "      |                  '-------|---------------------'"
echo "      |                          |"
echo "      |                    .-----+------."
echo "      |                    |            |"
echo "      v                    v            v"
printf "  ${GREEN}statusline.sh${RESET}       ${GREEN}viewer UI${RESET}    ${GREEN}API queries${RESET}\n"
echo "  (context %)         (:8477)      /v1/sessions"
echo ""
echo ""
printf "  ${DIM}SQLite: $COLLECTOR_STATE_DIR/collector.db${RESET}\n"
printf "  ${DIM}Binary: $COLLECTOR_BIN_PATH${RESET}\n"
printf "  ${DIM}Starts automatically on session-start. Stops when idle.${RESET}\n"
echo ""

if $MONITORING_STARTED; then
    echo ""
    printf "  ${BOLD}DOCKER${RESET} ${YELLOW}(requires Docker + Docker Compose)${RESET}\n"
    printf "  ${DIM}-----------------------------------------------${RESET}\n"
    echo "  events.jsonl --> OTEL Collector --> Loki + Prometheus"
    echo "                                 --> Tempo --> Grafana (:3000)"
    echo ""
    echo "  Grafana:    http://localhost:3000 (admin/admin)"
    echo "  Prometheus: http://localhost:9090"
    echo "  Loki:       http://localhost:3100"
elif [[ "$MONITORING" == "yes" ]]; then
    echo ""
    printf "  ${RED}Docker monitoring: NOT STARTED (see errors above)${RESET}\n"
else
    echo ""
    printf "  ${DIM}Optional: ./install.sh --monitoring  (Docker + Compose required)${RESET}\n"
    printf "  ${DIM}  Adds Grafana dashboards, Loki log aggregation, Tempo traces${RESET}\n"
fi

echo ""
echo "  Start a new Claude Code session to activate hooks."
if [[ "$MODE" == "symlink" ]]; then
    echo "  Edits to $WARDEN_DIR/ take effect immediately."
fi
echo ""
echo "  To change profile:    ./install.sh --profile <name>"
echo "  To customize:         cp config/user.json.template config/user.json && edit"

if (( ${#SHELL_RC_NEEDED[@]} > 0 )); then
    echo ""
    printf "  ${YELLOW}Add this line to your shell RC file:${RESET}\n"
    echo ""
    printf "    ${CYAN}# claude-warden env${RESET}\n"
    printf "    ${CYAN}source \"%s/warden.env.sh\"${RESET}\n" "$WARDEN_ENV_DIR"
    echo ""
    printf "  Applies to: %s\n" "${SHELL_RC_NEEDED[*]}"
fi

# === Interactive walkthrough (opt-in) ===
if [[ -t 0 ]]; then
    echo ""
    printf "  ${CYAN}Want a quick walkthrough of what was installed? [y/N]:${RESET} "
    read -r _TOUR_CHOICE
    if [[ "${_TOUR_CHOICE:-n}" =~ ^[yY] ]]; then
        echo ""
        printf "${BOLD}  1/5  Hooks${RESET}\n"
        echo ""
        echo "  Hooks intercept every Claude Code tool call. They enforce token"
        echo "  limits, block dangerous commands, truncate large outputs, and"
        echo "  compress verbose reads -- saving thousands of tokens per session."
        echo ""
        echo "    PreToolUse -----> pre-tool-use -----> allow / block / modify"
        echo "                          |"
        echo "                     [tool runs]"
        echo "                          |"
        echo "    PostToolUse ----> post-tool-use ----> truncate / compress / pass"
        echo ""
        printf "  ${DIM}Installed: $HOOKS_DIR/ (${#HOOK_FILES[@]} hooks)${RESET}\n"
        printf "  ${DIM}Key: pre-tool-use (guards), post-tool-use (truncation),${RESET}\n"
        printf "  ${DIM}     read-guard (blocks binary), read-compress (extracts structure)${RESET}\n"
        printf "  ${DIM}Press Enter...${RESET}" && read -r

        echo ""
        printf "${BOLD}  2/5  Go Collector${RESET}\n"
        echo ""
        echo "  Central backbone. Receives OTLP spans from Claude Code to track"
        echo "  tokens, model, and context utilization. Hooks POST events via"
        echo "  Unix socket. Manages subagent budget enforcement."
        echo ""
        echo "    Claude Code --OTLP--> :4319 --."
        echo "                                   +--> collector.db (SQLite)"
        echo "    hooks --------UDS------------>'"
        echo "                                   sessions | spans"
        echo "                                   hook_events | budgets"
        echo ""
        printf "  ${DIM}Binary: $COLLECTOR_BIN_PATH${RESET}\n"
        printf "  ${DIM}SQLite: $COLLECTOR_STATE_DIR/collector.db${RESET}\n"
        printf "  ${DIM}Socket: $COLLECTOR_STATE_DIR/collector.sock${RESET}\n"
        printf "  ${DIM}Starts on session-start, stops when idle.${RESET}\n"
        printf "  ${DIM}Press Enter...${RESET}" && read -r

        echo ""
        printf "${BOLD}  3/5  Statusline${RESET}\n"
        echo ""
        echo "  Live session metrics in Claude Code's status bar."
        echo "  Queries the collector every refresh cycle."
        echo ""
        echo "    collector.db --> statusline.sh --> Claude Code status bar"
        echo ""
        printf "  ${DIM}Shows: model | context%% | in/out tokens | cache | tools | subagents${RESET}\n"
        printf "  ${DIM}Press Enter...${RESET}" && read -r

        echo ""
        printf "${BOLD}  4/5  Viewer${RESET}\n"
        echo ""
        echo "  Web UI that reads directly from collector.db."
        echo "  Six views: context gauge, waterfall, events, cost, tools, trend."
        echo ""
        echo "    collector.db --> viewer (python3) --> http://localhost:8477"
        echo ""
        printf "  ${DIM}Run: python3 $WARDEN_DIR/viewer/warden-viewer.py${RESET}\n"
        printf "  ${DIM}Press Enter...${RESET}" && read -r

        echo ""
        printf "${BOLD}  5/5  Configuration${RESET}\n"
        echo ""
        echo "  Your profile ($PROFILE) sets token limits, tool permissions,"
        echo "  and subagent budgets."
        echo ""
        echo "    defaults.json + $PROFILE.json + user.json"
        echo "         |              |               |"
        echo "         '-------merge-------.----------'"
        echo "                             |"
        echo "                       settings.json + warden.env"
        echo ""
        printf "  ${DIM}Profile:  $PROFILE_FILE${RESET}\n"
        printf "  ${DIM}Env:      $WARDEN_ENV_DIR/warden.env${RESET}\n"
        printf "  ${DIM}Override: cp config/user.json.template config/user.json${RESET}\n"
        if [[ "$MONITORING" != "no" ]] || $MONITORING_STARTED; then
            printf "  ${DIM}Docker:   cd monitoring && docker compose up -d${RESET}\n"
        fi
        echo ""
        printf "  ${GREEN}Walkthrough complete. Start a new Claude Code session to begin.${RESET}\n"
    fi
fi
