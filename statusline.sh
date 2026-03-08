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
    COLOR="\033[32m"  # Green
elif [ "$PERCENT_INT" -lt 80 ]; then
    COLOR="\033[33m"  # Yellow
else
    COLOR="\033[31m"  # Red
fi
RESET="\033[0m"
DIM="\033[2m"
RED="\033[31m"
YELLOW="\033[33m"

STATE_DIR="$HOME/.claude/.statusline"
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
# ~50 usable chars before Claude Code's RHS token count clips us.
# Every char counts: short labels, no brackets, spaces as separators.
# NOTE: OSC 8 hyperlinks removed — Claude Code's statusline renderer counts
# escape bytes as visible characters, inflating length from ~51 to ~155 bytes
# and causing the entire line to be clipped/hidden.

out="${MODEL} ${COLOR}${USED_PCT_DISPLAY}%${RESET}"
if [ "$CONTEXT_SIZE" -gt 0 ]; then
    out="${out}/${CTX_TOTAL_FMT}"
fi
if [ -n "$TOTAL_COST_FMT" ]; then
    out="${out} \$${TOTAL_COST_FMT}"
fi

# Metrics: tightest labels possible
if [ -n "$CACHE_HIT_PCT" ]; then
    if [ "$CACHE_HIT_PCT" -ge 60 ]; then
        out="${out} C:\033[32m${CACHE_HIT_PCT}%${RESET}"
    elif [ "$CACHE_HIT_PCT" -le 30 ]; then
        out="${out} C:${YELLOW}${CACHE_HIT_PCT}%${RESET}"
    else
        out="${out} C:${CACHE_HIT_PCT}%"
    fi
fi
if [ "$LINES_ADDED" -gt 0 ] || [ "$LINES_REMOVED" -gt 0 ]; then
    out="${out} \033[32m+${LINES_ADDED}${RESET}/${RED}-${LINES_REMOVED}${RESET}"
fi
if [ -n "$TOOL_COUNT" ] && [ "$TOOL_COUNT" != "0" ]; then
    out="${out} T:${TOOL_COUNT}"
fi
if [ -n "$LAST_LATENCY_MS" ]; then
    if [ "$LAST_LATENCY_MS" -ge 5000 ]; then
        out="${out} ${RED}${LAST_LATENCY_MS}ms${RESET}"
    elif [ "$LAST_LATENCY_MS" -ge 2000 ]; then
        out="${out} ${YELLOW}${LAST_LATENCY_MS}ms${RESET}"
    else
        out="${out} ${DIM}${LAST_LATENCY_MS}ms${RESET}"
    fi
fi
if [ "$TOKENS_SAVED" -gt 0 ]; then
    out="${out} \033[32m↓$(format_tokens "$TOKENS_SAVED")t${RESET}"
fi

# Warnings: only shown when active (rare, worth the space)
if [ "$SUB_COUNT" -gt 0 ]; then
    out="${out} Sub:${SUB_COUNT}"
fi
if [ "$CLR_COUNT" -gt 0 ]; then
    if [ "$CLR_COUNT" -ge 3 ]; then
        CLR_COLOR="${RED}"
    elif [ "$CLR_COUNT" -ge 2 ]; then
        CLR_COLOR="${YELLOW}"
    else
        CLR_COLOR="\033[32m"
    fi
    out="${out} ${CLR_COLOR}Clr:${CLR_COUNT}${RESET}"
fi
if [ -n "$BUDGET_PCT" ]; then
    if [ "$BUDGET_PCT" -ge 90 ]; then
        out="${out} ${RED}B:${BUDGET_PCT}%${RESET}"
    elif [ "$BUDGET_PCT" -ge 75 ]; then
        out="${out} ${YELLOW}B:${BUDGET_PCT}%${RESET}"
    else
        out="${out} B:${BUDGET_PCT}%"
    fi
fi
if [ "$SHOW_RESET" -eq 1 ]; then
    if [ -n "$RESET_LABEL" ]; then
        out="${out} ${YELLOW}Rst:${RESET_LABEL}${RESET}"
    else
        out="${out} ${YELLOW}Rst${RESET}"
    fi
fi

_warden_sl_printed=1
printf '%b\n' "$out"
