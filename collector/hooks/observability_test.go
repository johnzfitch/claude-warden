package hooks

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type preCompactResult struct {
	SystemMessage string `json:"systemMessage"`
}

func TestToolErrorObservability(t *testing.T) {
	t.Run("permission denied logs event and hint", func(t *testing.T) {
		home, collector := setupObservabilityTest(t)
		cwd := t.TempDir()
		withChdir(t, cwd)

		out, code, stderr := runToolError(t, HookInput{ToolName: "Bash", SessionID: "abc123", ToolError: "permission denied: /root/secret"})
		if code != 0 || len(out) != 0 {
			t.Fatalf("code=%d out=%q", code, out)
		}
		if strings.TrimSpace(stderr) != "Hint: May need sudo or file permissions check" {
			t.Fatalf("stderr=%q", stderr)
		}

		log := readFile(t, filepath.Join(home, ".claude", "errors.log"))
		for _, want := range []string{"Time: ", "Tool: Bash", "Error: permission denied: /root/secret", "PWD: " + cwd, "Git: "} {
			if !strings.Contains(log, want) {
				t.Fatalf("log=%q missing %q", log, want)
			}
		}

		if len(collector.events) != 1 {
			t.Fatalf("events=%#v", collector.events)
		}
		evt := collector.events[0]
		if evt["event_type"] != "tool_error" || evt["tool_name"] != "Bash" || evt["session_id"] != "abc123" || evt["error_message"] != "permission denied: /root/secret" {
			t.Fatalf("event=%#v", evt)
		}
	})

	t.Run("command not found hint", func(t *testing.T) {
		_, _ = setupObservabilityTest(t)
		_, code, stderr := runToolError(t, HookInput{ToolName: "Bash", ToolError: "command not found: foo"})
		if code != 0 {
			t.Fatalf("code=%d", code)
		}
		if strings.TrimSpace(stderr) != "Hint: Check if command is installed or PATH is set" {
			t.Fatalf("stderr=%q", stderr)
		}
	})

	t.Run("read-only hint only for edit write", func(t *testing.T) {
		_, _ = setupObservabilityTest(t)
		_, code, stderr := runToolError(t, HookInput{ToolName: "Write", ToolError: "read-only file system"})
		if code != 0 {
			t.Fatalf("code=%d", code)
		}
		if strings.TrimSpace(stderr) != "Hint: File may be read-only or in a protected directory" {
			t.Fatalf("stderr=%q", stderr)
		}
	})

	t.Run("error fallback scrubbing and truncation", func(t *testing.T) {
		_, collector := setupObservabilityTest(t)
		_, code, stderr := runToolError(t, HookInput{ToolName: "Bash", SessionID: "../bad", Error: "api_key=secret " + strings.Repeat("x", 300)})
		if code != 0 || stderr != "" {
			t.Fatalf("code=%d stderr=%q", code, stderr)
		}
		evt := collector.events[0]
		msg := evt["error_message"].(string)
		if evt["session_id"] != "" {
			t.Fatalf("session_id=%q want empty", evt["session_id"])
		}
		if len(msg) > 200 {
			t.Fatalf("len(error_message)=%d want <= 200", len(msg))
		}
		if !strings.Contains(msg, "[REDACTED]") || strings.Contains(msg, "secret") {
			t.Fatalf("error_message=%q", msg)
		}
	})

	t.Run("empty error becomes unknown error", func(t *testing.T) {
		_, collector := setupObservabilityTest(t)
		_, code, _ := runToolError(t, HookInput{ToolName: "Bash"})
		if code != 0 {
			t.Fatalf("code=%d", code)
		}
		if collector.events[0]["error_message"] != "unknown error" {
			t.Fatalf("event=%#v", collector.events[0])
		}
	})

	t.Run("rotates error log at over 1500 lines", func(t *testing.T) {
		home, _ := setupObservabilityTest(t)
		path := filepath.Join(home, ".claude", "errors.log")
		var b strings.Builder
		for i := 0; i < 1501; i++ {
			b.WriteString("line\n")
		}
		writeFile(t, path, b.String())

		_, code, _ := runToolError(t, HookInput{ToolName: "Bash", ToolError: "permission denied"})
		if code != 0 {
			t.Fatalf("code=%d", code)
		}
		if got := countLines(readFile(t, path)); got != 1000 {
			t.Fatalf("line count=%d want 1000", got)
		}
		if !strings.Contains(readFile(t, path), "Tool: Bash") {
			t.Fatalf("rotated log missing appended entry")
		}
	})
}

