# Claude Code Native OTEL Schema

> Populated from binary analysis of Claude Code 2.1.76.
> Run `scripts/discover-otel-schema.sh` to capture live data and verify.

## Activation

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=true
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
```

Without `CLAUDE_CODE_ENABLE_TELEMETRY=true`, no OTEL is exported to user endpoints.

## Known Metrics

| Metric | Type | Labels | Notes |
|--------|------|--------|-------|
| `claude_code_cost_usage_USD_total` | counter | `session.id`, `model` | Session cost in USD |
| `claude_code_token_usage_tokens_total` | counter | `session.id`, `model`, `type` | Token consumption |
| `claude_code_active_time_seconds_total` | counter | `session.id`, `model` | Wall-clock active time |
| `claude_code_session_count_total` | counter | `session.id`, `model` | Session count |

### Token Type Labels (live-confirmed 2.1.76)

`type` values on `claude_code_token_usage_tokens_total`:
- `input` — prompt tokens
- `output` — completion tokens
- `cacheCreation` — new prompt cache entries
- `cacheRead` — prompt cache hits

### Metric Label Control

| Variable | Default | Effect |
|----------|---------|--------|
| `OTEL_METRICS_INCLUDE_SESSION_ID` | true | Add `session.id` to metrics |
| `OTEL_METRICS_INCLUDE_VERSION` | false | Add `service.version` to metrics |
| `OTEL_METRICS_INCLUDE_ACCOUNT_UUID` | true | Add account UUID (PII risk) |

### PII in Metric Labels (live-confirmed)

The following PII labels appear on all metrics **by default**, independent of
`OTEL_METRICS_INCLUDE_ACCOUNT_UUID`:

| Label | Example | Notes |
|-------|---------|-------|
| `user_email` | `user@example.com` | Always present |
| `user_id` | SHA-256 hash | Always present |
| `user_account_id` | `user_01Eiim...` | Always present |
| `user_account_uuid` | UUID | Controlled by `OTEL_METRICS_INCLUDE_ACCOUNT_UUID` |
| `organization_id` | UUID | Always present |
| `terminal_type` | `kitty`, `iterm2` | Always present |

**Recommendation:** If exporting to shared infrastructure, strip PII labels in
the OTEL collector via a `transform` processor before the Prometheus exporter.

## Trace Spans

### Span Hierarchy

```
claude_code.interaction          <- top-level user turn
  claude_code.llm_request        <- API call to Claude
  claude_code.tool               <- tool invocation
    claude_code.tool.blocked_on_user  <- permission prompt wait
    claude_code.tool.execution        <- actual execution
  claude_code.hook               <- hook system call
