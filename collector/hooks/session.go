package hooks

import (
	"bufio"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var execCommand = exec.Command

func init() {
	hookHandlers["session-start"] = handleSessionStart
	hookHandlers["session-end"] = handleSessionEnd
	hookHandlers["stop"] = handleStop
}

func handleSessionStart(input HookInput) ([]byte, int) {
	sid := sanitizeID(input.SessionID)
	if sid != "" {
		now := timeNow()
		_ = os.MkdirAll(sessionTimesDir(), 0o755)
		_ = os.MkdirAll(statuslineDir(), 0o755)
		_ = os.WriteFile(filepath.Join(sessionTimesDir(), sid+".start"), []byte(strconv.FormatInt(now.Unix(), 10)+"\n"), 0o644)
		_ = os.WriteFile(filepath.Join(statuslineDir(), ".session_start-"+sid), []byte(formatSecondNanos(now)+"\n"), 0o644)

		// Save model name for statusline (avoids stale cache from previous sessions)
		if input.Model != "" {
			modelFile := filepath.Join(statuslineDir(), "startup-model-"+sid)
			_ = os.WriteFile(modelFile+".tmp", []byte(input.Model+"\n"), 0o644)
			_ = os.Rename(modelFile+".tmp", modelFile)
		}

		if snapshot, err := exportBudgetJSON(); err == nil {
			_ = os.MkdirAll(sessionBudgetDir(), 0o755)
			_ = os.WriteFile(sessionBudgetSnapshotPath(sid), snapshot, 0o644)
		}

		_ = ensureAgentStatsCSV()
		_ = appendAgentStatsRow([]string{
			timeNow().Format(time.RFC3339),
			"terminal-" + sid,
			"terminal",
			"main",
			"0",
			sid,
			"started",
		})

		cwd, _ := os.Getwd()
		label := fmt.Sprintf("%s (%s)", filepath.Base(cwd), lastN(sid, 6))
		postJSONEvent(newEventPoster(), map[string]any{
			"timestamp":     0,
			"event_type":    "session_start",
			"tool":          "SessionStart",
			"session_id":    sid,
			"cwd":           cwd,
			"session_label": label,
		})
	}

	if ctx := gitContext(); ctx != "" {
		return AdditionalContext("SessionStart", ctx), 0
	}
	return nil, 0
}

func handleSessionEnd(input HookInput) ([]byte, int) {
	sid := sanitizeID(input.SessionID)
	if sid == "" {
		sid = "unknown"
	}
	reasonDisplay := sessionEndReasonDisplay(input.Reason)
	sessionStartS := resolveSessionStart(sid)

	durationSeconds, durationKnown := sessionDurationSeconds(sid)
	if durationKnown {
		_ = ensureAgentStatsCSV()
		_ = appendAgentStatsRow([]string{
			timeNow().Format(time.RFC3339),
			"terminal-" + sid,
			"terminal",
			"main",
			strconv.FormatInt(durationSeconds, 10),
			sid,
			"completed",
		})

		postJSONEvent(newEventPoster(), map[string]any{
			"timestamp":        relativeTimestamp(sessionStartS),
			"event_type":       "session_end",
			"tool":             "SessionEnd",
			"session_id":       sid,
			"duration_seconds": durationSeconds,
		})

		if startConsumed, ok := readBudgetSnapshotConsumed(sid); ok {
			endBudget, err := currentBudgetState()
			if err == nil {
				delta := endBudget.Consumed - startConsumed
				if delta < 0 {
					delta = 0
				}
				subagents := countCompletedSubagents(sid)
				_ = ensureSessionCostsCSV()
				_ = appendCSVRow(sessionCostsCSVPath(), []string{
					timeNow().Format(time.RFC3339),
					sid,
					strconv.FormatInt(durationSeconds, 10),
					strconv.FormatInt(startConsumed, 10),
					strconv.FormatInt(endBudget.Consumed, 10),
					strconv.FormatInt(delta, 10),
					strconv.Itoa(subagents),
				})
				removeBudgetSnapshot(sid)
			}
		}
	}

	reapGhostSubagents(sid)
	cleanupStaleStateFiles()
	appendSessionEndLog(sid, durationSeconds, durationKnown, reasonDisplay)
	writeResetReason(sid, reasonDisplay, input.Reason != "")
	cleanupSessionStateFiles(sid)
	removeSessionPromFiles(sid)
	return nil, 0
}

func handleStop(input HookInput) ([]byte, int) {
	if input.StopHookActive {
		return nil, 0
	}

	sid := sanitizeID(input.SessionID)
	sessionStartS := resolveSessionStart(sid)
	durationSeconds, durationKnown := sessionDurationSeconds(sid)
	durationText := "unknown"
	if durationKnown {
		durationText = fmt.Sprintf("%ds", durationSeconds)
	}

	appendStopLog(input.Reason, input.ToolName, durationText)
	postJSONEvent(newEventPoster(), map[string]any{
		"timestamp":        relativeTimestamp(sessionStartS),
		"event_type":       "session_stop",
		"tool":             "Stop",
		"session_id":       sid,
		"reason":           input.Reason,
		"duration_seconds": durationSeconds,
	})

	return StopSummary(fmt.Sprintf("Session: %s | reason: %s", durationText, input.Reason)), 0
}

func gitContext() string {
	cwd, err := os.Getwd()
	if err != nil || cwd == "" {
		return ""
	}

	if !runGitCheck(cwd, "rev-parse", "--is-inside-work-tree") {
		return ""
	}

	branch := strings.TrimSpace(runGitOutput(cwd, "branch", "--show-current"))
	if branch == "" {
		branch = "detached"
	}
	dirtyCount := countNonEmptyLines(runGitOutput(cwd, "status", "--porcelain"))
	lastCommit := strings.TrimSpace(runGitOutput(cwd, "log", "-1", "--format=%h %s"))

	ctx := "[Git] " + branch
	if dirtyCount > 0 {
		ctx += fmt.Sprintf(" (%d dirty)", dirtyCount)
	}
	if lastCommit != "" {
		ctx += ", last: " + lastCommit
	}
	return ctx
}

func runGitCheck(dir string, args ...string) bool {
	cmd := execCommand("git", args...)
	cmd.Dir = dir
	return cmd.Run() == nil
}

func runGitOutput(dir string, args ...string) string {
	cmd := execCommand("git", args...)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return string(out)
}

func countNonEmptyLines(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	count := 0
	for _, line := range strings.Split(s, "\n") {
		if strings.TrimSpace(line) != "" {
			count++
		}
	}
	return count
}

func sessionDurationSeconds(sid string) (int64, bool) {
	if sid == "" {
		return 0, false
	}
	b, err := os.ReadFile(filepath.Join(sessionTimesDir(), sid+".start"))
	if err != nil {
		return 0, false
	}
	start, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil {
		return 0, false
	}
	end := timeNow().Unix()
	if end < start {
		return 0, true
	}
	return end - start, true
}

func formatSecondNanos(t time.Time) string {
	return fmt.Sprintf("%d.%09d", t.Unix(), t.Nanosecond())
}

func lastN(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}

func sessionTimesDir() string {
	return filepath.Join(homeDir(), ".claude", ".session-times")
}

func claudeDir() string {
	return filepath.Join(homeDir(), ".claude")
}

func sessionBudgetDir() string {
	if dir := os.Getenv("WARDEN_SESSION_BUDGET_DIR"); dir != "" {
		return dir
	}
	legacy := filepath.Join(claudeDir(), ".session-budgets")
	if _, err := os.Stat(legacy); err == nil {
		return legacy
	}
	return filepath.Join(claudeDir(), ".warden", "session-budgets")
}

func alternateSessionBudgetDir() string {
	primary := sessionBudgetDir()
	legacy := filepath.Join(claudeDir(), ".session-budgets")
	preferred := filepath.Join(claudeDir(), ".warden", "session-budgets")
	if primary == legacy {
		return preferred
	}
	if primary == preferred {
		return legacy
	}
	return ""
}

func sessionBudgetSnapshotPath(sid string) string {
	return filepath.Join(sessionBudgetDir(), sid+".start.json")
}

type budgetState struct {
	Consumed    int64 `json:"consumed"`
	Limit       int64 `json:"limit"`
	TotalLimit  int64 `json:"total_limit"`
	Utilization int64 `json:"utilization"`
}

func currentBudgetState() (budgetState, error) {
	consumed := readNumericFile(filepath.Join(claudeDir(), ".warden", "budget.state"))
	total, _ := strconv.ParseInt(os.Getenv("WARDEN_BUDGET_TOTAL"), 10, 64)
	util := int64(0)
	if total > 0 {
		util = consumed * 100 / total
	}
	return budgetState{
		Consumed:    consumed,
		Limit:       total,
		TotalLimit:  total,
		Utilization: util,
	}, nil
}

func exportBudgetJSON() ([]byte, error) {
	state, err := currentBudgetState()
	if err != nil {
		return nil, err
	}
	return json.Marshal(state)
}

func readNumericFile(path string) int64 {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil {
		return 0
	}
	return n
}

func readBudgetSnapshotConsumed(sid string) (int64, bool) {
	for _, path := range budgetSnapshotPaths(sid) {
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var state budgetState
		if err := json.Unmarshal(b, &state); err == nil {
			return state.Consumed, true
		}
		var raw map[string]any
		if err := json.Unmarshal(b, &raw); err != nil {
			return 0, true
		}
		switch v := raw["consumed"].(type) {
		case float64:
			return int64(v), true
		}
		return 0, true
	}
	return 0, false
}

func budgetSnapshotPaths(sid string) []string {
	paths := []string{filepath.Join(sessionBudgetDir(), sid+".start.json")}
	if alt := alternateSessionBudgetDir(); alt != "" {
		paths = append(paths, filepath.Join(alt, sid+".start.json"))
	}
	return paths
}

func removeBudgetSnapshot(sid string) {
	for _, path := range budgetSnapshotPaths(sid) {
		_ = os.Remove(path)
	}
}

func agentStatsCSVPath() string {
	return filepath.Join(claudeDir(), "agent-stats.csv")
}

func ensureAgentStatsCSV() error {
	return ensureCSVHeader(agentStatsCSVPath(), []string{"timestamp", "agent_id", "agent_category", "agent_type", "duration_seconds", "session_id", "status"})
}

func sessionCostsCSVPath() string {
	return filepath.Join(claudeDir(), ".monitoring", "session-costs.csv")
}

func ensureSessionCostsCSV() error {
	return ensureCSVHeader(sessionCostsCSVPath(), []string{"timestamp", "session_id", "duration_seconds", "budget_start", "budget_end", "budget_delta", "subagent_count"})
}

func ensureCSVHeader(path string, header []string) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return appendCSVRow(path, header)
}

