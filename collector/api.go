package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// validSessionID matches UUID v4 format (Claude Code session IDs).
var validSessionID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// APIHandler serves query endpoints for the collector.
type APIHandler struct {
	store     *Store
	startTime time.Time
}

func NewAPIHandler(store *Store) *APIHandler {
	return &APIHandler{store: store, startTime: time.Now()}
}

func (a *APIHandler) HandleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"status":    "ok",
		"uptime_ms": time.Since(a.startTime).Milliseconds(),
	})
}

// HandleSessionContext returns context data for a single session.
// GET /v1/sessions/{session_id}/context
func (a *APIHandler) HandleSessionContext(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// Extract session_id from path: /v1/sessions/{id}/context
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/v1/sessions/"), "/")
	if len(parts) < 1 || parts[0] == "" {
		http.Error(w, "missing session_id", http.StatusBadRequest)
		return
	}
	sessionID := parts[0]
	if !validSessionID.MatchString(sessionID) {
		http.Error(w, "invalid session_id format", http.StatusBadRequest)
		return
	}

	sc, err := a.store.GetSessionContext(r.Context(), sessionID)
	if err != nil {
		slog.Warn("get session context failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if sc == nil {
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(sc)
}

// HandleSessions lists all sessions.
// GET /v1/sessions
func (a *APIHandler) HandleSessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	sessions, err := a.store.ListSessions(r.Context())
	if err != nil {
		slog.Warn("list sessions failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if sessions == nil {
		sessions = []SessionSummary{}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(sessions)
}

// HandleHookIngest accepts hook events via HTTP.
// POST /v1/ingest/hook
func (a *APIHandler) HandleHookIngest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	bodyBytes, err := io.ReadAll(io.LimitReader(r.Body, 64*1024))
	if err != nil {
		http.Error(w, "read error", http.StatusBadRequest)
		return
	}

	var evt map[string]any
	if err := json.Unmarshal(bodyBytes, &evt); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}

	sessionID, _ := evt["session_id"].(string)
	eventType, _ := evt["event_type"].(string)
	// Hooks emit "tool", not "tool_name" — check both for compatibility
	toolName, _ := evt["tool"].(string)
	if toolName == "" {
		toolName, _ = evt["tool_name"].(string)
	}

	if err := a.store.InsertHookEvent(r.Context(), sessionID, eventType, toolName, string(bodyBytes)); err != nil {
		slog.Warn("insert hook event failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	// Create session row on lifecycle events so sessions appear before OTEL
	if eventType == "session_start" && sessionID != "" {
		if err := a.store.EnsureSession(r.Context(), sessionID); err != nil {
			slog.Warn("ensure session failed", "session_id", sessionID, "err", err)
		}
	}

	// Subagent budget management — async deny-file pattern
	agentID, _ := evt["agent_id"].(string)
	if agentID != "" {
		a.handleSubagentBudget(r, eventType, agentID, sessionID, evt)
	}

	w.WriteHeader(http.StatusAccepted)
	w.Write([]byte(`{"status":"accepted"}`))
}

// handleSubagentBudget processes subagent lifecycle events and manages deny files.
func (a *APIHandler) handleSubagentBudget(r *http.Request, eventType, agentID, sessionID string, evt map[string]any) {
	ctx := r.Context()

	switch eventType {
	case "subagent_start":
		agentType, _ := evt["agent_type"].(string)
		callLimit := intFromAny(evt["call_limit"], 30)
		byteLimit := intFromAny(evt["byte_limit"], 102400)
		if err := a.store.InitSubagent(ctx, agentID, sessionID, agentType, callLimit, byteLimit); err != nil {
			slog.Warn("init subagent budget failed", "err", err, "agent_id", agentID)
		}

	case "subagent_tool_call":
		result, err := a.store.IncrementSubagentCall(ctx, agentID)
		if err != nil {
			slog.Warn("increment subagent call failed", "err", err, "agent_id", agentID)
			return
		}
		if result.Exceeded {
			a.writeDenyFile(agentID, fmt.Sprintf("calls %d/%d", result.Current, result.Limit))
			a.store.MarkSubagentDenied(ctx, agentID)
		}

	case "subagent_bytes":
		bytes := intFromAny(evt["bytes"], 0)
		if bytes <= 0 {
			return
		}
		result, err := a.store.AddSubagentBytes(ctx, agentID, bytes)
		if err != nil {
			slog.Warn("add subagent bytes failed", "err", err, "agent_id", agentID)
			return
		}
		if result.Exceeded {
			a.writeDenyFile(agentID, fmt.Sprintf("bytes %d/%d", result.Current, result.Limit))
			a.store.MarkSubagentDenied(ctx, agentID)
		}

	case "subagent_stop":
		a.removeDenyFile(agentID)
		if err := a.store.RemoveSubagentBudget(ctx, agentID); err != nil {
			slog.Warn("remove subagent budget failed", "err", err, "agent_id", agentID)
		}
	}
}

// writeDenyFile creates a budget-deny file that pre-tool-use can stat.
// The directory always mirrors the XDG state path used by the hooks so that
// deny files are visible regardless of where the collector's -db flag points.
func (a *APIHandler) writeDenyFile(agentID, reason string) {
	dir := stateDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		slog.Warn("ensure deny file dir failed", "err", err, "agent_id", agentID)
		return
	}
	path := filepath.Join(dir, "budget-deny-"+agentID)
	if err := os.WriteFile(path, []byte(reason), 0o600); err != nil {
		slog.Warn("write deny file failed", "err", err, "agent_id", agentID)
	} else {
		slog.Info("budget exceeded, deny file written", "agent_id", agentID, "reason", reason)
	}
}

// removeDenyFile removes a budget-deny file on subagent stop.
func (a *APIHandler) removeDenyFile(agentID string) {
	path := filepath.Join(stateDir(), "budget-deny-"+agentID)
	os.Remove(path)
}

// intFromAny extracts an int from interface{} (JSON numbers are float64).
func intFromAny(v any, fallback int) int {
	switch n := v.(type) {
	case float64:
		return int(n)
	case int:
		return n
	case string:
		// ignore non-numeric
	}
	return fallback
}