```

### `claude_code.interaction`

| Attribute | Type | Notes |
|-----------|------|-------|
| `span.type` | string | `"interaction"` |
| `user_prompt` | string | REDACTED unless `OTEL_LOG_USER_PROMPTS=true` |
| `user_prompt_length` | int | Always present |
| `interaction.sequence` | int | Incremental counter per session |
| `interaction.duration_ms` | int | Set on span end |

### `claude_code.llm_request`

| Attribute | Type | Notes |
|-----------|------|-------|
| `model` | string | e.g., `claude-sonnet-4-5` |
| `llm_request.context` | string | `"interaction"` or `"standalone"` |
| `speed` | string | `"fast"` or `"normal"` |
| `query_source` | string | Optional metadata |
| `duration_ms` | int | Total request time |
| `input_tokens` | int | Prompt tokens (exact) |
| `output_tokens` | int | Completion tokens (exact) |
| `cache_read_tokens` | int | Prompt cache hits |
| `cache_creation_tokens` | int | New cache entries |
| `success` | bool | |
| `status_code` | int | HTTP status |
| `error` | string | Error message if failed |
| `attempt` | int | Retry count |
| `response.has_tool_call` | bool | |
| `ttft_ms` | int | Time-to-first-token |

### `claude_code.tool`

| Attribute | Type | Notes |
|-----------|------|-------|
| `tool_name` | string | e.g., `Read`, `Bash`, `Write` |
| `span.type` | string | `"tool"` |
| `duration_ms` | int | Tool execution time |
| `result_tokens` | int | Token count of tool result |
| `success` | bool | |

### `claude_code.tool.blocked_on_user`

| Attribute | Type | Notes |
|-----------|------|-------|
| `decision` | string | `"approve"`, `"deny"`, etc. |
| `source` | string | `"permission_prompt"`, etc. |
| `duration_ms` | int | User wait time |

### `claude_code.tool.execution`

| Attribute | Type | Notes |
|-----------|------|-------|
| `success` | bool | |
| `error` | string | |
| `duration_ms` | int | |

### `claude_code.hook`

| Attribute | Type | Notes |
|-----------|------|-------|
| `hook_event` | string | `PreToolUse`, `PostToolUse`, etc. |
| `hook_name` | string | Script name |
| `num_hooks` | int | Total hooks for this event |
| `hook_definitions` | string | JSON config |
| `num_success` | int | |
| `num_blocking` | int | |
| `num_non_blocking_error` | int | |
| `num_cancelled` | int | |
| `duration_ms` | int | |

## Resource Attributes (Auto-Detected)

| Attribute | Value | Live-Confirmed |
|-----------|-------|----------------|
| `host.arch` | `amd64`, `arm64` | `amd64` |
| `os.type` | `linux`, `darwin` | `linux` |
| `os.version` | kernel version | `6.19.6-arch1-1` |
| `service.name` | `claude-code` | `claude-code` |
| `service.version` | semver | `2.1.76` |
| `otel_scope_name` | instrumentation scope | `com.anthropic.claude_code` |
| `otel_scope_version` | semver | `2.1.76` |
| `terminal_type` | terminal emulator | `kitty` |
| `host.name` | hostname | -- |
| `host.id` | machine ID | -- |
| `service.instance.id` | random UUID per process | -- |
| `telemetry.sdk.name` | `opentelemetry` | -- |
| `telemetry.sdk.language` | `nodejs` | -- |

## Logs (1P Event Pipeline)

Logger: `com.anthropic.claude_code.events`. Over 400 `tengu_*` events emitted to
Anthropic's 1P pipeline. Key categories relevant to warden overlap:

| Category | Key Events | Overlap with Hooks |
|----------|-----------|-------------------|
| Tool use | `tengu_tool_use_success/error/cancelled` | Tool outcome tracking |
| Bash | `tengu_bash_tool_command_executed` | Command tracking |
| Compact | `tengu_compact`, `tengu_auto_compact_succeeded` | Compaction detection |
| Hooks | `tengu_run_hook`, `tengu_pre_tool_hook_error` | Hook self-monitoring |
| API | `tengu_api_query/success/error/retry` | API request tracking |
| Session | `tengu_session_resumed`, `tengu_context_size` | Session lifecycle |
| MCP | `tengu_mcp_tool_call_auth_error` | MCP tool tracking |

These logs flow to Anthropic's internal pipeline; they are NOT exported to the user's
OTEL endpoint unless `CLAUDE_CODE_ENABLE_TELEMETRY=true` AND the OTEL log exporter
catches them (the 1P logger shares the LoggerProvider).

## Signal Gap Analysis

### Hooks provide / OTEL does not (unique value)

| Signal | Hook Source | Why OTEL can't replace |
|--------|-----------|----------------------|
| Tool output truncation | `post-tool-use` modifyOutput | Enforcement: hooks *modify* the output |
| Blocked tool calls | `pre-tool-use` deny | Enforcement: hooks *prevent* execution |
| Quiet override injection | `pre-tool-use` updatedInput | Enforcement: hooks *rewrite* commands |
| System reminder stripping | `post-tool-use` modifyOutput | Enforcement: hooks *remove* content |
| Subagent budget enforcement | `subagent-start` continue=false | Enforcement: hooks *stop* subagents |
| Output size before truncation | `post-tool-use` | Native OTEL only sees post-hook output |
| Bytes-to-tokens saved estimate | `post-tool-use` | Savings metric not in native OTEL |
| Subagent cumulative byte tracking | `post-tool-use` byte file | Per-agent output accumulation |

### Overlap Analysis (hooks reconstruct / OTEL already has)

| Signal | Hook Source | Native OTEL Source | Action |
|--------|-----------|-------------------|--------|
| Tool latency | `.tool-start-*` file + compute_tool_latency | `claude_code.tool` span `duration_ms` | **REMOVE** from hooks (Phase 4a) |
| Tool OTEL trace span | `otel-trace.sh` curl to 4318 | `claude_code.tool` span | **REMOVE** from hooks (Phase 4a) |
| Session cost | statusline prom scrape | `claude_code_cost_usage_USD_total` metric | **REMOVE** when collector serves `/metrics` |
| Token counts | estimated (bytes/3.5) | `input_tokens`, `output_tokens` on `llm_request` | **REPLACE** estimate with native (Phase 6f) |
| Active time | statusline prom scrape | `claude_code_active_time_seconds_total` metric | **REMOVE** when collector serves `/metrics` |
| TTFT | Not implemented | `ttft_ms` on `llm_request` | **USE** native directly (Phase 6a) |
| Cache efficiency | statusline snapshot | `cache_read_tokens`, `cache_creation_tokens` | **USE** native directly (Phase 6c) |
| Tool success/failure | Not tracked | `success` on `claude_code.tool` span | **USE** native (new signal for free) |
| Permission wait time | Not tracked | `claude_code.tool.blocked_on_user` `duration_ms` | **USE** native (new signal for free) |
| Hook execution time | Not tracked | `claude_code.hook` `duration_ms` | **USE** native (warden self-monitoring) |

### New signals available for free (no hook work needed)

| Signal | Source | Use case |
|--------|--------|----------|
| TTFT (time-to-first-token) | `llm_request.ttft_ms` | Model responsiveness tracking |
| Retry count | `llm_request.attempt` | API reliability monitoring |
| Cache hit ratio | `cache_read_tokens / input_tokens` | Prompt cache effectiveness |
| Permission friction | `tool.blocked_on_user.duration_ms` | UX measurement |
| Hook overhead | `hook.duration_ms` | Warden self-monitoring |
| Model fallback | `tengu_model_fallback_triggered` | Model availability |
| Interaction sequence | `interaction.sequence` | Turn counter per session |

## Env Var Reference

### Export Control

| Variable | Default | Effect |
|----------|---------|--------|
| `CLAUDE_CODE_ENABLE_TELEMETRY` | false | Master switch for user OTLP export |
| `DISABLE_TELEMETRY` | false | Kills ALL non-essential telemetry |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | false | Same as DISABLE_TELEMETRY |

### OTEL Endpoint Configuration

| Variable | Default | Effect |
|----------|---------|--------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | -- | Base OTLP endpoint URL |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | `grpc`, `http/protobuf`, `http/json` |
| `OTEL_EXPORTER_OTLP_HEADERS` | -- | Auth headers |
| `OTEL_SERVICE_NAME` | -- | Overrides `service.name` resource attr |
| `OTEL_RESOURCE_ATTRIBUTES` | -- | `key=value,key=value` pairs |

### Privacy Controls

| Variable | Default | Effect |
|----------|---------|--------|
| `OTEL_LOG_USER_PROMPTS` | false | Include raw user prompts in spans (PII) |
| `OTEL_LOG_TOOL_CONTENT` | false | Include tool I/O in span events (PII) |
| `OTEL_METRICS_INCLUDE_ACCOUNT_UUID` | true | Add account UUID to metrics (PII) |

### Batch Tuning

| Variable | Default | Effect |
|----------|---------|--------|
| `OTEL_LOGS_EXPORT_INTERVAL` | 10000ms | Log batch flush interval |
| `OTEL_METRIC_EXPORT_INTERVAL` | 60000ms | Metric flush interval |
| `OTEL_BLRP_MAX_EXPORT_BATCH_SIZE` | 512 | Max logs per batch |
| `OTEL_BLRP_MAX_QUEUE_SIZE` | 2048 | Max queue before drop |
| `OTEL_BLRP_SCHEDULE_DELAY` | 5000ms | Batch schedule delay |
| `OTEL_BLRP_EXPORT_TIMEOUT` | 30000ms | Export timeout |

### Additional Telemetry Surfaces

| Variable | Effect |
|----------|--------|
| `CLAUDE_CODE_PERFETTO_TRACE` | Path to `.pftrace` file for Perfetto trace capture |
| `ENABLE_BETA_TRACING_DETAILED` + `BETA_TRACING_ENDPOINT` | Detailed OTEL with hook spans |
| `CLAUDE_CODE_DEBUG_LOGS_DIR` | Debug log directory (default: `~/.claude/logs/`) |
| `CLAUDE_CODE_DEBUG_LOG_LEVEL` | `verbose`, `debug`, `info`, `warn`, `error` |
| `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` | Enhanced internal telemetry |

## Perfetto Trace Capture

### Activation

```bash
export CLAUDE_CODE_PERFETTO_TRACE=/path/to/session.pftrace
```

Produces a Chrome Trace Event file viewable in [ui.perfetto.dev](https://ui.perfetto.dev).
Captures the same span hierarchy as OTEL but in a local file, no collector needed.

### Span Types (mapped 1:1 from OTEL spans)

| Perfetto ID | OTEL Span | Begin/End | Key Args |
|-------------|-----------|-----------|----------|
| `p8f` / `U8f` | `interaction` | prompt / id | user prompt (if enabled) |
| `C8f` / `u8f` | `llm_request` | model, querySource, messageId / id, meta | see metadata below |
| `b8f` / `x8f` | `tool` | toolName, meta / id, success, resultTokens | tool I/O |
| `m8f` / `B8f` | `tool.blocked_on_user` | type / id, decision, source | permission prompt |

### Perfetto-Specific Metadata (LLM request spans)

On span end (`u8f`), additional fields not present in the OTEL span:

| Field | Type | Notes |
|-------|------|-------|
| `ttftMs` | int | Time-to-first-token |
| `ttltMs` | int | Time-to-last-token |
| `promptTokens` | int | Input token count |
| `outputTokens` | int | Output token count |
| `cacheReadTokens` | int | Prompt cache hits |
| `cacheCreationTokens` | int | New cache entries |
| `success` | bool | |
| `error` | string | Error message if failed |
| `requestSetupMs` | int | Pre-request overhead |
| `attemptStartTimes` | int[] | Timestamps for each retry attempt |

## Beta Tracing (Detailed OTEL)

### Activation

```bash
export ENABLE_BETA_TRACING_DETAILED=true
export BETA_TRACING_ENDPOINT=http://your-collector:4318
```

Enables richer OTEL spans including hook execution detail. May include additional
span attributes not present in standard telemetry mode. Experimental -- format may
change between versions.

## Implications for Warden Architecture

### Phase 4 (Slim Hooks): What to remove

1. **Tool latency file correlation** (`_warden_record_tool_start`, `_warden_compute_tool_latency`, `.tool-start-*` files): Native `claude_code.tool` span provides `duration_ms` directly.

2. **OTEL trace emission** (`otel-trace.sh`, curl to `localhost:4318`): Native spans are richer (include `result_tokens`, `success`, parent span context). Hook-emitted spans are redundant and lack parent correlation.

3. **Token estimation** (bytes/3.5 conversion): Native `llm_request` span provides exact `input_tokens`, `output_tokens`, `cache_read_tokens`.

### Phase 5 (Collector): What to ingest

The Go collector should subscribe to the native OTEL pipeline (as an exporter or via the OTEL collector) to receive:
- Exact token counts (replace estimates)
- Tool latency (replace file correlation)
- TTFT, cache efficiency, retry counts (new signals)

While continuing to ingest hook envelopes for enforcement-only data (truncation events, blocked calls, budget updates).

### Recommended warden OTEL config

```bash
# In warden install or session-start
export CLAUDE_CODE_ENABLE_TELEMETRY=true
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_SERVICE_NAME=claude-code
export OTEL_LOG_USER_PROMPTS=false
export OTEL_LOG_TOOL_CONTENT=false
export OTEL_METRICS_INCLUDE_ACCOUNT_UUID=false
export OTEL_METRICS_INCLUDE_SESSION_ID=true
```
