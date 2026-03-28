package hooks

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type postToolUseResult struct {
	ModifyOutput       string `json:"modifyOutput"`
	Suppress           bool   `json:"suppressOutput"`
	HookSpecificOutput struct {
		HookEventName     string `json:"hookEventName"`
		AdditionalContext string `json:"additionalContext"`
	} `json:"hookSpecificOutput"`
}

func TestPostToolUseEmptyOutput(t *testing.T) {
	_, collector := setupPostToolUseTest(t)
	out, code := handlePostToolUse(postToolUseInput("Bash", "echo hi", "", ""))
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(out) != 0 {
		t.Fatalf("out=%q want empty", out)
	}
	if len(collector.events) != 0 {
		t.Fatalf("events=%#v want none", collector.events)
	}
}

func TestPostToolUseOutputSizeEvents(t *testing.T) {
	_, collector := setupPostToolUseTest(t)
	small := strings.Join([]string{"a", "b", "c"}, "\n")
	res := runPostToolUse(t, postToolUseInput("Bash", "cat small.txt", small, ""))
	if !res.Suppress {
		t.Fatalf("small output should pass through: %#v", res)
	}
	evt := collector.events[0]
	if evt["event_type"] != "tool_output_size" || evt["output_lines"] != float64(3) {
		t.Fatalf("unexpected small size event: %#v", evt)
	}

	collector.events = nil
	large := strings.Repeat("0123456789abcdef\n", 4000)
	_ = runPostToolUse(t, postToolUseInput("Bash", "cat big.txt", large, ""))
	evt = collector.events[0]
	if evt["event_type"] != "tool_output_size" {
		t.Fatalf("unexpected large size event: %#v", evt)
	}
	wantLines := float64(sampleLineEstimate(large))
	if evt["output_lines"] != wantLines {
		t.Fatalf("output_lines=%v want %v", evt["output_lines"], wantLines)
	}
}

func TestPostToolUseSystemReminderStripping(t *testing.T) {
	_, collector := setupPostToolUseTest(t)
	text := "keep 1\n<system-reminder>\nnoise\n</system-reminder>\nkeep 2\n<system-reminder>\nmore noise\n</system-reminder>\n"
	res := runPostToolUse(t, postToolUseInput("Read", "file.txt", text, ""))
	if res.ModifyOutput != "keep 1\nkeep 2" {
		t.Fatalf("modifyOutput=%q", res.ModifyOutput)
	}
	assertEventRule(t, collector.events, "truncated", "system_reminder")
}

func TestPostToolUseMCPReminderStripContinuesToMCPCompress(t *testing.T) {
	_, collector := setupPostToolUseTest(t)
	base := strings.Repeat("x", 13000)
	text := "<system-reminder>\nignore\n</system-reminder>\n" + base
	res := runPostToolUse(t, postToolUseInput("mcp__github__search", "prompt text", text, ""))
	if res.ModifyOutput == "" || strings.Contains(res.ModifyOutput, "<system-reminder>") {
		t.Fatalf("unexpected output: %#v", res)
	}
	assertEventRule(t, collector.events, "truncated", "system_reminder")
	assertEventRule(t, collector.events, "truncated", "mcp_file_offload")
}

func TestPostToolUseSSHCleaningAndIPSCompression(t *testing.T) {
	_, collector := setupPostToolUseTest(t)
	sshText := strings.Join([]string{
		" ____",
		"/ _  |",
		"help -> stuff",
		"Warning: Permanently added 'h'",
		"UNIX authentication refused",
		"UNIX authentication refused",
		"Permission denied, please try again",
		"Host key verification failed",
		"Host key verification failed",
		"Connection closed by 1.2.3.4",
		"real output",
	}, "\n")
	res := runPostToolUse(t, postToolUseInput("Bash", "ssh host", sshText, ""))
	if res.ModifyOutput != "[SSH: auth refused]\n[SSH: host key verification failed]\nreal output" {
		t.Fatalf("modifyOutput=%q", res.ModifyOutput)
	}
	assertEventRule(t, collector.events, "truncated", "ssh_noise")

	collector.events = nil
	ips := strings.Join([]string{
		`{"app_name":"Demo"}`,
		`  "incident_id": "1",`,
		`  "threads": [`,
		`    {}`,
		`  ]`,
	}, "\n")
	res = runPostToolUse(t, postToolUseInput("Bash", "frida-ps -U", ips, ""))
	if !strings.Contains(res.ModifyOutput, `"threads": [... omitted ...]`) || !strings.Contains(res.ModifyOutput, `[crash log: threads array omitted]`) {
		t.Fatalf("ips output=%q", res.ModifyOutput)
	}
}

