package hooks

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func init() {
	hookHandlers["tool-error"] = handleToolError
	hookHandlers["elicitation"] = handleElicitation
	hookHandlers["elicitation-result"] = handleElicitationResult
	hookHandlers["instructions-loaded"] = handleInstructionsLoaded
	hookHandlers["pre-compact"] = handlePreCompact
}

func handleToolError(input HookInput) ([]byte, int) {
	toolName := sanitizeID(input.ToolName)
	if toolName == "" {
		toolName = "unknown"
	}
	sessionID := sanitizeID(input.SessionID)
	errorMessage := firstNonEmpty(input.ToolError, input.Error)
	if errorMessage == "" {
		errorMessage = "unknown error"
	}

	appendToolErrorLog(toolName, errorMessage)
	rotateErrorLogIfNeeded(errorLogPath())
	emitToolErrorHint(toolName, errorMessage)

	postJSONEvent(newEventPoster(), map[string]any{
		"timestamp":     relativeTimestamp(resolveSessionStart(sessionID)),
		"event_type":    "tool_error",
		"tool_name":     toolName,
		"session_id":    sessionID,
		"error_message": truncateString(scrubSecrets(errorMessage), 200),
	})
	return nil, 0
}

func handleElicitation(input HookInput) ([]byte, int) {
	mcpServer := sanitizeID(defaultIfEmpty(input.MCPServerName, "unknown"))
	mode := scrubSecrets(defaultIfEmpty(input.Mode, "form"))
	elicitationID := scrubSecrets(input.ElicitationID)
	message := scrubSecrets(input.Message)

	postJSONEvent(newEventPoster(), map[string]any{
		"timestamp":      relativeTimestamp(resolveSessionStart(input.SessionID)),
		"event_type":     "elicitation",
		"mcp_server":     mcpServer,
		"mode":           mode,
		"elicitation_id": elicitationID,
		"message":        message,
	})
	return nil, 0
}

func handleElicitationResult(input HookInput) ([]byte, int) {
	mcpServer := sanitizeID(defaultIfEmpty(input.MCPServerName, "unknown"))
	elicitationID := scrubSecrets(input.ElicitationID)
	action := scrubSecrets(defaultIfEmpty(input.Action, "unknown"))
	mode := scrubSecrets(defaultIfEmpty(input.Mode, "form"))

	postJSONEvent(newEventPoster(), map[string]any{
		"timestamp":      relativeTimestamp(resolveSessionStart(input.SessionID)),
		"event_type":     "elicitation_result",
		"mcp_server":     mcpServer,
		"elicitation_id": elicitationID,
		"action":         action,
		"mode":           mode,
		"content_fields": contentFieldCount(input.Content),
	})
	return nil, 0
}

func handleInstructionsLoaded(input HookInput) ([]byte, int) {
	postJSONEvent(newEventPoster(), map[string]any{
		"timestamp":   relativeTimestamp(resolveSessionStart(input.SessionID)),
		"event_type":  "instructions_loaded",
		"file_path":   scrubSecrets(defaultIfEmpty(input.FilePath, "unknown")),
		"memory_type": scrubSecrets(defaultIfEmpty(input.MemoryType, "unknown")),
		"load_reason": scrubSecrets(defaultIfEmpty(input.LoadReason, "unknown")),
		"glob_count":  len(input.Globs),
	})
	return nil, 0
}

func handlePreCompact(input HookInput) ([]byte, int) {
	sessionID := sanitizeID(input.SessionID)
	sessionStartS := resolveSessionStart(sessionID)
	toolCount, subagentCount := fetchSessionContext(sessionID)
	durationText := preCompactDurationText(sessionID)
	budget := currentPreCompactBudgetState()

	summary := fmt.Sprintf("[Warden Session State]\n- Tool calls: %d\n- Duration: %s\n- Active subagents: %d\n- Budget: %d%% (%d/%d)",
		toolCount, durationText, subagentCount, budget.Utilization, budget.Consumed, budget.TotalLimit)

	postJSONEvent(newEventPoster(), map[string]any{
		"timestamp":  relativeTimestamp(sessionStartS),
		"event_type": "compaction",
		"session_id": sessionID,
		"tool_count": toolCount,
	})
	return SystemMessage(summary), 0
}