func appendAgentStatsRow(row []string) error {
	return appendCSVRow(agentStatsCSVPath(), row)
}

func appendCSVRow(path string, row []string) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	w := csv.NewWriter(f)
	if err := w.Write(row); err != nil {
		return err
	}
	w.Flush()
	return w.Error()
}

func countCompletedSubagents(sid string) int {
	f, err := os.Open(agentStatsCSVPath())
	if err != nil {
		return 0
	}
	defer f.Close()

	r := csv.NewReader(f)
	rows, err := r.ReadAll()
	if err != nil {
		return 0
	}
	count := 0
	for _, row := range rows {
		if len(row) < 7 {
			continue
		}
		if row[5] == sid && row[2] == "subagent" && row[6] == "completed" {
			count++
		}
	}
	return count
}

func subagentStateDir() string {
	if dir := os.Getenv("WARDEN_SUBAGENT_STATE_DIR"); dir != "" {
		return dir
	}
	return filepath.Join(claudeDir(), ".subagent-state")
}

func reapGhostSubagents(sid string) {
	entries, err := os.ReadDir(subagentStateDir())
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		if strings.Contains(name, ".") {
			continue
		}
		path := filepath.Join(subagentStateDir(), name)
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			continue
		}
		if !fileContainsLine(path, "SESSION_ID="+sid) {
			continue
		}
		_ = os.Remove(path)
		_ = os.Remove(path + ".start")
	}
}