func TestPostToolUseGitHintStrip(t *testing.T) {
	_, collector := setupPostToolUseTest(t)
	text := strings.Join([]string{
		"hint: use --rebase",
		"warning: refs/tags/v1",
		"Note: switching to 'abc'",
		"You are in 'detached HEAD' state.",
		"HEAD is now at abc123",
		"If you want to create a new branch to retain commits",
		" (e.g. 'git switch -c <new-branch-name>'), then",
		"Or if you want to keep this update but want to use it",
		" then, discard",
		"actual git output",
	}, "\n")
	res := runPostToolUse(t, postToolUseInput("Bash", "git checkout abc", text, ""))
	if res.ModifyOutput != "actual git output" {
		t.Fatalf("modifyOutput=%q", res.ModifyOutput)
	}
	assertEventRule(t, collector.events, "truncated", "git_hints")
}

func TestPostToolUseQuietOverrideReminders(t *testing.T) {
	home, collector := setupPostToolUseTest(t)
	cases := []struct {
		rule    string
		command string
		want    string
	}{
		{"git_quiet_override", "git commit -q -m x", "[warden: ran as git commit -q — next time include -q yourself]"},
		{"npm_quiet_override", "npm install --silent express", "[warden: ran with --silent — next time use npm install --silent]"},
		{"cargo_quiet_override", "cargo build -q", "[warden: ran as cargo build -q — next time include -q yourself]"},
		{"make_quiet_override", "make -s all", "[warden: ran as make -s — next time include -s yourself]"},
		{"pip_quiet_override", "pip install -q flask", "[warden: ran with -q — next time use pip install -q]"},
		{"wget_quiet_override", "wget -q https://example.com", "[warden: ran as wget -q — next time include -q yourself]"},
		{"docker_quiet_override", "docker build -q .", "[warden: ran with -q — next time use docker build -q]"},
		{"ffmpeg_quiet_override", "ffmpeg -nostats -loglevel error in out", "[warden: ran with -nostats -loglevel error — next time include these flags yourself]"},
		{"curl_sanitized", "curl -sS --max-time 30 https://example.com", "[warden: curl sanitized — added -sS/--max-time, stripped verbose flags]"},
		{"git_diff_bounded", "git diff --no-color | head -200", "[warden: git diff piped through head -200 — use --stat for summary or specify file paths to narrow output]"},
		{"cat_to_head", "head -c 8192 big.txt", "[warden: cat -> head -c 8192 (file too large) — use Read tool with offset/limit for full content]"},
	}
	for i, tc := range cases {
		collector.events = nil
		sid := fmt.Sprintf("sid%d", i)
		writeQuietOverrideStateFile(t, home, "Bash", sid, tc.rule)
		res := runPostToolUse(t, postToolUseInputWithSession("Bash", sid, tc.command, "ok", ""))
		if res.HookSpecificOutput.AdditionalContext != tc.want {
			t.Fatalf("rule=%s got=%q want=%q", tc.rule, res.HookSpecificOutput.AdditionalContext, tc.want)
		}
		if _, err := os.Stat(filepath.Join(home, ".claude", ".statusline", ".quiet-override-Bash-"+sid)); !os.IsNotExist(err) {
			t.Fatalf("quiet override file still exists for %s", tc.rule)
		}
	}
}

func TestPostToolUseRoutingAndThresholds(t *testing.T) {
	_, collector := setupPostToolUseTest(t)
	large := strings.Repeat("a", 11000)
	res := runPostToolUse(t, postToolUseInput("Read", "file.txt", large, ""))
	if !res.Suppress {
		t.Fatalf("main Read should pass through: %#v", res)
	}
	assertEventRule(t, collector.events, "allowed", "")

	collector.events = nil
	res = runPostToolUse(t, postToolUseInput("Read", "file.txt", large, "/work/subagents/agent-a1.jsonl"))
	if res.ModifyOutput == "" {
		t.Fatalf("subagent Read should truncate")
	}
	assertEventRule(t, collector.events, "truncated", "output_truncated")
	assertLastSubagentBytes(t, collector.events, len(res.ModifyOutput))

	collector.events = nil
	exact := strings.Repeat("x", 12288)
	res = runPostToolUse(t, postToolUseInput("Bash", "cat exact.txt", exact, ""))
	if !res.Suppress {
		t.Fatalf("exact threshold should pass through: %#v", res)
	}

	collector.events = nil
	res = runPostToolUse(t, postToolUseInput("Write", "out.txt", strings.Repeat("z", 30000), ""))
	if !res.Suppress {
		t.Fatalf("non-Bash output should pass through: %#v", res)
	}

	collector.events = nil
	res = runPostToolUse(t, postToolUseInput("Bash", "cat huge.txt", strings.Repeat("y", 20000), ""))
	if res.HookSpecificOutput.AdditionalContext != "" || res.ModifyOutput == "" {
		t.Fatalf("missing quiet override should continue to truncation: %#v", res)
	}
}

func TestPostToolUseTaskStructuredExtraction(t *testing.T) {
	_, collector := setupPostToolUseTest(t)
	var b strings.Builder
	for i := 0; i < 220; i++ {
		fmt.Fprintf(&b, "Paragraph %d %s\n- bullet %d\nfile.go:%d detail\n", i, strings.Repeat("x", 30), i, i+1)
	}
	res := runPostToolUse(t, postToolUseInput("Task", "plan", b.String(), ""))
	if !strings.Contains(res.ModifyOutput, "Agent output compressed") || !strings.Contains(res.ModifyOutput, "- bullet 0") {
		t.Fatalf("modifyOutput=%q", res.ModifyOutput)
	}
	assertEventRule(t, collector.events, "truncated", "task_structured")
}

