#!/usr/bin/env bash
# parity-check.sh — Compare bash hook output vs Go hook output for all fixtures
# Usage: bash tests/parity-check.sh [hook-name]
set -o pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$ROOT_DIR/collector/warden-collector"
FIXTURES_DIR="$ROOT_DIR/tests/fixtures"

RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
DIFFS=""

# Build Go binary if needed
if [[ ! -x "$GO_BIN" ]]; then
    echo "Building Go binary..."
    (cd "$ROOT_DIR/collector" && go build -o warden-collector .) || { echo "Build failed"; exit 1; }
fi

# Source warden env for bash hooks
[[ -f "$HOME/.claude/.warden/warden.env" ]] && . "$HOME/.claude/.warden/warden.env"

# Export vars the hooks expect
export WARDEN_SESSION_ID="parity-test"
export WARDEN_STATE_DIR="$(mktemp -d)"
export WARDEN_EVENTS_FILE="$WARDEN_STATE_DIR/events.jsonl"
touch "$WARDEN_EVENTS_FILE"
mkdir -p "$WARDEN_STATE_DIR"

cleanup() { rm -rf "$WARDEN_STATE_DIR"; }
trap cleanup EXIT

run_hook() {
    local hook="$1" input="$2" binary="$3"
    if [[ "$binary" == "go" ]]; then
        echo "$input" | "$GO_BIN" hook "$hook" 2>/dev/null
    else
        echo "$input" | "$ROOT_DIR/hooks/$hook" 2>/dev/null
    fi
}

normalize_json() {
    # Sort keys for stable comparison, strip volatile fields
    jq -S 'del(.hookSpecificOutput.updatedInput.command)' 2>/dev/null || echo "{}"
}

# Which hooks to test
if [[ -n "${1:-}" ]]; then
    HOOKS=("$1")
else
    HOOKS=()
    for dir in "$FIXTURES_DIR"/*/; do
        hook=$(basename "$dir")
        [[ "$hook" == "observe" ]] && continue
        [[ -f "$ROOT_DIR/hooks/$hook" ]] || continue
        HOOKS+=("$hook")
    done
fi

for hook in "${HOOKS[@]}"; do
    FIXTURE_DIR="$FIXTURES_DIR/$hook"
    [[ -d "$FIXTURE_DIR" ]] || continue

    echo ""
    echo "=== $hook ==="

    for fixture in "$FIXTURE_DIR"/*.json; do
        [[ -f "$fixture" ]] || continue
        name=$(basename "$fixture" .json)
        input=$(cat "$fixture")

        # Run through both
        bash_out=$(run_hook "$hook" "$input" "bash")
        bash_rc=$?
        go_out=$(run_hook "$hook" "$input" "go")
        go_rc=$?

        # Compare exit codes
        if [[ "$bash_rc" != "$go_rc" ]]; then
            printf "${RED}FAIL${NC}  %-45s exit: bash=%d go=%d\n" "$name" "$bash_rc" "$go_rc"
            FAIL=$((FAIL + 1))
            DIFFS+="$hook/$name: exit code mismatch (bash=$bash_rc, go=$go_rc)\n"
            continue
        fi

        # Compare decision (allow vs deny)
        bash_decision=$(echo "$bash_out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
        go_decision=$(echo "$go_out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)

        if [[ "$bash_decision" != "$go_decision" ]]; then
            printf "${RED}FAIL${NC}  %-45s decision: bash=%s go=%s\n" "$name" "$bash_decision" "$go_decision"
            FAIL=$((FAIL + 1))
            DIFFS+="$hook/$name: decision mismatch (bash=$bash_decision, go=$go_decision)\n  bash: $bash_out\n  go:   $go_out\n"
            continue
        fi

        # For denials, compare message presence (not exact text)
        bash_has_msg=$(echo "$bash_out" | jq -r '.hookSpecificOutput.userFacingMessage // empty' 2>/dev/null)
        go_has_msg=$(echo "$go_out" | jq -r '.hookSpecificOutput.userFacingMessage // empty' 2>/dev/null)

        if [[ -n "$bash_has_msg" && -z "$go_has_msg" ]] || [[ -z "$bash_has_msg" && -n "$go_has_msg" ]]; then
            printf "${RED}FAIL${NC}  %-45s message presence mismatch\n" "$name"
            FAIL=$((FAIL + 1))
            DIFFS+="$hook/$name: message presence mismatch\n  bash: $bash_out\n  go:   $go_out\n"
            continue
        fi

        # For quiet overrides, check that both produce updatedInput
        bash_has_override=$(echo "$bash_out" | jq -r '.hookSpecificOutput.updatedInput // empty' 2>/dev/null)
        go_has_override=$(echo "$go_out" | jq -r '.hookSpecificOutput.updatedInput // empty' 2>/dev/null)

        if [[ -n "$bash_has_override" && -z "$go_has_override" ]] || [[ -z "$bash_has_override" && -n "$go_has_override" ]]; then
            printf "${RED}FAIL${NC}  %-45s override presence mismatch\n" "$name"
            FAIL=$((FAIL + 1))
            DIFFS+="$hook/$name: override mismatch\n  bash: $bash_out\n  go:   $go_out\n"
            continue
        fi

        # Check modifyOutput presence
        bash_modify=$(echo "$bash_out" | jq -r '.modifyOutput // empty' 2>/dev/null)
        go_modify=$(echo "$go_out" | jq -r '.modifyOutput // empty' 2>/dev/null)

        if [[ -n "$bash_modify" && -z "$go_modify" ]] || [[ -z "$bash_modify" && -n "$go_modify" ]]; then
            printf "${RED}FAIL${NC}  %-45s modifyOutput presence mismatch\n" "$name"
            FAIL=$((FAIL + 1))
            DIFFS+="$hook/$name: modifyOutput mismatch\n  bash: ${bash_modify:0:100}\n  go:   ${go_modify:0:100}\n"
            continue
        fi

        # Check suppressOutput
        bash_suppress=$(echo "$bash_out" | jq -r '.suppressOutput // empty' 2>/dev/null)
        go_suppress=$(echo "$go_out" | jq -r '.suppressOutput // empty' 2>/dev/null)

        if [[ "$bash_suppress" != "$go_suppress" ]]; then
            printf "${RED}FAIL${NC}  %-45s suppressOutput mismatch\n" "$name"
            FAIL=$((FAIL + 1))
            DIFFS+="$hook/$name: suppressOutput mismatch (bash=$bash_suppress, go=$go_suppress)\n"
            continue
        fi

        printf "${GREEN}PASS${NC}  %-45s %s\n" "$name" "${bash_decision:-$(echo "$bash_out" | jq -r 'keys[0]' 2>/dev/null)}"
        PASS=$((PASS + 1))
    done
done

echo ""
echo "========================================"
printf "  Passed: ${GREEN}%d${NC}  Failed: ${RED}%d${NC}  Skipped: %d\n" "$PASS" "$FAIL" "$SKIP"
echo "========================================"

if [[ -n "$DIFFS" ]]; then
    echo ""
    echo "=== Failures ==="
    printf "$DIFFS"
fi

exit $FAIL
