#!/usr/bin/env bash
# claude-warden shared library
# Source this file at the top of hooks to access common utilities
# Cost: ~1ms per source (negligible vs 55-110ms hook overhead)

# ==============================================================================
# ENVIRONMENT SETUP (executed once per hook invocation)
# ==============================================================================

# State directories
export WARDEN_STATE_DIR="${WARDEN_STATE_DIR:-$HOME/.claude/.statusline}"
export WARDEN_SESSION_BUDGET_DIR="${WARDEN_SESSION_BUDGET_DIR:-$HOME/.claude/.session-budgets}"
export WARDEN_SUBAGENT_STATE_DIR="${WARDEN_SUBAGENT_STATE_DIR:-$HOME/.claude/.subagent-state}"
export WARDEN_EVENTS_FILE="$WARDEN_STATE_DIR/events.jsonl"

# Session start timestamp (cached for this invocation)
if [[ -f "$WARDEN_STATE_DIR/.session_start" ]]; then
    _WARDEN_SESSION_START_NS=$(cat "$WARDEN_STATE_DIR/.session_start" 2>/dev/null)
    # Handle both formats: seconds-only and seconds.nanoseconds
    if [[ "$_WARDEN_SESSION_START_NS" == *.* ]]; then
        _WARDEN_SESSION_START_S=$(cut -d. -f1 <<< "$_WARDEN_SESSION_START_NS")
    else
        _WARDEN_SESSION_START_S="$_WARDEN_SESSION_START_NS"
    fi
else
    _WARDEN_SESSION_START_S=$(date +%s)
fi
export _WARDEN_SESSION_START_S

# Current timestamp (captured once)
export _WARDEN_NOW_S=$(date +%s)
export _WARDEN_NOW_NS=$(date +%s.%N)

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
    if [[ "$WARDEN_INPUT" =~ \"$field\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        value="${BASH_REMATCH[1]}"
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
    [[ "$transcript_path" == *"/subagents/"* || "$transcript_path" == *"/tmp/"* ]]
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

# Emit JSONL event for blocked commands (pre-tool-use)
# Usage: _warden_emit_block RULE TOKENS_SAVED [CMD_OVERRIDE]
_warden_emit_block() {
    local rule="$1" tokens="$2" cmd_override="${3:-}"
    local ts=$((_WARDEN_NOW_S - _WARDEN_SESSION_START_S))
    local cmd_safe="${cmd_override:-${WARDEN_COMMAND:0:200}}"

    # Sanitize command for JSON
    cmd_safe="${cmd_safe//$'\n'/ }"
    cmd_safe="${cmd_safe//\\/\\\\}"
    cmd_safe="${cmd_safe//\"/\\\"}"

    # Scrub potential secrets
    if [[ "$cmd_safe" =~ (-H|--header|Bearer|Authorization|token|_KEY=|_SECRET=|_TOKEN=|PASSWORD=|CREDENTIAL) ]]; then
        cmd_safe=$(printf '%s' "$cmd_safe" | sed -E \
            's/(-H|--header) +[^ ]+/\1 [REDACTED]/g;
             s/(Bearer |Authorization: ?)[^ ]+/\1[REDACTED]/g;
             s/([A-Z_]*(KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL)[A-Z_]*)=[^ ]+/\1=[REDACTED]/g')
    fi

    printf '{"timestamp":%d,"event_type":"blocked","tool":"%s","original_cmd":"%s","rule":"%s","tokens_saved":%d}\n' \
        "$ts" "${WARDEN_TOOL_NAME:-unknown}" "$cmd_safe" "$rule" "$tokens" \
        >> "$WARDEN_EVENTS_FILE" 2>/dev/null
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
    [[ -n "$rule" ]] && rule_field="$(printf ',"rule":"%s"' "$rule")"

    local cmd_safe="${WARDEN_COMMAND:0:200}"
    cmd_safe="${cmd_safe//$'\n'/ }"
    cmd_safe="${cmd_safe//\\/\\\\}"
    cmd_safe="${cmd_safe//\"/\\\"}"

    # Scrub secrets
    if [[ "$cmd_safe" =~ (-H|--header|Bearer|Authorization|token|_KEY=|_SECRET=|_TOKEN=|PASSWORD=|CREDENTIAL) ]]; then
        cmd_safe=$(printf '%s' "$cmd_safe" | sed -E \
            's/(-H|--header) +[^ ]+/\1 [REDACTED]/g;
             s/(Bearer |Authorization: ?)[^ ]+/\1[REDACTED]/g;
             s/([A-Z_]*(KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL)[A-Z_]*)=[^ ]+/\1=[REDACTED]/g')
    fi

    printf '{"timestamp":%d,"event_type":"%s","tool":"%s","original_cmd":"%s","tokens_saved":%d,"original_output_bytes":%d,"final_output_bytes":%d%s}\n' \
        "$ts" "$etype" "${WARDEN_TOOL_NAME:-unknown}" "$cmd_safe" "$saved" "$orig_bytes" "$final_bytes" "$rule_field" \
        >> "$WARDEN_EVENTS_FILE" 2>/dev/null
}

# ==============================================================================
# SYSTEM REMINDER STRIPPING
# ==============================================================================

# Strip <system-reminder> blocks from text
# Usage: _warden_strip_reminders "$TEXT"
# Returns: cleaned text via stdout
_warden_strip_reminders() {
    local -n text_ref=$1
    local cleaned

    cleaned=$(printf '%s' "${text_ref}" | sed '/^<system-reminder>/,/^<\/system-reminder>/d')
    cleaned=$(printf '%s' "$cleaned" | sed -e :a -e '/^[[:space:]]*$/{ $d; N; ba; }')

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

    echo "$(date -Iseconds),$agent_id,$category,$type,$duration,$session_id,$status" >> "$agent_stats"
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
        osascript -e "display notification \"$body\" with title \"$title\""
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
_warden_deny() {
    local reason="$1"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
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