func errorLogPath() string {
	return filepath.Join(homeDir(), ".claude", "errors.log")
}

func appendToolErrorLog(toolName, errorMessage string) {
	path := errorLogPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}

	cwd, err := os.Getwd()
	if err != nil {
		cwd = ""
	}
	branch := gitBranchForErrorLog(cwd)

	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()

	_, _ = fmt.Fprintf(f, "=== Tool Error ===\nTime: %s\nTool: %s\nError: %s\nPWD: %s\nGit: %s\n\n",
		timeNow().Format(time.RFC3339), toolName, errorMessage, cwd, branch)
}

func gitBranchForErrorLog(dir string) string {
	if dir == "" {
		return "N/A"
	}
	cmd := execCommand("git", "symbolic-ref", "--short", "HEAD")
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return "N/A"
	}
	branch := strings.TrimSpace(string(out))
	if branch == "" {
		return "N/A"
	}
	return branch
}

func rotateErrorLogIfNeeded(path string) {
	lineCount, err := fileLineCount(path)
	if err != nil || lineCount <= 1500 {
		return
	}

	lines, err := readLastLines(path, 1000)
	if err != nil {
		return
	}

	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".")
	if err != nil {
		return
	}
	tmpPath := tmp.Name()
	defer func() {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
	}()

	content := strings.Join(lines, "\n")
	if content != "" {
		content += "\n"
	}
	if _, err := tmp.WriteString(content); err != nil {
		return
	}
	if err := tmp.Close(); err != nil {
		return
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return
	}
	_ = os.Remove(tmpPath)
}

func fileLineCount(path string) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()

	s := bufio.NewScanner(f)
	count := 0
	for s.Scan() {
		count++
	}
	if err := s.Err(); err != nil {
		return 0, err
	}
	return count, nil
}

func readLastLines(path string, keep int) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	lines := make([]string, 0, keep)
	s := bufio.NewScanner(f)
	for s.Scan() {
		lines = append(lines, s.Text())
		if len(lines) > keep {
			copy(lines, lines[1:])
			lines = lines[:keep]
		}
	}
	if err := s.Err(); err != nil {
		return nil, err
	}
	return lines, nil
}

func emitToolErrorHint(toolName, errorMessage string) {
	lower := strings.ToLower(errorMessage)
	if strings.Contains(lower, "permission denied") {
		_, _ = fmt.Fprintln(os.Stderr, "Hint: May need sudo or file permissions check")
	}
	if strings.Contains(lower, "command not found") {
		_, _ = fmt.Fprintln(os.Stderr, "Hint: Check if command is installed or PATH is set")
	}
	if (toolName == "Edit" || toolName == "Write") && strings.Contains(lower, "read-only") {
		_, _ = fmt.Fprintln(os.Stderr, "Hint: File may be read-only or in a protected directory")
	}
}

func contentFieldCount(raw json.RawMessage) int {
	if len(raw) == 0 {
		return 0
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err != nil {
		return 0
	}
	return len(object)
}

func fetchSessionContext(sessionID string) (int, int) {
	if sessionID == "" {
		return 0, 0
	}
	socketPath := os.Getenv("WARDEN_COLLECTOR_SOCK")
	if socketPath == "" {
		socketPath = filepath.Join(stateDir(), "collector.sock")
	}
	if _, err := os.Stat(socketPath); err != nil {
		return 0, 0
	}

	client := &http.Client{
		Timeout: 100 * time.Millisecond,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", socketPath)
			},
		},
	}

	resp, err := client.Get("http://localhost/v1/sessions/" + url.PathEscape(sessionID) + "/context")
	if err != nil {
		return 0, 0
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, 0
	}

	var payload struct {
		ToolCount     int `json:"tool_count"`
		SubagentCount int `json:"subagent_count"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return 0, 0
	}
	return payload.ToolCount, payload.SubagentCount
}

func preCompactDurationText(sessionID string) string {
	seconds, ok := sessionDurationSeconds(sessionID)
	if !ok {
		return "unknown"
	}
	return fmt.Sprintf("%dm", seconds/60)
}

func currentPreCompactBudgetState() budgetState {
	state, err := currentBudgetState()
	if err != nil {
		return budgetState{}
	}
	return state
}

func defaultIfEmpty(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
