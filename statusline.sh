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

# Percentage: prefer used_percentage from Claude Code (includes system prompt,
# tool defs, CLAUDE.md — everything in the context window). current_usage only
# counts API-reported tokens and consistently under-reports by ~10%.
# Fall back to computing from current_usage when used_percentage is absent.
if [[ "$USED_PCT_RAW" =~ ^([0-9]+)(\.([0-9]+))?$ ]]; then
    whole="${BASH_REMATCH[1]}"
    dec="${BASH_REMATCH[3]}"
    dec="${dec:0:1}"
    if [ -z "$dec" ]; then
        dec=0
    fi
    PCT_TENTHS=$((whole * 10 + dec))
    USED_PCT_DISPLAY="$(format_percent_from_tenths "$PCT_TENTHS")"
elif [ "$HAS_CURR" = "1" ] && [ "$CONTEXT_SIZE" -gt 0 ]; then
    CTX_USED=$((CURR_IN + CURR_OUT + CACHE_CREATE + CACHE_READ))
    PCT_TENTHS=$((CTX_USED * 1000 / CONTEXT_SIZE))
    USED_PCT_DISPLAY="$(format_percent_from_tenths "$PCT_TENTHS")"
fi

# CTX_USED: compute from current_usage when available (for delta/clear detection),
# otherwise derive from percentage.
if [ "$HAS_CURR" = "1" ]; then
    CTX_USED=$((CURR_IN + CURR_OUT + CACHE_CREATE + CACHE_READ))
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

if [ "$PERCENT_INT" -lt 50 ]; then
    COLOR=$'\033[32m'  # Green
elif [ "$PERCENT_INT" -lt 80 ]; then
    COLOR=$'\033[33m'  # Yellow
else
    COLOR=$'\033[31m'  # Red
fi
RESET=$'\033[0m'
DIM=$'\033[2m'
RED=$'\033[31m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
CYAN=$'\033[36m'

STATE_DIR="${WARDEN_STATE_DIR:-$HOME/.claude/.statusline}"
STATE_FILE="$STATE_DIR/state${SESSION_ID:+-$SESSION_ID}"
REASON_FILE="$STATE_DIR/reset-reason"
mkdir -p "$STATE_DIR"

PREV_SESSION=""
PREV_TOTAL_IN=0
PREV_TOTAL_OUT=0
PREV_CTX=0
PREV_COST_USD="0"
RESET_TS=0
RESET_REASON=""

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

TOOL_COUNT=""
# Prefer hook-tracked count (session state file) over JSON's tool_count,
# which Claude Code often sends as 0 or omits entirely.
if [ -n "$SESSION_ID" ]; then
    SESSION_STATE_FILE="$STATE_DIR/session-$SESSION_ID"
    if [ -f "$SESSION_STATE_FILE" ]; then
        SS_COUNT="" _SS_TS=""
        IFS='|' read -r SS_COUNT _ _ _SS_TS < "$SESSION_STATE_FILE" 2>/dev/null || true
        if [[ "${SS_COUNT:-}" =~ ^[0-9]+$ ]] && [ "$SS_COUNT" -gt 0 ]; then
            TOOL_COUNT="$SS_COUNT"
        fi
    fi
fi
# Fallback to JSON tool_count if hooks haven't tracked anything yet
if [ -z "$TOOL_COUNT" ] && [[ "$TOOL_COUNT_RAW" =~ ^[0-9]+$ ]] && [ "$TOOL_COUNT_RAW" -gt 0 ]; then
    TOOL_COUNT="$TOOL_COUNT_RAW"
fi

SUB_COUNT=0
SUB_COUNT_FILE="$STATE_DIR/subagent-count"
if [ -f "$SUB_COUNT_FILE" ]; then
    SUB_SESSION="" SUB_VALUE="" _SUB_TS=""
    IFS='|' read -r SUB_SESSION SUB_VALUE _SUB_TS < "$SUB_COUNT_FILE" 2>/dev/null || true
    if [ "${SUB_SESSION:-}" = "$SESSION_ID" ]; then
        SUB_COUNT=$(num_or_zero "${SUB_VALUE:-0}")
    fi
