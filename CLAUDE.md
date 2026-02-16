# claude-warden

Token-saving hooks + monitoring infrastructure for Claude Code.

## Repository structure

- `hooks/` -- Bash hook scripts invoked by Claude Code at tool-use lifecycle events
- `hooks/lib/common.sh` -- Shared library sourced by all hooks (parsing, event emission, latency tracking, sanitization)
- `hooks/lib/otel-trace.sh` -- OTLP/HTTP trace span emitter (bash + curl, fire-and-forget)
- `monitoring/` -- Docker Compose observability stack (Loki, OTEL Collector, Prometheus, Node Exporter, Grafana)
- `monitoring/otel-collector-config.yaml` -- Collector pipelines: logs (otlp + filelog -> Loki), metrics (otlp -> Prometheus), traces (otlp -> debug)
- `monitoring/loki-config.yaml` -- Loki 3.4.2 config (TSDB schema v13, filesystem storage, 30-day retention)
- `monitoring/grafana/` -- Provisioned datasources (Prometheus, Loki) and dashboards
- `tests/` -- Fixture-driven test harness (`bash tests/run.sh`)
- `install.sh` / `uninstall.sh` -- Manages symlinks into `~/.claude/`

## Key patterns

### Hook conventions
- All hooks source `hooks/lib/common.sh` first
- Input is read once via `_warden_read_input` (stdin with 5s timeout)
- Field extraction uses bash regex for top-level strings (`_warden_parse_toplevel`) -- 10ms faster than jq
- Nested fields use a single jq call returning TSV (`_warden_parse_tool_input`)
- Events are appended to `$WARDEN_EVENTS_FILE` (`~/.claude/.statusline/events.jsonl`)
- Hooks exit with `_warden_suppress_ok` (allow, suppress output) or `_warden_deny` (block with reason)

### Event schema (events.jsonl)
Every line is a JSON object with at minimum:
```json
{"timestamp": <relative_seconds>, "event_type": "<type>", "tool": "<tool_name>"}
```
Event types: `allowed`, `blocked`, `truncated`, `tool_latency`, `completed`

The `timestamp` field is **relative to session start** (not epoch). The OTEL collector filelog receiver uses ingestion time as the log timestamp and preserves the relative value as `session_relative_ts`.

### Latency tracking
- `pre-tool-use` calls `_warden_record_tool_start "$TOOL_NAME"` which writes `date +%s%N` to a state file
- `post-tool-use` calls `_warden_compute_tool_latency "$TOOL_NAME"` which reads start, computes delta, sets `WARDEN_TOOL_LATENCY_MS`
- `_warden_emit_latency` writes the `tool_latency` event
- `otel-trace.sh` emits an OTLP span via curl to `localhost:4318/v1/traces`

### Trace span format
- `trace_id`: deterministic from session ID (md5 of `"warden-trace-$session_id"`)
- `span_id`: random 16 hex chars (head -c8 /dev/urandom | xxd -p)
- `parent_span_id`: deterministic from session ID (md5 of `"warden-root-$session_id"`, first 16 chars)
- Span kind: 3 (CLIENT)
- Attributes: `tool.name`, `tool.command`, `tool.output_bytes`, `tool.duration_ms`

## Monitoring stack

All containers use `network_mode: host`. Start with `cd monitoring && docker compose up -d`.

| Service | Port | Notes |
|---|---|---|
| Loki | 3100 | OTLP ingestion at `/otlp`, LogQL queries at `/loki/api/v1/query_range` |
| OTEL Collector | 4317 (gRPC), 4318 (HTTP) | Receives from Claude Code + hook curl calls |
| Prometheus | 9090 | Scrapes OTEL collector metrics exporter on 8889 |
| Node Exporter | 9101 | Textfile collector for budget-cli metrics |
| Grafana | 3000 | admin/admin, two provisioned datasources (Prometheus, Loki) |

### OTEL collector pipelines
- **logs**: receivers `[otlp, filelog/warden]` -> processors `[memory_limiter, resource, batch]` -> exporters `[otlp_http/loki, debug]`
- **metrics**: receivers `[otlp]` -> same processors -> exporters `[prometheus, debug]`
- **traces**: receivers `[otlp]` -> same processors -> exporters `[debug]`

The `filelog/warden` receiver tails `/var/log/claude/events.jsonl` (bind-mounted from `~/.claude/.statusline/events.jsonl`).

### LogQL examples
```
# All events
{service_name="claude-code"} | json

# Slow tool calls
{service_name="claude-code"} | json | event_type="tool_latency" | duration_ms > 2000

# Blocked events with rule details
{service_name="claude-code"} | json | event_type="blocked"

# Specific tool
{service_name="claude-code"} | json | tool_name="Bash"
```

## Development notes

### Running the stack
```bash
cd monitoring && docker compose up -d
```

### Restarting after config changes
```bash
cd monitoring && docker compose restart otel-collector  # after editing otel-collector-config.yaml
cd monitoring && docker compose restart grafana          # after editing provisioning yamls
```

### Adding a new dashboard
Drop a JSON file into `monitoring/grafana/dashboards/`. Grafana auto-provisions every 10 seconds. Use datasource uid `loki-claude-warden` for Loki panels and `PBFA97CFB590B2093` for Prometheus panels.

### Future work
- **Tempo**: Add Grafana Tempo container for full trace storage and visualization. Currently traces export to `debug` only. Would enable trace-to-log correlation in Grafana.
- **Alerting**: Grafana alerting rules for sustained high latency, budget threshold breaches, or error rate spikes.
- **Session-level spans**: Emit a root span at `session-start` and close it at `session-end` to get full session trace waterfall.
- **TTFB approximation**: The delta between an `api_request` log timestamp and the next `pre-tool-use` invocation gives model planning overhead. Not yet implemented.
- **Dashboard variables**: Add Grafana template variables for tool_name, session_id, and time range filtering.
- **Retention tuning**: Loki is set to 30 days. Adjust `limits_config.retention_period` in `loki-config.yaml` as needed.

## Code style
- Bash hooks: `set -o pipefail`, no `set -e` (hooks must not fail silently on benign errors)
- Functions prefixed with `_warden_`
- State files in `$WARDEN_STATE_DIR` (`~/.claude/.statusline/`)
- Secrets are scrubbed before writing to events.jsonl (see `_warden_emit_block`, `_warden_emit_event`)
- JSON output uses `jq -n` for safe escaping
- Fire-and-forget background processes use `& disown` pattern
