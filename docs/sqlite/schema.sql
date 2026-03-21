PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;

BEGIN;

-- Single-writer collector metadata.
CREATE TABLE IF NOT EXISTS meta_kv (
    key TEXT PRIMARY KEY,
    value_text TEXT,
    updated_at_ns INTEGER NOT NULL
);

-- Registry of every ingest surface the collector knows about: hook stdin,
-- file tails, OTLP listeners, capture logs, temp directories, and exports.
CREATE TABLE IF NOT EXISTS source_registry (
    source_id INTEGER PRIMARY KEY,
    source_key TEXT NOT NULL UNIQUE,
    source_kind TEXT NOT NULL CHECK (
        source_kind IN (
            'hook',
            'statusline',
            'file_tail',
            'file_snapshot',
            'temp_file',
            'temp_dir',
            'socket',
            'otlp_grpc',
            'otlp_http',
            'prometheus_scrape',
            'http_api',
            'ui',
            'capture',
            'external'
        )
    ),
    transport TEXT,
    owner TEXT NOT NULL,
    location TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    notes TEXT,
    created_at_ns INTEGER NOT NULL,
    updated_at_ns INTEGER NOT NULL
);

-- Registry of local endpoints exposed or consumed by claude-warden.
CREATE TABLE IF NOT EXISTS endpoint_registry (
    endpoint_id INTEGER PRIMARY KEY,
    endpoint_key TEXT NOT NULL UNIQUE,
    direction TEXT NOT NULL CHECK (direction IN ('ingest', 'egress', 'query', 'ui')),
    protocol TEXT NOT NULL,
    bind_host TEXT,
    port INTEGER,
    path TEXT,
    url TEXT,
    source_id INTEGER REFERENCES source_registry(source_id) ON DELETE SET NULL,
    notes TEXT,
    created_at_ns INTEGER NOT NULL,
    updated_at_ns INTEGER NOT NULL
);

-- Append-only raw envelope store. Every ingest path lands here first.
CREATE TABLE IF NOT EXISTS raw_envelopes (
    envelope_id INTEGER PRIMARY KEY,
    received_at_ns INTEGER NOT NULL,
    source_id INTEGER REFERENCES source_registry(source_id) ON DELETE SET NULL,
    source_key TEXT NOT NULL,
    session_id TEXT,
    agent_id TEXT,
    event_name TEXT,
    content_type TEXT NOT NULL,
    schema_version TEXT,
    dedupe_key TEXT,
    fs_path TEXT,
    payload_bytes INTEGER NOT NULL,
    payload_json TEXT NOT NULL,
    parse_status TEXT NOT NULL DEFAULT 'pending' CHECK (
        parse_status IN ('pending', 'parsed', 'rejected', 'duplicate', 'error')
    ),
    error_text TEXT
);

CREATE INDEX IF NOT EXISTS idx_raw_envelopes_source_time
    ON raw_envelopes(source_key, received_at_ns);
CREATE INDEX IF NOT EXISTS idx_raw_envelopes_session_time
    ON raw_envelopes(session_id, received_at_ns);

-- Session rollup. Updated by session-start/session-end/statusline projections.
CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY,
    started_at_ns INTEGER NOT NULL,
    ended_at_ns INTEGER,
    cwd TEXT,
    transcript_path TEXT,
    model_id TEXT,
    model_display TEXT,
    session_label TEXT,
    context_window_size INTEGER,
    end_reason TEXT,
    stop_reason TEXT,
    total_input_tokens INTEGER NOT NULL DEFAULT 0,
    total_output_tokens INTEGER NOT NULL DEFAULT 0,
    cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
    cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
    used_pct_tenths INTEGER NOT NULL DEFAULT 0,
    current_context_tokens INTEGER NOT NULL DEFAULT 0,
    total_cost_usd REAL NOT NULL DEFAULT 0,
    total_duration_ms INTEGER NOT NULL DEFAULT 0,
    total_api_duration_ms INTEGER NOT NULL DEFAULT 0,
    tool_count INTEGER NOT NULL DEFAULT 0,
    blocked_count INTEGER NOT NULL DEFAULT 0,
    error_count INTEGER NOT NULL DEFAULT 0,
    truncation_count INTEGER NOT NULL DEFAULT 0,
    compaction_count INTEGER NOT NULL DEFAULT 0,
    clear_count INTEGER NOT NULL DEFAULT 0,
    active_subagent_count INTEGER NOT NULL DEFAULT 0,
    budget_consumed_tokens INTEGER NOT NULL DEFAULT 0,
    budget_limit_tokens INTEGER NOT NULL DEFAULT 0,
    created_at_ns INTEGER NOT NULL,
    updated_at_ns INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_started_at
    ON sessions(started_at_ns);