fi

# Tokens saved (cumulative, written by hooks)
TOKENS_SAVED=0
if [ -n "$SESSION_ID" ]; then
    SAVED_FILE="$STATE_DIR/saved-$SESSION_ID"
    if [ -f "$SAVED_FILE" ]; then
        read -r TOKENS_SAVED < "$SAVED_FILE" 2>/dev/null || true
        [[ "${TOKENS_SAVED:-}" =~ ^[0-9]+$ ]] || TOKENS_SAVED=0
    fi
fi

# Last tool latency (written by post-tool-use)
LAST_LATENCY_MS=""
LAST_LATENCY_TOOL=""
if [ -n "$SESSION_ID" ]; then
    LATENCY_FILE="$STATE_DIR/latency-$SESSION_ID"
    if [ -f "$LATENCY_FILE" ]; then
        IFS='|' read -r LAST_LATENCY_MS LAST_LATENCY_TOOL < "$LATENCY_FILE" 2>/dev/null || true
        [[ "${LAST_LATENCY_MS:-}" =~ ^[0-9]+$ ]] || LAST_LATENCY_MS=""
    fi
fi

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
        PEAK_COST=$(<"$PEAK_FILE" 2>/dev/null || echo "0")
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
        PEAK_COST=$(<"$PEAK_FILE" 2>/dev/null || echo "0")
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
        SEGMENT="${DIM}Sub:${RESET}${SUB_COUNT} ${DIM}Clr:${RESET}${CLR_COUNT}"
    elif [ "$SUB_COUNT" -gt 0 ]; then
        SEGMENT="${DIM}Sub:${RESET}${SUB_COUNT}"
    else
        SEGMENT="${DIM}Clr:${RESET}${CLR_COUNT}"
    fi
