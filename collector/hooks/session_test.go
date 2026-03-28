package hooks

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type sessionStartResult struct {
	HookSpecificOutput struct {
		HookEventName     string `json:"hookEventName"`
		AdditionalContext string `json:"additionalContext"`
	} `json:"hookSpecificOutput"`
}

type stopResult struct {
	StopHookSummary string `json:"stop_hook_summary"`
}

func TestSessionStartGitContextAndFiles(t *testing.T) {
	home, collector := setupSessionTest(t)
	now := time.Unix(220, 123456789)
	setSessionNow(t, now)

	if err := os.Setenv("WARDEN_BUDGET_TOTAL", "1000"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Unsetenv("WARDEN_BUDGET_TOTAL") })

	if err := os.MkdirAll(filepath.Join(home, ".claude", ".warden"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".claude", ".warden", "budget.state"), []byte("25\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	repo := t.TempDir()
	initGitRepo(t, repo)
	writeAndCommitFile(t, repo, "note.txt", "hello\n", "fix typo")
	if err := os.WriteFile(filepath.Join(repo, "note.txt"), []byte("hello\nworld\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "new.txt"), []byte("new\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	withChdir(t, repo)

	out, code := handleSessionStart(HookInput{SessionID: "abc123"})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}

	var res sessionStartResult
	if err := json.Unmarshal(out, &res); err != nil {
		t.Fatalf("unmarshal %s: %v", out, err)
	}
	if res.HookSpecificOutput.HookEventName != "SessionStart" {
		t.Fatalf("hook=%q", res.HookSpecificOutput.HookEventName)
	}
	if !strings.Contains(res.HookSpecificOutput.AdditionalContext, "[Git] main (2 dirty), last: ") {
		t.Fatalf("additionalContext=%q", res.HookSpecificOutput.AdditionalContext)
	}
	if !strings.Contains(res.HookSpecificOutput.AdditionalContext, "fix typo") {
		t.Fatalf("additionalContext=%q", res.HookSpecificOutput.AdditionalContext)
	}

	assertFileEquals(t, filepath.Join(home, ".claude", ".session-times", "abc123.start"), "220\n")
	assertFileEquals(t, filepath.Join(home, ".claude", ".statusline", ".session_start-abc123"), "220.123456789\n")

	var budget budgetState
	readJSONFile(t, sessionBudgetSnapshotPath("abc123"), &budget)
	if budget.Consumed != 25 || budget.Limit != 1000 || budget.TotalLimit != 1000 || budget.Utilization != 2 {
		t.Fatalf("budget=%+v", budget)
	}

	agentStats := readFile(t, filepath.Join(home, ".claude", "agent-stats.csv"))
	if !strings.Contains(agentStats, "timestamp,agent_id,agent_category,agent_type,duration_seconds,session_id,status") {
		t.Fatalf("agent-stats missing header: %q", agentStats)
	}
	if !strings.Contains(agentStats, "terminal-abc123,terminal,main,0,abc123,started") {
		t.Fatalf("agent-stats missing started row: %q", agentStats)
	}

	if len(collector.events) != 1 {
		t.Fatalf("events=%#v", collector.events)
	}
	evt := collector.events[0]
	if evt["event_type"] != "session_start" || evt["session_id"] != "abc123" || evt["cwd"] != repo || evt["session_label"] != filepath.Base(repo)+" (abc123)" {
		t.Fatalf("event=%#v", evt)
	}
}

func TestSessionStartNoGitContext(t *testing.T) {
	home, collector := setupSessionTest(t)
	now := time.Unix(220, 0)
	setSessionNow(t, now)
	withChdir(t, t.TempDir())

	out, code := handleSessionStart(HookInput{SessionID: "sid123"})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(out) != 0 {
		t.Fatalf("out=%q want empty", out)
	}
	assertFileEquals(t, filepath.Join(home, ".claude", ".session-times", "sid123.start"), "220\n")
	if len(collector.events) != 1 || collector.events[0]["event_type"] != "session_start" {
		t.Fatalf("events=%#v", collector.events)
	}
}

func TestSessionStartSanitizesSessionID(t *testing.T) {
	home, collector := setupSessionTest(t)
	withChdir(t, t.TempDir())

	out, code := handleSessionStart(HookInput{SessionID: "../bad"})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(out) != 0 {
		t.Fatalf("out=%q want empty", out)
	}
	if _, err := os.Stat(filepath.Join(home, ".claude", ".session-times")); !os.IsNotExist(err) {
		t.Fatalf("session-times dir should not exist; err=%v", err)
	}
	if len(collector.events) != 0 {
		t.Fatalf("events=%#v want none", collector.events)
	}
}

func TestSessionEndDurationBudgetCleanupAndResetReason(t *testing.T) {
	home, collector := setupSessionTest(t)
	now := time.Unix(220, 0)
	setSessionNow(t, now)
	cwd := t.TempDir()
	withChdir(t, cwd)

	writeFile(t, filepath.Join(home, ".claude", ".session-times", "abc123.start"), "100\n")
	writeFile(t, filepath.Join(home, ".claude", ".statusline", ".session_start-abc123"), "100.0\n")

	writeFile(t, agentStatsCSVPath(), strings.Join([]string{
		"timestamp,agent_id,agent_category,agent_type,duration_seconds,session_id,status",
		"2026-03-27T00:00:00Z,agent-1,subagent,Explore,5,abc123,completed",
		"2026-03-27T00:00:00Z,agent-2,subagent,Explore,5,other,completed",
	}, "\n")+"\n")

	writeFile(t, filepath.Join(home, ".claude", ".warden", "budget.state"), "90\n")
	writeJSONFile(t, sessionBudgetSnapshotPath("abc123"), budgetState{Consumed: 40, Limit: 1000, TotalLimit: 1000, Utilization: 4})

	writeFile(t, filepath.Join(home, ".claude", ".subagent-state", "agent1"), "SESSION_ID=abc123\n")
	writeFile(t, filepath.Join(home, ".claude", ".subagent-state", "agent1.start"), "1\n")
	writeFile(t, filepath.Join(home, ".claude", ".subagent-state", "agent2"), "SESSION_ID=other\n")
	writeFile(t, filepath.Join(home, ".claude", ".subagent-state", "agent2.start"), "1\n")

	writeFile(t, filepath.Join(home, ".claude", ".statusline", "subagent-count-abc123"), "1\n")
	writeFile(t, filepath.Join(home, ".claude", ".statusline", ".tool-start-1-abc123"), "1\n")
	writeFile(t, filepath.Join(home, ".claude", ".statusline", ".quiet-override-Bash-abc123"), "1\n")
	writeFile(t, filepath.Join(home, ".claude", ".statusline", "session-abc123"), "1\n")
	writeFile(t, filepath.Join(home, ".claude", ".statusline", "session-abc123.lock"), "1\n")
	writeFile(t, filepath.Join(home, ".claude", ".statusline", "subagent-count-abc123.lock"), "1\n")
	mustMkdirAll(t, filepath.Join(home, ".claude", ".statusline", "session-abc123.lock.d"))
	mustMkdirAll(t, filepath.Join(home, ".claude", ".statusline", "subagent-count-abc123.lock.d"))

	writeFile(t, filepath.Join(home, ".claude", ".statusline", ".tool-start-1-other"), "1\n")
	writeFile(t, filepath.Join(home, ".claude", ".statusline", ".quiet-override-Bash-other"), "1\n")
	writeFile(t, filepath.Join(home, ".claude", ".statusline", "session-other"), "1\n")

	old := now.Add(-25 * time.Hour)
	recent := now.Add(-30 * time.Minute)
	for _, name := range []string{
		"tool-count-old",
		"tool-top-old",
		"session-old",
		"state-old",
		".tool-start-old",
		".quiet-override-old",
		"clears-old",
		"peak-old",
		".session_start-old",
		"subagent-count-old",
	} {
		writeFileAt(t, filepath.Join(home, ".claude", ".statusline", name), "x\n", old)
	}
	writeFileAt(t, filepath.Join(home, ".claude", ".statusline", "tool-count-fresh"), "x\n", recent)
	writeFileAt(t, filepath.Join(home, ".claude", ".statusline", "stale.lock"), "x\n", now.Add(-61*time.Minute))
	writeFileAt(t, filepath.Join(home, ".claude", ".subagent-state", "old-agent"), "SESSION_ID=stale\n", old)
	writeFileAt(t, filepath.Join(home, ".claude", ".subagent-state", "old-agent.start"), "1\n", old)
	mkdirAt(t, filepath.Join(home, ".claude", ".statusline", "stale.lock.d"), now.Add(-61*time.Minute))

	promPath := filepath.Join(home, ".claude", ".monitoring", "textfile", "claude-code-session-abc123.prom")
	writeFile(t, promPath, "metric 1\n")
	writeFile(t, promPath+".tombstone", "1\n")

	out, code := handleSessionEnd(HookInput{SessionID: "abc123", Reason: "bypass_permissions_disabled"})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(out) != 0 {
		t.Fatalf("out=%q want empty", out)
	}

	agentStats := readFile(t, agentStatsCSVPath())
	if !strings.Contains(agentStats, "terminal-abc123,terminal,main,120,abc123,completed") {
		t.Fatalf("agent-stats=%q", agentStats)
	}

	if len(collector.events) != 1 {
		t.Fatalf("events=%#v", collector.events)
	}
	evt := collector.events[0]
	if evt["event_type"] != "session_end" || evt["session_id"] != "abc123" || evt["duration_seconds"] != float64(120) || evt["timestamp"] != float64(120) {
		t.Fatalf("event=%#v", evt)
	}

	costs := readFile(t, sessionCostsCSVPath())
	if !strings.Contains(costs, "timestamp,session_id,duration_seconds,budget_start,budget_end,budget_delta,subagent_count") {
		t.Fatalf("session-costs header missing: %q", costs)
	}
	if !strings.Contains(costs, ",abc123,120,40,90,50,1") {
		t.Fatalf("session-costs row missing: %q", costs)
	}
	if _, err := os.Stat(sessionBudgetSnapshotPath("abc123")); !os.IsNotExist(err) {
		t.Fatalf("budget snapshot still exists: %v", err)
	}

	assertNotExists(t, filepath.Join(home, ".claude", ".subagent-state", "agent1"))
	assertNotExists(t, filepath.Join(home, ".claude", ".subagent-state", "agent1.start"))
	assertExists(t, filepath.Join(home, ".claude", ".subagent-state", "agent2"))
	assertExists(t, filepath.Join(home, ".claude", ".subagent-state", "agent2.start"))

	for _, name := range []string{
		"tool-count-old",
		"tool-top-old",
		"session-old",
		"state-old",
		".tool-start-old",
		".quiet-override-old",
		"clears-old",
		"peak-old",
		".session_start-old",
		"subagent-count-old",
		"stale.lock",
	} {
		assertNotExists(t, filepath.Join(home, ".claude", ".statusline", name))
	}
	assertNotExists(t, filepath.Join(home, ".claude", ".statusline", "stale.lock.d"))
	assertExists(t, filepath.Join(home, ".claude", ".statusline", "tool-count-fresh"))
	assertNotExists(t, filepath.Join(home, ".claude", ".subagent-state", "old-agent"))
	assertNotExists(t, filepath.Join(home, ".claude", ".subagent-state", "old-agent.start"))

	logText := readFile(t, filepath.Join(home, ".claude", "session-log.txt"))
	if !strings.Contains(logText, "Session ended: abc123 (duration: 2m, dir: "+cwd+", reason: bypass mode disabled)") {
		t.Fatalf("session-log=%q", logText)
	}
	assertFileEquals(t, filepath.Join(home, ".claude", ".statusline", "reset-reason"), "220|bypass mode disabled|abc123\n")

	for _, path := range []string{
		filepath.Join(home, ".claude", ".statusline", ".session_start-abc123"),
		filepath.Join(home, ".claude", ".statusline", "subagent-count-abc123"),
		filepath.Join(home, ".claude", ".statusline", ".tool-start-1-abc123"),
		filepath.Join(home, ".claude", ".statusline", ".quiet-override-Bash-abc123"),
		filepath.Join(home, ".claude", ".statusline", "session-abc123"),
		filepath.Join(home, ".claude", ".statusline", "session-abc123.lock"),
		filepath.Join(home, ".claude", ".statusline", "subagent-count-abc123.lock"),
		filepath.Join(home, ".claude", ".statusline", "session-abc123.lock.d"),
		filepath.Join(home, ".claude", ".statusline", "subagent-count-abc123.lock.d"),
		promPath,
		promPath + ".tombstone",
	} {
		assertNotExists(t, path)
	}
	assertExists(t, filepath.Join(home, ".claude", ".statusline", ".tool-start-1-other"))
	assertExists(t, filepath.Join(home, ".claude", ".statusline", ".quiet-override-Bash-other"))
	assertExists(t, filepath.Join(home, ".claude", ".statusline", "session-other"))
}

func TestSessionEndUnknownDurationAndMissingBudgetSkipDelta(t *testing.T) {
	home, collector := setupSessionTest(t)
	setSessionNow(t, time.Unix(220, 0))
	withChdir(t, t.TempDir())

	out, code := handleSessionEnd(HookInput{SessionID: "missing", Reason: "user_cancelled"})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(out) != 0 {
		t.Fatalf("out=%q want empty", out)
	}
	if len(collector.events) != 0 {
		t.Fatalf("events=%#v want none", collector.events)
	}
	logText := readFile(t, filepath.Join(home, ".claude", "session-log.txt"))
	if !strings.Contains(logText, "Session ended: missing (duration: unknown") {
		t.Fatalf("session-log=%q", logText)
	}
	if _, err := os.Stat(sessionCostsCSVPath()); !os.IsNotExist(err) {
		t.Fatalf("session-costs should not exist: %v", err)
	}
}

func TestSessionEndMissingBudgetSnapshotSkipsCostLog(t *testing.T) {
	home, collector := setupSessionTest(t)
	setSessionNow(t, time.Unix(220, 0))
	withChdir(t, t.TempDir())

	writeFile(t, filepath.Join(home, ".claude", ".session-times", "abc123.start"), "100\n")
	writeFile(t, filepath.Join(home, ".claude", ".statusline", ".session_start-abc123"), "100.0\n")

	out, code := handleSessionEnd(HookInput{SessionID: "abc123", Reason: "user_cancelled"})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(out) != 0 {
		t.Fatalf("out=%q want empty", out)
	}
	if len(collector.events) != 1 || collector.events[0]["event_type"] != "session_end" {
		t.Fatalf("events=%#v", collector.events)
	}
	if _, err := os.Stat(sessionCostsCSVPath()); !os.IsNotExist(err) {
		t.Fatalf("session-costs should not exist: %v", err)
	}
}

func TestStopActiveImmediate(t *testing.T) {
	home, collector := setupSessionTest(t)

	out, code := handleStop(HookInput{SessionID: "abc123", StopHookActive: true})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(out) != 0 {
		t.Fatalf("out=%q want empty", out)
	}
	if len(collector.events) != 0 {
		t.Fatalf("events=%#v want none", collector.events)
	}
	if _, err := os.Stat(filepath.Join(home, ".claude", "session-log.txt")); !os.IsNotExist(err) {
		t.Fatalf("session-log should not exist: %v", err)
	}
}

func TestStopSummaryAndUnknownDuration(t *testing.T) {
	t.Run("duration from start file", func(t *testing.T) {
		home, collector := setupSessionTest(t)
		setSessionNow(t, time.Unix(220, 0))
		withChdir(t, t.TempDir())

		writeFile(t, filepath.Join(home, ".claude", ".session-times", "abc123.start"), "100\n")
		writeFile(t, filepath.Join(home, ".claude", ".statusline", ".session_start-abc123"), "100.0\n")

		out, code := handleStop(HookInput{SessionID: "abc123", Reason: "user_cancelled", ToolName: "Bash"})
		if code != 0 {
			t.Fatalf("code=%d want 0", code)
		}

		var res stopResult
		if err := json.Unmarshal(out, &res); err != nil {
			t.Fatalf("unmarshal %s: %v", out, err)
		}
		if res.StopHookSummary != "Session: 120s | reason: user_cancelled" {
			t.Fatalf("summary=%q", res.StopHookSummary)
		}

		logText := readFile(t, filepath.Join(home, ".claude", "session-log.txt"))
		if !strings.Contains(logText, "Stop: user_cancelled (tool: Bash, duration: 120s)") {
			t.Fatalf("session-log=%q", logText)
		}
		if len(collector.events) != 1 {
			t.Fatalf("events=%#v", collector.events)
		}
		evt := collector.events[0]
		if evt["event_type"] != "session_stop" || evt["duration_seconds"] != float64(120) || evt["timestamp"] != float64(120) {
			t.Fatalf("event=%#v", evt)
		}
	})

	t.Run("missing start file", func(t *testing.T) {
		home, collector := setupSessionTest(t)
		setSessionNow(t, time.Unix(220, 0))
		withChdir(t, t.TempDir())

		out, code := handleStop(HookInput{SessionID: "missing", Reason: "user_cancelled"})
		if code != 0 {
			t.Fatalf("code=%d want 0", code)
		}

		var res stopResult
		if err := json.Unmarshal(out, &res); err != nil {
			t.Fatalf("unmarshal %s: %v", out, err)
		}
		if res.StopHookSummary != "Session: unknown | reason: user_cancelled" {
			t.Fatalf("summary=%q", res.StopHookSummary)
		}

		logText := readFile(t, filepath.Join(home, ".claude", "session-log.txt"))
		if !strings.Contains(logText, "Stop: user_cancelled (duration: unknown)") {
			t.Fatalf("session-log=%q", logText)
		}
		if len(collector.events) != 1 || collector.events[0]["duration_seconds"] != float64(0) {
			t.Fatalf("events=%#v", collector.events)
		}
	})
}

func setupSessionTest(t *testing.T) (home string, collector *recordedCollector) {
	t.Helper()
	home = t.TempDir()
	withHomeDir(t, home)
	collector = &recordedCollector{}
	prevPoster := newEventPoster
	newEventPoster = func() eventPoster { return collector }
	t.Cleanup(func() { newEventPoster = prevPoster })
	return home, collector
}

func setSessionNow(t *testing.T, now time.Time) {
	t.Helper()
	prevNow := timeNow
	timeNow = func() time.Time { return now }
	t.Cleanup(func() { timeNow = prevNow })
}

func withChdir(t *testing.T, dir string) {
	t.Helper()
	prev, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.Chdir(prev)
	})
}

