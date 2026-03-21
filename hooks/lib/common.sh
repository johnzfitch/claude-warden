#!/usr/bin/env bash
# claude-warden shared library
# Source this file at the top of hooks to access common utilities
# Cost: ~1ms per source (negligible vs 55-110ms hook overhead)

# ==============================================================================
# ENVIRONMENT SETUP (executed once per hook invocation)
# ==============================================================================

# State directories
export WARDEN_STATE_DIR="${WARDEN_STATE_DIR:-$HOME/.claude/.statusline}"
export WARDEN_EVENTS_FILE="${WARDEN_EVENTS_FILE:-$WARDEN_STATE_DIR/events.jsonl}"
export WARDEN_SESSION_BUDGET_DIR="${WARDEN_SESSION_BUDGET_DIR:-$HOME/.claude/.session-budgets}"
export WARDEN_SUBAGENT_STATE_DIR="${WARDEN_SUBAGENT_STATE_DIR:-$HOME/.claude/.subagent-state}"

# ==============================================================================
# CROSS-PLATFORM HELPERS (must be defined before first use)
# ==============================================================================

# Detect platform once
_WARDEN_OS="$(uname -s)"

# Get nanosecond-precision timestamp (epoch nanoseconds as integer)
# macOS date doesn't support %N; falls back to seconds * 10^9
_warden_date_ns() {
    if [[ "$_WARDEN_OS" == "Darwin" ]]; then
        # macOS: use perl for sub-second precision if available, else seconds
        if command -v perl &>/dev/null; then
            perl -MTime::HiRes=time -e 'printf "%d\n", time()*1e9'
        else
            echo "$(date +%s)000000000"
        fi
    else
        date +%s%N
    fi
}

# Get seconds.nanoseconds timestamp (e.g., 1234567890.123456789)
# macOS date doesn't support %N; falls back to seconds.000000000
_warden_date_sns() {
    if [[ "$_WARDEN_OS" == "Darwin" ]]; then
        if command -v perl &>/dev/null; then
            perl -MTime::HiRes=time -e 'printf "%.9f\n", time()'
        else
            echo "$(date +%s).000000000"
        fi
    else
        date +%s.%N
    fi
}

# Get ISO 8601 date string (e.g., 2024-01-15T10:30:00+0000)
# macOS date doesn't support -Iseconds
_warden_date_iso() {
    if [[ "$_WARDEN_OS" == "Darwin" ]]; then
        date -u +%Y-%m-%dT%H:%M:%S%z
    else
        date -Iseconds
    fi
}

# Cross-platform md5 hash (returns 32 hex chars on stdout)
_warden_md5() {
    if command -v md5sum &>/dev/null; then
        md5sum | cut -c1-32
    elif command -v md5 &>/dev/null; then
        md5 -q
    else
        # Fallback: use openssl which is available on both platforms
        openssl md5 -r | cut -c1-32
    fi
}

# ==============================================================================
# JSON ESCAPING
# ==============================================================================

# Escape a variable's value for safe embedding in JSON strings.
# Handles: \ " newline CR tab (all JSON-unsafe characters in typical hook data)
# Usage: _warden_json_escape VARNAME   (modifies in-place via printf -v)
_warden_json_escape() {
    local _var="$1"
    local _val="${!_var}"
    _val="${_val//\\/\\\\}"        # \ → \\  (must be first)
    _val="${_val//\"/\\\"}"        # " → \"
    _val="${_val//$'\n'/\\n}"      # newline → \n
    _val="${_val//$'\r'/\\r}"      # CR → \r
    _val="${_val//$'\t'/\\t}"      # tab → \t
    printf -v "$_var" '%s' "$_val"
}

# ==============================================================================
# CROSS-PROCESS LOCKING (flock on Linux/WSL, mkdir fallback on macOS)
# ==============================================================================