func fileContainsLine(path, want string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		if s.Text() == want {
			return true
		}
	}
	return false
}

func cleanupStaleStateFiles() {
	cleanupStaleMatches(statuslineDir(), func(name string, info os.FileInfo) bool {
		if info.Mode().IsRegular() {
			switch {
			case strings.HasPrefix(name, "tool-count-"),
				strings.HasPrefix(name, "tool-top-"),
				strings.HasPrefix(name, "session-"),
				strings.HasPrefix(name, "state-"),
				strings.HasPrefix(name, ".tool-start-"),
				strings.HasPrefix(name, ".quiet-override-"),
				strings.HasPrefix(name, "clears-"),
				strings.HasPrefix(name, "peak-"),
				strings.HasPrefix(name, ".session_start-"),
				strings.HasPrefix(name, "subagent-count-"):
				return ageExceeds(info.ModTime(), 24*time.Hour)
			case strings.HasSuffix(name, ".lock"):
				return ageExceeds(info.ModTime(), 60*time.Minute)
			}
		}
		return info.IsDir() && strings.HasSuffix(name, ".lock.d") && ageExceeds(info.ModTime(), 60*time.Minute)
	})

	cleanupStaleMatches(subagentStateDir(), func(name string, info os.FileInfo) bool {
		if !info.Mode().IsRegular() {
			return false
		}
		return ageExceeds(info.ModTime(), 24*time.Hour) && (strings.HasSuffix(name, ".start") || !strings.HasPrefix(name, "."))
	})
}

