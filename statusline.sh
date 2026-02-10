#!/usr/bin/env bash
# Claude Code statusline - display model and token usage.
#
# Input: JSON on stdin per Claude Code status line docs.

set -u

input="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
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
        (.cost.total_lines_removed // 0)
      ] | @tsv
    ' <<<"$input" 2>/dev/null
)"

if [ -z "$parsed" ]; then
    printf '[Claude] Ctx 0%%\n'
    exit 0
fi

IFS=$'\t' read -r \
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
    COST_USD \
    DURATION_MS \
    API_DURATION_MS \
    LINES_ADDED \
    LINES_REMOVED \
    <<<"$parsed"

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

CONTEXT_SIZE=$(num_or_zero "$CONTEXT_SIZE")
TOTAL_INPUT=$(num_or_zero "$TOTAL_INPUT")
TOTAL_OUTPUT=$(num_or_zero "$TOTAL_OUTPUT")
CURR_IN=$(num_or_zero "$CURR_IN")
CURR_OUT=$(num_or_zero "$CURR_OUT")
CACHE_CREATE=$(num_or_zero "$CACHE_CREATE")
CACHE_READ=$(num_or_zero "$CACHE_READ")

TOTAL=$((TOTAL_INPUT + TOTAL_OUTPUT))

CTX_USED=0
PCT_TENTHS=0
USED_PCT_DISPLAY="0"

if [ "$HAS_CURR" = "1" ]; then
    CTX_USED=$((CURR_IN + CURR_OUT + CACHE_CREATE + CACHE_READ))
    if [ "$CONTEXT_SIZE" -gt 0 ]; then
        PCT_TENTHS=$((CTX_USED * 1000 / CONTEXT_SIZE))
        USED_PCT_DISPLAY="$(format_percent_from_tenths "$PCT_TENTHS")"
    fi
else
    if [[ "$USED_PCT_RAW" =~ ^([0-9]+)(\.([0-9]+))?$ ]]; then
        whole="${BASH_REMATCH[1]}"
        dec="${BASH_REMATCH[3]}"
        dec="${dec:0:1}"
        if [ -z "$dec" ]; then
            dec=0
        fi
        PCT_TENTHS=$((whole * 10 + dec))
        USED_PCT_DISPLAY="$(format_percent_from_tenths "$PCT_TENTHS")"
        if [ "$CONTEXT_SIZE" -gt 0 ]; then
            CTX_USED=$((CONTEXT_SIZE * PCT_TENTHS / 1000))
        fi
    fi
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
STATE_FILE="$STATE_DIR/state"
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
    IFS='|' read -r PREV_SESSION PREV_F2 PREV_F3 PREV_F4 PREV_F5 \
        _P6 _P7 _P8 _P9 _P10 _P11 _P12 _P13 PREV_F14 PREV_F15 < "$STATE_FILE"
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
if [ "$PREV_TOTAL" -gt 0 ] && [ "$TOTAL" -lt "$PREV_TOTAL" ]; then
    RESET_NOW=1
    RESET_REASON="reset"
fi

CTX_CLEAR_NOW=0
if [ "$PREV_CTX" -gt 0 ] && [ "$CTX_USED" -lt "$PREV_CTX" ]; then
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
CLR_FILE="$STATE_DIR/clears-$SESSION_ID"

# Reset clears on session change
if [ -n "$SESSION_ID" ] && [ -n "$PREV_SESSION" ] && [ "$SESSION_ID" != "$PREV_SESSION" ]; then
    rm -f "$STATE_DIR/clears-$PREV_SESSION" "$STATE_DIR/peak-$PREV_SESSION"
fi

if [ -n "$SESSION_ID" ] && [ -f "$CLR_FILE" ]; then
    IFS='|' read -r CLR_COUNT CLR_CTX_LOST CLR_COST_AT_CLEAR < "$CLR_FILE" 2>/dev/null
    CLR_COUNT=$(num_or_zero "$CLR_COUNT")
    CLR_CTX_LOST=$(num_or_zero "$CLR_CTX_LOST")
    CLR_COST_AT_CLEAR="${CLR_COST_AT_CLEAR:-0}"
fi

if [ "$CTX_CLEAR_NOW" -eq 1 ] && [ -n "$SESSION_ID" ]; then
    CLR_COUNT=$((CLR_COUNT + 1))
    CLR_CTX_LOST=$((CLR_CTX_LOST + DELTA))
    CLR_COST_AT_CLEAR="$COST_USD"
    printf '%s|%s|%s\n' "$CLR_COUNT" "$CLR_CTX_LOST" "$CLR_COST_AT_CLEAR" > "$CLR_FILE"
