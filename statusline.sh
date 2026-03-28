#!/usr/bin/env bash
# Claude Code statusline - display model and token usage.
#
# Input: JSON on stdin per Claude Code status line docs.

set -u
# ERR trap catches most failures, but set -u errors bypass it in bash.
# Add an EXIT trap as a safety net: if nothing was printed, emit fallback.
_warden_sl_printed=0
trap 'printf "[Claude] err\n"; exit 0' ERR
trap '[ "$_warden_sl_printed" -eq 0 ] && printf "[Claude]\n"' EXIT

input="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
    _warden_sl_printed=1
    printf '[Claude] Ctx 0%%\n'
    exit 0
fi

parsed="$(
    jq -r '
      def toolcount:
        (.tool_count // .tool_counts.total // .tools.total // .tool_usage.total // .tool_usage.total_calls // .usage.tools.total // 0);
      [
        (.session_id // ""),
        (.model.display_name // .model.id // "Unknown"),
        (.context_window.context_window_size // 0),
        (.context_window.total_input_tokens // 0),
        (.context_window.total_output_tokens // 0),
        (.context_window.used_percentage // ""),
        (if .context_window.current_usage == null then 0 else 1 end),
        (.context_window.current_usage.input_tokens // 0),
        (.context_window.current_usage.output_tokens // 0),
        (.context_window.current_usage.cache_creation_input_tokens // 0),
        (.context_window.current_usage.cache_read_input_tokens // 0),
        toolcount,
        (.cost.total_cost_usd // 0),
        (.cost.total_duration_ms // 0),
        (.cost.total_api_duration_ms // 0),
        (.cost.total_lines_added // 0),
        (.cost.total_lines_removed // 0),
        (.transcript_path // "")
      ]
      | map(tostring)
      | join("\u001f")
    ' <<<"$input" 2>/dev/null
)"

if [ -z "$parsed" ]; then
    _warden_sl_printed=1
    printf '[Claude] Ctx 0%%\n'
    exit 0
fi

IFS=$'\x1f' read -r \
    SESSION_ID \
    MODEL \
    CONTEXT_SIZE \
    TOTAL_INPUT \
    TOTAL_OUTPUT \
    USED_PCT_RAW \
    HAS_CURR \
    CURR_IN \
    CURR_OUT \
    CACHE_CREATE \
    CACHE_READ \
    TOOL_COUNT_RAW \
    COST_RAW \
    DURATION_MS \
    API_DURATION_MS \
    LINES_ADDED \
    LINES_REMOVED \
    TRANSCRIPT_PATH \
    <<<"$parsed"

# Parsing complete — clear ERR trap so state file reads don't trigger it
trap - ERR

# Sanitize SESSION_ID before using in file paths (comes from stdin JSON)
SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"

# When SESSION_ID is empty, derive a stable per-terminal fallback from the
# parent PID so concurrent terminals never share a single state file.
if [ -z "$SESSION_ID" ]; then
    SESSION_ID="tty-${PPID:-$$}"
fi

num_or_zero() {
    local value="$1"
    if [[ "$value" =~ ^-?[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '0'
    fi
}

format_tokens() {
    local value="$1"
    if [ "$value" -ge 1000000 ]; then
        local whole=$((value / 1000000))
        local dec=$(((value % 1000000) / 100000))
        if [ "$dec" -eq 0 ]; then
            printf '%sM' "$whole"
        else
            printf '%s.%sM' "$whole" "$dec"
        fi
    elif [ "$value" -ge 1000 ]; then
        local whole=$((value / 1000))
        local dec=$(((value % 1000) / 100))
        if [ "$dec" -eq 0 ]; then
            printf '%sk' "$whole"
        else
            printf '%s.%sk' "$whole" "$dec"
        fi
    else
        printf '%s' "$value"
    fi
}

format_percent_from_tenths() {
    local tenths="$1"
    local whole=$((tenths / 10))
    local dec=$((tenths % 10))
    if [ "$dec" -eq 0 ]; then
        printf '%s' "$whole"
    else
        printf '%s.%s' "$whole" "$dec"
    fi
}

escape_prom_label() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    printf '%s' "$value"
}

write_session_metrics_prom() {
    local session_id="$1"
    local model="$2"
    local total_input="$3"
    local total_output="$4"
    local duration_ms="$5"
    local cost_usd="$6"

    [ -n "$session_id" ] || return 0

    local prom_dir="${HOME}/.claude/.monitoring/textfile"
    local prom_file="${prom_dir}/claude-code-session-${session_id}.prom"
    local model_label active_seconds tmp_file

    mkdir -p "$prom_dir" 2>/dev/null || return 0
    model_label="$(escape_prom_label "$model")"
    active_seconds="$(LC_NUMERIC=C awk -v ms="$duration_ms" 'BEGIN { printf "%.3f", ms / 1000 }' 2>/dev/null)"
    if [[ ! "$active_seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        active_seconds="0"
    fi
    if [[ ! "$cost_usd" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        cost_usd="0"
    fi

    tmp_file="${prom_file}.tmp.$$"
    {
        printf '# HELP claude_warden_cost_usage_USD_total Current session cost exported by claude-warden statusline\n'
        printf '# TYPE claude_warden_cost_usage_USD_total gauge\n'
        printf 'claude_warden_cost_usage_USD_total{session_id="%s",model="%s"} %s\n' "$session_id" "$model_label" "$cost_usd"
        printf '# HELP claude_warden_token_usage_tokens_total Current session token totals exported by claude-warden statusline\n'
        printf '# TYPE claude_warden_token_usage_tokens_total gauge\n'
        printf 'claude_warden_token_usage_tokens_total{session_id="%s",model="%s",type="input"} %s\n' "$session_id" "$model_label" "$total_input"
        printf 'claude_warden_token_usage_tokens_total{session_id="%s",model="%s",type="output"} %s\n' "$session_id" "$model_label" "$total_output"
        printf '# HELP claude_warden_active_time_seconds_total Current session active time exported by claude-warden statusline\n'
        printf '# TYPE claude_warden_active_time_seconds_total gauge\n'
        printf 'claude_warden_active_time_seconds_total{session_id="%s",model="%s"} %s\n' "$session_id" "$model_label" "$active_seconds"
        printf '# HELP claude_warden_session_count_total Active sessions exported by claude-warden statusline\n'
        printf '# TYPE claude_warden_session_count_total gauge\n'
        printf 'claude_warden_session_count_total{session_id="%s",model="%s"} 1\n' "$session_id" "$model_label"
    } > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$prom_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null
}

abbreviate_model() {
    local model="$1"

    case "$model" in
        claude-opus-4-6-*|claude-opus-4-6)
            model="Opus 4.6"
            ;;
        claude-opus-4-5-*|claude-opus-4-5)
            model="Opus 4.5"
            ;;
        claude-opus-4-*|claude-opus-4)
            model="Opus 4"
            ;;
        claude-sonnet-4-6-*|claude-sonnet-4-6)
            model="Sonnet 4.6"
            ;;
        claude-sonnet-4-5-*|claude-sonnet-4-5)
            model="Sonnet 4.5"
            ;;
        claude-sonnet-4-*|claude-sonnet-4)
            model="Sonnet 4"
            ;;
        claude-haiku-4-5-*|claude-haiku-4-5)
            model="Haiku 4.5"
            ;;
        claude-haiku-*)
            model="Haiku"
            ;;
        "Claude Opus 4.6"*)
            model="${model/Claude /}"
            ;;
        "Claude Opus 4.5"*)
            model="${model/Claude /}"
            ;;
        "Claude Opus 4"*)
            model="${model/Claude /}"
            ;;
        "Claude Sonnet 4.6"*)
            model="${model/Claude /}"
            model="${model/ Thinking/}"
            ;;
        "Claude Sonnet 4.5"*)
            model="${model/Claude /}"
            model="${model/ Thinking/}"
            ;;
        "Claude Sonnet 4"*)
            model="${model/Claude /}"
            model="${model/ Thinking/}"
            ;;
        "Claude Haiku"*)
            model="${model/Claude /}"
            ;;
    esac

    model="${model//  / }"
    # Strip parenthetical suffixes like "(with 1M context)" before truncating
    model="${model%% (*}"
    if [ "${#model}" -gt 14 ]; then
        model="${model:0:14}"
    fi
    printf '%s' "$model"
}

abbreviate_reset_label() {
    local label="$1"

    case "$label" in
        prompt_input_exit)
            label="prompt"
            ;;
        bypass_permissions_disabled|"bypass mode disabled")
            label="bypass-off"
            ;;
        user_exit)
            label="user"
            ;;
    esac

    label="${label// /-}"
    label="${label//_/-}"
    if [ "${#label}" -gt 10 ]; then
        label="${label:0:10}"
    fi
    printf '%s' "$label"
}

statusline_bytes() {
    # Strip ANSI SGR escape sequences before counting so the byte budget
    # applies to visible characters, not invisible formatting codes.
    LC_ALL=C printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g' | wc -c | tr -d ' '
}

append_segment_if_fits() {
    local current="$1"
    local segment="$2"
    local max_bytes="$3"
    local candidate="$segment"
    local bytes

    if [ -z "$segment" ]; then
        printf '%s' "$current"
        return
    fi

    if [ -n "$current" ]; then
        candidate="${current} ${segment}"
    fi

    bytes=$(statusline_bytes "$candidate")
    if [ "$bytes" -le "$max_bytes" ]; then
        printf '%s' "$candidate"
    else
        printf '%s' "$current"
    fi
}

normalize_cost_usd() {
    # Claude Code has shipped at least two representations:
    # - dollars as a float (e.g. 0.127007)
    # - microdollars as an integer (e.g. 127007)
    # Single awk call handles all cases (avoids spawning up to 3 processes).
    local raw="${1:-0}"
    local total_tokens="${2:-0}"

    raw="${raw//[[:space:]]/}"
    if [[ ! "$raw" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        printf '0'
        return
    fi

    # Floats are already USD
    if [[ "$raw" == *.* ]]; then
        printf '%s' "$raw"
        return
    fi

    # Integer: decide dollars vs microdollars in one awk call
    total_tokens=$(num_or_zero "$total_tokens")
    LC_NUMERIC=C awk -v raw="$raw" -v tokens="$total_tokens" 'BEGIN {
        if (tokens > 0 && raw / tokens > 1) { printf "%.6f", raw / 1000000; exit }
        if (raw >= 1000) { printf "%.6f", raw / 1000000; exit }
        print raw
    }' 2>/dev/null
}

CONTEXT_SIZE=$(num_or_zero "$CONTEXT_SIZE")
TOTAL_INPUT=$(num_or_zero "$TOTAL_INPUT")
TOTAL_OUTPUT=$(num_or_zero "$TOTAL_OUTPUT")
CURR_IN=$(num_or_zero "$CURR_IN")
CURR_OUT=$(num_or_zero "$CURR_OUT")
CACHE_CREATE=$(num_or_zero "$CACHE_CREATE")
CACHE_READ=$(num_or_zero "$CACHE_READ")

TOTAL=$((TOTAL_INPUT + TOTAL_OUTPUT))
COST_USD="$(normalize_cost_usd "${COST_RAW:-0}" "$TOTAL")"

CTX_USED=0
PCT_TENTHS=0
USED_PCT_DISPLAY="0"

# Context % priority:
# 1. Collector (OTEL-sourced, tracks context growth between API calls)
# 2. Claude Code's used_percentage (stale between API calls)
COLLECTOR_SOCK="${WARDEN_COLLECTOR_SOCK:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-warden/collector.sock}"
COLLECTOR_JSON=""
COLLECTOR_PCT=""
COLLECTOR_MODEL=""
COLLECTOR_TOOL_COUNT=""
COLLECTOR_SUBAGENT_COUNT=""
COLLECTOR_LAST_TOOL=""
COLLECTOR_LAST_TOOL_MS=""
COLLECTOR_CACHE_HIT=""
if [ -n "$SESSION_ID" ] && [ -S "$COLLECTOR_SOCK" ]; then
    COLLECTOR_JSON="$(curl -sf --max-time 0.05 \
        --unix-socket "$COLLECTOR_SOCK" \
        "http://localhost/v1/sessions/${SESSION_ID}/context" 2>/dev/null)" || COLLECTOR_JSON=""
    if [ -n "$COLLECTOR_JSON" ]; then
        # Extract all useful fields in one jq call
        eval "$(printf '%s' "$COLLECTOR_JSON" | jq -r '
            "COLLECTOR_PCT=\(.used_pct // "" | @sh)",
            "COLLECTOR_INPUT_TOKENS=\((.input_tokens // 0) + (.cache_read_tokens // 0) + (.cache_creation_tokens // 0) | @sh)",
            "COLLECTOR_MODEL=\(.model // "" | @sh)",
            "COLLECTOR_TOOL_COUNT=\(.tool_count // 0 | @sh)",
            "COLLECTOR_SUBAGENT_COUNT=\(.subagent_count // 0 | @sh)",
            "COLLECTOR_LAST_TOOL=\(.last_tool // "" | @sh)",
            "COLLECTOR_LAST_TOOL_MS=\(.last_tool_duration_ms // "" | @sh)",
            "COLLECTOR_CACHE_HIT=\(.cache_hit_rate // "" | @sh)",
            "COLLECTOR_COMPACT_PCT=\(.compact_threshold_pct // 85 | @sh)"
        ' 2>/dev/null)" || true
    fi
fi

COLLECTOR_INPUT_TOKENS=$(num_or_zero "${COLLECTOR_INPUT_TOKENS:-0}")
if [ -n "$COLLECTOR_PCT" ] && [[ "$COLLECTOR_PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
    && [ "$COLLECTOR_INPUT_TOKENS" -gt 0 ]; then
    # Collector has OTEL data with actual token counts — most accurate
    PCT_TENTHS=$(printf '%s' "$COLLECTOR_PCT" | LC_NUMERIC=C awk '{printf "%d", $1 * 10}')
    USED_PCT_DISPLAY="$(format_percent_from_tenths "$PCT_TENTHS")"
elif [[ "$USED_PCT_RAW" =~ ^([0-9]+)(\.([0-9]+))?$ ]]; then
    whole="${BASH_REMATCH[1]}"
    dec="${BASH_REMATCH[3]}"
    dec="${dec:0:1}"
    if [ -z "$dec" ]; then
        dec=0
    fi
    PCT_TENTHS=$((whole * 10 + dec))
    USED_PCT_DISPLAY="$(format_percent_from_tenths "$PCT_TENTHS")"
elif [ "$HAS_CURR" = "1" ] && [ "$CONTEXT_SIZE" -gt 0 ]; then
    CTX_USED=$((CURR_IN + CACHE_CREATE + CACHE_READ))
    PCT_TENTHS=$((CTX_USED * 1000 / CONTEXT_SIZE))
    USED_PCT_DISPLAY="$(format_percent_from_tenths "$PCT_TENTHS")"
fi

# CTX_USED: compute from current_usage when available (for delta/clear detection),
# otherwise derive from percentage.
if [ "$HAS_CURR" = "1" ]; then
    CTX_USED=$((CURR_IN + CACHE_CREATE + CACHE_READ))
elif [ "$CONTEXT_SIZE" -gt 0 ] && [ "$PCT_TENTHS" -gt 0 ]; then
    CTX_USED=$((CONTEXT_SIZE * PCT_TENTHS / 1000))
fi

CTX_LEFT=0
if [ "$CONTEXT_SIZE" -gt 0 ]; then
    if [ "$CTX_USED" -le "$CONTEXT_SIZE" ]; then
        CTX_LEFT=$((CONTEXT_SIZE - CTX_USED))
    fi
fi

PERCENT_INT="${USED_PCT_DISPLAY%.*}"
if [ -z "$PERCENT_INT" ] || ! [[ "$PERCENT_INT" =~ ^[0-9]+$ ]]; then
    PERCENT_INT=0
fi

# Color thresholds derived from compact threshold (default 85%)
# Yellow at 75% of compact threshold, red at compact threshold
COMPACT_PCT="${COLLECTOR_COMPACT_PCT:-85}"
YELLOW_AT=$((COMPACT_PCT * 75 / 100))
if [ "$PERCENT_INT" -lt "$YELLOW_AT" ]; then
    COLOR=$'\033[32m'  # Green: well below compact
elif [ "$PERCENT_INT" -lt "$COMPACT_PCT" ]; then
    COLOR=$'\033[33m'  # Yellow: approaching compact
else
    COLOR=$'\033[31m'  # Red: at or past compact threshold
fi
RESET=$'\033[0m'
DIM=$'\033[2m'
RED=$'\033[31m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
CYAN=$'\033[36m'

STATE_DIR="${WARDEN_STATE_DIR:-$HOME/.claude/.statusline}"
STATE_FILE="$STATE_DIR/state${SESSION_ID:+-$SESSION_ID}"
STARTUP_MODEL_FILE="$STATE_DIR/startup-model${SESSION_ID:+-$SESSION_ID}"
REASON_FILE="$STATE_DIR/reset-reason${SESSION_ID:+-$SESSION_ID}"
mkdir -p "$STATE_DIR"

if [ "${WARDEN_DEBUG:-}" = "1" ]; then
    printf '%s sid=%s model="%s" pct_raw="%s" ctx=%s curr_in=%s curr_out=%s cc=%s cr=%s has_curr=%s\n' \
        "$(date +%H:%M:%S)" "$SESSION_ID" "$MODEL" "$USED_PCT_RAW" \
        "$CONTEXT_SIZE" "$CURR_IN" "$CURR_OUT" "$CACHE_CREATE" "$CACHE_READ" "$HAS_CURR" \
        >> "$STATE_DIR/statusline-debug.log" 2>/dev/null
fi

PREV_SESSION=""
PREV_TOTAL_IN=0
PREV_TOTAL_OUT=0
PREV_CTX=0
PREV_COST_USD="0"
PREV_MODEL=""
STARTUP_MODEL=""
RESET_TS=0
RESET_REASON=""

if [ -f "$STARTUP_MODEL_FILE" ]; then
    STARTUP_MODEL="$(cat "$STARTUP_MODEL_FILE" 2>/dev/null || true)"
fi

if [ -f "$STATE_FILE" ]; then
    PREV_F2="" PREV_F3="" PREV_F4="" PREV_F5=""
    _P6="" _P7="" _P8="" _P9="" _P10="" _P11="" _P12="" _P13=""
    PREV_F14="" PREV_F15=""
    IFS='|' read -r PREV_SESSION PREV_F2 PREV_F3 PREV_F4 PREV_F5 \
        _P6 _P7 _P8 _P9 _P10 _P11 _P12 _P13 PREV_F14 PREV_F15 < "$STATE_FILE" 2>/dev/null || true
    # Sanitize PREV_SESSION read from disk (may predate path-safe writes)
    PREV_SESSION="$(printf '%s' "${PREV_SESSION:-}" | tr -cd 'A-Za-z0-9._-')"
    if [ -n "$PREV_F14" ]; then
        # New 15-field format
        PREV_TOTAL_IN=$(num_or_zero "$PREV_F2")
        PREV_TOTAL_OUT=$(num_or_zero "$PREV_F3")
        PREV_CTX=$(num_or_zero "$PREV_F4")
        PREV_COST_USD="${_P6:-0}"
        PREV_MODEL="${_P13:-}"
        RESET_TS=$(num_or_zero "$PREV_F14")
        RESET_REASON="${PREV_F15:-}"
    else
        # Old 5-field format: SESSION|TOTAL|CTX_USED|RESET_TS|RESET_REASON
        PREV_TOTAL_IN=$(num_or_zero "$PREV_F2")
        PREV_TOTAL_OUT=0
        PREV_CTX=$(num_or_zero "$PREV_F3")
        RESET_TS=$(num_or_zero "$PREV_F4")
        RESET_REASON="${PREV_F5:-}"
    fi
fi

NOW_TS=$(date +%s)
RESET_NOW=0

if [ -n "$SESSION_ID" ] && [ -n "$PREV_SESSION" ] && [ "$SESSION_ID" != "$PREV_SESSION" ]; then
    RESET_NOW=1
    RESET_REASON="session"
fi

PREV_TOTAL=$((PREV_TOTAL_IN + PREV_TOTAL_OUT))
PREV_COST_USD="$(normalize_cost_usd "${PREV_COST_USD:-0}" "$PREV_TOTAL")"
SAME_SESSION=0
if [ -n "$SESSION_ID" ] && [ "$PREV_SESSION" = "$SESSION_ID" ]; then
    SAME_SESSION=1
fi

# Model source: Claude Code's statusline JSON is authoritative (refreshed every poll).
# Only fall back to collector/cache when the payload is empty (e.g. between API calls).
if [ -z "$MODEL" ] || [ "$MODEL" = "Unknown" ]; then
    if [ -n "$COLLECTOR_MODEL" ]; then
        MODEL="$COLLECTOR_MODEL"
    elif [ -n "$STARTUP_MODEL" ]; then
        MODEL="$STARTUP_MODEL"
    elif [ "$SAME_SESSION" -eq 1 ] && [ -n "$PREV_MODEL" ]; then
        MODEL="$PREV_MODEL"
    fi
fi

# Token reset and context clear only valid within the same session.
# The state file is shared across concurrent sessions — without this
# guard, a new session with lower tokens/context falsely triggers
# resets when it reads another session's higher values.
if [ "$SAME_SESSION" -eq 1 ] && [ "$PREV_TOTAL" -gt 0 ] && [ "$TOTAL" -lt "$PREV_TOTAL" ]; then
    RESET_NOW=1
    RESET_REASON="reset"
fi

CTX_CLEAR_NOW=0
if [ "$SAME_SESSION" -eq 1 ] && [ "$PREV_CTX" -gt 0 ] && [ "$CTX_USED" -lt "$PREV_CTX" ]; then
    DELTA=$((PREV_CTX - CTX_USED))
    if [ "$DELTA" -ge 2000 ]; then
        RESET_NOW=1
        RESET_REASON="context"
        CTX_CLEAR_NOW=1
    fi
fi

if [ "$RESET_NOW" -eq 1 ]; then
    RESET_TS="$NOW_TS"
fi

# Context clear tracking: count + cumulative tokens lost + cost at time of clear
CLR_COUNT=0
CLR_CTX_LOST=0
CLR_COST_AT_CLEAR="0"

# Session cleanup is handled by session-end hook, not here.
# Deleting another session's files from a statusline render races with
# concurrent terminals that may still be using those files.

if [ -n "$SESSION_ID" ]; then
    CLR_FILE="$STATE_DIR/clears-$SESSION_ID"
    if [ -f "$CLR_FILE" ]; then
        IFS='|' read -r CLR_COUNT CLR_CTX_LOST CLR_COST_AT_CLEAR < "$CLR_FILE" 2>/dev/null || true
        CLR_COUNT=$(num_or_zero "$CLR_COUNT")
        CLR_CTX_LOST=$(num_or_zero "$CLR_CTX_LOST")
        CLR_COST_AT_CLEAR="${CLR_COST_AT_CLEAR:-0}"
    fi

    if [ "$CTX_CLEAR_NOW" -eq 1 ]; then
        CLR_COUNT=$((CLR_COUNT + 1))
        CLR_CTX_LOST=$((CLR_CTX_LOST + DELTA))
        CLR_COST_AT_CLEAR="$COST_USD"
        printf '%s|%s|%s\n' "$CLR_COUNT" "$CLR_CTX_LOST" "$CLR_COST_AT_CLEAR" > "$CLR_FILE.tmp.$$" && mv "$CLR_FILE.tmp.$$" "$CLR_FILE"
    fi
fi

printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$SESSION_ID" "$TOTAL_INPUT" "$TOTAL_OUTPUT" "$CTX_USED" "$CONTEXT_SIZE" \
    "$COST_USD" "$DURATION_MS" "$API_DURATION_MS" "$LINES_ADDED" "$LINES_REMOVED" \
    "$CACHE_READ" "$CACHE_CREATE" "$MODEL" "$RESET_TS" "$RESET_REASON" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"

RESET_LABEL=""
RESET_WINDOW=45
SHOW_RESET=0

if [ "$RESET_TS" -gt 0 ] && [ $((NOW_TS - RESET_TS)) -le "$RESET_WINDOW" ]; then
    # Only show for genuine token anomalies ("reset"). Session changes
    # are normal (especially with concurrent sessions sharing state),
    # and context clears are already covered by Clr:N.
    if [ "$RESET_REASON" = "reset" ]; then
        SHOW_RESET=1
    fi
fi

if [ -f "$REASON_FILE" ]; then
    REASON_TS="" REASON_VALUE="" REASON_SESSION=""
    IFS='|' read -r REASON_TS REASON_VALUE REASON_SESSION < "$REASON_FILE" 2>/dev/null || true
    REASON_TS=$(num_or_zero "${REASON_TS:-0}")
    if [ "$REASON_TS" -gt 0 ] && [ $((NOW_TS - REASON_TS)) -le 120 ] && [ "${REASON_SESSION:-}" = "$SESSION_ID" ]; then
        RESET_LABEL="$REASON_VALUE"
        SHOW_RESET=1
    fi
fi
if [ -n "$RESET_LABEL" ]; then
    RESET_LABEL="$(abbreviate_reset_label "$RESET_LABEL")"
fi

# Tool count: prefer collector (OTEL-sourced), fallback to JSON
TOOL_COUNT=""
if [ "${COLLECTOR_TOOL_COUNT:-0}" -gt 0 ]; then
    TOOL_COUNT="$COLLECTOR_TOOL_COUNT"
elif [[ "$TOOL_COUNT_RAW" =~ ^[0-9]+$ ]] && [ "$TOOL_COUNT_RAW" -gt 0 ]; then
    TOOL_COUNT="$TOOL_COUNT_RAW"
fi

# Subagent count and last tool latency from collector (OTEL-sourced)
SUB_COUNT=$(num_or_zero "${COLLECTOR_SUBAGENT_COUNT:-0}")
LAST_LATENCY_MS="${COLLECTOR_LAST_TOOL_MS:-}"
LAST_LATENCY_TOOL="${COLLECTOR_LAST_TOOL:-}"
# Strip span name prefix if present (e.g., "claude_code.tool.Read" -> "Read")
LAST_LATENCY_TOOL="${LAST_LATENCY_TOOL##*.}"

CTX_TOTAL_FMT="$(format_tokens "$CONTEXT_SIZE")"
STATUSLINE_MAX_BYTES="${WARDEN_STATUSLINE_MAX_BYTES:-72}"
STATUSLINE_MAX_BYTES=$(num_or_zero "$STATUSLINE_MAX_BYTES")
[ "$STATUSLINE_MAX_BYTES" -gt 0 ] || STATUSLINE_MAX_BYTES=56

# --- Computed metrics ---

# Turn cost: delta from previous state file
# Only valid when previous session matches (not first observation or session switch)
TURN_COST="0"
TOTAL_COST_FMT=""
TURN_COST_FMT=""
HAS_VALID_DELTA=0
if [[ "$COST_USD" =~ ^[0-9]*\.?[0-9]+$ ]] && [ "$COST_USD" != "0" ]; then
    TOTAL_COST_FMT=$(LC_NUMERIC=C printf '%.2f' "$COST_USD")
    if [ "$PREV_SESSION" = "$SESSION_ID" ] && [[ "$PREV_COST_USD" =~ ^[0-9]*\.?[0-9]+$ ]] && [ "$PREV_COST_USD" != "0" ]; then
        TURN_COST=$(LC_NUMERIC=C awk -v cost="$COST_USD" -v prev="$PREV_COST_USD" 'BEGIN {v=cost-prev; printf "%.4f", (v<0?0:v)}' 2>/dev/null)
        HAS_VALID_DELTA=1
    fi
    TURN_COST_FMT=$(LC_NUMERIC=C printf '%.2f' "$TURN_COST")
fi

# Peak turn cost tracking (per session, only from real deltas)
PEAK_COST_FMT=""
if [ -n "$SESSION_ID" ] && [ "$HAS_VALID_DELTA" = "1" ]; then
    PEAK_FILE="$STATE_DIR/peak-$SESSION_ID"
    PEAK_COST="0"
    if [ -f "$PEAK_FILE" ]; then
        PEAK_COST="$(cat "$PEAK_FILE" 2>/dev/null || echo "0")"
        [[ "$PEAK_COST" =~ ^[0-9]*\.?[0-9]+$ ]] || PEAK_COST="0"
    fi
    IS_PEAK=$(LC_NUMERIC=C awk -v turn="$TURN_COST" -v peak="$PEAK_COST" 'BEGIN {print (turn > peak) ? 1 : 0}' 2>/dev/null)
    if [ "$IS_PEAK" = "1" ]; then
        PEAK_COST="$TURN_COST"
        LC_NUMERIC=C printf '%.4f' "$PEAK_COST" > "$PEAK_FILE.tmp.$$" && mv "$PEAK_FILE.tmp.$$" "$PEAK_FILE"
    fi
    PEAK_COST_FMT=$(LC_NUMERIC=C printf '%.2f' "$PEAK_COST")
elif [ -n "$SESSION_ID" ]; then
    # Read existing peak even if this turn has no valid delta
    PEAK_FILE="$STATE_DIR/peak-$SESSION_ID"
    if [ -f "$PEAK_FILE" ]; then
        PEAK_COST="$(cat "$PEAK_FILE" 2>/dev/null || echo "0")"
        [[ "$PEAK_COST" =~ ^[0-9]*\.?[0-9]+$ ]] || PEAK_COST="0"
        PEAK_COST_FMT=$(LC_NUMERIC=C printf '%.2f' "$PEAK_COST")
    fi
fi
# Sanity check: peak turn cost can never exceed total session cost
if [ -n "$PEAK_COST_FMT" ] && [ -n "$TOTAL_COST_FMT" ]; then
    PEAK_SANE=$(LC_NUMERIC=C awk -v peak="$PEAK_COST_FMT" -v total="$TOTAL_COST_FMT" 'BEGIN {print (peak <= total) ? 1 : 0}' 2>/dev/null)
    if [ "$PEAK_SANE" != "1" ]; then
        PEAK_COST_FMT=""
        [ -n "${PEAK_FILE:-}" ] && rm -f "$PEAK_FILE"
    fi
fi

# Cache hit rate
CACHE_HIT_PCT=""
if [ "$CACHE_CREATE" -gt 0 ] || [ "$CACHE_READ" -gt 0 ]; then
    CACHE_TOTAL=$((CACHE_CREATE + CACHE_READ))
    if [ "$CACHE_TOTAL" -gt 0 ]; then
        CACHE_HIT_PCT=$((CACHE_READ * 100 / CACHE_TOTAL))
    fi
fi

# LOC
LINES_ADDED=$(num_or_zero "$LINES_ADDED")
LINES_REMOVED=$(num_or_zero "$LINES_REMOVED")

DURATION_MS=$(num_or_zero "$DURATION_MS")
API_DURATION_MS=$(num_or_zero "$API_DURATION_MS")
write_session_metrics_prom "$SESSION_ID" "$MODEL" "$TOTAL_INPUT" "$TOTAL_OUTPUT" "$DURATION_MS" "$COST_USD"

# Reap tombstoned prom files (session-end delays deletion for one scrape interval)
_PROM_DIR="${HOME}/.claude/.monitoring/textfile"
if [ -d "$_PROM_DIR" ]; then
    for _ts_file in "$_PROM_DIR"/*.tombstone; do
        [ -f "$_ts_file" ] || continue
        _ts_val=""
        read -r _ts_val < "$_ts_file" 2>/dev/null || continue
        [[ "$_ts_val" =~ ^[0-9]+$ ]] || continue
        if [ $((NOW_TS - _ts_val)) -ge 60 ]; then
            rm -f "${_ts_file%.tombstone}" "$_ts_file" 2>/dev/null
        fi
    done
fi

# Budget (parse known-format JSON without jq to avoid process spawn)
BUDGET_PCT=""
BUDGET_CACHE="$STATE_DIR/budget-export"
if [ -f "$BUDGET_CACHE" ]; then
    CACHE_MTIME=$(stat -c %Y "$BUDGET_CACHE" 2>/dev/null || stat -f %m "$BUDGET_CACHE" 2>/dev/null || echo 0)
    if [ $((NOW_TS - CACHE_MTIME)) -le 5 ]; then
        _budget_raw=$(<"$BUDGET_CACHE" 2>/dev/null) || _budget_raw=""
        if [[ "$_budget_raw" =~ \"utilization\":([0-9]+) ]]; then
            BUDGET_PCT="${BASH_REMATCH[1]}"
            [ "$BUDGET_PCT" = "0" ] && BUDGET_PCT=""
        fi
    fi
fi

# --- Build single-line statusline ---
# Starship-inspired format: compact, cyan-themed, left-aligned segments
# Claude Code only gives us one printed field; keep the left side short so
# its native RHS token counter still has room to render.
MODEL="$(abbreviate_model "$MODEL")"
# CTX_USED_FMT="$(format_tokens "$CTX_USED")"
PRIMARY_SEGMENT="${COLOR}${USED_PCT_DISPLAY}%${RESET}"
if [ "$CONTEXT_SIZE" -gt 0 ]; then
    PRIMARY_SEGMENT="${PRIMARY_SEGMENT}${DIM}/${CTX_TOTAL_FMT}${RESET}"
fi
if [ -n "$TOTAL_COST_FMT" ]; then
    PRIMARY_SEGMENT="${PRIMARY_SEGMENT} \$${TOTAL_COST_FMT}"
fi

out="${MODEL} ${PRIMARY_SEGMENT}"
if [ "$(statusline_bytes "$out")" -gt "$STATUSLINE_MAX_BYTES" ]; then
    out="$PRIMARY_SEGMENT"
fi
if [ "$(statusline_bytes "$out")" -gt "$STATUSLINE_MAX_BYTES" ]; then
    out="${COLOR}${USED_PCT_DISPLAY}%${RESET}"
fi

SEGMENT=""
if [ -n "$LAST_LATENCY_TOOL" ]; then
    SEGMENT="${DIM}${LAST_LATENCY_TOOL}${RESET}"
fi
out="$(append_segment_if_fits "$out" "$SEGMENT" "$STATUSLINE_MAX_BYTES")"

SEGMENT=""
if [ -n "$CACHE_HIT_PCT" ]; then
    if [ "$CACHE_HIT_PCT" -ge 60 ]; then
        SEGMENT="C:${GREEN}${CACHE_HIT_PCT}%${RESET}"
    elif [ "$CACHE_HIT_PCT" -le 30 ]; then
        SEGMENT="C:${YELLOW}${CACHE_HIT_PCT}%${RESET}"
    else
        SEGMENT="C:${CACHE_HIT_PCT}%"
    fi
fi
out="$(append_segment_if_fits "$out" "$SEGMENT" "$STATUSLINE_MAX_BYTES")"

SEGMENT=""
if [ -n "$TOOL_COUNT" ] && [ "$TOOL_COUNT" != "0" ]; then
    SEGMENT="${DIM}T:${RESET}${TOOL_COUNT}"
fi
out="$(append_segment_if_fits "$out" "$SEGMENT" "$STATUSLINE_MAX_BYTES")"

SEGMENT=""
if [ "$LINES_ADDED" -gt 0 ] || [ "$LINES_REMOVED" -gt 0 ]; then
    SEGMENT="+${LINES_ADDED}/-${LINES_REMOVED}"
fi
out="$(append_segment_if_fits "$out" "$SEGMENT" "$STATUSLINE_MAX_BYTES")"

SEGMENT=""
if [ -n "$LAST_LATENCY_MS" ]; then
    if [ "$LAST_LATENCY_MS" -ge 5000 ]; then
        SEGMENT="${RED}${LAST_LATENCY_MS}ms${RESET}"
    elif [ "$LAST_LATENCY_MS" -ge 2000 ]; then
        SEGMENT="${YELLOW}${LAST_LATENCY_MS}ms${RESET}"
    elif [ "$LAST_LATENCY_MS" -ge 500 ]; then
        SEGMENT="${GREEN}${LAST_LATENCY_MS}ms${RESET}"
    else
        SEGMENT="${DIM}${LAST_LATENCY_MS}ms${RESET}"
    fi
fi
out="$(append_segment_if_fits "$out" "$SEGMENT" "$STATUSLINE_MAX_BYTES")"

SEGMENT=""
if [ "$SUB_COUNT" -gt 0 ] || [ "$CLR_COUNT" -gt 0 ]; then
    if [ "$SUB_COUNT" -gt 0 ] && [ "$CLR_COUNT" -gt 0 ]; then
        SEGMENT="${DIM}Sub:${SUB_COUNT}${RESET} ${DIM}Clr:${CLR_COUNT}${RESET}"
    elif [ "$SUB_COUNT" -gt 0 ]; then
        SEGMENT="${DIM}Sub:${SUB_COUNT}${RESET}"
    else
        SEGMENT="${DIM}Clr:${CLR_COUNT}${RESET}"
    fi
fi
out="$(append_segment_if_fits "$out" "$SEGMENT" "$STATUSLINE_MAX_BYTES")"

SEGMENT=""
if [ -n "$BUDGET_PCT" ]; then
    if [ "$BUDGET_PCT" -ge 90 ]; then
        SEGMENT="${RED}B:${BUDGET_PCT}%${RESET}"
    elif [ "$BUDGET_PCT" -ge 75 ]; then
        SEGMENT="${YELLOW}B:${BUDGET_PCT}%${RESET}"
    else
        SEGMENT="B:${BUDGET_PCT}%"
    fi
fi
out="$(append_segment_if_fits "$out" "$SEGMENT" "$STATUSLINE_MAX_BYTES")"

SEGMENT=""
if [ "$SHOW_RESET" -eq 1 ]; then
    if [ -n "$RESET_LABEL" ]; then
        SEGMENT="${DIM}Rst:${RESET_LABEL}${RESET}"
    else
        SEGMENT="${DIM}Rst${RESET}"
    fi
fi
out="$(append_segment_if_fits "$out" "$SEGMENT" "$STATUSLINE_MAX_BYTES")"

_warden_sl_printed=1
printf '%s\n' "$out"