# Execute a function while holding an advisory lock.
# Usage: _warden_with_lock LOCKFILE FUNC [ARGS...]
# Linux/WSL: fd-based flock (kernel-level, race-free, auto-releases on exit).
# macOS: mkdir fallback with explicit acquisition tracking (never runs unlocked).
_warden_with_lock() {
    local lockfile="$1"; shift
    mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true
    if command -v flock &>/dev/null; then
        local _lock_fd
        exec {_lock_fd}>"$lockfile"
        flock -w 5 "$_lock_fd" || { exec {_lock_fd}>&-; return 1; }
        "$@"
        local rc=$?
        flock -u "$_lock_fd"
        exec {_lock_fd}>&-
        return $rc
    else
        # macOS fallback: mkdir-based with correct acquisition tracking
        local max_attempts=50 attempt=0 acquired=false
        while (( attempt < max_attempts )); do
            if mkdir "$lockfile.d" 2>/dev/null; then
                # Write our PID so others can detect staleness
                printf '%d' $$ > "$lockfile.d/pid" 2>/dev/null
                acquired=true
                break
            fi
            # Check for stale lock: if holder PID is dead, break the lock
            if (( attempt == 25 )); then
                local _holder_pid=""
                [[ -f "$lockfile.d/pid" ]] && _holder_pid=$(<"$lockfile.d/pid")
                if [[ -n "$_holder_pid" && "$_holder_pid" =~ ^[0-9]+$ ]]; then
                    if ! kill -0 "$_holder_pid" 2>/dev/null; then
                        # Holder is dead — break the stale lock
                        rm -rf "$lockfile.d" 2>/dev/null
                    fi
                fi
            fi
            sleep 0.1
            attempt=$((attempt + 1))
        done
        if [[ "$acquired" == true ]]; then
            "$@"
            local rc=$?
            rm -rf "$lockfile.d" 2>/dev/null || true
            return $rc
        fi
        # Not acquired after 5s -- skip silently.
        # Better to miss one budget increment than corrupt state.
        return 1
    fi
}

# Session start timestamp (initial value, refined by _warden_resolve_session_start).
# No global file -- each session writes .session_start-$sid only.
# This initial value is a safe fallback until the hook parses session_id.
_WARDEN_SESSION_START_S=$(date +%s)
export _WARDEN_SESSION_START_S

# Refine session start to a per-session file (call after parsing session_id).
# Fixes: concurrent sessions sharing a single global .session_start would skew
# all relative timestamps for the non-latest session.
_warden_resolve_session_start() {
    local sid="$1"
    [[ -z "$sid" ]] && return
    local per_session="$WARDEN_STATE_DIR/.session_start-$sid"
    if [[ -f "$per_session" ]]; then
        _WARDEN_SESSION_START_NS=$(cat "$per_session" 2>/dev/null)
        if [[ "$_WARDEN_SESSION_START_NS" == *.* ]]; then
            _WARDEN_SESSION_START_S=$(cut -d. -f1 <<< "$_WARDEN_SESSION_START_NS")
        else
            _WARDEN_SESSION_START_S="$_WARDEN_SESSION_START_NS"
        fi
    fi
}

# Current timestamp (captured once)
export _WARDEN_NOW_S=$(date +%s)
export _WARDEN_NOW_NS=$(_warden_date_sns)

# Source warden config if available (generated by install.sh)
# Contains thresholds, subagent budgets, and other tunable values
_WARDEN_CONFIG_ENV="${HOME}/.claude/.warden/warden.env"
if [[ -f "$_WARDEN_CONFIG_ENV" ]]; then
    if bash -n "$_WARDEN_CONFIG_ENV" 2>/dev/null; then
        source "$_WARDEN_CONFIG_ENV"
    else
        printf 'warden: warning: invalid config syntax in "%s"; using defaults\n' "$_WARDEN_CONFIG_ENV" >&2
    fi
fi

# Truncation thresholds (warden.env overrides, or fallback defaults)
export WARDEN_TRUNCATE_BYTES=${WARDEN_TRUNCATE_BYTES:-20480}           # 20KB generic
export WARDEN_SUBAGENT_READ_BYTES=${WARDEN_SUBAGENT_READ_BYTES:-10240} # 10KB subagent
export WARDEN_SUPPRESS_BYTES=${WARDEN_SUPPRESS_BYTES:-524288}          # 500KB suppress
export WARDEN_READ_GUARD_MAX_MB=${WARDEN_READ_GUARD_MAX_MB:-2}
export WARDEN_WRITE_MAX_BYTES=${WARDEN_WRITE_MAX_BYTES:-102400}
export WARDEN_EDIT_MAX_BYTES=${WARDEN_EDIT_MAX_BYTES:-51200}
export WARDEN_NOTEBOOK_MAX_BYTES=${WARDEN_NOTEBOOK_MAX_BYTES:-51200}
export WARDEN_DEFAULT_CALL_LIMIT=${WARDEN_DEFAULT_CALL_LIMIT:-30}
export WARDEN_DEFAULT_BYTE_LIMIT=${WARDEN_DEFAULT_BYTE_LIMIT:-102400}
export WARDEN_BUDGET_TOTAL=${WARDEN_BUDGET_TOTAL:-280000}