func TestElicitationObservability(t *testing.T) {
	t.Run("sanitizes and scrubs message", func(t *testing.T) {
		_, collector := setupObservabilityTest(t)
		out, code := handleElicitation(HookInput{SessionID: "sid", MCPServerName: "server", Mode: "form", ElicitationID: "uuid-1", Message: "Bearer abc api_key=xyz"})
		if code != 0 || len(out) != 0 {
			t.Fatalf("code=%d out=%q", code, out)
		}
		evt := collector.events[0]
		if evt["event_type"] != "elicitation" || evt["mcp_server"] != "server" || evt["mode"] != "form" || evt["elicitation_id"] != "uuid-1" {
			t.Fatalf("event=%#v", evt)
		}
		msg := evt["message"].(string)
		if !strings.Contains(msg, "[REDACTED]") || strings.Contains(msg, "abc") || strings.Contains(msg, "xyz") {
			t.Fatalf("message=%q", msg)
		}
	})

	t.Run("invalid server id is sanitized", func(t *testing.T) {
		_, collector := setupObservabilityTest(t)
		_, code := handleElicitation(HookInput{MCPServerName: "bad/server"})
		if code != 0 {
			t.Fatalf("code=%d", code)
		}
		if collector.events[0]["mcp_server"] != "" {
			t.Fatalf("event=%#v", collector.events[0])
		}
	})
}

func TestElicitationResultObservability(t *testing.T) {
	t.Run("counts object fields", func(t *testing.T) {
		_, collector := setupObservabilityTest(t)
		out, code := handleElicitationResult(HookInput{MCPServerName: "server", ElicitationID: "uuid", Action: "accept", Mode: "form", Content: mustRawJSON(t, map[string]string{"field1": "value1", "field2": "value2"})})
		if code != 0 || len(out) != 0 {
			t.Fatalf("code=%d out=%q", code, out)
		}
		evt := collector.events[0]
		if evt["event_type"] != "elicitation_result" || evt["content_fields"] != float64(2) {
			t.Fatalf("event=%#v", evt)
		}
	})

	t.Run("non-object content counts as zero", func(t *testing.T) {
		_, collector := setupObservabilityTest(t)
		_, code := handleElicitationResult(HookInput{Content: mustRawJSON(t, []string{"a"})})
		if code != 0 {
			t.Fatalf("code=%d", code)
		}
		if collector.events[0]["content_fields"] != float64(0) {
			t.Fatalf("event=%#v", collector.events[0])
		}
	})
}

func TestInstructionsLoadedObservability(t *testing.T) {
	t.Run("counts globs", func(t *testing.T) {
		_, collector := setupObservabilityTest(t)
		out, code := handleInstructionsLoaded(HookInput{FilePath: `/home/user/.claude/CLAUDE.md`, MemoryType: "User", LoadReason: "session_start", Globs: []string{"*.md", "*.txt"}})
		if code != 0 || len(out) != 0 {
			t.Fatalf("code=%d out=%q", code, out)
		}
		evt := collector.events[0]
		if evt["event_type"] != "instructions_loaded" || evt["glob_count"] != float64(2) || evt["file_path"] != "/home/user/.claude/CLAUDE.md" {
			t.Fatalf("event=%#v", evt)
		}
	})

	t.Run("empty globs count as zero", func(t *testing.T) {
		_, collector := setupObservabilityTest(t)
		_, code := handleInstructionsLoaded(HookInput{})
		if code != 0 {
			t.Fatalf("code=%d", code)
		}
		if collector.events[0]["glob_count"] != float64(0) {
			t.Fatalf("event=%#v", collector.events[0])
		}
	})
}