func TestPostToolUseGrepSpecificTruncation(t *testing.T) {
	_, collector := setupPostToolUseTest(t)
	out := strings.Repeat("match line\n", 500)
	res := runPostToolUse(t, postToolUseInput("Bash", "rg needle .", out, ""))
	if !strings.Contains(res.ModifyOutput, "grep output truncated to 5KB") {
		t.Fatalf("modifyOutput=%q", res.ModifyOutput)
	}
	assertEventRule(t, collector.events, "truncated", "grep_truncated")
}

func TestPostToolUseBinarySuppressAndHeadTail(t *testing.T) {
	_, collector := setupPostToolUseTest(t)
	binary := strings.Repeat("a", 13000) + string([]byte{0}) + "tail"
	res := runPostToolUse(t, postToolUseInput("Bash", "cat bin.dat", binary, ""))
	if !strings.Contains(res.ModifyOutput, "[Binary output:") {
		t.Fatalf("binary output=%q", res.ModifyOutput)
	}
	assertEventRule(t, collector.events, "truncated", "binary_output")

	collector.events = nil
	res = runPostToolUse(t, postToolUseInput("Bash", "cat huge.log", strings.Repeat("b", 2*1048576), ""))
	if !strings.Contains(res.ModifyOutput, "[Output too large: 2MB") {
		t.Fatalf("suppressed output=%q", res.ModifyOutput)
	}
	assertEventRule(t, collector.events, "truncated", "output_suppressed")

	collector.events = nil
	res = runPostToolUse(t, postToolUseInput("Bash", "cat big.log", strings.Repeat("c", 20000), ""))
	if !strings.Contains(res.ModifyOutput, "truncated to 10KB") {
		t.Fatalf("truncated output=%q", res.ModifyOutput)
	}
	assertEventRule(t, collector.events, "truncated", "output_truncated")

	collector.events = nil
	res = runPostToolUse(t, postToolUseInput("Bash", "nm a.out", strings.Repeat("d", 20000), ""))
	if res.ModifyOutput == "" || strings.Contains(res.ModifyOutput, "truncated to 10KB") {
		t.Fatalf("head-only output=%q", res.ModifyOutput)
	}
	assertEventRule(t, collector.events, "truncated", "head-only")
}

func setupPostToolUseTest(t *testing.T) (string, *recordedCollector) {
	t.Helper()
	home := t.TempDir()
	withHomeDir(t, home)
	collector := &recordedCollector{}
	prevPoster := newEventPoster
	newEventPoster = func() eventPoster { return collector }
	t.Cleanup(func() { newEventPoster = prevPoster })
	return home, collector
}

func postToolUseInput(tool, commandOrPath, output, transcript string) HookInput {
	return postToolUseInputWithSession(tool, "sid", commandOrPath, output, transcript)
}

func postToolUseInputWithSession(tool, sid, commandOrPath, output, transcript string) HookInput {
	input := HookInput{SessionID: sid, ToolName: tool, TranscriptPath: transcript}
	switch tool {
	case "Read", "Write":
		input.ToolInput = marshalRaw(map[string]string{"file_path": commandOrPath})
	default:
		input.ToolInput = marshalRaw(map[string]string{"command": commandOrPath})
	}
	input.ToolResponse.Content = []ToolResponseBlock{{Text: output}}
	return input
}

func runPostToolUse(t *testing.T, input HookInput) postToolUseResult {
	t.Helper()
	out, code := handlePostToolUse(input)
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(out) == 0 {
		return postToolUseResult{}
	}
	var res postToolUseResult
	if err := json.Unmarshal(out, &res); err != nil {
		t.Fatalf("unmarshal %s: %v", out, err)
	}
	return res
}

func marshalRaw(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

func writeQuietOverrideStateFile(t *testing.T, home, tool, sid, rule string) {
	t.Helper()
	dir := filepath.Join(home, ".claude", ".statusline")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf(".quiet-override-%s-%s", tool, sid)), []byte(rule), 0o644); err != nil {
		t.Fatal(err)
	}
}

func assertEventRule(t *testing.T, events []map[string]any, eventType, rule string) {
	t.Helper()
	for _, evt := range events {
		if evt["event_type"] == eventType {
			if rule == "" || evt["rule"] == rule {
				return
			}
		}
	}
	t.Fatalf("events=%#v want event_type=%q rule=%q", events, eventType, rule)
}

func assertLastSubagentBytes(t *testing.T, events []map[string]any, want int) {
	t.Helper()
	if len(events) == 0 {
		t.Fatalf("no events")
	}
	last := events[len(events)-1]
	if last["event_type"] != "subagent_bytes" || int(last["bytes"].(float64)) != want {
		t.Fatalf("last event=%#v want subagent_bytes=%d", last, want)
	}
}
