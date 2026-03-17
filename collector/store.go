package main

import (
	"context"
	"database/sql"
	_ "embed"
	"fmt"
	"log/slog"
	"time"

	_ "modernc.org/sqlite"
)

//go:embed schema.sql
var schemaSQL string

// Store wraps a SQLite database for the warden collector.
type Store struct {
	db *sql.DB
}

// OpenStore opens (or creates) a SQLite database at dbPath with WAL mode.
func OpenStore(dbPath string) (*Store, error) {
	db, err := sql.Open("sqlite", dbPath+"?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	db.SetMaxOpenConns(1) // single writer
	db.SetMaxIdleConns(1)

	if _, err := db.Exec(schemaSQL); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate schema: %w", err)
	}

	slog.Info("database opened", "path", dbPath)
	return &Store{db: db}, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

// SessionContext is the response type for statusline queries.
type SessionContext struct {
	SessionID           string  `json:"session_id"`
	Model               string  `json:"model"`
	ContextWindow       int     `json:"context_window"`
	InputTokens         int     `json:"input_tokens"`
	OutputTokens        int     `json:"output_tokens"`
	CacheReadTokens     int     `json:"cache_read_tokens"`
	CacheCreateTokens   int     `json:"cache_creation_tokens"`
	PendingOutputTokens int     `json:"pending_output_tokens"`
	EstimatedContext    int     `json:"estimated_context"`
	CostUSD             float64 `json:"cost_usd"`
	ToolCount           int     `json:"tool_count"`
	UsedPct             float64 `json:"used_pct"`
	UpdatedAt           int64   `json:"updated_at_ns"`
}

// GetSessionContext returns the latest context data for a session.
// EstimatedContext = input_tokens (last LLM request) + pending_output_tokens
// (accumulated from tool result_tokens since last LLM request).
func (s *Store) GetSessionContext(ctx context.Context, sessionID string) (*SessionContext, error) {
	sc := &SessionContext{SessionID: sessionID}
	err := s.db.QueryRowContext(ctx, `
		SELECT model, context_window, input_tokens, output_tokens,
		       cache_read_tokens, cache_creation_tokens, cost_usd,
		       tool_count, pending_output_tokens, updated_at_ns
		FROM sessions WHERE session_id = ?`, sessionID,
	).Scan(&sc.Model, &sc.ContextWindow, &sc.InputTokens, &sc.OutputTokens,
		&sc.CacheReadTokens, &sc.CacheCreateTokens, &sc.CostUSD,
		&sc.ToolCount, &sc.PendingOutputTokens, &sc.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	// Estimated context = last known input + tool results accumulated since
	sc.EstimatedContext = sc.InputTokens + sc.PendingOutputTokens
	if sc.ContextWindow > 0 {
		sc.UsedPct = float64(sc.EstimatedContext) / float64(sc.ContextWindow) * 100
		if sc.UsedPct > 100 {
			sc.UsedPct = 100
		}
	}
	return sc, nil
}

// SessionSummary is a lightweight session listing.
type SessionSummary struct {
	SessionID           string  `json:"session_id"`
	Model               string  `json:"model"`
	ContextWindow       int     `json:"context_window"`
	InputTokens         int     `json:"input_tokens"`
	OutputTokens        int     `json:"output_tokens"`
	CostUSD             float64 `json:"cost_usd"`
	ToolCount           int     `json:"tool_count"`
	PendingOutputTokens int     `json:"pending_output_tokens"`
	StartedAt           int64   `json:"started_at_ns"`
	UpdatedAt           int64   `json:"updated_at_ns"`
}

// ListSessions returns all sessions ordered by most recently updated.
func (s *Store) ListSessions(ctx context.Context) ([]SessionSummary, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT session_id, model, context_window, input_tokens, output_tokens,
		       cost_usd, tool_count, pending_output_tokens, started_at_ns, updated_at_ns
		FROM sessions ORDER BY updated_at_ns DESC LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []SessionSummary
	for rows.Next() {
		var ss SessionSummary
		if err := rows.Scan(&ss.SessionID, &ss.Model, &ss.ContextWindow,
			&ss.InputTokens, &ss.OutputTokens, &ss.CostUSD,
			&ss.ToolCount, &ss.PendingOutputTokens, &ss.StartedAt, &ss.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, ss)
	}
	return out, rows.Err()
}

// UpsertSessionFromSpan updates session data from an llm_request span.
// Resets pending_output_tokens because the new LLM request already includes
// all prior context (tool results become cached input on the next call).
func (s *Store) UpsertSessionFromSpan(ctx context.Context, sessionID, model string, contextWindow, inputTokens, outputTokens, cacheRead, cacheCreate int) error {
	now := time.Now().UnixNano()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO sessions (session_id, model, context_window, input_tokens, output_tokens,
		                      cache_read_tokens, cache_creation_tokens, pending_output_tokens,
		                      started_at_ns, updated_at_ns)
		VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
		ON CONFLICT(session_id) DO UPDATE SET
			model = CASE WHEN excluded.model != '' THEN excluded.model ELSE sessions.model END,
			context_window = CASE WHEN excluded.context_window > 0 THEN excluded.context_window ELSE sessions.context_window END,
			input_tokens = excluded.input_tokens,
			output_tokens = excluded.output_tokens,
			cache_read_tokens = excluded.cache_read_tokens,
			cache_creation_tokens = excluded.cache_creation_tokens,
			pending_output_tokens = 0,
			updated_at_ns = excluded.updated_at_ns`,
		sessionID, model, contextWindow, inputTokens, outputTokens, cacheRead, cacheCreate, now, now)
	return err
}

// AccumulateToolTokens adds result_tokens from a tool span to the session's
// pending output, tracking context growth between LLM requests.
func (s *Store) AccumulateToolTokens(ctx context.Context, sessionID string, resultTokens int) error {
	now := time.Now().UnixNano()
	_, err := s.db.ExecContext(ctx, `
		UPDATE sessions
		SET pending_output_tokens = pending_output_tokens + ?,
		    tool_count = tool_count + 1,
		    updated_at_ns = ?
		WHERE session_id = ?`, resultTokens, now, sessionID)
	return err
}

// InsertSpan stores a raw OTLP span.
func (s *Store) InsertSpan(ctx context.Context, traceID, spanID, parentSpanID, sessionID, name string, kind int, startNS, endNS, durationMS int64, attrsJSON, resourceJSON string) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO spans (trace_id, span_id, parent_span_id, session_id, name, kind,
		                             start_ns, end_ns, duration_ms, attrs_json, resource_json)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		traceID, spanID, parentSpanID, sessionID, name, kind, startNS, endNS, durationMS, attrsJSON, resourceJSON)
	return err
}

// InsertHookEvent stores a hook event.
func (s *Store) InsertHookEvent(ctx context.Context, sessionID, eventType, toolName, payloadJSON string) error {
	now := time.Now().UnixNano()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO hook_events (session_id, occurred_at_ns, event_type, tool_name, payload_json)
		VALUES (?, ?, ?, ?, ?)`, sessionID, now, eventType, toolName, payloadJSON)
	return err
}
