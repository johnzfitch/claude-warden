#!/usr/bin/env bash
# Bulk-generate post-tool-use fixture pairs
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$DIR/../../.." && pwd)"
DEMO="$ROOT_DIR/demo/mock-inputs"

# Helper: copy demo fixture and create expect
from_demo() {
  local name="$1" demo_file="$2" expect_json="$3"
  cp "$DEMO/$demo_file" "$DIR/$name.json"
  echo "$expect_json" > "$DIR/$name.expect"
}

# Helper: create inline fixture
fixture() {
  local name="$1" json="$2" expect="$3"
  echo "$json" > "$DIR/$name.json"
  echo "$expect" > "$DIR/$name.expect"
}

# === FROM DEMO FIXTURES ===
from_demo clean-bash post-tool-use-clean-bash.json \
  '{"exit_code":0,"stdout":{"jq":[".suppressOutput == true"]}}'

from_demo clean-read post-tool-use-clean-read.json \
  '{"exit_code":0,"stdout":{"jq":[".suppressOutput == true"]}}'

from_demo reminder-bash post-tool-use-reminder-bash.json \
  '{"exit_code":0,"stdout":{"jq":[".modifyOutput"],"not_contains":["<system-reminder>"]}}'

from_demo reminder-read post-tool-use-reminder-read.json \
  '{"exit_code":0,"stdout":{"jq":[".modifyOutput"],"not_contains":["<system-reminder>"]}}'

from_demo reminder-write post-tool-use-reminder-write.json \
  '{"exit_code":0,"stdout":{"jq":[".modifyOutput"],"not_contains":["<system-reminder>"]}}'

from_demo task-agent post-tool-use-task-agent.json \
  '{"exit_code":0,"stdout":{"jq":["has(\"modifyOutput\")"],"contains":["Agent output compressed:"]}}'

# === SMALL OUTPUT (pass-through) ===
jq -n '{
  tool_name:"Bash", session_id:"test-session",
  tool_input:{command:"echo hello"},
  tool_response:{content:[{type:"text",text:"hello\n"}]}
}' > "$DIR/small-bash-output.json"
echo '{"exit_code":0,"stdout":{"jq":[".suppressOutput == true"]}}' > "$DIR/small-bash-output.expect"

# === QUIET OVERRIDE REMINDER ===
# This test needs pre-tool-use state file; use a generate script instead
cat > "$DIR/quiet-override-reminder.generate" <<'GEOF'
#!/usr/bin/env bash
# Simulate quiet override state from pre-tool-use
CMD="npm install --silent express"
CMD_HASH=$(printf '%s' "$CMD" | { md5sum 2>/dev/null || md5 -q 2>/dev/null || openssl md5 -r; } | awk '{print $1}')
STATE_DIR="${WARDEN_STATE_DIR:-$HOME/.claude/.statusline}"
mkdir -p "$STATE_DIR"
printf '%s' "npm_quiet_override" > "$STATE_DIR/.quiet-override-Bash-test-session-${CMD_HASH}-fixture"
jq -n --arg cmd "$CMD" '{
  tool_name:"Bash", session_id:"test-session",
  tool_input:{command:$cmd},
  tool_response:{content:[{type:"text",text:"added 1 package"}]}
}'
GEOF
chmod +x "$DIR/quiet-override-reminder.generate"
echo '{"exit_code":0,"stdout":{"jq":[".hookSpecificOutput.additionalContext"],"contains":["npm install --silent"]}}' > "$DIR/quiet-override-reminder.expect"

# === GREP TRUNCATION (>4KB) ===
cat > "$DIR/grep-truncation.generate" <<'GEOF'
#!/usr/bin/env bash
TEXT=$(python3 -c "print('\n'.join(f'file.txt:{i}:match line content here with some data' for i in range(200)))")
jq -n --arg txt "$TEXT" '{
  tool_name:"Bash", session_id:"test-session",
  tool_input:{command:"grep -r pattern ."},
  tool_response:{content:[{type:"text",text:$txt}]}
}'
GEOF
chmod +x "$DIR/grep-truncation.generate"
echo '{"exit_code":0,"stdout":{"jq":[".modifyOutput"],"contains":["grep output truncated"]}}' > "$DIR/grep-truncation.expect"