# ==============================================================================
# BUILT-IN BUDGET TRACKER
# ==============================================================================
# Tracks estimated token consumption per session (~3.5 bytes/token).
# State: single file with consumed count. Total from WARDEN_BUDGET_TOTAL.
# Legacy budget-cli state is intentionally ignored; claude-warden owns this
# budget path inline under ~/.claude/.warden/.

WARDEN_BUDGET_STATE="${HOME}/.claude/.warden/budget.state"
WARDEN_BUDGET_CACHE="$WARDEN_STATE_DIR/budget-export"

# Read consumed tokens from state file (returns number on stdout)
_warden_budget_read() {
    [[ -f "$WARDEN_BUDGET_STATE" ]] || { echo 0; return; }
    local val
    val=$(<"$WARDEN_BUDGET_STATE")
    [[ "$val" =~ ^[0-9]+$ ]] && echo "$val" || echo 0
}

# Write consumed tokens to state file
_warden_budget_write() {
    mkdir -p "$(dirname "$WARDEN_BUDGET_STATE")"
    printf '%d' "$1" > "$WARDEN_BUDGET_STATE"
}

# Add tokens to consumed counter (locked to prevent concurrent race)
_warden_budget_update() {
    local tokens="${1:-0}"
    [[ "$tokens" =~ ^[0-9]+$ ]] || return 0
    (( tokens == 0 )) && return 0
    _budget_add() {
        local consumed
        consumed=$(_warden_budget_read)
        consumed=$((consumed + tokens))
        _warden_budget_write "$consumed"
    }
    _warden_with_lock "${WARDEN_BUDGET_STATE}.lock" _budget_add
}

# Check if budget is available (exit 0 = ok, exit 1 = exhausted)
_warden_budget_check() {
    local consumed
    consumed=$(_warden_budget_read)
    (( consumed < WARDEN_BUDGET_TOTAL ))
}

# Read a numeric value from a file with fallback (prevents arithmetic errors on corrupt/empty files)
_warden_read_numeric() {
    local file="$1" fallback="${2:-0}"
    local val=""
    [[ -f "$file" ]] && val=$(<"$file" 2>/dev/null)
    [[ "$val" =~ ^[0-9]+$ ]] && printf '%s' "$val" || printf '%s' "$fallback"
}

# Export budget state as JSON to stdout AND write cache for statusline
_warden_budget_export() {
    local consumed total util
    consumed=$(_warden_budget_read)
    total="$WARDEN_BUDGET_TOTAL"
    util=0
    (( total > 0 )) && util=$((consumed * 100 / total))
    local json
    json=$(printf '{"consumed":%d,"limit":%d,"total_limit":%d,"utilization":%d}' \
        "$consumed" "$total" "$total" "$util")
    echo "$json"
    # Write cache for statusline (non-blocking)
    mkdir -p "$(dirname "$WARDEN_BUDGET_CACHE")"
    printf '%s' "$json" > "$WARDEN_BUDGET_CACHE.tmp.$$" 2>/dev/null && mv "$WARDEN_BUDGET_CACHE.tmp.$$" "$WARDEN_BUDGET_CACHE" 2>/dev/null || true
}

# Reset budget counter (called at session start)
_warden_budget_reset() {
    _warden_budget_write 0
}

# ==============================================================================
# SUBAGENT LIMIT LOOKUPS (Bash 3.2 compatible)
# ==============================================================================
# warden.env exports WARDEN_CALL_LIMIT_<type> and WARDEN_BYTE_LIMIT_<type>
# as individual vars (hyphens replaced with underscores).
# These helpers look up the correct var via indirect expansion.

_warden_call_limit() {
    local type="${1//-/_}"
    local var="WARDEN_CALL_LIMIT_${type}"
    echo "${!var:-$WARDEN_DEFAULT_CALL_LIMIT}"
}

