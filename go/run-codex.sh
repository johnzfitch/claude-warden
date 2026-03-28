#!/usr/bin/env bash
# Run each hook spec through Codex sequentially.
# Each task builds on the shared types from 01.
#
# Usage:
#   bash go/run-codex.sh                    # run all from project dir
#   bash go/run-codex.sh 5                  # start from spec 05
#   WORKDIR=/tmp/claude-warden-go-port bash go/run-codex.sh  # eval in /tmp
set -euo pipefail

# Resolve workdir: explicit env, or infer from script location
WORKDIR="${WORKDIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$WORKDIR"
echo "workdir: $WORKDIR"

START=${1:-1}
SPECS=(
  "01-shared-types"
  "02-pre-tool-use"
  "03-post-tool-use"
  "04-read-compress"
  "05-read-guard"
  "06-mcp-output-compress"
  "07-session-lifecycle"
  "08-subagent-lifecycle"
  "09-observability"
  "10-config-change"
  "11-permission-request"
)

PASS=0
FAIL=0

for spec in "${SPECS[@]}"; do
  NUM="${spec%%-*}"
  (( 10#$NUM < START )) && continue

  echo ""
  echo "============================================"
  echo "  Task: $spec"
  echo "============================================"

  SPEC_FILE="go/specs/${spec}.md"
  if [[ ! -f "$SPEC_FILE" ]]; then
    echo "SKIP: $SPEC_FILE not found"
    continue
  fi

  # Use absolute paths in prompt so Codex doesn't get lost
  codex exec --lite \
    "You are implementing Go hooks for claude-warden.
Your working directory is ${WORKDIR}. All paths below are relative to it.

INSTRUCTIONS:
1. Read ${WORKDIR}/go/specs/${spec}.md — this is your complete specification
2. Read the bash reference files it points to in ${WORKDIR}/go/reference/
3. Read ${WORKDIR}/go/specs/00-overview.md for architecture context
4. Implement the Go code in ${WORKDIR}/collector/hooks/ package
5. Write tests in ${WORKDIR}/collector/hooks/*_test.go
6. Run: cd ${WORKDIR}/collector && go test ./hooks/... and fix until green

CONSTRAINTS:
- stdlib only, no third-party imports
- Do NOT modify any existing files in ${WORKDIR}/collector/*.go
- Do NOT add features not in the spec
- Do NOT rename or restructure — follow the spec exactly
- Every behavior rule in the spec needs a test case
- Check your work: re-read the spec after implementing, verify nothing was missed"

  echo "--- Completed: $spec ---"

  # Run tests after each spec to catch regressions early
  echo "--- Running tests ---"
  if (cd "$WORKDIR/collector" && go test ./hooks/... 2>&1 | tail -5); then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "WARNING: tests failed after $spec"
  fi
  echo ""
done

echo ""
echo "============================================"
echo "  All specs complete"
echo "  Passed: $PASS  Failed: $FAIL"
echo "============================================"
echo ""
echo "Final verification:"
(cd "$WORKDIR/collector" && go test ./hooks/... -v -count=1)
(cd "$WORKDIR/collector" && go vet ./hooks/...)
echo ""
echo "Build check:"
(cd "$WORKDIR/collector" && go build ./...)
