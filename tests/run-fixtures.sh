#!/usr/bin/env bash
# Fixture-driven test harness for warden hooks.
# Each fixture: tests/fixtures/{hook}/{name}.json + {name}.expect
# Optional: {name}.generate (script that outputs input JSON), {name}.setup (pre-hook env)
#
# Usage:
#   bash tests/run-fixtures.sh                     # run all
#   bash tests/run-fixtures.sh pre-tool-use        # run one hook
#   bash tests/run-fixtures.sh pre-tool-use deny-rm # run one fixture (prefix match)
#   WARDEN_FIXTURE_VERBOSE=1 bash tests/run-fixtures.sh  # show details on pass
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$ROOT_DIR/tests/fixtures"

# Counters
PASS=0 FAIL=0 SKIP=0
FAILURES=()

# Colors (when tty)
if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m' C_RED=$'\033[31m' C_YELLOW=$'\033[33m' C_RESET=$'\033[0m'
else
  C_GREEN="" C_RED="" C_YELLOW="" C_RESET=""
fi

die() { echo "${C_RED}FATAL: $*${C_RESET}" >&2; exit 1; }

# === Sandbox setup ===
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT

export HOME="$TMP_HOME"
unset WARDEN_STATE_DIR WARDEN_SESSION_BUDGET_DIR WARDEN_SUBAGENT_STATE_DIR
mkdir -p "$HOME/.claude/.statusline" "$HOME/.claude/.session-times" "$HOME/.claude/.monitoring/textfile"

# Seed session start files for common test session IDs
_SEED_TS="$(date +%s).000000000"
for _sid in test-session demo-session size-test quiet-test fixture-session; do
  printf '%s\n' "$_SEED_TS" > "$HOME/.claude/.statusline/.session_start-$_sid"
done

# === Assertion engine ===
# Reads an .expect JSON file and validates actual stdout/stderr/exit_code against it.
check_fixture() {
  local expect_file="$1" actual_stdout="$2" actual_stderr="$3" actual_rc="$4" label="$5"
  local errors=()

  # Parse expected exit code
  local expected_rc
  expected_rc=$(jq -r '.exit_code // 0' "$expect_file")
  if [[ "$actual_rc" != "$expected_rc" ]]; then
    errors+=("exit_code: expected $expected_rc, got $actual_rc")
  fi

  # --- stdout assertions ---
  # stdout.empty
  local want_empty
  want_empty=$(jq -r '.stdout.empty // false' "$expect_file")
  if [[ "$want_empty" == "true" ]]; then
    if [[ -s "$actual_stdout" ]]; then
      errors+=("stdout: expected empty, got $(wc -c < "$actual_stdout" | tr -d ' ') bytes")
    fi
  fi

  # stdout.jq — array of jq expressions that must evaluate truthy
  local jq_count
  jq_count=$(jq -r '.stdout.jq // [] | length' "$expect_file")
  if [[ "$jq_count" -gt 0 ]]; then
    for i in $(seq 0 $((jq_count - 1))); do
      local expr
      expr=$(jq -r ".stdout.jq[$i]" "$expect_file")
      if ! jq -e "$expr" < "$actual_stdout" >/dev/null 2>&1; then
        local preview
        preview=$(head -c 200 "$actual_stdout")
        errors+=("stdout.jq[$i]: '$expr' failed (stdout: ${preview})")
      fi
    done
  fi

  # stdout.contains
  local contains_count
  contains_count=$(jq -r '.stdout.contains // [] | length' "$expect_file")
  if [[ "$contains_count" -gt 0 ]]; then
    local stdout_text
    stdout_text=$(<"$actual_stdout")
    for i in $(seq 0 $((contains_count - 1))); do
      local needle
      needle=$(jq -r ".stdout.contains[$i]" "$expect_file")
      if [[ "$stdout_text" != *"$needle"* ]]; then
        errors+=("stdout.contains[$i]: missing '$needle'")
      fi
    done
  fi

  # stdout.not_contains
  local nc_count
  nc_count=$(jq -r '.stdout.not_contains // [] | length' "$expect_file")
  if [[ "$nc_count" -gt 0 ]]; then
    local stdout_text
    stdout_text=$(<"$actual_stdout")
    for i in $(seq 0 $((nc_count - 1))); do
      local needle
      needle=$(jq -r ".stdout.not_contains[$i]" "$expect_file")
      if [[ "$stdout_text" == *"$needle"* ]]; then
        errors+=("stdout.not_contains[$i]: found unwanted '$needle'")
      fi
    done
  fi

  # --- stderr assertions ---
  # stderr.contains
  local se_count
  se_count=$(jq -r '.stderr.contains // [] | length' "$expect_file")
  if [[ "$se_count" -gt 0 ]]; then
    local stderr_text
    stderr_text=$(<"$actual_stderr")
    for i in $(seq 0 $((se_count - 1))); do
      local needle
      needle=$(jq -r ".stderr.contains[$i]" "$expect_file")
      if [[ "$stderr_text" != *"$needle"* ]]; then
        errors+=("stderr.contains[$i]: missing '$needle'")
      fi
    done
  fi

  # stderr.not_contains
  local snc_count
  snc_count=$(jq -r '.stderr.not_contains // [] | length' "$expect_file")
  if [[ "$snc_count" -gt 0 ]]; then
    local stderr_text
    stderr_text=$(<"$actual_stderr")
    for i in $(seq 0 $((snc_count - 1))); do
      local needle
      needle=$(jq -r ".stderr.not_contains[$i]" "$expect_file")
      if [[ "$stderr_text" == *"$needle"* ]]; then
        errors+=("stderr.not_contains[$i]: found unwanted '$needle'")
      fi
    done
  fi

  # --- files assertions ---
  # files.exist — array of paths (relative to $HOME) that must exist after hook runs
  local fe_count
  fe_count=$(jq -r '.files.exist // [] | length' "$expect_file")
  if [[ "$fe_count" -gt 0 ]]; then
    for i in $(seq 0 $((fe_count - 1))); do
      local fpath
      fpath=$(jq -r ".files.exist[$i]" "$expect_file")
      # Expand $HOME
      fpath="${fpath//\$HOME/$HOME}"
      if [[ ! -e "$fpath" ]]; then
        errors+=("files.exist[$i]: '$fpath' not found")
      fi
    done
  fi

  # --- report ---
  if [[ ${#errors[@]} -gt 0 ]]; then
    echo "  ${C_RED}FAIL${C_RESET} $label"
    for e in "${errors[@]}"; do
      echo "       $e"
    done
    FAIL=$((FAIL + 1))
    FAILURES+=("$label")
    return 1
  else
    if [[ "${WARDEN_FIXTURE_VERBOSE:-}" == "1" ]]; then
      echo "  ${C_GREEN}PASS${C_RESET} $label"
    fi
    PASS=$((PASS + 1))
    return 0
  fi
}

# === Main loop ===
FILTER_HOOK="${1:-}"
FILTER_NAME="${2:-}"

hook_dirs=()
if [[ -n "$FILTER_HOOK" ]]; then
  [[ -d "$FIXTURES_DIR/$FILTER_HOOK" ]] || die "No fixture dir: $FIXTURES_DIR/$FILTER_HOOK"
  hook_dirs+=("$FIXTURES_DIR/$FILTER_HOOK")
else
  for d in "$FIXTURES_DIR"/*/; do
    [[ -d "$d" ]] && hook_dirs+=("$d")
  done
fi

[[ ${#hook_dirs[@]} -gt 0 ]] || die "No fixture directories found in $FIXTURES_DIR"

for hook_dir in "${hook_dirs[@]}"; do
  hook_name="$(basename "$hook_dir")"
  hook_script="$ROOT_DIR/hooks/$hook_name"
  [[ -x "$hook_script" ]] || { echo "${C_YELLOW}SKIP${C_RESET} $hook_name (no executable hook)"; SKIP=$((SKIP+1)); continue; }

  echo "[${hook_name}]"

  # Collect .expect files (each corresponds to a test)
  expect_files=()
  while IFS= read -r -d '' f; do
    expect_files+=("$f")
  done < <(find "$hook_dir" -name '*.expect' -print0 | sort -z)

  [[ ${#expect_files[@]} -gt 0 ]] || { echo "  ${C_YELLOW}(no fixtures)${C_RESET}"; continue; }

  for expect_file in "${expect_files[@]}"; do
    test_name="$(basename "$expect_file" .expect)"

    # Filter by name prefix if specified
    if [[ -n "$FILTER_NAME" && "$test_name" != "$FILTER_NAME"* ]]; then
      continue
    fi

    label="${hook_name}/${test_name}"

    # Determine input source
    input_file="$hook_dir/${test_name}.json"
    generate_script="$hook_dir/${test_name}.generate"

    if [[ -x "$generate_script" ]]; then
      input_file="$(mktemp)"
      bash "$generate_script" > "$input_file" || { echo "  ${C_RED}FAIL${C_RESET} $label (generate script failed)"; FAIL=$((FAIL+1)); FAILURES+=("$label"); continue; }
    elif [[ ! -f "$input_file" ]]; then
      echo "  ${C_YELLOW}SKIP${C_RESET} $label (no .json or .generate)"
      SKIP=$((SKIP + 1))
      continue
    fi

    # Run optional setup script
    setup_script="$hook_dir/${test_name}.setup"
    if [[ -x "$setup_script" ]]; then
      bash "$setup_script" || true
    fi

    # Load optional env vars
    env_file="$hook_dir/${test_name}.env"
    if [[ -f "$env_file" ]]; then
      set -a
      source "$env_file"
      set +a
    fi

    # Run the hook
    actual_stdout="$(mktemp)"
    actual_stderr="$(mktemp)"
    set +e
    "$hook_script" < "$input_file" > "$actual_stdout" 2> "$actual_stderr"
    actual_rc=$?
    set -e

    # Check
    check_fixture "$expect_file" "$actual_stdout" "$actual_stderr" "$actual_rc" "$label"

    # Cleanup generated input
    [[ -x "$generate_script" ]] && rm -f "$input_file"
    rm -f "$actual_stdout" "$actual_stderr"

    # Unset env vars from env file
    if [[ -f "$env_file" ]]; then
      while IFS='=' read -r key _; do
        [[ -n "$key" && "$key" != "#"* ]] && unset "$key"
      done < "$env_file"
    fi
  done
done

# === Summary ===
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
total=$((PASS + FAIL + SKIP))
echo " ${C_GREEN}$PASS passed${C_RESET}  ${C_RED}$FAIL failed${C_RESET}  ${C_YELLOW}$SKIP skipped${C_RESET}  ($total total)"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo ""
  echo " Failures:"
  for f in "${FAILURES[@]}"; do
    echo "   - $f"
  done
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0