# === LARGE OUTPUT HEAD+TAIL TRUNCATION (>20KB) ===
cat > "$DIR/large-output-truncation.generate" <<'GEOF'
#!/usr/bin/env bash
TEXT=$(python3 -c "print('\n'.join(f'line {i:06d}: ' + 'x'*80 for i in range(450)))")
jq -n --arg txt "$TEXT" '{
  tool_name:"Bash", session_id:"test-session",
  tool_input:{command:"cat bigfile.txt"},
  tool_response:{content:[{type:"text",text:$txt}]}
}'
GEOF
chmod +x "$DIR/large-output-truncation.generate"
echo '{"exit_code":0,"stdout":{"jq":["has(\"modifyOutput\")"],"contains":["truncated to 10KB"]}}' > "$DIR/large-output-truncation.expect"

# === VERY LARGE OUTPUT (>50KB sampling) ===
cat > "$DIR/vlarge-output-sampling.generate" <<'GEOF'
#!/usr/bin/env bash
TEXT=$(python3 -c "print('\n'.join(f'line {i:07d}: ' + 'x'*90 for i in range(600)))")
jq -n --arg txt "$TEXT" '{
  tool_name:"Bash", session_id:"test-session",
  tool_input:{command:"find / -name \"*.log\""},
  tool_response:{content:[{type:"text",text:$txt}]}
}'
GEOF
chmod +x "$DIR/vlarge-output-sampling.generate"
echo '{"exit_code":0,"stdout":{"jq":["has(\"modifyOutput\")"]}}' > "$DIR/vlarge-output-sampling.expect"

# === READ PASSTHROUGH (non-subagent) ===
jq -n '{
  tool_name:"Read", session_id:"test-session",
  tool_input:{file_path:"src/main.ts"},
  tool_response:{content:[{type:"text",text:"const x = 1;\n"}]},
  transcript_path:"/tmp/main.jsonl"
}' > "$DIR/read-passthrough.json"
echo '{"exit_code":0,"stdout":{"jq":[".suppressOutput == true"]}}' > "$DIR/read-passthrough.expect"

# === EDIT/WRITE/OTHER TOOL PASSTHROUGH ===
jq -n '{
  tool_name:"Edit", session_id:"test-session",
  tool_input:{file_path:"src/main.ts"},
  tool_response:{content:[{type:"text",text:"File edited"}]}
}' > "$DIR/edit-passthrough.json"
echo '{"exit_code":0,"stdout":{"jq":[".suppressOutput == true"]}}' > "$DIR/edit-passthrough.expect"

# === GIT HINT STRIP ===
cat > "$DIR/git-hint-strip.generate" <<'GEOF'
#!/usr/bin/env bash
TEXT="$(printf 'Switched to branch main\nhint: You have diverged from remote.\nhint: Run git pull to reconcile.\nhint: See git help for more info.\nYour branch is up to date.\n')"
jq -n --arg txt "$TEXT" '{
  tool_name:"Bash", session_id:"test-session",
  tool_input:{command:"git checkout main"},
  tool_response:{content:[{type:"text",text:$txt}]}
}'
GEOF
chmod +x "$DIR/git-hint-strip.generate"
echo '{"exit_code":0,"stdout":{"not_contains":["hint: "]}}' > "$DIR/git-hint-strip.expect"

# === MCP TOOL PASSTHROUGH ===
jq -n '{
  tool_name:"mcp__llmx__search", session_id:"test-session",
  tool_input:{query:"test"},
  tool_response:{content:[{type:"text",text:"small result"}]}
}' > "$DIR/mcp-small-passthrough.json"
echo '{"exit_code":0,"stdout":{"jq":[".suppressOutput == true"]}}' > "$DIR/mcp-small-passthrough.expect"

echo "Generated $(find "$DIR" -name '*.expect' | wc -l) fixtures"
