# SQLite Collector Design

This document turns the current multi-surface `claude-warden` state model into a single-writer collector design backed by one SQLite database. The concrete schema lives in [schema.sql](docs/sqlite/schema.sql).

## Goals

- Replace pipe-delimited state files, JSONL, CSV, temp files, and Prometheus textfiles as the canonical write surfaces.
- Keep hooks cheap: no direct SQLite writes from short-lived Bash processes.
- Preserve all current observability surfaces:
  - hook/session events
  - statusline snapshots
  - budget tracking
  - subagent lifecycle
  - OTLP logs/metrics/traces
  - capture wrapper traffic logs
- Run on Linux, macOS, and Windows with one local collector binary.

## Proposed Go Collector

Use a single local Go binary as the only SQLite writer.

### Runtime shape

- Language: Go
- DB: SQLite in WAL mode
- Write model: single process owns DB handle
- Read model: same process exposes `/metrics` and optional query/debug endpoints
- Transport from hooks:
  - primary: Unix domain socket on Linux/macOS
  - primary on Windows: named pipe
  - fallback: loopback HTTP

### Proposed local paths

- Linux
  - config: `${XDG_CONFIG_HOME:-$HOME/.config}/claude-warden`
  - state: `${XDG_STATE_HOME:-$HOME/.local/state}/claude-warden`
  - cache: `${XDG_CACHE_HOME:-$HOME/.cache}/claude-warden`
- macOS
  - config/state/cache: `$HOME/Library/Application Support/claude-warden`
- Windows
  - config: `%AppData%\\claude-warden`
  - state/cache: `%LocalAppData%\\claude-warden`

Compatibility shims can continue to read `~/.claude/...` during migration.

### Proposed collector endpoints

Primary ingest transport:

- `unix://${STATE_DIR}/collector.sock`
- `\\\\.\\pipe\\claude-warden`

Optional HTTP mirror on `127.0.0.1:9464`:

- `GET /healthz`
- `GET /readyz`
- `GET /metrics`
- `GET /debug/sources`
- `GET /debug/endpoints`
- `GET /debug/open-artifacts`
- `GET /v1/sessions`
- `GET /v1/sessions/{session_id}`
- `GET /v1/events`
- `GET /v1/artifacts`
- `POST /v1/ingest/hook`
- `POST /v1/ingest/statusline`
- `POST /v1/ingest/capture`

Optional per-hook HTTP aliases if you want explicit routes instead of one generic ingest route:

- `POST /v1/ingest/session-start`
- `POST /v1/ingest/session-end`
- `POST /v1/ingest/stop`
- `POST /v1/ingest/pre-tool-use`
- `POST /v1/ingest/post-tool-use`
- `POST /v1/ingest/post-tool-use-failure`
- `POST /v1/ingest/subagent-start`
- `POST /v1/ingest/subagent-stop`
- `POST /v1/ingest/pre-compact`
- `POST /v1/ingest/config-change`
- `POST /v1/ingest/elicitation`
- `POST /v1/ingest/elicitation-result`
- `POST /v1/ingest/instructions-loaded`
- `POST /v1/ingest/statusline-snapshot`

Optional OTLP listeners, owned directly by the collector:

- `127.0.0.1:4317` OTLP gRPC
- `127.0.0.1:4318` OTLP HTTP

That lets the collector replace the current OTEL collector for local persistence, while still optionally forwarding to Loki/Tempo/Prometheus.

## Current Repo-Owned Data Sources

These are the sources that `claude-warden` itself configures or writes today.

### Claude hook ingress

Configured in [settings.hooks.json](settings.hooks.json):

- `PreToolUse` -> `$HOME/.claude/hooks/pre-tool-use`
- `PostToolUse` -> `$HOME/.claude/hooks/post-tool-use`
- `PostToolUse` for `Read` -> `$HOME/.claude/hooks/read-compress`
- `PostToolUse` for `mcp__*` -> `$HOME/.claude/hooks/mcp-output-compress`
- `PermissionRequest` -> `$HOME/.claude/hooks/permission-request`
- `Stop` -> `$HOME/.claude/hooks/stop`
- `SubagentStart` -> `$HOME/.claude/hooks/subagent-start`
- `SubagentStop` -> `$HOME/.claude/hooks/subagent-stop`
- `SessionStart` -> `$HOME/.claude/hooks/session-start`
- `PostToolUseFailure` -> `$HOME/.claude/hooks/tool-error`
- `SessionEnd` -> `$HOME/.claude/hooks/session-end`
- `ConfigChange` -> `$HOME/.claude/hooks/config-change`
- `PreCompact` -> `$HOME/.claude/hooks/pre-compact`
- `Elicitation` -> `$HOME/.claude/hooks/elicitation`
- `ElicitationResult` -> `$HOME/.claude/hooks/elicitation-result`
- `InstructionsLoaded` -> `$HOME/.claude/hooks/instructions-loaded`
- Statusline -> `$HOME/.claude/statusline.sh`