func cleanupStaleMatches(dir string, match func(string, os.FileInfo) bool) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		path := filepath.Join(dir, entry.Name())
		info, err := os.Lstat(path)
		if err != nil || !match(entry.Name(), info) {
			continue
		}
		if info.IsDir() {
			_ = os.RemoveAll(path)
		} else {
			_ = os.Remove(path)
		}
	}
}

func ageExceeds(modTime time.Time, minAge time.Duration) bool {
	return timeNow().Sub(modTime) > minAge
}

func appendSessionEndLog(sid string, durationSeconds int64, durationKnown bool, reason string) {
	duration := "unknown"
	if durationKnown {
		duration = fmt.Sprintf("%dm", durationSeconds/60)
	}
	cwd, _ := os.Getwd()
	line := fmt.Sprintf("[%s] Session ended: %s (duration: %s, dir: %s, reason: %s)\n", timeNow().Format("2006-01-02 15:04:05"), sid, duration, cwd, reason)
	_ = appendTextFile(filepath.Join(claudeDir(), "session-log.txt"), line)
}

func writeResetReason(sid, reason string, enabled bool) {
	if !enabled {
		return
	}
	_ = os.MkdirAll(statuslineDir(), 0o755)
	path := filepath.Join(statuslineDir(), "reset-reason")
	tmp := path + ".tmp"
	line := fmt.Sprintf("%d|%s|%s\n", timeNow().Unix(), reason, sid)
	_ = os.WriteFile(tmp, []byte(line), 0o644)
	_ = os.Rename(tmp, path)
}

func cleanupSessionStateFiles(sid string) {
	if sid == "" {
		return
	}
	_ = os.Remove(filepath.Join(statuslineDir(), ".session_start-"+sid))
	_ = os.Remove(filepath.Join(statuslineDir(), "subagent-count-"+sid))
	_ = os.Remove(filepath.Join(statuslineDir(), "session-"+sid))
	_ = os.Remove(filepath.Join(statuslineDir(), "session-"+sid+".lock"))
	_ = os.Remove(filepath.Join(statuslineDir(), "subagent-count-"+sid+".lock"))
	_ = os.RemoveAll(filepath.Join(statuslineDir(), "session-"+sid+".lock.d"))
	_ = os.RemoveAll(filepath.Join(statuslineDir(), "subagent-count-"+sid+".lock.d"))

	entries, err := os.ReadDir(statuslineDir())
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		switch {
		case strings.HasPrefix(name, ".tool-start-") && strings.HasSuffix(name, "-"+sid):
			_ = os.Remove(filepath.Join(statuslineDir(), name))
		case strings.HasPrefix(name, ".quiet-override-") && strings.HasSuffix(name, "-"+sid):
			_ = os.Remove(filepath.Join(statuslineDir(), name))
		}
	}
}

func removeSessionPromFiles(sid string) {
	if sid == "" {
		return
	}
	base := filepath.Join(claudeDir(), ".monitoring", "textfile", "claude-code-session-"+sid+".prom")
	_ = os.Remove(base)
	_ = os.Remove(base + ".tombstone")
}

func appendStopLog(reason, toolName, duration string) {
	var line string
	if toolName != "" {
		line = fmt.Sprintf("[%s] Stop: %s (tool: %s, duration: %s)\n", timeNow().Format("2006-01-02 15:04:05"), reason, toolName, duration)
	} else {
		line = fmt.Sprintf("[%s] Stop: %s (duration: %s)\n", timeNow().Format("2006-01-02 15:04:05"), reason, duration)
	}
	_ = appendTextFile(filepath.Join(claudeDir(), "session-log.txt"), line)
}

func appendTextFile(path, text string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(text)
	return err
}

func sessionEndReasonDisplay(reason string) string {
	switch reason {
	case "bypass_permissions_disabled":
		return "bypass mode disabled"
	default:
		return reason
	}
}

func postJSONEvent(poster eventPoster, v any) {
	if poster == nil {
		return
	}
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	poster.PostEvent(b)
}
