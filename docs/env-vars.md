# Claude Warden Environment Variables

> Complete reference for all environment variables used by claude-warden and Claude Code.
> Variables are set in `~/.claude/settings.json` under `"env"`, or in warden's `config/defaults.json`.

---

## Privacy

Control what data leaves your machine and what PII appears in telemetry.

| Variable | Default | Description |
|----------|---------|-------------|
| `OTEL_LOG_USER_PROMPTS` | `false` | Include raw user prompts in OTEL trace spans. **PII risk**: your actual queries appear in Tempo/collector. |
| `OTEL_LOG_TOOL_CONTENT` | `false` | Include tool input/output in OTEL span events. **PII risk**: file contents, command output, API responses appear in logs. |
| `OTEL_LOG_TOOL_DETAILS` | `false` | Additional tool detail attributes in spans. Less verbose than `TOOL_CONTENT` but still exposes tool metadata. |
| `OTEL_METRICS_INCLUDE_ACCOUNT_UUID` | `true` | Add your Anthropic account UUID to every metric. Set `false` for shared infrastructure. |
| `OTEL_METRICS_INCLUDE_SESSION_ID` | `true` | Add `session.id` to metrics. Increases cardinality but enables per-session dashboards. |
| `OTEL_METRICS_INCLUDE_VERSION` | `false` | Add `service.version` to metrics. Useful for tracking behavior across Claude Code updates. |
| `DISABLE_ERROR_REPORTING` | `0` | Set `1` to suppress error ring buffer reporting to Anthropic. |
| `DO_NOT_TRACK` | — | W3C DNT signal. Some OTEL SDKs respect this and silently suppress export. **Avoid setting to `1` if you want telemetry.** |

### Privacy notes

Even with `OTEL_METRICS_INCLUDE_ACCOUNT_UUID=false`, the following PII labels appear on all metrics unconditionally:

- `user_email` — your login email
- `user_id` — SHA-256 hash of your user ID
- `user_account_id` — Anthropic account ID (e.g., `user_01Eiim...`)
- `organization_id` — your org UUID

To strip these for shared infrastructure, add a `transform` processor to your OTEL collector config before the Prometheus exporter.

---

## Security