CREATE INDEX IF NOT EXISTS idx_sessions_updated_at
    ON sessions(updated_at_ns);

-- Statusline snapshots, including the exact raw fields that caused prior bugs.
CREATE TABLE IF NOT EXISTS context_snapshots (
    snapshot_id INTEGER PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    captured_at_ns INTEGER NOT NULL,
    context_window_size INTEGER NOT NULL,
    used_pct_tenths INTEGER NOT NULL,
    total_input_tokens INTEGER NOT NULL DEFAULT 0,
    total_output_tokens INTEGER NOT NULL DEFAULT 0,
    current_input_tokens INTEGER NOT NULL DEFAULT 0,
    current_output_tokens INTEGER NOT NULL DEFAULT 0,
    cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
    cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
    computed_context_tokens INTEGER NOT NULL,
    free_context_tokens INTEGER NOT NULL DEFAULT 0,
    cost_usd REAL NOT NULL DEFAULT 0,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    api_duration_ms INTEGER NOT NULL DEFAULT 0,
    raw_envelope_id INTEGER REFERENCES raw_envelopes(envelope_id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_context_snapshots_session_time
    ON context_snapshots(session_id, captured_at_ns);

-- Budget state over time, regardless of whether it came from hooks or statusline.
CREATE TABLE IF NOT EXISTS budget_snapshots (
    snapshot_id INTEGER PRIMARY KEY,
    session_id TEXT REFERENCES sessions(session_id) ON DELETE SET NULL,
    captured_at_ns INTEGER NOT NULL,
    consumed_tokens INTEGER NOT NULL,
    limit_tokens INTEGER NOT NULL,
    remaining_tokens INTEGER NOT NULL,
    utilization_pct_tenths INTEGER NOT NULL,
    active_subagents INTEGER NOT NULL DEFAULT 0,
    state_path TEXT,
    raw_envelope_id INTEGER REFERENCES raw_envelopes(envelope_id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_budget_snapshots_time
    ON budget_snapshots(captured_at_ns);
CREATE INDEX IF NOT EXISTS idx_budget_snapshots_session_time
    ON budget_snapshots(session_id, captured_at_ns);

-- Normalized hook/session events. payload_json keeps the full body for forensics.
CREATE TABLE IF NOT EXISTS hook_events (
    event_id INTEGER PRIMARY KEY,
    session_id TEXT REFERENCES sessions(session_id) ON DELETE CASCADE,
    agent_id TEXT,
    occurred_at_ns INTEGER,
    session_relative_ms INTEGER,
    event_type TEXT NOT NULL,
    tool_name TEXT,
    rule TEXT,
    reason TEXT,
    severity TEXT,
    original_cmd TEXT,
    tokens_saved INTEGER NOT NULL DEFAULT 0,
    original_output_bytes INTEGER,
    final_output_bytes INTEGER,
    output_bytes INTEGER,
    output_lines INTEGER,
    estimated_tokens INTEGER,
    duration_ms INTEGER,
    duration_seconds REAL,
    mcp_server TEXT,
    mcp_tool TEXT,
    elicitation_id TEXT,
    action TEXT,
    mode TEXT,
    content_fields INTEGER,
    file_path TEXT,
    memory_type TEXT,
    load_reason TEXT,
    error_message TEXT,
    has_worktree INTEGER CHECK (has_worktree IN (0, 1)),
    cwd TEXT,
    session_label TEXT,
    message TEXT,
    payload_json TEXT NOT NULL,
    raw_envelope_id INTEGER REFERENCES raw_envelopes(envelope_id) ON DELETE SET NULL,
    source_id INTEGER REFERENCES source_registry(source_id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_hook_events_session_time
    ON hook_events(session_id, occurred_at_ns);
CREATE INDEX IF NOT EXISTS idx_hook_events_type_time
    ON hook_events(event_type, occurred_at_ns);
CREATE INDEX IF NOT EXISTS idx_hook_events_tool_time
    ON hook_events(tool_name, occurred_at_ns);

-- Tool invocation projection. One row per tool call after collector correlation.
CREATE TABLE IF NOT EXISTS tool_calls (
    tool_call_id INTEGER PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    agent_id TEXT,
    invocation_key TEXT,
    tool_name TEXT NOT NULL,
    mcp_server TEXT,
    mcp_tool TEXT,
    started_at_ns INTEGER,
    ended_at_ns INTEGER,
    duration_ms INTEGER,
    pid INTEGER,
    transcript_path TEXT,
    command_preview TEXT,
    decision TEXT NOT NULL DEFAULT 'unknown' CHECK (
        decision IN ('allow', 'deny', 'truncate', 'suppress', 'error', 'unknown')
    ),
    rule TEXT,
    output_bytes INTEGER NOT NULL DEFAULT 0,
    output_lines INTEGER NOT NULL DEFAULT 0,
    estimated_tokens INTEGER NOT NULL DEFAULT 0,
    tokens_saved INTEGER NOT NULL DEFAULT 0,
    latency_measured INTEGER NOT NULL DEFAULT 0 CHECK (latency_measured IN (0, 1)),
    worktree_path TEXT,
    error_text TEXT,
    raw_start_event_id INTEGER REFERENCES hook_events(event_id) ON DELETE SET NULL,
    raw_end_event_id INTEGER REFERENCES hook_events(event_id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_tool_calls_session_start
    ON tool_calls(session_id, started_at_ns);
CREATE INDEX IF NOT EXISTS idx_tool_calls_tool_start
    ON tool_calls(tool_name, started_at_ns);

-- Subagent lifecycle projection.
CREATE TABLE IF NOT EXISTS subagents (
    agent_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    agent_type TEXT,
    started_at_ns INTEGER NOT NULL,
    ended_at_ns INTEGER,
    duration_seconds REAL,
    has_worktree INTEGER NOT NULL DEFAULT 0 CHECK (has_worktree IN (0, 1)),
    worktree_path TEXT,
    output_bytes INTEGER NOT NULL DEFAULT 0,
    estimated_tokens INTEGER NOT NULL DEFAULT 0,
    budget_reserved_tokens INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'started' CHECK (
        status IN ('started', 'completed', 'failed', 'orphaned')
    ),
    metadata_json TEXT
);

CREATE INDEX IF NOT EXISTS idx_subagents_session_start
    ON subagents(session_id, started_at_ns);

-- Every on-disk artifact the collector chooses to inventory.
CREATE TABLE IF NOT EXISTS artifacts (
    artifact_id INTEGER PRIMARY KEY,
    session_id TEXT REFERENCES sessions(session_id) ON DELETE SET NULL,
    agent_id TEXT REFERENCES subagents(agent_id) ON DELETE SET NULL,
    artifact_kind TEXT NOT NULL,
    producer TEXT NOT NULL,
    root_scope TEXT NOT NULL CHECK (
        root_scope IN (
            'claude_home',
            'xdg_state',
            'xdg_cache',
            'tmp',
            'home_tmp',
            'capture',
            'monitoring',
            'external'
        )
    ),
    path TEXT NOT NULL UNIQUE,
    content_type TEXT,
    exists_on_disk INTEGER NOT NULL DEFAULT 1 CHECK (exists_on_disk IN (0, 1)),
    size_bytes INTEGER,
    sha256 TEXT,
    first_seen_ns INTEGER NOT NULL,
    last_seen_ns INTEGER NOT NULL,
    deleted_at_ns INTEGER,
    expires_at_ns INTEGER,
    metadata_json TEXT
);

CREATE INDEX IF NOT EXISTS idx_artifacts_session
    ON artifacts(session_id, first_seen_ns);
CREATE INDEX IF NOT EXISTS idx_artifacts_scope
    ON artifacts(root_scope, producer);

CREATE TABLE IF NOT EXISTS artifact_events (
    artifact_event_id INTEGER PRIMARY KEY,
    artifact_id INTEGER NOT NULL REFERENCES artifacts(artifact_id) ON DELETE CASCADE,
    observed_at_ns INTEGER NOT NULL,
    action TEXT NOT NULL CHECK (
        action IN ('create', 'update', 'delete', 'rotate', 'offload', 'snapshot', 'observe')
    ),
    size_bytes INTEGER,
    metadata_json TEXT
);

CREATE INDEX IF NOT EXISTS idx_artifact_events_artifact_time
    ON artifact_events(artifact_id, observed_at_ns);

-- OTLP logs received directly by the collector or imported from existing JSONL.
CREATE TABLE IF NOT EXISTS otlp_logs (
    log_id INTEGER PRIMARY KEY,
    received_at_ns INTEGER NOT NULL,
    timestamp_ns INTEGER,
    observed_time_ns INTEGER,
    trace_id TEXT,
    span_id TEXT,
    severity_number INTEGER,
    severity_text TEXT,
    body_text TEXT,
    event_name TEXT,
    service_name TEXT,
    session_id TEXT REFERENCES sessions(session_id) ON DELETE SET NULL,
    scope_name TEXT,
    scope_version TEXT,
    resource_attributes_json TEXT NOT NULL DEFAULT '{}',
    attributes_json TEXT NOT NULL DEFAULT '{}',
    raw_envelope_id INTEGER REFERENCES raw_envelopes(envelope_id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_otlp_logs_time
    ON otlp_logs(timestamp_ns);
CREATE INDEX IF NOT EXISTS idx_otlp_logs_service_time
    ON otlp_logs(service_name, timestamp_ns);
CREATE INDEX IF NOT EXISTS idx_otlp_logs_session_time
    ON otlp_logs(session_id, timestamp_ns);

-- OTLP spans. Used for direct trace storage if Tempo is bypassed or mirrored.
CREATE TABLE IF NOT EXISTS otlp_spans (
    span_row_id INTEGER PRIMARY KEY,
    received_at_ns INTEGER NOT NULL,
    trace_id TEXT NOT NULL,
    span_id TEXT NOT NULL,
    parent_span_id TEXT,
    session_id TEXT REFERENCES sessions(session_id) ON DELETE SET NULL,
    service_name TEXT,
    scope_name TEXT,
    scope_version TEXT,
    name TEXT NOT NULL,
    kind INTEGER NOT NULL,
    start_time_ns INTEGER NOT NULL,
    end_time_ns INTEGER NOT NULL,
    duration_ns INTEGER NOT NULL,
    status_code INTEGER,
    status_message TEXT,
    resource_attributes_json TEXT NOT NULL DEFAULT '{}',
    attributes_json TEXT NOT NULL DEFAULT '{}',
    events_json TEXT,
    links_json TEXT,
    raw_envelope_id INTEGER REFERENCES raw_envelopes(envelope_id) ON DELETE SET NULL,
    UNIQUE(trace_id, span_id)
);

CREATE INDEX IF NOT EXISTS idx_otlp_spans_trace
    ON otlp_spans(trace_id, start_time_ns);
CREATE INDEX IF NOT EXISTS idx_otlp_spans_session
    ON otlp_spans(session_id, start_time_ns);

-- OTLP numeric datapoints. Suitable for Prometheus export from SQLite.
CREATE TABLE IF NOT EXISTS otlp_metric_points (
    metric_point_id INTEGER PRIMARY KEY,
    received_at_ns INTEGER NOT NULL,
    start_time_ns INTEGER,
    end_time_ns INTEGER,
    service_name TEXT,
    session_id TEXT REFERENCES sessions(session_id) ON DELETE SET NULL,
    scope_name TEXT,
    scope_version TEXT,
    metric_name TEXT NOT NULL,
    description TEXT,
    unit TEXT,
    instrument_type TEXT NOT NULL,
    aggregation_temporality TEXT,
    is_monotonic INTEGER CHECK (is_monotonic IN (0, 1)),
    number_type TEXT NOT NULL CHECK (number_type IN ('int', 'double')),
    value_int INTEGER,
    value_double REAL,
    exemplar_json TEXT,
    attributes_json TEXT NOT NULL DEFAULT '{}',
    resource_attributes_json TEXT NOT NULL DEFAULT '{}',
    raw_envelope_id INTEGER REFERENCES raw_envelopes(envelope_id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_otlp_metric_points_name_time
    ON otlp_metric_points(metric_name, end_time_ns);
CREATE INDEX IF NOT EXISTS idx_otlp_metric_points_session_time
    ON otlp_metric_points(session_id, end_time_ns);

-- MITM / capture wrapper output.
CREATE TABLE IF NOT EXISTS api_captures (
    capture_id INTEGER PRIMARY KEY,
    observed_at_ns INTEGER NOT NULL,
    flow_id TEXT NOT NULL,
    capture_type TEXT NOT NULL CHECK (
        capture_type IN ('stream_start', 'stream_chunk', 'stream_end', 'exchange')
    ),
    request_method TEXT,
    request_url TEXT,
    request_http_version TEXT,
    request_headers_json TEXT,
    request_body_text TEXT,
    response_status_code INTEGER,
    response_http_version TEXT,
    response_headers_json TEXT,
    response_body_text TEXT,
    chunk_index INTEGER,
    elapsed_ms REAL,
    duration_ms REAL,
    source_file_path TEXT,
    session_id TEXT REFERENCES sessions(session_id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_api_captures_flow
    ON api_captures(flow_id, observed_at_ns);
CREATE INDEX IF NOT EXISTS idx_api_captures_time
    ON api_captures(observed_at_ns);

-- Collector-side failures and rejected envelopes.
CREATE TABLE IF NOT EXISTS ingest_failures (
    failure_id INTEGER PRIMARY KEY,
    failed_at_ns INTEGER NOT NULL,
    source_key TEXT NOT NULL,
    endpoint_key TEXT,
    fs_path TEXT,
    payload_excerpt TEXT,
    error_text TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ingest_failures_time
    ON ingest_failures(failed_at_ns);

-- Alert stream: budget warnings, stale files, orphaned subagents, scrape gaps.
CREATE TABLE IF NOT EXISTS alerts (
    alert_id INTEGER PRIMARY KEY,
    raised_at_ns INTEGER NOT NULL,
    cleared_at_ns INTEGER,
    severity TEXT NOT NULL CHECK (severity IN ('info', 'warn', 'error', 'critical')),
    alert_key TEXT NOT NULL,
    session_id TEXT REFERENCES sessions(session_id) ON DELETE SET NULL,
    source_id INTEGER REFERENCES source_registry(source_id) ON DELETE SET NULL,
    message TEXT NOT NULL,
    metadata_json TEXT
);

CREATE INDEX IF NOT EXISTS idx_alerts_open
    ON alerts(cleared_at_ns, severity, raised_at_ns);

-- Convenience views for a Prometheus exporter built on top of SQLite.
CREATE VIEW IF NOT EXISTS v_prom_active_sessions AS
SELECT
    session_id,
    model_display AS model,
    total_cost_usd AS cost_usage_usd,
    total_input_tokens AS input_tokens,
    total_output_tokens AS output_tokens,
    (total_duration_ms / 1000.0) AS active_time_seconds,
    budget_consumed_tokens,
    budget_limit_tokens,
    active_subagent_count
FROM sessions
WHERE ended_at_ns IS NULL;

CREATE VIEW IF NOT EXISTS v_prom_token_usage AS
SELECT session_id, model, 'input' AS type, input_tokens AS value
FROM v_prom_active_sessions
UNION ALL
SELECT session_id, model, 'output' AS type, output_tokens AS value
FROM v_prom_active_sessions;

COMMIT;