fi

printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$SESSION_ID" "$TOTAL_INPUT" "$TOTAL_OUTPUT" "$CTX_USED" "$CONTEXT_SIZE" \
    "$COST_USD" "$DURATION_MS" "$API_DURATION_MS" "$LINES_ADDED" "$LINES_REMOVED" \
    "$CACHE_READ" "$CACHE_CREATE" "$MODEL" "$RESET_TS" "$RESET_REASON" > "$STATE_FILE"

RESET_LABEL=""
RESET_WINDOW=45
SHOW_RESET=0

if [ "$RESET_TS" -gt 0 ] && [ $((NOW_TS - RESET_TS)) -le "$RESET_WINDOW" ]; then
    SHOW_RESET=1
fi

if [ -f "$REASON_FILE" ]; then
    IFS='|' read -r REASON_TS REASON_VALUE REASON_SESSION < "$REASON_FILE"
    REASON_TS=$(num_or_zero "$REASON_TS")
    if [ "$REASON_TS" -gt 0 ] && [ $((NOW_TS - REASON_TS)) -le 120 ]; then
        RESET_LABEL="$REASON_VALUE"
        SHOW_RESET=1
    fi
fi

TOOL_COUNT=""
if [[ "$TOOL_COUNT_RAW" =~ ^[0-9]+$ ]]; then
    TOOL_COUNT="$TOOL_COUNT_RAW"
fi

HOT_LABEL=""
HOT_SIZE_BYTES=0
HOT_SIZE_KB=0

if [ -n "$SESSION_ID" ]; then
    # Read combined session state (count|top_bytes|top_label|timestamp)
    SESSION_STATE_FILE="$STATE_DIR/session-$SESSION_ID"
    if [ -f "$SESSION_STATE_FILE" ]; then
        IFS='|' read -r SS_COUNT SS_BYTES SS_LABEL _SS_TS < "$SESSION_STATE_FILE" 2>/dev/null
        if [ -z "$TOOL_COUNT" ] && [[ "${SS_COUNT:-}" =~ ^[0-9]+$ ]]; then
            TOOL_COUNT="$SS_COUNT"
        fi
        SS_BYTES=$(num_or_zero "${SS_BYTES:-0}")
        if [ "$SS_BYTES" -gt 0 ]; then
            HOT_LABEL="${SS_LABEL:-}"
            HOT_SIZE_BYTES="$SS_BYTES"
            HOT_SIZE_KB=$(((HOT_SIZE_BYTES + 1023) / 1024))
        fi
    fi
    # Fallback: legacy separate files (transition period)
    if [ -z "$TOOL_COUNT" ]; then
        COUNT_FILE="$STATE_DIR/tool-count-$SESSION_ID"
        if [ -f "$COUNT_FILE" ]; then
            IFS='|' read -r COUNT_SESSION COUNT_VALUE _COUNT_TS < "$COUNT_FILE"
            if [ "$COUNT_SESSION" = "$SESSION_ID" ]; then
                TOOL_COUNT="$COUNT_VALUE"
            fi
        fi
    fi
fi

SUB_COUNT=0
SUB_COUNT_FILE="$STATE_DIR/subagent-count"
if [ -f "$SUB_COUNT_FILE" ]; then
    IFS='|' read -r SUB_SESSION SUB_VALUE _SUB_TS < "$SUB_COUNT_FILE"
    if [ "$SUB_SESSION" = "$SESSION_ID" ]; then
        SUB_COUNT=$(num_or_zero "$SUB_VALUE")
    fi
fi

CTX_USED_FMT="$(format_tokens "$CTX_USED")"
CTX_TOTAL_FMT="$(format_tokens "$CONTEXT_SIZE")"
CTX_LEFT_FMT="$(format_tokens "$CTX_LEFT")"
IO_IN_FMT="$(format_tokens "$TOTAL_INPUT")"
IO_OUT_FMT="$(format_tokens "$TOTAL_OUTPUT")"
MSG_IN_FMT="$(format_tokens "$CURR_IN")"
MSG_OUT_FMT="$(format_tokens "$CURR_OUT")"
CACHE_CREATE_FMT="$(format_tokens "$CACHE_CREATE")"
CACHE_READ_FMT="$(format_tokens "$CACHE_READ")"