_warden_byte_limit() {
    local type="${1//-/_}"
    local var="WARDEN_BYTE_LIMIT_${type}"
    echo "${!var:-$WARDEN_DEFAULT_BYTE_LIMIT}"
}

# ==============================================================================
# INPUT PARSING
# ==============================================================================

# Parse stdin input with timeout
# Usage: _warden_read_input
# Sets global: WARDEN_INPUT
_warden_read_input() {
    read -r -t 5 -d '' WARDEN_INPUT || true
    export WARDEN_INPUT
    [[ -z "$WARDEN_INPUT" ]] && return 1
    return 0
}

# Two-tier jq extraction optimized for hot path
# Tier 1: Bash extraction for top-level string fields (safe, machine-generated JSON)
# Tier 2: Single jq call for nested fields or non-string types
#
# Usage: _warden_parse_toplevel FIELD_NAME
# Extracts top-level string fields using parameter expansion (10ms faster than jq)
# SAFETY: Only works for top-level string fields in well-formed machine JSON
# ASSUMPTION: Claude Code emits JSON where top-level strings don't contain escaped quotes
_warden_parse_toplevel() {
    local field="$1"
    local value=""

    # Extract using bash parameter expansion: "field":"value"
    if [[ "$WARDEN_INPUT" =~ \"$field\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
        value="${BASH_REMATCH[1]}"
    fi

    # Fallback to jq if the match contains backslashes (possible escaped quotes)
    # or if the regex missed entirely (empty value for a field that exists)
    if [[ "$value" == *\\* ]] || { [[ -z "$value" ]] && [[ "$WARDEN_INPUT" == *"\"$field\""* ]]; }; then
        value=$(printf '%s' "$WARDEN_INPUT" | jq -r ".$field // \"\"" 2>/dev/null) || value=""
    fi

    printf '%s' "$value"
}

# Fast extraction of common top-level fields (non-Bash fast path)
# Usage: _warden_parse_tool_name
# Returns: tool_name value
_warden_parse_tool_name() {
    _warden_parse_toplevel "tool_name"
}

_warden_parse_session_id() {
    _warden_parse_toplevel "session_id"
}

_warden_parse_transcript_path() {
    _warden_parse_toplevel "transcript_path"
}

# Parse nested tool_input fields (single jq call, returns TSV)
# Usage: IFS=$'\t' read -r VAR1 VAR2 VAR3 < <(_warden_parse_tool_input field1 field2 field3)
_warden_parse_tool_input() {
    local -a fields=("$@")
    local jq_expr='['
    for field in "${fields[@]}"; do
        jq_expr+=".tool_input.$field // \"\", "
    done
    jq_expr="${jq_expr%, }] | @tsv"

    printf '%s' "$WARDEN_INPUT" | jq -r "$jq_expr" 2>/dev/null
}

# ==============================================================================
# ID SANITIZATION
# ==============================================================================

# Sanitize session/agent IDs to prevent path traversal
# Usage: _warden_sanitize_id "$ID"
# Returns: sanitized ID or empty string if invalid
_warden_sanitize_id() {
    local id="$1"
    if [[ "$id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        printf '%s' "$id"
    fi
}

# ==============================================================================
# SUBAGENT DETECTION
# ==============================================================================

# Detect if current invocation is from a subagent
# Usage: _warden_is_subagent "$TRANSCRIPT_PATH"
# Returns: 0 if subagent, 1 if main agent
_warden_is_subagent() {
    local transcript_path="$1"
    [[ "$transcript_path" == *"/subagents/"* ]]
}

# Extract agent ID from transcript path
# Usage: _warden_get_agent_id "$TRANSCRIPT_PATH"
# Returns: sanitized agent ID or empty
_warden_get_agent_id() {
    local transcript_path="$1"
    local agent_id=""

    if [[ "$transcript_path" == *"/subagents/"* ]]; then
        agent_id=$(basename "$transcript_path" .jsonl | sed 's/^agent-//')
        agent_id=$(_warden_sanitize_id "$agent_id")
    fi

    printf '%s' "$agent_id"
}

# Get agent type from state file
# Usage: _warden_get_agent_type "$AGENT_ID"
# Returns: agent type or empty
_warden_get_agent_type() {
    local agent_id="$1"
    local agent_type=""

    if [[ -n "$agent_id" && -f "$WARDEN_SUBAGENT_STATE_DIR/$agent_id" ]]; then
        agent_type=$(grep '^AGENT_TYPE=' "$WARDEN_SUBAGENT_STATE_DIR/$agent_id" 2>/dev/null | head -1 | cut -d= -f2)
    fi

    printf '%s' "$agent_type"
}

# ==============================================================================
# EVENT EMISSION
# ==============================================================================

# Scrub potential secrets from command strings
# Usage: echo "$text" | _warden_scrub_secrets
_warden_scrub_secrets() {
    sed -E \
        's/(-H|--header) +[^ ]+/\1 [REDACTED]/g;
         s/(Bearer |Authorization: ?)[^ ]+/\1[REDACTED]/gi;
         s/([a-zA-Z_]*(key|secret|token|password|credential|api_key|database_url|client_id|client_secret|access_token|refresh_token)[a-zA-Z_]*)=[^ ]+/\1=[REDACTED]/gi;
         s/(ghp_|github_pat_|sk-|gho_|glpat-|xox[bpsa]-)[^ ]+/[REDACTED]/g'
}

# Scrub secrets from a variable in-place if it looks like it may contain them
# Usage: _warden_maybe_scrub cmd_safe
# Bash 3.2 compatible: uses ${!var} indirect read + printf -v write (no local -n)
_warden_maybe_scrub() {
    local _varname=$1
    local _val="${!_varname}"
    # Case-insensitive check via shopt (scoped to this function via subshell-free restore)
    local _prev_nocasematch
    _prev_nocasematch=$(shopt -p nocasematch 2>/dev/null || true)
    shopt -s nocasematch
    if [[ "$_val" =~ (-H|--header|bearer|authorization|token|key=|secret=|password=|credential=|database_url=|client_id=|client_secret=|access_token=|ghp_|github_pat_|sk-|gho_|glpat-|xox[bpsa]-) ]]; then
        printf -v "$_varname" '%s' "$(printf '%s' "$_val" | _warden_scrub_secrets)"
    fi
    eval "$_prev_nocasematch" 2>/dev/null || true
}


# ==============================================================================
# COLLECTOR INTEGRATION
# ==============================================================================


# Start the Go collector if enabled and not already running.
# Called once per session from session-start — NOT from per-tool hooks.
# Uses /healthz probe (50ms timeout) to detect a running instance.
# The collector is a single-writer SQLite process; starting a second
# instance would fail on bind anyway, so this is safe to race.
_warden_ensure_collector() {
    local _state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/claude-warden"
    local _pidfile="${_state_dir}/collector.pid"
    local _logfile="${_state_dir}/collector.log"

    # Fast path: pidfile check (stat + read + kill syscall, ~0ms)
    if [[ -f "$_pidfile" ]]; then
        local _pid
        _pid=$(<"$_pidfile")
        # Validate numeric and process alive
        if [[ "$_pid" =~ ^[0-9]+$ ]] && kill -0 "$_pid" 2>/dev/null; then
            # Guard against PID reuse: verify it is actually the collector
            # /proc check is Linux-only; skip on macOS (PID reuse is rare enough)
            if [[ -r "/proc/$_pid/comm" ]]; then
                [[ "$(<"/proc/$_pid/comm")" == warden-collecto* ]] && return 0
            else
                return 0  # non-Linux: trust kill -0
            fi
        fi
        # Stale pidfile — remove it
        rm -f "$_pidfile" 2>/dev/null
    fi

    # Find the binary: env override -> installed -> dev tree
    local _bin="" _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for _candidate in \
        "${WARDEN_COLLECTOR_BIN:-}" \
        "$HOME/.local/bin/warden-collector" \
        "${_lib_dir}/../../collector/warden-collector"; do
        [[ -n "$_candidate" && -x "$_candidate" ]] && { _bin="$_candidate"; break; }
    done
    [[ -z "$_bin" ]] && return 0  # no binary found, skip silently

    # Ensure state dir exists (first-ever run)
    [[ -d "$_state_dir" ]] || mkdir -p "$_state_dir" 2>/dev/null

    # Rotate log if > 1MB
    if [[ -f "$_logfile" ]]; then
        local _logsz
        _logsz=$(stat -c%s "$_logfile" 2>/dev/null || stat -f%z "$_logfile" 2>/dev/null || echo 0)
        (( _logsz > 1048576 )) && mv -f "$_logfile" "${_logfile}.1" 2>/dev/null
    fi

    # Start in background, detached from hook process tree
    nohup "$_bin" >> "$_logfile" 2>&1 &
    disown

    # Brief wait for bind, then verify via pidfile (not network)
    sleep 0.15
    [[ -f "$_pidfile" ]] && return 0
    return 1
}

# Post event to local Go collector (async, non-blocking)
# Falls back silently if collector is not running.
# Usage: _warden_post_to_collector JSON_STRING
_warden_append_event_jsonl() {
    local _payload="$1"
    [[ -z "$_payload" ]] && return 0
    mkdir -p "$(dirname "$WARDEN_EVENTS_FILE")" 2>/dev/null || return 0
    printf '%s\n' "$_payload" >> "$WARDEN_EVENTS_FILE" 2>/dev/null || true
}

_warden_post_to_collector() {
    local _payload="$1"
    local _sock="${XDG_STATE_HOME:-$HOME/.local/state}/claude-warden/collector.sock"
    _warden_append_event_jsonl "$_payload"
    # Fire-and-forget: 100ms timeout, background, discard output
    # Uses UDS for lower latency and security
    command curl -s --max-time 0.1 -X POST \
        -H 'Content-Type: application/json' \
        --unix-socket "$_sock" \
        --data-raw "$_payload" \
        "http://localhost/v1/ingest/hook" \
        &>/dev/null &
}
# Emit JSONL event for blocked commands (pre-tool-use)
# Usage: _warden_emit_block RULE TOKENS_SAVED [CMD_OVERRIDE]
_warden_emit_block() {
    local rule="$1" tokens="$2" cmd_override="${3:-}"
    local ts=$((_WARDEN_NOW_S - _WARDEN_SESSION_START_S))
    local cmd_safe="${cmd_override:-${WARDEN_COMMAND:0:200}}"
    local tool_safe="${WARDEN_TOOL_NAME:-unknown}"
    local sid_safe="${WARDEN_SESSION_ID:-}"

    _warden_json_escape cmd_safe
    _warden_json_escape tool_safe
    _warden_json_escape sid_safe
    _warden_json_escape rule
    _warden_maybe_scrub cmd_safe

    local _evt
    printf -v _evt '{"timestamp":%d,"event_type":"blocked","tool":"%s","session_id":"%s","original_cmd":"%s","rule":"%s","tokens_saved":%d}' \
        "$ts" "$tool_safe" "$sid_safe" "$cmd_safe" "$rule" "$tokens"
    _warden_post_to_collector "$_evt"
}

# Emit JSONL event for post-tool-use accounting
# Usage: _warden_emit_event EVENT_TYPE ORIG_BYTES FINAL_BYTES [RULE]
_warden_emit_event() {
    local etype="$1" orig_bytes="$2" final_bytes="$3" rule="${4:-}"

    # 3.5 bytes/token average
    local saved=$(( (orig_bytes - final_bytes) * 10 / 35 ))
    (( saved < 0 )) && saved=0

    local ts=$((_WARDEN_NOW_S - _WARDEN_SESSION_START_S))
    local rule_field=""
    if [[ -n "$rule" ]]; then
        _warden_json_escape rule
        rule_field="$(printf ',"rule":"%s"' "$rule")"
    fi

    local cmd_safe="${WARDEN_COMMAND:0:200}"
    local tool_safe="${WARDEN_TOOL_NAME:-unknown}"
    local sid_safe="${WARDEN_SESSION_ID:-}"

    _warden_json_escape cmd_safe
    _warden_json_escape tool_safe
    _warden_json_escape sid_safe
    _warden_json_escape etype
    _warden_maybe_scrub cmd_safe
    local _evt
    printf -v _evt '{"timestamp":%d,"event_type":"%s","tool":"%s","session_id":"%s","original_cmd":"%s","tokens_saved":%d,"original_output_bytes":%d,"final_output_bytes":%d%s}' \
        "$ts" "$etype" "$tool_safe" "$sid_safe" "$cmd_safe" "$saved" "$orig_bytes" "$final_bytes" "$rule_field"
    _warden_post_to_collector "$_evt"

    # Track final output size for subagent byte correction (read by EXIT trap in post-tool-use)
    _WARDEN_FINAL_SIZE="$final_bytes"
}

# Emit JSONL event for tool output size tracking
# Usage: _warden_emit_output_size TOOL_NAME OUTPUT_BYTES OUTPUT_LINES CMD
_warden_emit_output_size() {
    local tool_name="$1" output_bytes="$2" output_lines="${3:-0}" cmd="${4:-}"
    local ts=$((_WARDEN_NOW_S - _WARDEN_SESSION_START_S))

    local estimated_tokens=$(( output_bytes * 10 / 35 ))

    local cmd_safe="${cmd:0:200}"
    local sid="${WARDEN_SESSION_ID:-}"

    _warden_json_escape cmd_safe
    _warden_json_escape tool_name
    _warden_json_escape sid
    _warden_maybe_scrub cmd_safe
    local _evt
    printf -v _evt '{"timestamp":%d,"event_type":"tool_output_size","tool":"%s","session_id":"%s","output_bytes":%d,"output_lines":%d,"estimated_tokens":%d,"original_cmd":"%s"}' \
        "$ts" "$tool_name" "$sid" "$output_bytes" "$output_lines" "$estimated_tokens" "$cmd_safe"
    _warden_post_to_collector "$_evt"
}

# ==============================================================================
# SYSTEM REMINDER STRIPPING
# ==============================================================================

# Strip <system-reminder> blocks from text
# Usage: _warden_strip_reminders VAR_NAME
# Returns: cleaned text via stdout
# Bash 3.2 compatible: uses ${!1} indirect read (no local -n)
_warden_strip_reminders() {
    local text_ref="${!1}"
    local cleaned

    cleaned=$(printf '%s' "${text_ref}" | sed '/^<system-reminder>/,/^<\/system-reminder>/d')
    # Trim trailing blank lines: BSD sed branch labels don't work cross-platform; awk does
    cleaned=$(printf '%s' "$cleaned" | awk 'NF{found=NR} {a[NR]=$0} END{for(i=1;i<=found;i++)print a[i]}')

    printf '%s' "$cleaned"
}

# ==============================================================================
# FILE UTILITIES
# ==============================================================================

# Get file modification time
# Usage: _warden_stat_mtime "$FILE_PATH"
# Returns: mtime in seconds
_warden_stat_mtime() {
    local file="$1"
    stat -c%Y "$file" 2>/dev/null || stat -f%m "$file" 2>/dev/null || echo 0
}

# ==============================================================================
# AGENT STATS
# ==============================================================================

# Append to unified agent stats CSV
# Usage: _warden_agent_stats_append AGENT_ID AGENT_CATEGORY AGENT_TYPE DURATION STATUS
_warden_agent_stats_append() {
    local agent_id="$1" category="$2" type="$3" duration="$4" status="$5"
    local agent_stats="$HOME/.claude/agent-stats.csv"
    local session_id="${WARDEN_SESSION_ID:-unknown}"

    # Initialize CSV with header if needed
    if [[ ! -f "$agent_stats" ]]; then
        echo "timestamp,agent_id,agent_category,agent_type,duration_seconds,session_id,status" > "$agent_stats"
    fi

    echo "$(_warden_date_iso),$agent_id,$category,$type,$duration,$session_id,$status" >> "$agent_stats"
}

# ==============================================================================
# NOTIFICATIONS
# ==============================================================================

# Cross-platform notification
# Usage: _warden_notify URGENCY TITLE BODY
_warden_notify() {
    local urgency="$1" title="$2" body="$3"
    if command -v notify-send &>/dev/null; then
        notify-send -u "$urgency" "$title" "$body"
    elif command -v osascript &>/dev/null; then
        # Escape for AppleScript string literals (backslash + double quote)
        local as_title="${title//\\/\\\\}" as_body="${body//\\/\\\\}"
        as_title="${as_title//\"/\\\"}" as_body="${as_body//\"/\\\"}"
        osascript -e "display notification \"$as_body\" with title \"$as_title\""
    fi
}

# ==============================================================================
# HOOK OUTPUT HELPERS
# ==============================================================================

# Suppress output (pass through)
_warden_suppress_ok() {
    echo '{"suppressOutput":true}'
    exit 0
}

# Deny with reason (PreToolUse)
# Model sees permissionDecisionReason, user sees stderr
# SECURITY: Uses jq for JSON construction — reason may contain adversarial
# command fragments that could inject into permissionDecision if printf-escaped.
_warden_deny() {
    local reason="$1"
    printf 'warden: %s\n' "$reason" >&2
    jq -n --arg reason "$reason" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
    exit 0
}

# Quiet override: modify command via updatedInput and signal post-tool-use (PreToolUse)
# Usage: _warden_quiet_override RULE MODIFIED_COMMAND
# Writes a command-scoped marker file for post-tool-use reminders so overlapping
# quiet overrides in the same session do not stomp each other.
_warden_quiet_override() {
    local rule="$1" cmd="$2"
    local tool="${WARDEN_TOOL_NAME:-Bash}"
    local sid="${WARDEN_SESSION_ID:-$$}"
    local cmd_hash
    cmd_hash=$(printf '%s' "$cmd" | _warden_md5 2>/dev/null)
    [[ -z "$cmd_hash" ]] && cmd_hash="unknown"
    mkdir -p "$WARDEN_STATE_DIR"
    printf '%s' "$rule" > "$WARDEN_STATE_DIR/.quiet-override-${tool}-${sid}-${cmd_hash}-$(_warden_date_ns)-$$"
    _warden_emit_event "allowed" 0 0 "$rule"
    jq -n --arg cmd "$cmd" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":$cmd}}}'
    exit 0
}

# ==============================================================================
# INLINE AGENT VALIDATIONS (from agents/)
# ==============================================================================

# Redact secrets from tool output (PostToolUse)
# Usage: _warden_check_secrets "$RESPONSE_TEXT"
# Returns: 0 if secrets found, 1 if clean
_warden_check_secrets() {
    local response="$1"
    local secret_patterns='(AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]+\.eyJ|-----BEGIN .* PRIVATE KEY-----|api[_-]?key.*=.*[a-zA-Z0-9]{20,})'

    if printf '%s' "$response" | grep -qiE "$secret_patterns"; then
        return 0
    fi
    return 1
}

# Validate readonly for code-reviewer agents (PreToolUse)
# Usage: _warden_validate_readonly "$COMMAND"
# Returns: 0 if allowed, 1 if blocked
_warden_validate_readonly() {
    local command="$1"
    # Fixed bug #7: include BOL redirects with (^|[^-])>
    local write_patterns='(\brm\b|\brmdir\b|\bmv\b|\bcp\b|(^|[^-])>|>>|\btee\b|sed -i|\bchmod\b|\bchown\b|\btruncate\b|\bdd\b|\binstall\b|rsync.*--delete|\bpatch\b|git checkout -- |git restore|\bunlink\b|\bshred\b|\btouch\b|\bln\b|\bmkdir\b)'

    if printf '%s' "$command" | grep -qiE "$write_patterns"; then
        return 1
    fi
    return 0
}

# Validate git commands (PreToolUse)
# Usage: _warden_validate_git "$COMMAND"
# Returns: 0 if allowed, 1 if blocked (with stderr message)
_warden_validate_git() {
    local command="$1"

    # Block dangerous git operations
    if printf '%s' "$command" | grep -qiE '(git push.*--force|git push.*-f|git reset --hard|git clean -fd|git clean -f)'; then
        if printf '%s' "$command" | grep -qiE '(main|master|origin)'; then
            echo "Blocked: Force push/reset to main/master requires explicit user approval" >&2
            return 1
        fi
    fi

    # Block git config writes
    if printf '%s' "$command" | grep -qiE 'git config'; then
        if printf '%s' "$command" | grep -qiE '(--get|--get-all|--list|-l|--show-origin)'; then
            return 0  # Read-only, allow
        elif printf '%s' "$command" | grep -qiE '(user\.|email|name|credential)'; then
            echo "Blocked: Git config writes not allowed" >&2
            return 1
        fi
    fi

    return 0
}

# ==============================================================================
# INITIALIZATION COMPLETE
# ==============================================================================
# Library loaded. Hooks can now use all _warden_* functions.
