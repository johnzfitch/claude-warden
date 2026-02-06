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
        (.tool_count // .tool_counts.total // .tools.total // .tool_usage.total // .tool_usage.total_calls // .usage.tools.total // "");
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
        toolcount
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
PREV_TOTAL=0
PREV_CTX=0
RESET_TS=0
RESET_REASON=""

if [ -f "$STATE_FILE" ]; then
    IFS='|' read -r PREV_SESSION PREV_TOTAL PREV_CTX RESET_TS RESET_REASON < "$STATE_FILE"
fi

PREV_TOTAL=$(num_or_zero "$PREV_TOTAL")
PREV_CTX=$(num_or_zero "$PREV_CTX")
RESET_TS=$(num_or_zero "$RESET_TS")

NOW_TS=$(date +%s)
RESET_NOW=0

if [ -n "$SESSION_ID" ] && [ -n "$PREV_SESSION" ] && [ "$SESSION_ID" != "$PREV_SESSION" ]; then
    RESET_NOW=1
    RESET_REASON="session"
fi

if [ "$PREV_TOTAL" -gt 0 ] && [ "$TOTAL" -lt "$PREV_TOTAL" ]; then
    RESET_NOW=1
    RESET_REASON="reset"
fi

if [ "$PREV_CTX" -gt 0 ] && [ "$CTX_USED" -lt "$PREV_CTX" ]; then
    DELTA=$((PREV_CTX - CTX_USED))
    if [ "$DELTA" -ge 2000 ]; then
        RESET_NOW=1
        RESET_REASON="context"
    fi
fi

if [ "$RESET_NOW" -eq 1 ]; then
    RESET_TS="$NOW_TS"
fi

printf '%s|%s|%s|%s|%s\n' "$SESSION_ID" "$TOTAL" "$CTX_USED" "$RESET_TS" "$RESET_REASON" > "$STATE_FILE"

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

segments=()
segments+=("[${MODEL}]")

ctx_segment="Ctx ${COLOR}${USED_PCT_DISPLAY}%${RESET}"
if [ "$CONTEXT_SIZE" -gt 0 ]; then
    ctx_segment="${ctx_segment} ${DIM}(${CTX_USED_FMT}/${CTX_TOTAL_FMT}, ${CTX_LEFT_FMT} left)${RESET}"
fi
segments+=("$ctx_segment")

segments+=("IO ${IO_IN_FMT}/${IO_OUT_FMT}")

if [ "$CURR_IN" -gt 0 ] || [ "$CURR_OUT" -gt 0 ]; then
    segments+=("Msg ${MSG_IN_FMT}/${MSG_OUT_FMT}")
fi

if [ "$CACHE_CREATE" -gt 0 ] || [ "$CACHE_READ" -gt 0 ]; then
    segments+=("Cache +${CACHE_CREATE_FMT}/${CACHE_READ_FMT}")
fi

if [ -n "$TOOL_COUNT" ]; then
    segments+=("Tools ${TOOL_COUNT}")
fi

if [ -n "$HOT_LABEL" ] && [ "$HOT_SIZE_KB" -gt 0 ]; then
    segments+=("Hot ${HOT_LABEL} ${HOT_SIZE_KB}KB")
fi

if [ "$SUB_COUNT" -gt 0 ]; then
    segments+=("Sub ${SUB_COUNT}")
fi

# Budget utilization (cached, max 5s stale)
# Cross-platform stat for mtime: Linux (-c %Y) || macOS (-f %m)
BUDGET_CACHE="$STATE_DIR/budget-export"
if [ -f "$BUDGET_CACHE" ]; then
    CACHE_MTIME=$(stat -c %Y "$BUDGET_CACHE" 2>/dev/null || stat -f %m "$BUDGET_CACHE" 2>/dev/null || echo 0)
    if [ $((NOW_TS - CACHE_MTIME)) -le 5 ]; then
        BUDGET_PCT=$(jq -r '(.consumed / .limit * 100) | floor' "$BUDGET_CACHE" 2>/dev/null || echo 0)
        if [ "$BUDGET_PCT" -gt 0 ]; then
            if [ "$BUDGET_PCT" -ge 90 ]; then
                segments+=("${RED}Bgt ${BUDGET_PCT}%${RESET}")
            elif [ "$BUDGET_PCT" -ge 75 ]; then
                segments+=("${YELLOW}Bgt ${BUDGET_PCT}%${RESET}")
            else
                segments+=("Bgt ${BUDGET_PCT}%")
            fi
        fi
    fi
fi

if [ "$SHOW_RESET" -eq 1 ]; then
    if [ -n "$RESET_LABEL" ]; then
        segments+=("Reset ${RESET_LABEL}")
    else
        segments+=("Reset")
    fi
fi

(
    IFS=' | '
    printf '%b\n' "${segments[*]}"
)