Restrict what Claude Code can do and what data it can access.

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_CODE_BUBBLEWRAP` | `0` | Enable Bubblewrap sandboxing for Bash tool execution (Linux only). |
| `DISABLE_TELEMETRY` | `0` | Kill ALL non-essential telemetry (Segment, DataDog, 1P, OTEL). Nuclear option. |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `false` | Same as `DISABLE_TELEMETRY`. |

### Warden security thresholds

These are set in `config/defaults.json` under `"warden"` and exported as env vars by the install script:

| Variable | Default | Description |
|----------|---------|-------------|
| `WARDEN_WRITE_MAX_BYTES` | `102400` (100KB) | Max bytes for a single Write tool call. Blocks oversized generated files. |
| `WARDEN_EDIT_MAX_BYTES` | `51200` (50KB) | Max bytes for a single Edit tool call. |
| `WARDEN_NOTEBOOK_MAX_BYTES` | `51200` (50KB) | Max bytes for a single NotebookEdit tool call. |
| `WARDEN_READ_GUARD_MAX_MB` | `2` | Max file size (MB) that Read will pass through. Larger files get structural extraction. |

---

## Efficiency (Budgeting & Savings)

Control token consumption, output sizes, and subagent budgets.

| Variable | Default | Description |
|----------|---------|-------------|
| `WARDEN_BUDGET_TOTAL` | `280000` | Total token budget per session. Subagents are blocked when exhausted. |
| `WARDEN_TRUNCATE_BYTES` | `20480` (20KB) | Tool output above this is truncated (tail-preserved). Saves tokens on every subsequent turn. |
| `WARDEN_SUBAGENT_READ_BYTES` | `10240` (10KB) | Stricter truncation for subagent tool output. |
| `WARDEN_SUPPRESS_BYTES` | `524288` (500KB) | Tool output above this is fully suppressed (replaced with size summary). |
| `WARDEN_DEFAULT_CALL_LIMIT` | `30` | Default max tool calls per subagent before it's stopped. |
| `WARDEN_DEFAULT_BYTE_LIMIT` | `102400` (100KB) | Default max cumulative output bytes per subagent. |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | — | Claude Code native: max output tokens per response. |
| `CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS` | — | Max output tokens for file Read results. |
| `BASH_MAX_OUTPUT_LENGTH` | — | Max output length for Bash tool results. |
| `TASK_MAX_OUTPUT_LENGTH` | — | Max output length for Task tool results. |
| `MAX_MCP_OUTPUT_TOKENS` | — | Max output tokens for MCP tool results. |
| `MAX_THINKING_TOKENS` | — | Max tokens for extended thinking. |
| `DISABLE_COST_WARNINGS` | `0` | Suppress Claude Code's built-in cost threshold warnings. |
| `DISABLE_NON_ESSENTIAL_MODEL_CALLS` | `0` | Skip non-essential LLM calls (e.g., commit message generation). |

### Per-subagent budgets

Configured in `config/defaults.json` under `"warden".subagent_call_limits` and `"warden".subagent_byte_limits`:

| Agent Type | Call Limit | Byte Limit | Notes |
|------------|-----------|------------|-------|
| `Explore` | 30 | 80KB | Codebase exploration subagent |
| `Plan` | 30 | 80KB | Planning subagent |
| `general-purpose` | 35 | 120KB | Default subagent type |
| `deep-debugger` | 40 | 150KB | Higher limits for complex debugging |
| `code-reviewer` | 25 | 100KB | Review-focused subagent |
| `security-auditor` | 30 | 100KB | Security audit subagent |
| `architect` | 35 | 120KB | Architecture subagent |
| `Bash` | 20 | (default) | Shell-only subagent |

---

## Performance (Speed & Consistency)

Tune model behavior, concurrency, timeouts, and caching.

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_CODE_SUBAGENT_MODEL` | — | Model for subagents (e.g., `claude-sonnet-4-5`). Use a faster/cheaper model than the main session. |
| `ANTHROPIC_SMALL_FAST_MODEL` | — | Model for lightweight internal tasks (e.g., `claude-haiku-4-5`). |
| `CLAUDE_CODE_EFFORT_LEVEL` | — | Reasoning effort: `0` (low), `1` (medium), `2` (high). |
| `CLAUDE_CODE_ALWAYS_ENABLE_EFFORT` | `0` | Always apply the effort level (even when not explicitly requested). |
| `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY` | — | Max parallel tool calls. Higher = faster but more resource use. |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | — | Trigger compaction at this % of context window (e.g., `85`). |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | — | Context window size for auto-compact threshold (tokens). |
| `CLAUDE_CODE_DISABLE_1M_CONTEXT` | `0` | Disable 1M token context window (stick to default). |
| `MCP_TIMEOUT` | `60000` | MCP server call timeout (ms). Increase for slow MCP servers. |
| `MCP_TOOL_TIMEOUT` | — | Individual MCP tool execution timeout (ms). |
| `MCP_CONNECTION_NONBLOCKING` | `0` | Set `1` to not block startup waiting for MCP connections. |
| `CLAUDE_CODE_GLOB_TIMEOUT_SECONDS` | — | Timeout for glob file searches (seconds). |
| `CLAUDE_CODE_TMPDIR` | — | Custom temp directory for Claude Code scratch files. |
| `CLI_WIDTH` | — | Terminal width override for formatting. |
| `CLAUDE_CODE_SKIP_PROMPT_HISTORY` | `0` | Skip loading prompt history on startup (faster init). |
| `CLAUDE_CODE_RESUME_INTERRUPTED_TURN` | `0` | Auto-resume if the previous turn was interrupted mid-response. |
| `CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING` | `0` | Stream tool results incrementally (reduces perceived latency). |
| `CLAUDE_ENABLE_STREAM_WATCHDOG` | `0` | Enable stream watchdog to detect stalled connections. |

---

## Quality (Better Output)