func TestPreCompactObservability(t *testing.T) {
	t.Run("collector available summary includes counts and budget", func(t *testing.T) {
		home, collector := setupObservabilityTest(t)
		setSessionNow(t, time.Unix(1000, 0))
		writeFile(t, filepath.Join(home, ".claude", ".session-times", "abc123.start"), "100\n")
		writeFile(t, filepath.Join(home, ".claude", ".statusline", ".session_start-abc123"), "100.0\n")
		writeFile(t, filepath.Join(home, ".claude", ".warden", "budget.state"), "450\n")
		setEnvValue(t, "WARDEN_BUDGET_TOTAL", "1000")

		socketPath := filepath.Join(t.TempDir(), "collector.sock")
		requests := startContextServer(t, socketPath, "/v1/sessions/abc123/context", `{"tool_count":42,"subagent_count":2}`)
		setEnvValue(t, "WARDEN_COLLECTOR_SOCK", socketPath)

		out, code := handlePreCompact(HookInput{SessionID: "abc123"})
		if code != 0 {
			t.Fatalf("code=%d", code)
		}
		var res preCompactResult
		if err := json.Unmarshal(out, &res); err != nil {
			t.Fatalf("unmarshal %s: %v", out, err)
		}
		want := "[Warden Session State]\n- Tool calls: 42\n- Duration: 15m\n- Active subagents: 2\n- Budget: 45% (450/1000)"
		if res.SystemMessage != want {
			t.Fatalf("systemMessage=%q want %q", res.SystemMessage, want)
		}
		if len(*requests) != 1 || (*requests)[0] != "GET /v1/sessions/abc123/context" {
			t.Fatalf("requests=%v", *requests)
		}
		evt := collector.events[0]
		if evt["event_type"] != "compaction" || evt["session_id"] != "abc123" || evt["tool_count"] != float64(42) || evt["timestamp"] != float64(900) {
			t.Fatalf("event=%#v", evt)
		}
	})

	t.Run("collector unavailable and missing session start fall back cleanly", func(t *testing.T) {
		_, collector := setupObservabilityTest(t)
		setSessionNow(t, time.Unix(1000, 0))
		unsetEnv(t, "WARDEN_BUDGET_TOTAL")
		setEnvValue(t, "WARDEN_COLLECTOR_SOCK", filepath.Join(t.TempDir(), "missing.sock"))

		out, code := handlePreCompact(HookInput{SessionID: "abc123"})
		if code != 0 {
			t.Fatalf("code=%d", code)
		}
		var res preCompactResult
		if err := json.Unmarshal(out, &res); err != nil {
			t.Fatalf("unmarshal %s: %v", out, err)
		}
		want := "[Warden Session State]\n- Tool calls: 0\n- Duration: unknown\n- Active subagents: 0\n- Budget: 0% (0/0)"
		if res.SystemMessage != want {
			t.Fatalf("systemMessage=%q want %q", res.SystemMessage, want)
		}
		evt := collector.events[0]
		if evt["event_type"] != "compaction" || evt["tool_count"] != float64(0) {
			t.Fatalf("event=%#v", evt)
		}
	})
}

func setupObservabilityTest(t *testing.T) (string, *recordedCollector) {
	t.Helper()
	home := t.TempDir()
	withHomeDir(t, home)
	collector := &recordedCollector{}
	prevPoster := newEventPoster
	newEventPoster = func() eventPoster { return collector }
	t.Cleanup(func() { newEventPoster = prevPoster })
	return home, collector
}

func runToolError(t *testing.T, input HookInput) ([]byte, int, string) {
	t.Helper()
	var out []byte
	var code int
	stderr := captureStderr(t, func() {
		out, code = handleToolError(input)
	})
	return out, code, stderr
}

func startContextServer(t *testing.T, socketPath, wantPath, response string) *[]string {
	t.Helper()
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		skipIfUnixSocketUnavailable(t, err)
		t.Fatal(err)
	}
	requests := make([]string, 0, 1)
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests = append(requests, r.Method+" "+r.URL.Path)
		if r.Method != http.MethodGet || r.URL.Path != wantPath {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = io.WriteString(w, response)
	})}
	go server.Serve(ln)
	t.Cleanup(func() {
		_ = server.Close()
		_ = ln.Close()
		_ = os.Remove(socketPath)
	})
	return &requests
}

func setEnvValue(t *testing.T, key, value string) {
	t.Helper()
	prev, ok := os.LookupEnv(key)
	if err := os.Setenv(key, value); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if ok {
			_ = os.Setenv(key, prev)
		} else {
			_ = os.Unsetenv(key)
		}
	})
}
