package main

import (
	"context"
	"database/sql"
	_ "embed"
	"fmt"
	"log/slog"
	"os"
	"strconv"
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

	// Extended fields for statusline (Phase 5)
	CompactThresholdPct int     `json:"compact_threshold_pct"` // default 85
	EffectiveWindow     int     `json:"effective_window"`      // context_window - 20000
	CompactThreshold    int     `json:"compact_threshold"`     // calculated threshold
	LastTool            string  `json:"last_tool"`             // most recent tool name
	LastToolDurationMS  int64   `json:"last_tool_duration_ms"` // most recent tool duration
	SubagentCount       int     `json:"subagent_count"`        // active subagents
	CacheHitRate        float64 `json:"cache_hit_rate"`        // cache_read / (cache_read + input)
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

	// Estimated context = raw input + cache_read + cache_create + tool results since last LLM call
	sc.EstimatedContext = sc.InputTokens + sc.CacheReadTokens + sc.CacheCreateTokens + sc.PendingOutputTokens
	if sc.ContextWindow > 0 {
		sc.UsedPct = float64(sc.EstimatedContext) / float64(sc.ContextWindow) * 100
		if sc.UsedPct > 100 {
			sc.UsedPct = 100
		}
	}

	// Extended fields for statusline
	// Read compact threshold from Claude Code's env var, default 85%
	sc.CompactThresholdPct = 85
	if envPct := os.Getenv("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"); envPct != "" {
		if v, err := strconv.Atoi(envPct); err == nil && v > 0 && v <= 100 {
			sc.CompactThresholdPct = v
		}
	}
	sc.EffectiveWindow = sc.ContextWindow - 20000
	if sc.EffectiveWindow < 0 {
		sc.EffectiveWindow = sc.ContextWindow
	}
	// compact_threshold = min(floor(effective_window * pct/100), effective_window - 13000)
	threshold := sc.EffectiveWindow * sc.CompactThresholdPct / 100
	maxThreshold := sc.EffectiveWindow - 13000
	if maxThreshold < 0 {
		maxThreshold = 0
	}
	if threshold > maxThreshold {
		threshold = maxThreshold
	}
	sc.CompactThreshold = threshold

	// Cache hit rate
	totalInput := sc.CacheReadTokens + sc.InputTokens
	if totalInput > 0 {
		sc.CacheHitRate = float64(sc.CacheReadTokens) / float64(totalInput) * 100
	}

	// Last tool and subagent count from recent spans/events
	s.enrichWithLastTool(ctx, sessionID, sc)
	s.enrichWithSubagentCount(ctx, sessionID, sc)

	return sc, nil
}

// enrichWithLastTool adds the most recent tool name and duration.
func (s *Store) enrichWithLastTool(ctx context.Context, sessionID string, sc *SessionContext) {
	// Get most recent tool span for this session
	var name string
	var durationMS int64
	err := s.db.QueryRowContext(ctx, `
		SELECT name, duration_ms FROM spans
		WHERE session_id = ? AND name LIKE 'claude_code.tool%'
		ORDER BY end_ns DESC LIMIT 1`, sessionID,
	).Scan(&name, &durationMS)
	if err == nil {
		sc.LastTool = name
		sc.LastToolDurationMS = durationMS
	}
}

// enrichWithSubagentCount counts active subagents from hook events.
func (s *Store) enrichWithSubagentCount(ctx context.Context, sessionID string, sc *SessionContext) {
	// Count subagent_start - subagent_stop for this session
	var starts, stops int
	s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM hook_events
		WHERE session_id = ? AND event_type = 'subagent_start'`, sessionID,
	).Scan(&starts)
	s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM hook_events
		WHERE session_id = ? AND event_type = 'subagent_stop'`, sessionID,
	).Scan(&stops)
	sc.SubagentCount = starts - stops
	if sc.SubagentCount < 0 {
		sc.SubagentCount = 0
	}
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
// Creates the session row if it doesn't exist (tool span before llm_request).
func (s *Store) AccumulateToolTokens(ctx context.Context, sessionID string, resultTokens int) error {
	now := time.Now().UnixNano()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO sessions (session_id, pending_output_tokens, tool_count, started_at_ns, updated_at_ns)
		VALUES (?, ?, 1, ?, ?)
		ON CONFLICT(session_id) DO UPDATE SET
			pending_output_tokens = sessions.pending_output_tokens + excluded.pending_output_tokens,
			tool_count = sessions.tool_count + 1,
			updated_at_ns = excluded.updated_at_ns`,
		sessionID, resultTokens, now, now)
	return err
}

// InsertSpan stores a raw OTLP span. Returns true if the span was newly
// inserted (false on duplicate, which happens on OTLP retries).
func (s *Store) InsertSpan(ctx context.Context, traceID, spanID, parentSpanID, sessionID, name string, kind int, startNS, endNS, durationMS int64, attrsJSON, resourceJSON string) (bool, error) {
	res, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO spans (trace_id, span_id, parent_span_id, session_id, name, kind,
		                             start_ns, end_ns, duration_ms, attrs_json, resource_json)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		traceID, spanID, parentSpanID, sessionID, name, kind, startNS, endNS, durationMS, attrsJSON, resourceJSON)
	if err != nil {
		return false, err
	}
	rows, _ := res.RowsAffected()
	return rows > 0, nil
}

// InsertHookEvent stores a hook event.
func (s *Store) InsertHookEvent(ctx context.Context, sessionID, eventType, toolName, payloadJSON string) error {
	now := time.Now().UnixNano()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO hook_events (session_id, occurred_at_ns, event_type, tool_name, payload_json)
		VALUES (?, ?, ?, ?, ?)`, sessionID, now, eventType, toolName, payloadJSON)
	return err
}