Tune model quality, tool behavior, and code generation.

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES` | `0` | Emit summaries of tool use (can help model track what it's done). |
| `CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS` | `0` | Skip auto-injecting git status/instructions into context. Frees tokens for your actual task. |
| `ENABLE_TOOL_SEARCH` | — | Tool search mode: `auto:N` defers loading tool schemas until needed, showing only N at startup. Reduces prompt noise. |
| `CLAUDE_CODE_PLAN_V2_AGENT_COUNT` | `1` | Number of planning agents in plan mode v2. |
| `CLAUDE_CODE_PLAN_V2_EXPLORE_AGENT_COUNT` | `1` | Number of exploration agents in plan mode v2. |
| `CLAUDE_CODE_PLAN_MODE_INTERVIEW_PHASE` | `0` | Enable interview phase in plan mode (asks clarifying questions before planning). |
| `CLAUDE_CODE_SAVE_HOOK_ADDITIONAL_CONTEXT` | `0` | Persist hook `additionalContext` output into the conversation. |
| `CLAUDE_CODE_SYNTAX_HIGHLIGHT` | `true` | Enable syntax highlighting in code output. |
| `CLAUDE_CODE_GLOB_HIDDEN` | `0` | Include hidden files (dotfiles) in glob searches. |
| `ENABLE_LSP_TOOL` | `0` | Enable Language Server Protocol tool for type-aware code intelligence. |
| `ENABLE_MCP_LARGE_OUTPUT_FILES` | `0` | Allow MCP tools to write large output to files (vs. inline). |
| `FORCE_AUTOUPDATE_PLUGINS` | `false` | Auto-update plugins without prompting. |
| `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY` | `0` | Suppress feedback survey prompts. |

---

## Traceability (Telemetry & Logging)

Six telemetry surfaces are available. Warden enables the user-facing ones by default.

### Surface 1: OpenTelemetry (Traces, Metrics, Logs)

The primary observability pipeline. Sends structured data to your OTEL collector.

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_CODE_ENABLE_TELEMETRY` | `false` | **Master switch.** Must be `true`/`1` for any OTEL export. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | — | Collector URL (e.g., `http://localhost:4317`). |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | `grpc` \| `http/protobuf` \| `http/json`. Use `grpc` for lower overhead. |
| `OTEL_EXPORTER_OTLP_HEADERS` | — | Auth headers (e.g., `x-api-key=...`). |
| `OTEL_EXPORTER_OTLP_TRACES_HEADERS` | — | Trace-specific header override. |
| `OTEL_EXPORTER_OTLP_METRICS_HEADERS` | — | Metric-specific header override. |
| `OTEL_EXPORTER_OTLP_LOGS_HEADERS` | — | Log-specific header override. |
| `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL` | — | Protocol override for traces only. |
| `OTEL_EXPORTER_OTLP_METRICS_PROTOCOL` | — | Protocol override for metrics only. |
| `OTEL_EXPORTER_OTLP_LOGS_PROTOCOL` | — | Protocol override for logs only. |
| `OTEL_METRICS_EXPORTER` | — | `otlp` \| `console` \| `prometheus` \| `none`. |
| `OTEL_LOGS_EXPORTER` | — | `otlp` \| `console` \| `none`. |
| `OTEL_SERVICE_NAME` | `claude-code` | Override service name in resource attributes. **Must be a real name, not `"1"`.** |
| `OTEL_RESOURCE_ATTRIBUTES` | — | Additional resource attributes as `key=value,key=value`. |

### Surface 2: Perfetto Tracing