else
    _vibes=(
        "good luck:)"
        "well done!"
        "you got this!"
        "way to go ^_^"
        "hello hi you"
        "good tidings"
        "good prompt"
        "nice prompt"
        "well said"
        "I agree"
        "u go glencoco"
        "tbd"
        "i ate a bug"
        "who done it?"
        "no way jose!"
        "no u"
        "got mail!"
        "ytmnd"
        "lawl"
        "stp tr0ll1n"
        "who hurt u?"
        "Much success"
        "Another one!"
        "Much wow"
        "nice"
        "neat"
        "cool cool"
        "coolio"
        "rad"
        "tubular"
        "gnarly"
        "bodacious"
        "righteous"
        "excellent"
        "stellar"
        "superb"
        "splendid"
        "brilliant"
        "lovely"
        "delightful"
        "charming"
        "swell"
        "groovy"
        "far out"
        "outta sight"
        "peachy keen"
        "hunky dory"
        "ship shape"
        "tip top"
        "A-OK"
        "all good"
        "we vibin"
        "vibes: good"
        "status: chill"
        "mood: coding"
        "vibe check: ok"
        "based"
        "valid"
        "big if true"
        "this is fine"
        "everything ok"
        "all systems go"
        "nominal"
        "five by five"
        "loud and clear"
        "roger that"
        "copy that"
        "10-4"
        "affirmative"
        "aye aye"
        "understood"
        "on it"
        "say less"
        "bet"
        "no cap"
        "fr fr"
        "ong"
        "slay"
        "period"
        "iconic"
        "legendary"
        "elite"
        "goated"
        "built diff"
        "hits diff"
        "bussin"
        "fire"
        "lit"
        "dope"
        "sick"
        "tight"
        "mint"
        "chef's kiss"
        "no notes"
        "immaculate"
        "pristine"
        "flawless"
        "perfect 5/7"
        "solid 10"
        "A+"
        "gold star"
        "two thumbs up"
        ":)"
        ":D"
        "^_^"
        "uwu"
        "owo"
        "<3"
        "xoxo"
        ":3"
        "c:"
        "n_n"
        "o7"
        "\\o/"
        "(づ￣ ³￣)づ"
        "ᕙ(⇀‸↼‶)ᕗ"
        "( ͡° ͜ʖ ͡°)"
        "¯\\_(ツ)_/¯"
        "hehe"
        "heh"
        "hah"
        "lol"
        "lmao"
        "rofl"
        "kek"
        "teehee"
        "huzzah"
        "woot"
        "yay"
        "woohoo"
        "yahoo"
        "wahoo"
        "yeehaw"
        "yippee"
        "hooray"
        "hurrah"
        "cheers"
        "salud"
        "prost"
        "skol"
        "kanpai"
        "l'chaim"
        "onwards"
        "excelsior"
        "ad astra"
        "per aspera"
        "semper fi"
        "carpe diem"
        "c'est la vie"
        "que sera sera"
        "hakuna matata"
        "no worries"
        "easy peasy"
        "piece of cake"
        "walk in park"
        "smooth sailing"
        "clear skies"
        "green lights"
        "full steam"
        "pedal down"
        "let's gooo"
        "here we go"
        "off we go"
        "away we go"
        "onward!"
        "tally ho"
        "allons-y"
        "geronimo"
        "vamanos"
        "andale"
        "leggo"
        "ship it"
        "send it"
        "full send"
        "yolo"
        "leeroy"
        "witness me"
        "hold my beer"
        "watch this"
        "trust me"
        "i got u"
        "gotchu fam"
        "say no more"
        "i see u"
        "respect"
        "props"
        "kudos"
        "big ups"
        "shoutout"
        "salute"
        "hats off"
        "nice work"
        "good job"
        "keep it up"
        "keep going"
        "stay gold"
        "stay frosty"
        "stay cool"
        "stay classy"
        "be excellent"
        "be kind"
        "be brave"
        "be curious"
        "dream big"
        "think big"
        "aim high"
        "reach far"
        "make waves"
        "break molds"
        "push limits"
        "level up"
        "power up"
        "glow up"
        "git gud"
        "gg"
        "gg ez"
        "ez pz"
        "gg wp"
        "glhf"
        "glgl"
        "wp"
        "ns"
        "gj"
        "ty"
        "np"
        "nw"
        "yw"
        "ily"
        "brb"
        "ttyl"
        "l8r"
        "cya"
        "peace"
        "deuces"
        "later sk8r"
        "catch ya"
        "godspeed"
        "bon voyage"
        "safe travels"
        "happy trails"
        "fare thee well"
        "solid"
        "right on"
        "boss"
        "primo"
        "choice"
        "crucial"
        "key"
        "mint condition"
        "prime"
        "righteous"
        "mean"
        "tough"
        "bad"
        "cold"
        "vicious"
        "heavy"
        "cosmic"
        "what a trip"
        "trippy"
        "outta sight"
        "way out"
        "out there"
        "dig?"
        "dig it"
        "can you dig?"
        "catch my drift"
        "on the level"
        "no jive"
        "straight up"
        "word is bond"
        "book it"
        "let's book"
        "let's motor"
        "let's bounce"
        "let's jet"
        "let's split"
        "let's vamoose"
        "gotta split"
        "gotta jet"
        "gotta motor"
        "catch you later"
        "catch the wave"
        "hang loose"
        "stay loose"
        "keep it movin"
        "keep on truckin"
        "that's the ticket"
        "you're money"
        "money"
        "bread"
        "scratch"
        "gravy"
        "smooth"
        "smooth move"
        "slick"
        "slick move"
        "sharp"
        "looking sharp"
        "clean"
        "fresh"
        "fly"
        "def"
        "funky fresh"
        "cold chillin"
        "coolin"
        "just coolin"
        "kickin it"
        "doing the do"
        "doing my thing"
        "do your thing"
        "do you"
        "be easy"
        "stay up"
        "one love"
        "one"
        "peace out"
        "peace"
        "later days"
        "take it light"
        "keep it light"
        "keep it tight"
        "tight"
        "airtight"
        "locked in"
        "dialed in"
        "on point"
        "on the money"
        "on the nose"
        "on the button"
        "right there"
        "that's it"
        "that's the one"
        "there it is"
        "now we cookin"
        "now you talkin"
        "talk to me"
        "lay it on me"
        "hit me"
        "run it"
        "say word"
        "you said it"
        "you know it"
        "you got it"
        "bet that"
        "bet"
        "you better know"
        "know what I mean"
        "feel me?"
        "heard"
        "I hear you"
        "loud and clear"
        "crystal"
        "clear as day"
        "plain as day"
        "no doubt"
        "no question"
        "for real"
        "for true"
        "real talk"
        "true story"
        "true that"
        "facts"
        "straight facts"
        "nothing but"
        "all day"
        "all the way"
        "to the max"
        "maxed out"
        "full tilt"
        "full bore"
        "balls out"
        "flat out"
        "straight ahead"
        "dead ahead"
        "onward"
        "onwards"
        "press on"
        "push on"
        "roll on"
        "rock on"
        "rock steady"
        "steady on"
        "steady as she goes"
        "easy does it"
        "nice and easy"
        "slow your roll"
        "pump the brakes"
        "cool your jets"
        "chill out"
        "mellow out"
        "settle down"
        "simmer down"
        "take five"
        "take a breather"
        "take a load off"
        "sit tight"
        "hang tight"
        "hold tight"
        "hold it down"
        "hold the fort"
        "got your back"
        "I got you"
        "covered"
        "you're covered"
        "handled"
        "sorted"
        "squared away"
        "taken care of"
        "in the bag"
        "money in bank"
        "done deal"
        "locked"
        "wrapped up"
        "buttoned up"
        "good to go"
        "ready to roll"
        "let's roll"
        "let's ride"
        "let's do this"
        "let's get it"
        "let's go then"
        "say when"
        "whenever"
        "your move"
        "your call"
        "ball's in play"
        "game on"
        "it's on"
        "we're on"
        "we're live"
        "we're cooking"
        "in the groove"
        "in the zone"
        "in the pocket"
        "locked in"
        "tuned in"
        "tapped in"
        "plugged in"
        "wired in"
        "dialed"
        "zeroed in"
        "honed in"
        "on target"
        "bullseye"
        "nailed it"
        "crushed it"
        "killed it"
        "smashed it"
        "knocked it out"
        "home run"
        "touchdown"
        "score"
        "winner"
        "winning"
        "champion"
        "the champ"
        "heavyweight"
        "big league"
        "major league"
        "pro level"
        "next level"
        "leveled up"
        "upgraded"
        "evolved"
        "ascended"
        "transcended"
        "peaked"
        "at the top"
        "on top"
        "king of hill"
        "top dog"
        "head honcho"
        "big cheese"
        "big kahuna"
        "main event"
        "headliner"
        "prime time"
        "showtime"
        "curtain up"
        "lights camera"
        "action"
        "rolling"
        "we're rolling"
        "cameras hot"
        "hot mic"
        "go time"
        "crunch time"
        "clutch time"
        "money time"
        "fourth quarter"
        "bottom of 9th"
        "sudden death"
        "do or die"
        "now or never"
        "moment of truth"
        "here goes"
        "here we go"
        "and away we go"
        "off to races"
        "out the gate"
        "from the jump"
        "from the get"
        "from the rip"
        "since day one"
        "day one stuff"
        "OG"
        "original"
        "the original"
        "classic"
        "old school"
        "throwback"
        "vintage"
        "retro"
        "timeless"
        "eternal"
        "forever"
        "always"
        "consistent"
        "steady"
        "reliable"
        "dependable"
        "trustworthy"
        "solid gold"
        "pure gold"
        "gold"
        "golden"
        "platinum"
        "diamond"
        "gem"
        "jewel"
        "treasure"
        "precious"
        "priceless"
        "invaluable"
        "essential"
        "vital"
        "critical"
        "clutch"
        "all that"
        "da bomb"
        "phat"
        "off the hook"
        "off the chain"
        "off the heezy"
        "fo sheezy"
        "fo sho"
        "true dat"
        "aight"
        "my bad"
        "don't go there"
        "talk to hand"
        "whateva"
        "as if!"
        "NOT!"
        "psych!"
        "booyah"
        "raise the roof"
        "gettin jiggy"
        "I'm ghost"
        "I'm Audi"
        "outtie 5000"
        "holla"
        "holla back"
        "holla at me"
        "hit me up"
        "page me"
        "beep me"
        "two-way me"
        "what's the 411"
        "on the DL"
        "keep it DL"
        "low key"
        "dead ass"
        "you know how we do"
        "that's how we do"
        "represent"
        "reppin"
        "hold it down"
        "keep it real"
        "keep it 100"
        "player"
        "playa"
        "baller"
        "shot caller"
        "big baller"
        "big willie"
        "don't hate"
        "game recognize"
        "game tight"
        "got game"
        "come correct"
        "come proper"
        "official"
        "certified"
        "bona fide"
        "real deal"
        "cheddar"
        "cheese"
        "paper"
        "stacks"
        "cream"
        "benjamins"
        "dead presidents"
        "whip"
        "whippin"
        "stuntin"
        "flossin"
        "shinin"
        "blingin"
        "iced out"
        "fresh to death"
        "crispy"
        "butter"
        "chillin villain"
        "lampin"
        "loungin"
        "maxin relaxin"
        "posted up"
        "bling bling"
        "ice"
        "wrist game"
        "stay fly"
        "stay fresh"
        "stay blessed"
        "be easy"
        "crunk"
        "turnt up"
        "turn up"
        "get crunk"
        "get hyphy"
        "go dumb"
        "get stupid"
        "act a fool"
        "wildin"
        "buggin"
        "trippin"
        "frontin"
        "faking funk"
        "wack"
        "weak"
        "corny"
        "played out"
        "so yesterday"
        "that's hot"
        "fierce"
        "perf"
        "totes"
        "whatevs"
        "obvi"
        "nm u"
        "nm hbu"
        "asl"
        "sup"
        "was good"
        "wyd"
        "ight"
        "kk"
        "kthxbai"
        "pwned"
        "owned"
        "noob"
        "n00b"
        "1337"
        "w00t"
        "ftw"
        "srsly"
        "4 realz"
        "jk jk"
        "mad props"
        "props yo"
        "givin props"
        "where u at"
        "where you be"
        "what it do"
        "what it is"
        "what the deal"
        "what the dilly"
        "what the dilio"
        "you feel me"
        "na mean"
        "kna mean"
        "know what I'm sayin"
        "heard dat"
        "feel dat"
        "respect"
        "much respect"
        "big respect"
        "big ups"
        "one love"
        "one time"
        "deuces"
        "threes"
        "a hundo"
        "a bean"
        "a stack"
        "cheese"
        "scrilla"
        "grip"
        "ends"
        "loot"
        "guap"
        "cake"
        "bread up"
        "caked up"
        "paid"
        "gettin paid"
        "get money"
        "money over"
        "paper chasin"
        "chasin paper"
        "about that life"
        "bout it bout it"
        "real recognize"
        "trill"
        "true to game"
        "down for mine"
        "down for whatever"
        "ride or die"
        "day one"
        "from day one"
        "since day one"
        "OG status"
        "vet status"
        "been doing this"
        "been on this"
        "stay on grind"
        "on the grind"
        "grindin"
        "hustlin"
        "makin moves"
        "movin weight"
        "heavy hitter"
        "major player"
        "key player"
        "MVP"
        "franchise"
        "the man"
        "that dude"
        "that guy"
        "him"
        "its him"
        "he's him"
        "she's her"
        "that one"
        "the one"
        "only one"
        "numero uno"
        "top dog"
        "head honcho"
        "HNIC"
        "runnin this"
        "runnin things"
        "callin shots"
        "shot caller"
        "decision maker"
        "go-to"
        "the go-to"
        "my guy"
        "my dude"
        "my mans"
        "my dog"
        "my dawg"
        "homie"
        "homeboy"
        "home slice"
        "home skillet"
        "ace"
        "ace boon"
        "partner"
        "patna"
        "road dog"
        "day one homie"
        "real one"
        "solid dude"
        "good peoples"
        "good people"
        "fam"
        "family"
        "blood"
        "cuz"
        "cuzzo"
        "kinfolk"
        "folk"
        "gang"
        "squad"
        "crew"
        "clique"
        "set"
        "team"
        "my team"
        "team deep"
        "deep"
        "we deep"
        "mob deep"
        "mobbin"
        "rollin deep"
        "rollin thick"
        "thick in game"
        "in the mix"
        "in the cut"
        "in the lab"
        "in the stu"
        "in the zone"
        "zone"
        "zoned"
        "zoned out"
        "focused"
        "locked"
        "locked in"
        "dialed"
        "tuned"
        "in tune"
        "in pocket"
        "in groove"
        "flowin"
        "in the flow"
        "zone"
        "feeling it"
        "vibin"
        "vibes"
        "good vibes"
        "good energy"
        "energy right"
        "aura"
        "aura crazy"
        "presence"
        "that presence"
        "gravitas"
        "weight"
        "that weight"
        "heavy"
        "that heavy"
        "serious"
        "dead serious"
        "no games"
        "no cap"
        "straight"
        "straight talk"
        "real rap"
        "real spit"
        "on the real"
        "on everything"
        "on my mama"
        "on my life"
        "swear to god"
        "swear down"
        "word to"
        "word is bond"
        "bond"
        "facts only"
        "nothing but"
        "nuthin but"
        "all facts"
        "all truth"
        "no lies"
        "lie detector"
        "gospel"
        "scripture"
        "written"
        "it's written"
        "destined"
        "fated"
        "meant to be"
        "in the stars"
        "aligned"
        "stars aligned"
        "everything lined"
        "all lined up"
        "set up nice"
        "looking good"
        "looking right"
        "sitting pretty"
        "sitting nice"
        "in position"
        "positioned"
        "ready"
        "stay ready"
        "been ready"
        "born ready"
        "built for this"
        "made for this"
        "built different"
        "cut different"
        "wired different"
        "another breed"
        "different breed"
        "rare breed"
        "thoroughbred"
        "purebred"
        "blue chip"
        "top shelf"
        "top tier"
        "first class"
        "A1"
        "grade A"
        "top notch"
        "cream of crop"
        "best of best"
        "elite"
        "upper echelon"
        "top percentile"
        "one percent"
        "rare air"
        "stratosphere"
        "ionosphere"
        "out of orbit"
        "outta here"
        "gone"
        "see ya"
        "wouldn't wanna"
        "dueces"
        "im out"
        "ghost mode"
        "ghost"
        "casper"
        "disappeared"
        "vanished"
        "poof"
        "magic"
        "Houdini"
        "dipped"
        "slid"
        "slid out"
        "crept"
        "crept out"
        "bounced"
        "jetted"
        "booked"
        "split"
        "broke out"
        "made moves"
        "had to slide"
        "gotta dip"
        "gotta run"
        "gotta bounce"
        "catch you"
        "catch ya"
        "see you when"
        "until then"
        "til next time"
        "next time"
        "same time"
        "same place"
        "you know where"
        "usual spot"
        "the spot"
        "pull up"
        "slide thru"
        "come thru"
        "tap in"
        "link up"
        "link"
        "connect"
        "reconnect"
        "get up"
        "chop it up"
        "kick it"
        "hang"
        "chill"
        "vibe"
        "build"
        "politic"
        "conversate"
        "rap"
        "talk"
        "talk that talk"
        "speak on it"
        "put me on"
        "hip me"
        "school me"
        "teach"
        "learn me"
        "drop knowledge"
        "drop gems"
        "gems"
        "jewels"
        "game"
        "free game"
        "that's game"
        "duly noted"
        "noted"
        "copy"
        "copied"
        "filed away"
        "mentally noted"
        "understood"
        "comprehended"
        "received"
        "message received"
        "loud clear"
        "5 by 5"
        "crystal"
        "crystal clear"
        "clear as mud"
        "no confusion"
        "we clear"
        "all clear"
        "clear"
        "cleared"
        "green light"
        "go ahead"
        "proceed"
        "carry on"
        "continue"
        "as you were"
        "dismissed"
        "at ease"
        "rest"
        "relax"
        "breathe"
        "exhale"
        "release"
        "let go"
        "let it go"
        "shake it off"
        "brush it off"
        "dust off"
        "dust yourself"
        "get back up"
        "get up"
        "rise"
        "rise up"
        "stand tall"
        "chin up"
        "head high"
        "chest out"
        "back straight"
        "shoulders back"
        "posture"
        "presence"
        "command"
        "command room"
        "own it"
        "own that"
        "yours"
        "it's yours"
        "take it"
        "claim it"
        "manifest"
        "speak it"
        "believe it"
        "achieve it"
        "receive it"
        "conceive it"
        "envision"
        "visualize"
        "see it"
        "seen"
        "already seen"
        "been seen"
        "foreseen"
        "predicted"
        "called it"
        "knew it"
        "told you"
        "said so"
        "what I said"
        "like I said"
        "as I said"
        "per usual"
        "as usual"
        "same old"
        "business usual"
        "another day"
        "just another"
        "routine"
        "on schedule"
        "on track"
        "right track"
        "correct path"
        "true north"
        "guided"
        "directed"
        "led"
        "pointed right"
        "aimed true"
        "calibrated"
        "adjusted"
        "fine tuned"
        "optimized"
        "maximized"
        "peaked"
        "pinnacle"
        "summit"
        "apex"
        "zenith"
        "peak form"
        "final form"
        "ultimate"
        "the ultimate"
        "the pinnacle"
        "the peak"
        "the top"
        "the tip"
        "tippy top"
        "very top"
        "highest"
        "supreme"
        "paramount"
        "unmatched"
        "unrivaled"
        "undefeated"
        "untouched"
        "unbothered"
        "unfazed"
        "unmoved"
        "unshaken"
        "steady"
        "stable"
        "grounded"
        "rooted"
        "planted"
        "firm"
        "solid ground"
        "foundation"
        "bedrock"
        "cornerstone"
        "pillar"
        "rock"
        "the rock"
        "anchor"
        "anchored"
        "secured"
        "fastened"
        "locked down"
        "battened"
        "fortified"
        "reinforced"
        "strengthened"
        "bolstered"
        "supported"
        "backed"
        "backed up"
        "got backup"
        "reinforcements"
        "cavalry"
        "the cavalry"
        "backup arrived"
        "help here"
        "support here"
        "we here"
        "arrived"
        "touchdown"
        "landed"
        "boots down"
        "wheels down"
        "on ground"
        "on site"
        "in building"
        "in house"
        "present"
        "accounted for"
        "roll call"
        "here"
        "present"
        "yo"
        "right here"
        "over here"
        "this way"
        "come thru"
    )
    SEGMENT="${DIM}${_vibes[$((RANDOM % ${#_vibes[@]}))]}"
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
        SEGMENT="${DIM}Rst:${RESET}${RESET_LABEL}"
    else
        SEGMENT="${DIM}Rst${RESET}"
    fi
fi
out="$(append_segment_if_fits "$out" "$SEGMENT" "$STATUSLINE_MAX_BYTES")"

_warden_sl_printed=1
printf '%s\n' "$out"
