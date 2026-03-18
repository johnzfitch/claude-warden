package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

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
	toolName, _ := evt["tool_name"].(string)

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

	w.WriteHeader(http.StatusAccepted)
	w.Write([]byte(`{"status":"accepted"}`))
}