Local trace capture to a Chrome Trace Event file. Viewable at [ui.perfetto.dev](https://ui.perfetto.dev).

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_CODE_PERFETTO_TRACE` | — | **Absolute path** to `.pftrace` output file. `$HOME` is NOT expanded — use full path (e.g., `/home/user/traces/session.pftrace`). File written on session end. |

### Surface 3: Debug Logging

Verbose local log files for debugging Claude Code itself.

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_CODE_DEBUG_LOGS_DIR` | `~/.claude/logs/` | **Absolute path** to debug log directory. `$HOME` is NOT expanded. Directory must exist. |
| `CLAUDE_CODE_DEBUG_LOG_LEVEL` | — | `verbose` \| `debug` \| `info` \| `warn` \| `error`. |

### Surface 4: Beta Tracing (Detailed OTEL)

Experimental richer OTEL spans including hook execution detail. May change between versions.

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_BETA_TRACING_DETAILED` | `false` | Enable detailed OTEL spans. Also gated by `tengu_trace_lantern` feature flag. |
| `BETA_TRACING_ENDPOINT` | — | Collector endpoint for beta traces (e.g., `http://localhost:4317`). |

### Surface 5: Enhanced Telemetry

Additional internal telemetry for Anthropic. Opt-in.

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` | `false` | Enable enhanced internal telemetry metrics. |

### Batch Tuning

Control how frequently and in what volume OTEL data is flushed.

| Variable | Default | Recommended | Description |
|----------|---------|-------------|-------------|
| `OTEL_METRIC_EXPORT_INTERVAL` | `60000` | `15000` | Metric flush interval (ms). Lower = smoother data, more requests. |
| `OTEL_LOGS_EXPORT_INTERVAL` | `10000` | `10000` | Log batch flush interval (ms). |
| `OTEL_BLRP_MAX_EXPORT_BATCH_SIZE` | `512` | `1024` | Max logs per batch. Increase for high-volume sessions. |
| `OTEL_BLRP_MAX_QUEUE_SIZE` | `2048` | `4096` | Max queue before dropping. Increase to prevent data loss during bursts. |
| `OTEL_BLRP_SCHEDULE_DELAY` | `5000` | `5000` | Batch schedule delay (ms). |
| `OTEL_BLRP_EXPORT_TIMEOUT` | `30000` | `30000` | Export timeout (ms). |

### Resource Limits

| Variable | Default | Description |
|----------|---------|-------------|
| `OTEL_ATTRIBUTE_COUNT_LIMIT` | — | Max attributes per span. |
| `OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT` | — | Max attribute value string length. |
| `OTEL_LOGRECORD_ATTRIBUTE_COUNT_LIMIT` | `128` | Max attributes per log record. |
| `OTEL_LOGRECORD_ATTRIBUTE_VALUE_LENGTH_LIMIT` | — | Max log attribute value string length. |

### Startup Profiling

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_CODE_PROFILE_STARTUP` | `0` | Enable `perf_hooks` startup performance marks. |

---

## Warden Recommended Defaults

The `config/defaults.json` ships these as the baseline. Copy `config/user.json.template` to `config/user.json` to override.

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4319",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_SERVICE_NAME": "claude-code",
    "OTEL_METRIC_EXPORT_INTERVAL": "15000",
    "OTEL_LOGS_EXPORT_INTERVAL": "10000",
    "OTEL_BLRP_MAX_QUEUE_SIZE": "4096",
    "OTEL_LOG_USER_PROMPTS": "false",
    "OTEL_LOG_TOOL_CONTENT": "false",
    "OTEL_METRICS_INCLUDE_ACCOUNT_UUID": "false",
    "DISABLE_ERROR_REPORTING": "1",
    "DISABLE_TELEMETRY": "0"
  }
}
```

---

## Surfaces NOT User-Accessible

These telemetry surfaces exist in the Claude Code binary but are gated by internal feature flags. Listed for awareness.

| Surface | Backend | Gate | Notes |
|---------|---------|------|-------|
| Segment.io Analytics | `api.segment.io/v1/batch` | `tengu_log_segment_events` | Hardcoded write key. Cannot be redirected. |
| DataDog Logs | `http-intake.logs.us5.datadoghq.com` | `tengu_log_datadog_events` | Hardcoded API key. Cannot be redirected. |
| 1P Event Pipeline | OTEL LoggerProvider -> Anthropic | `is1PEventLoggingEnabled()` | 400+ `tengu_*` events. Partially visible via OTEL log export if `CLAUDE_CODE_ENABLE_TELEMETRY=true`. |

---

## Common Gotchas

1. **`$HOME` is not expanded** in `settings.json` env values. Use absolute paths (`/home/user/...`), not `$HOME/...`.

2. **`OTEL_SERVICE_NAME` must be a real name** (e.g., `claude-code`), not `"1"` or `"true"`. It becomes a Prometheus label.

3. **`DO_NOT_TRACK=1`** can silently suppress OTEL export in some SDK configurations. Don't set it alongside `CLAUDE_CODE_ENABLE_TELEMETRY=1`.

4. **Directories must exist** for Perfetto (`CLAUDE_CODE_PERFETTO_TRACE`) and debug logs (`CLAUDE_CODE_DEBUG_LOGS_DIR`). Claude Code will silently fail if they don't.

5. **Loki structured metadata limit** defaults to 64KB. With `OTEL_LOG_TOOL_CONTENT=true`, tool I/O in log attributes can exceed this. Set `max_structured_metadata_size: 131072` in `loki-config.yaml`.

6. **Multiple concurrent sessions** each export independently. With `OTEL_METRICS_INCLUDE_SESSION_ID=true`, this increases Prometheus cardinality. Plan retention accordingly.