### Hook event types currently emitted

Observed from hook implementations under [hooks/](hooks):

- `session_start`
- `session_end`
- `session_stop`
- `subagent_start`
- `subagent_stop`
- `compaction`
- `tool_output_size`
- `tool_latency`
- `blocked`
- `allowed`
- `truncated`
- `tool_error`
- `instructions_loaded`
- `elicitation`
- `elicitation_result`
- `mcp_tool_start`

Important nuance: the repo does not currently emit a separate `suppressed` event type. Suppressed output is recorded as `event_type="truncated"` with a rule like `output_suppressed`.

### `~/.claude` file surfaces written by `claude-warden`

Current repo defaults come from [hooks/lib/common.sh](hooks/lib/common.sh), [statusline.sh](statusline.sh), and the hook scripts.

Canonical state files:

- `~/.claude/.statusline/events.jsonl`
- `~/.claude/.statusline/events.jsonl.1`
- `~/.claude/.statusline/.session_start`
- `~/.claude/.statusline/budget-export`
- `~/.claude/.statusline/budget-alert`
- `~/.claude/.statusline/reset-reason`
- `~/.claude/.statusline/subagent-count`

Per-session state patterns:

- `~/.claude/.statusline/state-{session_id}`
- `~/.claude/.statusline/session-{session_id}`
- `~/.claude/.statusline/saved-{session_id}`
- `~/.claude/.statusline/latency-{session_id}`
- `~/.claude/.statusline/clears-{session_id}`
- `~/.claude/.statusline/peak-{session_id}`

Per-invocation scratch patterns:

- `~/.claude/.statusline/.tool-start-{tool_name}-{pid}`
- `~/.claude/.statusline/.quiet-override-*`

Budget/config surfaces:

- `~/.claude/.warden/budget.state`
- `~/.claude/.warden/profile`
- `~/.claude/.warden/warden.env`
- `~/.claude/.warden/warden.env.sh`

Session timing/budget snapshots:

- `~/.claude/.session-times/{session_id}.start`
- `~/.claude/.session-times/{session_id}.start_ns`
- `~/.claude/.session-budgets/{session_id}.start.json`

Subagent state:

- `~/.claude/.subagent-state/{agent_id}`
- `~/.claude/.subagent-state/{agent_id}.start`
- `~/.claude/.subagent-state/{agent_id}.bytes`
- `~/.claude/.subagent-state/session-{session_id}`

Monitoring/log outputs:

- `~/.claude/.monitoring/session-costs.csv`
- `~/.claude/.monitoring/textfile/budget.prom`
- `~/.claude/.monitoring/textfile/claude-code-session-{session_id}.prom`
- `~/.claude/errors.log`
- `~/.claude/session-log.txt`
- `~/.claude/agent-stats.csv`

Optional capture wrapper outputs:

- `~/.claude/capture-mitm.log`
- `~/claude-captures/YYYY-MM-DD/capture-HHMMSS.jsonl`

### Temp/offload surfaces written by the repo

Observed in [hooks/mcp-output-compress](hooks/mcp-output-compress) and [hooks/lib/common.sh](hooks/lib/common.sh):

- `${TMPDIR:-/tmp}/claude-mcp-output/.seq-{session_short}`
- `${TMPDIR:-/tmp}/claude-mcp-output/{session_short}-{mcp_server}-{mcp_op}-{seq}.txt`
- `/tmp/warden-tc.XXXXXX/` token-count scratch dirs

These belong in the `artifacts` and `artifact_events` tables, not as first-class canonical state.

## Current Network / Telemetry Endpoints

These are the configured or observed endpoints in the current repo, not every vendor endpoint each upstream product supports.

### Claude Code telemetry -> OTEL collector

Configured in [config/defaults.json](config/defaults.json):

- `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317`
- `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`
- `OTEL_METRICS_EXPORTER=otlp`
- `OTEL_LOGS_EXPORTER=otlp`
- `CLAUDE_CODE_ENABLE_TELEMETRY=1`

This implies Claude Code may emit OTLP metrics and logs to:

- `localhost:4317` OTLP gRPC

### Hook trace egress

Configured in [hooks/lib/otel-trace.sh](hooks/lib/otel-trace.sh):

- `http://localhost:4318/v1/traces`

### OTEL collector

Configured in [monitoring/otel-collector-config.yaml](monitoring/otel-collector-config.yaml):

- ingest:
  - `0.0.0.0:4317` OTLP gRPC
  - `0.0.0.0:4318` OTLP HTTP
  - file tail on `/var/log/claude/events.jsonl`
- export:
  - `0.0.0.0:8889` Prometheus scrape endpoint
  - `http://localhost:3100/otlp` Loki OTLP HTTP
  - `localhost:3205` Tempo OTLP gRPC

macOS Docker override swaps the Loki and Tempo targets to service names in [monitoring/macos/otel-collector-config.yaml](monitoring/macos/otel-collector-config.yaml):