// EnsureSession creates a session row if it doesn't already exist.
// Called from hook ingest on session_start events so sessions appear
// in the API even before OTEL spans arrive.
func (s *Store) EnsureSession(ctx context.Context, sessionID string) error {
	now := time.Now().UnixNano()
	_, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO sessions (session_id, started_at_ns, updated_at_ns)
		VALUES (?, ?, ?)`, sessionID, now, now)
	return err
}

// BudgetResult is returned by IncrementSubagentBudget to tell the caller
// whether the budget is exceeded (and a deny file should be written).
type BudgetResult struct {
	Exceeded    bool
	Reason      string // "calls" or "bytes"
	Current     int
	Limit       int
	WarnAt80Pct bool
}

// InitSubagent creates a budget row for a new subagent. Called on subagent_start.
func (s *Store) InitSubagent(ctx context.Context, agentID, sessionID, agentType string, callLimit, byteLimit int) error {
	now := time.Now().UnixNano()
	_, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO subagent_budgets
			(agent_id, session_id, agent_type, call_limit, byte_limit, started_at_ns, updated_at_ns)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		agentID, sessionID, agentType, callLimit, byteLimit, now, now)
	return err
}

// IncrementSubagentCall increments call count and checks budget.
func (s *Store) IncrementSubagentCall(ctx context.Context, agentID string) (*BudgetResult, error) {
	now := time.Now().UnixNano()

	// Increment atomically
	_, err := s.db.ExecContext(ctx, `
		UPDATE subagent_budgets
		SET call_count = call_count + 1, updated_at_ns = ?
		WHERE agent_id = ?`, now, agentID)
	if err != nil {
		return nil, err
	}

	// Read current state
	var calls, limit int
	err = s.db.QueryRowContext(ctx,
		`SELECT call_count, call_limit FROM subagent_budgets WHERE agent_id = ?`,
		agentID).Scan(&calls, &limit)
	if err != nil {
		return nil, err
	}

	result := &BudgetResult{Current: calls, Limit: limit}
	if calls >= limit {
		result.Exceeded = true
		result.Reason = "calls"
	} else if calls >= limit*80/100 {
		result.WarnAt80Pct = true
	}
	return result, nil
}

// AddSubagentBytes adds output bytes and checks budget.
func (s *Store) AddSubagentBytes(ctx context.Context, agentID string, bytes int) (*BudgetResult, error) {
	now := time.Now().UnixNano()

	_, err := s.db.ExecContext(ctx, `
		UPDATE subagent_budgets
		SET byte_count = byte_count + ?, updated_at_ns = ?
		WHERE agent_id = ?`, bytes, now, agentID)
	if err != nil {
		return nil, err
	}

	var total, limit int
	err = s.db.QueryRowContext(ctx,
		`SELECT byte_count, byte_limit FROM subagent_budgets WHERE agent_id = ?`,
		agentID).Scan(&total, &limit)
	if err != nil {
		return nil, err
	}

	result := &BudgetResult{Current: total, Limit: limit}
	if total >= limit {
		result.Exceeded = true
		result.Reason = "bytes"
	} else if total >= limit*80/100 {
		result.WarnAt80Pct = true
	}
	return result, nil
}

// MarkSubagentDenied sets the denied flag on a subagent budget.
func (s *Store) MarkSubagentDenied(ctx context.Context, agentID string) error {
	now := time.Now().UnixNano()
	_, err := s.db.ExecContext(ctx, `
		UPDATE subagent_budgets SET denied = 1, updated_at_ns = ?
		WHERE agent_id = ?`, now, agentID)
	return err
}

// RemoveSubagentBudget deletes the budget row on subagent stop.
func (s *Store) RemoveSubagentBudget(ctx context.Context, agentID string) error {
	_, err := s.db.ExecContext(ctx, `
		DELETE FROM subagent_budgets WHERE agent_id = ?`, agentID)
	return err
}
