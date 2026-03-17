package main

import (
	"encoding/json"
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

	var evt struct {
		SessionID string `json:"session_id"`
		EventType string `json:"event_type"`
		ToolName  string `json:"tool_name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&evt); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}

	// Re-encode the full payload for storage
	payloadJSON, _ := json.Marshal(evt)

	if err := a.store.InsertHookEvent(r.Context(), evt.SessionID, evt.EventType, evt.ToolName, string(payloadJSON)); err != nil {
		slog.Warn("insert hook event failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusAccepted)
	w.Write([]byte(`{"status":"accepted"}`))
}
