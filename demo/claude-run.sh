#!/bin/bash
# Wrapper for claude -p that uses JSON output mode and formats results cleanly.
# Strips OTEL telemetry noise and shows a clear narrative of what happened.
#
# Usage: ./demo/claude-run.sh "prompt" [extra claude flags...]

set -euo pipefail

BOLD='\033[1m'
DIM='\033[2m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

prompt="$1"
shift

printf "${CYAN}[Prompt]${RESET} %s\n" "$prompt"
printf "${DIM}Running claude -p ...${RESET}\n"

# Capture full output (telemetry + JSON result)
RAW=$(timeout 60 claude -p "$prompt" --print --model haiku --no-session-persistence --output-format json "$@" 2>/dev/null) || true

# Extract the JSON result line (contains "type":"result")
RESULT_LINE=$(echo "$RAW" | grep '"type":"result"' | head -1)

if [[ -z "$RESULT_LINE" ]]; then
    printf "${RED}[Error]${RESET} No result from Claude\n"
    exit 1
fi

# Parse key fields
RESULT_TEXT=$(echo "$RESULT_LINE" | jq -r '.result // "No result"')
NUM_TURNS=$(echo "$RESULT_LINE" | jq -r '.num_turns // 0')
IS_ERROR=$(echo "$RESULT_LINE" | jq -r '.is_error // false')
COST=$(echo "$RESULT_LINE" | jq -r '.total_cost_usd // 0')

# Extract tool usage from telemetry (tool_result events)
TOOL_EVENTS=$(echo "$RAW" | grep -o '"tool_parameters":"[^"]*"' | sed 's/\\"/"/g; s/"tool_parameters":"//; s/"$//' || true)

# Show tool interactions from telemetry
if [[ -n "$TOOL_EVENTS" ]]; then
    while IFS= read -r event; do
        CMD=$(echo "$event" | jq -r '.full_command // .command // empty' 2>/dev/null || true)
        if [[ -n "$CMD" ]]; then
            printf "${YELLOW}[Tool]${RESET} Bash: %s\n" "$CMD"
        fi
    done <<< "$TOOL_EVENTS"
fi

# Show blocked commands from telemetry (hook errors)
HOOK_ERRORS=$(echo "$RAW" | grep -o 'BLOCKED:[^"]*' || true)
if [[ -n "$HOOK_ERRORS" ]]; then
    while IFS= read -r err; do
        printf "${RED}[Warden]${RESET} %s\n" "$err"
    done <<< "$HOOK_ERRORS"
fi

# Show result
if [[ "$IS_ERROR" == "true" ]]; then
    printf "${RED}[Result]${RESET} %s\n" "$RESULT_TEXT"
else
    printf "${GREEN}[Result]${RESET} %s\n" "$RESULT_TEXT"
fi

# Show turns info
if (( NUM_TURNS > 1 )); then
    printf "${DIM}(%d turns - hook triggered adaptation)${RESET}\n" "$NUM_TURNS"
fi