- `http://loki:3100/otlp`
- `tempo:3205`

### Prometheus

Configured in [monitoring/prometheus.yml](monitoring/prometheus.yml) and [monitoring/docker-compose.yml](monitoring/docker-compose.yml):

- UI/API: `http://localhost:9090`
- configured scrape targets:
  - `localhost:8889` OTEL collector Prometheus exporter
  - `localhost:9101` node-exporter textfile collector
  - `localhost:9090` self scrape
- lifecycle reload endpoint is enabled via `--web.enable-lifecycle`

### Node exporter

Configured in [monitoring/docker-compose.yml](monitoring/docker-compose.yml):

- `http://localhost:9101/metrics`
- reads `~/.claude/.monitoring/textfile`

### Loki

Configured in [monitoring/loki-config.yaml](monitoring/loki-config.yaml):

- `http://localhost:3100`
- `http://localhost:3100/ready`
- `http://localhost:3100/loki/api/v1/query`
- `http://localhost:3100/loki/api/v1/query_range`
- OTLP HTTP ingest at `http://localhost:3100/otlp`

### Tempo

Configured in [monitoring/tempo-config.yaml](monitoring/tempo-config.yaml):

- UI/API base: `http://localhost:3200`
- `http://localhost:3200/ready`
- OTLP gRPC ingest: `localhost:3205`
- OTLP HTTP ingest: `localhost:3206`
- internal Tempo gRPC server: `localhost:9096`

### Grafana

Configured in [monitoring/grafana/provisioning/datasources/datasources.yaml](monitoring/grafana/provisioning/datasources/datasources.yaml):

- UI/API: `http://localhost:3000`
- provisioned datasources:
  - Prometheus -> `http://localhost:9090`
  - Loki -> `http://localhost:3100`
  - Tempo -> `http://localhost:3200`

Provisioned dashboard UIDs:

- `warden-live`
- `warden-output-size`
- `warden-session-detail`
- `warden-session-index`
- `warden-subagent-lifecycle`
- `warden-tool-latency`
- `claude-code-otel`

### Capture wrapper / MITM

Configured in [capture/claude](capture/claude):

- local proxy: `http://127.0.0.1:8080`
- upstream target: `api.anthropic.com`
- log file: `~/.claude/capture-mitm.log`
- JSONL captures: `~/claude-captures/YYYY-MM-DD/capture-HHMMSS.jsonl`

Capture record types from [capture/logger.py](capture/logger.py):

- `stream_start`
- `stream_chunk`
- `stream_end`
- `exchange`

## Machine-Observed But Not Repo-Owned Surfaces

These exist on this machine and may be session-adjacent, but they are not written by the `claude-warden` repo code itself. The collector should treat them as optional external sources.

Under `~/.claude` on this host:

- `~/.claude/.budget/budget.json` legacy budget-cli state
- `~/.claude/.credentials.json`
- `~/.claude/.mcp.json.tmp`
- `~/.claude/.claude.zip`
- `~/.claude/.monitoring.zip`
- `~/.claude/projects/` Claude Code built-in session logs
- `~/.claude/statsig/` or similar Claude Code telemetry/cache dirs if present

Under `/tmp` on this host:

- `/tmp/claude-mcp-browser-bridge-zack/*.sock`
- `/tmp/claude-mcp-output/*` from this repo

Under `/home/zack/tmp` on this host:

- `/home/zack/tmp/claude-1000/**` session/worktree scratch trees
- many unrelated scratch files and repos not referenced by `claude-warden`

Recommendation: only ingest `/home/zack/tmp/**` via explicit allowlist rules. It is too broad to treat as canonical collector input.

## Mapping Current Surfaces To SQLite Tables

- hook stdin JSON -> `raw_envelopes`
- normalized hook/session events -> `hook_events`
- session lifecycle rollups -> `sessions`
- statusline snapshots -> `context_snapshots`
- budget state and exported Prom snapshots -> `budget_snapshots`
- correlated tool calls -> `tool_calls`
- subagent lifecycle -> `subagents`
- file outputs and temp offloads -> `artifacts`, `artifact_events`
- OTLP logs -> `otlp_logs`
- OTLP traces -> `otlp_spans`
- OTLP metrics -> `otlp_metric_points`
- MITM/capture wrapper output -> `api_captures`
- parse/ingest failures -> `ingest_failures`
- warnings such as stale temp files or orphaned subagents -> `alerts`

## Recommended Migration Sequence

1. Introduce the Go collector and SQLite DB without changing dashboards.
2. Change hooks to emit one generic envelope to the collector instead of writing local state directly.
3. Keep exporting Prometheus metrics from the collector so Grafana stays unchanged.
4. Mirror `events.jsonl` into SQLite first, then stop using it as canonical state.
5. Replace the remaining `~/.claude/.statusline/*`, CSV, and textfile state with SQLite-backed projections.
6. Retain `~/.claude` only for Claude Code hook binaries, compat shims, and user-facing exports.