func initGitRepo(t *testing.T, dir string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	runCmd(t, dir, "git", "init")
	runCmd(t, dir, "git", "config", "user.email", "test@example.com")
	runCmd(t, dir, "git", "config", "user.name", "Test")
	runCmd(t, dir, "git", "checkout", "-b", "main")
}

func writeAndCommitFile(t *testing.T, dir, name, content, message string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	runCmd(t, dir, "git", "add", name)
	runCmd(t, dir, "git", "commit", "-m", message)
}

func runCmd(t *testing.T, dir, name string, args ...string) {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%s %v: %v\n%s", name, args, err, out)
	}
}

func writeJSONFile(t *testing.T, path string, v any) {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, path, string(b))
}

func readJSONFile(t *testing.T, path string, v any) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, v); err != nil {
		t.Fatalf("unmarshal %s: %v", path, err)
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeFileAt(t *testing.T, path, content string, modTime time.Time) {
	t.Helper()
	writeFile(t, path, content)
	if err := os.Chtimes(path, modTime, modTime); err != nil {
		t.Fatal(err)
	}
}

func mkdirAt(t *testing.T, path string, modTime time.Time) {
	t.Helper()
	mustMkdirAll(t, path)
	if err := os.Chtimes(path, modTime, modTime); err != nil {
		t.Fatal(err)
	}
}

func mustMkdirAll(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func assertFileEquals(t *testing.T, path, want string) {
	t.Helper()
	if got := readFile(t, path); got != want {
		t.Fatalf("%s = %q want %q", path, got, want)
	}
}

func assertExists(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("%s missing: %v", path, err)
	}
}

func assertNotExists(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("%s exists or unexpected err: %v", path, err)
	}
}