# --- Computed metrics ---

# Turn cost: delta from previous state file
# Only valid when previous session matches (not first observation or session switch)
TURN_COST="0"
TOTAL_COST_FMT=""
TURN_COST_FMT=""
HAS_VALID_DELTA=0
if [[ "$COST_USD" =~ ^[0-9]*\.?[0-9]+$ ]] && [ "$COST_USD" != "0" ]; then
    TOTAL_COST_FMT=$(printf '%.2f' "$COST_USD")
    if [ "$PREV_SESSION" = "$SESSION_ID" ] && [[ "$PREV_COST_USD" =~ ^[0-9]*\.?[0-9]+$ ]] && [ "$PREV_COST_USD" != "0" ]; then
        TURN_COST=$(awk "BEGIN {v=$COST_USD-$PREV_COST_USD; printf \"%.4f\", (v<0?0:v)}" 2>/dev/null)
        HAS_VALID_DELTA=1
    fi
    TURN_COST_FMT=$(printf '%.2f' "$TURN_COST")
fi

# Peak turn cost tracking (per session, only from real deltas)
PEAK_COST_FMT=""
if [ -n "$SESSION_ID" ] && [ "$HAS_VALID_DELTA" = "1" ]; then
    PEAK_FILE="$STATE_DIR/peak-$SESSION_ID"
    PEAK_COST="0"
    if [ -f "$PEAK_FILE" ]; then
        PEAK_COST=$(cat "$PEAK_FILE" 2>/dev/null || echo "0")
    fi
    IS_PEAK=$(awk "BEGIN {print ($TURN_COST > $PEAK_COST) ? 1 : 0}" 2>/dev/null)
    if [ "$IS_PEAK" = "1" ]; then
        PEAK_COST="$TURN_COST"
        printf '%.4f' "$PEAK_COST" > "$PEAK_FILE"
    fi
    PEAK_COST_FMT=$(printf '%.2f' "$PEAK_COST")
elif [ -n "$SESSION_ID" ]; then
    # Read existing peak even if this turn has no valid delta
    PEAK_FILE="$STATE_DIR/peak-$SESSION_ID"
    if [ -f "$PEAK_FILE" ]; then
        PEAK_COST=$(cat "$PEAK_FILE" 2>/dev/null || echo "0")
        PEAK_COST_FMT=$(printf '%.2f' "$PEAK_COST")
    fi
fi

# Most expensive I/O this turn: output tokens are the main cost driver
TURN_OUT_FMT=""
if [ "$CURR_OUT" -gt 0 ]; then
    TURN_OUT_FMT="$(format_tokens "$CURR_OUT")out"
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

# API efficiency
DURATION_MS=$(num_or_zero "$DURATION_MS")
API_DURATION_MS=$(num_or_zero "$API_DURATION_MS")
API_PCT=""
if [ "$DURATION_MS" -gt 0 ] && [ "$API_DURATION_MS" -gt 0 ]; then
    API_PCT=$((API_DURATION_MS * 100 / DURATION_MS))
fi

# Budget
BUDGET_PCT=""
BUDGET_CACHE="$STATE_DIR/budget-export"
if [ -f "$BUDGET_CACHE" ]; then
    CACHE_MTIME=$(stat -c %Y "$BUDGET_CACHE" 2>/dev/null || stat -f %m "$BUDGET_CACHE" 2>/dev/null || echo 0)
    if [ $((NOW_TS - CACHE_MTIME)) -le 5 ]; then
        BUDGET_PCT=$(jq -r '(.consumed / .limit * 100) | floor' "$BUDGET_CACHE" 2>/dev/null || echo "")
        [[ "$BUDGET_PCT" =~ ^[0-9]+$ ]] || BUDGET_PCT=""
        [ "$BUDGET_PCT" = "0" ] && BUDGET_PCT=""
    fi
fi

# --- Build segments ---
# Separator: dim pipe with single space each side (spaces OUTSIDE dim)
S=" ${DIM}|${RESET} "

segments=()
segments+=("[${MODEL}]")

