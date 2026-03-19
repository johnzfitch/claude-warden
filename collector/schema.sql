PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA busy_timeout = 5000;

CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY,
    model TEXT,
    context_window INTEGER NOT NULL DEFAULT 200000,
    input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
    cost_usd REAL NOT NULL DEFAULT 0,
    tool_count INTEGER NOT NULL DEFAULT 0,
    pending_output_tokens INTEGER NOT NULL DEFAULT 0,
    started_at_ns INTEGER NOT NULL,
    updated_at_ns INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS spans (
    id INTEGER PRIMARY KEY,
    trace_id TEXT NOT NULL,
    span_id TEXT NOT NULL,
    parent_span_id TEXT,
    session_id TEXT,
    name TEXT NOT NULL,
    kind INTEGER,
    start_ns INTEGER NOT NULL,
    end_ns INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    attrs_json TEXT NOT NULL DEFAULT '{}',
    resource_json TEXT NOT NULL DEFAULT '{}',
    UNIQUE(trace_id, span_id)
);

CREATE INDEX IF NOT EXISTS idx_spans_session ON spans(session_id, start_ns);
CREATE INDEX IF NOT EXISTS idx_spans_name ON spans(name, start_ns);

CREATE TABLE IF NOT EXISTS hook_events (
    id INTEGER PRIMARY KEY,
    session_id TEXT,
    occurred_at_ns INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    tool_name TEXT,
    payload_json TEXT NOT NULL DEFAULT '{}',
    source TEXT NOT NULL DEFAULT 'hook'
);

CREATE INDEX IF NOT EXISTS idx_hook_events_session ON hook_events(session_id, occurred_at_ns);
CREATE INDEX IF NOT EXISTS idx_hook_events_type ON hook_events(event_type, occurred_at_ns);

CREATE TABLE IF NOT EXISTS subagent_budgets (
    agent_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    agent_type TEXT NOT NULL DEFAULT '',
    call_count INTEGER NOT NULL DEFAULT 0,
    byte_count INTEGER NOT NULL DEFAULT 0,
    call_limit INTEGER NOT NULL DEFAULT 30,
    byte_limit INTEGER NOT NULL DEFAULT 102400,
    denied INTEGER NOT NULL DEFAULT 0,
    started_at_ns INTEGER NOT NULL,
    updated_at_ns INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_subagent_session ON subagent_budgets(session_id);

CREATE TABLE IF NOT EXISTS meta_kv (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at_ns INTEGER NOT NULL
);