# Cost: turn cost (total) peak — shows spend velocity
if [ -n "$TOTAL_COST_FMT" ]; then
    cost_seg="\$${TURN_COST_FMT}"
    # Show output tokens as the expensive part of this turn
    if [ -n "$TURN_OUT_FMT" ]; then
        cost_seg="${cost_seg} ${DIM}${TURN_OUT_FMT}${RESET}"
    fi
    cost_seg="${cost_seg} ${DIM}(\$${TOTAL_COST_FMT}"
    if [ -n "$PEAK_COST_FMT" ] && [ "$PEAK_COST_FMT" != "0.00" ]; then
        cost_seg="${cost_seg} pk \$${PEAK_COST_FMT}"
    fi
    cost_seg="${cost_seg})${RESET}"
    segments+=("$cost_seg")
fi

# Context
ctx_seg="Ctx ${COLOR}${USED_PCT_DISPLAY}%${RESET}"
if [ "$CONTEXT_SIZE" -gt 0 ]; then
    ctx_seg="${ctx_seg} ${DIM}${CTX_LEFT_FMT} left${RESET}"
fi
segments+=("$ctx_seg")

# IO
segments+=("IO ${IO_IN_FMT}/${IO_OUT_FMT}")

# Cache hit rate
if [ -n "$CACHE_HIT_PCT" ]; then
    if [ "$CACHE_HIT_PCT" -ge 60 ]; then
        segments+=("Cache \033[32m${CACHE_HIT_PCT}%${RESET}")
    elif [ "$CACHE_HIT_PCT" -le 30 ]; then
        segments+=("Cache ${YELLOW}${CACHE_HIT_PCT}%${RESET}")
    else
        segments+=("Cache ${CACHE_HIT_PCT}%")
    fi
fi

# Context clears: count + cumulative shrinkage
if [ "$CLR_COUNT" -gt 0 ]; then
    CLR_LOST_FMT="$(format_tokens "$CLR_CTX_LOST")"
    # Color: 1=green (normal), 2=yellow (watch it), 3+=red (session too long)
    if [ "$CLR_COUNT" -ge 3 ]; then
        CLR_COLOR="${RED}"
    elif [ "$CLR_COUNT" -ge 2 ]; then
        CLR_COLOR="${YELLOW}"
    else
        CLR_COLOR="\033[32m"
    fi
    # Show cost of summarization: delta between total cost at last clear and cost at prior clear
    clr_seg="${CLR_COLOR}Clr ${CLR_COUNT}${RESET} ${DIM}-${CLR_LOST_FMT} ctx${RESET}"
    segments+=("$clr_seg")
fi

# LOC
if [ "$LINES_ADDED" -gt 0 ] || [ "$LINES_REMOVED" -gt 0 ]; then
    segments+=("\033[32m+${LINES_ADDED}${RESET}/${RED}-${LINES_REMOVED}${RESET}")
fi

# Tools
if [ -n "$TOOL_COUNT" ] && [ "$TOOL_COUNT" != "0" ]; then
    segments+=("${DIM}T${RESET}${TOOL_COUNT}")
fi

# API efficiency
if [ -n "$API_PCT" ]; then
    if [ "$API_PCT" -le 40 ]; then
        segments+=("API ${YELLOW}${API_PCT}%${RESET}")
    else
        segments+=("${DIM}API ${API_PCT}%${RESET}")
    fi
fi

# Hot file
if [ -n "$HOT_LABEL" ] && [ "$HOT_SIZE_KB" -gt 0 ]; then
    segments+=("Hot ${HOT_LABEL} ${HOT_SIZE_KB}KB")
fi

# Subagents
if [ "$SUB_COUNT" -gt 0 ]; then
    segments+=("Sub ${SUB_COUNT}")
fi

# Budget
if [ -n "$BUDGET_PCT" ]; then
    if [ "$BUDGET_PCT" -ge 90 ]; then
        segments+=("${RED}Bgt ${BUDGET_PCT}%${RESET}")
    elif [ "$BUDGET_PCT" -ge 75 ]; then
        segments+=("${YELLOW}Bgt ${BUDGET_PCT}%${RESET}")
    else
        segments+=("Bgt ${BUDGET_PCT}%")
    fi
fi

# Reset
if [ "$SHOW_RESET" -eq 1 ]; then
    if [ -n "$RESET_LABEL" ]; then
        segments+=("${YELLOW}Reset ${RESET_LABEL}${RESET}")
    else
        segments+=("${YELLOW}Reset${RESET}")
    fi
fi

# --- Render: join with separator ---
out=""
for i in "${!segments[@]}"; do
    if [ "$i" -gt 0 ]; then
        out="${out}${S}"
    fi
    out="${out}${segments[$i]}"
done

printf '%b\n' "$out"
