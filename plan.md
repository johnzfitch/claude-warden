Plan: Restructure claude-warden Around the Go Collector

 Context

 The statusline context percentage drifts from Claude Code's native display because:
 1. used_percentage from Claude Code only updates at API call boundaries (stale between calls)
 2. Tool result tokens accumulate between API calls but aren't counted
 3. The denominator differs (full context window vs auto-compact threshold)

 The Go collector already solves this -- it ingests OTEL spans with exact token counts from Claude Code, tracks pending tool tokens between API calls, and exposes a
 session context API. But the collector is optional behind WARDEN_COLLECTOR_ENABLED and --logging, while the hooks carry ~935 lines of state management (latency
 tracking, budget files, subagent bytes, event JSONL, prom textfiles) that duplicate what the collector should own.

 Goal: Make the Go collector the required backbone. Hooks become thin enforcement shims (block/allow/modify). All observation, state, and query surfaces move to the
 collector.

 Decisions

 1. Distribution: Build from source only (require Go 1.23+). Most secure -- no pre-built binary download, no supply chain attack vector, full source auditability.
 2. Subagent budget: Async with deny-file hints. Hook POSTs async, collector writes deny files on budget exceeded. Next pre-tool-use checks deny file (<0.1ms stat).
 Target: hooks under 20ms.
 3. Monitoring: No Prometheus/Docker stack by default. Replace with lightweight local web viewer (warden-viewer) forked from hotbar trace-viewer. Blue-themed,
 localhost-only.
 4. Migration: Cut over immediately. Save legacy branch for comparison.

 Architecture

 Claude Code
   |-- OTEL spans (llm_request, tool, interaction) --> Go Collector (:4319 TCP)
   |                                                       |
   |   Hook events (block/allow/truncate) --------------> | (UDS /v1/ingest/hook)
   |                                                       |
   |   statusline.sh -- GET /v1/sessions/{id} ----------< | (UDS API)
   |                                                       |
   |                                                   SQLite WAL
   |                                                       |
   |                                         warden-viewer (localhost:8477)
   |                                         reads collector.db directly

 Hooks only do:
 1. Parse stdin JSON (fast regex, single jq call)
 2. Apply enforcement rules (block/allow/modify)
 3. POST a lightweight event to collector (fire-and-forget via UDS)

 Hooks do NOT:
 - Track latency, write state files, write events.jsonl, write prom textfiles
 - Compute or estimate tokens, source otel-trace.sh

 Complete OTEL Metrics Inventory (verified from 2.1.79 binary)

 Trace Spans (from com.anthropic.claude_code.tracing)

 All spans carry these resource attributes (set by AXH() in 2593.js/2589.js):

 ┌───────────────────┬────────┬───────────────────────────────────────────────────────────────────┐
 │     Attribute     │  Type  │                            Description                            │
 ├───────────────────┼────────┼───────────────────────────────────────────────────────────────────┤
 │ user.id           │ string │ Hashed user identifier                                            │
 ├───────────────────┼────────┼───────────────────────────────────────────────────────────────────┤
 │ session.id        │ string │ Session UUID (when OTEL_METRICS_INCLUDE_SESSION_ID is truthy)     │
 ├───────────────────┼────────┼───────────────────────────────────────────────────────────────────┤
 │ app.version       │ string │ Claude Code version (when OTEL_METRICS_INCLUDE_VERSION is truthy) │
 ├───────────────────┼────────┼───────────────────────────────────────────────────────────────────┤
 │ organization.id   │ string │ Org UUID (if authenticated)                                       │
 ├───────────────────┼────────┼───────────────────────────────────────────────────────────────────┤
 │ user.email        │ string │ Email (if authenticated)                                          │
 ├───────────────────┼────────┼───────────────────────────────────────────────────────────────────┤
 │ user.account_uuid │ string │ Account UUID (when OTEL_METRICS_INCLUDE_ACCOUNT_UUID is truthy)   │
 ├───────────────────┼────────┼───────────────────────────────────────────────────────────────────┤
 │ user.account_id   │ string │ Tagged account ID (from CLAUDE_CODE_ACCOUNT_TAGGED_ID)            │
 ├───────────────────┼────────┼───────────────────────────────────────────────────────────────────┤
 │ terminal.type     │ string │ Terminal emulator name                                            │
 └───────────────────┴────────┴───────────────────────────────────────────────────────────────────┘

 All spans carry span.type to identify their kind.

 claude_code.interaction (root span, one per user message)

 Start attributes:

 ┌──────────────────────┬────────┬──────────────────────────────────────────────────────────┐
 │      Attribute       │  Type  │                          Notes                           │
 ├──────────────────────┼────────┼──────────────────────────────────────────────────────────┤
 │ span.type            │ string │ "interaction"                                            │
 ├──────────────────────┼────────┼──────────────────────────────────────────────────────────┤
 │ user_prompt          │ string │ Prompt text (redacted unless OTEL_LOG_USER_PROMPTS=true) │
 ├──────────────────────┼────────┼──────────────────────────────────────────────────────────┤
 │ user_prompt_length   │ int    │ Character count of user prompt                           │
 ├──────────────────────┼────────┼──────────────────────────────────────────────────────────┤
 │ interaction.sequence │ int    │ Incrementing counter per session                         │
 └──────────────────────┴────────┴──────────────────────────────────────────────────────────┘

 End attributes:

 ┌─────────────────────────┬──────┬─────────────────────────────────────────┐
 │        Attribute        │ Type │                  Notes                  │
 ├─────────────────────────┼──────┼─────────────────────────────────────────┤
 │ interaction.duration_ms │ int  │ Wall-clock duration of full interaction │
 └─────────────────────────┴──────┴─────────────────────────────────────────┘

 claude_code.llm_request (child of interaction, one per API call)

 Start attributes:

 ┌─────────────────────┬────────┬──────────────────────────────────────┐
 │      Attribute      │  Type  │                Notes                 │
 ├─────────────────────┼────────┼──────────────────────────────────────┤
 │ span.type           │ string │ "llm_request"                        │
 ├─────────────────────┼────────┼──────────────────────────────────────┤
 │ model               │ string │ Model name (e.g., claude-sonnet-4-5) │
 ├─────────────────────┼────────┼──────────────────────────────────────┤
 │ llm_request.context │ string │ "interaction" or "standalone"        │
 ├─────────────────────┼────────┼──────────────────────────────────────┤
 │ speed               │ string │ "fast" or "normal"                   │
 ├─────────────────────┼────────┼──────────────────────────────────────┤
 │ query_source        │ string │ Query source identifier (optional)   │
 └─────────────────────┴────────┴──────────────────────────────────────┘

 End attributes:

 ┌────────────────────────┬────────┬──────────────────────────────────────┐
 │       Attribute        │  Type  │                Notes                 │
 ├────────────────────────┼────────┼──────────────────────────────────────┤
 │ duration_ms            │ int    │ API call wall-clock duration         │
 ├────────────────────────┼────────┼──────────────────────────────────────┤
 │ input_tokens           │ int    │ Non-cached input tokens              │
 ├────────────────────────┼────────┼──────────────────────────────────────┤
 │ output_tokens          │ int    │ Output tokens generated              │
 ├────────────────────────┼────────┼──────────────────────────────────────┤
 │ cache_read_tokens      │ int    │ Tokens read from cache               │
 ├────────────────────────┼────────┼──────────────────────────────────────┤
 │ cache_creation_tokens  │ int    │ Tokens written to cache              │
 ├────────────────────────┼────────┼──────────────────────────────────────┤
 │ success                │ bool   │ Whether the request succeeded        │
 ├────────────────────────┼────────┼──────────────────────────────────────┤
 │ status_code            │ int    │ HTTP status code                     │
 ├────────────────────────┼────────┼──────────────────────────────────────┤
 │ error                  │ string │ Error message (if failed)            │
 ├────────────────────────┼────────┼──────────────────────────────────────┤
 │ attempt                │ int    │ Retry attempt number                 │
 ├────────────────────────┼────────┼──────────────────────────────────────┤
 │ response.has_tool_call │ bool   │ Whether response contains tool calls │
 ├────────────────────────┼────────┼──────────────────────────────────────┤
 │ ttft_ms                │ int    │ Time to first token (ms)             │
 └────────────────────────┴────────┴──────────────────────────────────────┘

 Enhanced telemetry only (when CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=true):

 ┌───────────────────────────────────────┬────────┬──────────────────────────────┐
 │               Attribute               │  Type  │            Notes             │
 ├───────────────────────────────────────┼────────┼──────────────────────────────┤
 │ response.model_output                 │ string │ Truncated model output text  │
 ├───────────────────────────────────────┼────────┼──────────────────────────────┤
 │ response.model_output_truncated       │ bool   │ Whether output was truncated │
 ├───────────────────────────────────────┼────────┼──────────────────────────────┤
 │ response.model_output_original_length │ int    │ Original output length       │
 ├───────────────────────────────────────┼────────┼──────────────────────────────┤
 │ system_reminders                      │ string │ System reminder content      │
 ├───────────────────────────────────────┼────────┼──────────────────────────────┤
 │ system_reminders_count                │ int    │ Number of system reminders   │
 └───────────────────────────────────────┴────────┴──────────────────────────────┘

 claude_code.tool (child of interaction, one per tool call)

 Start attributes:

 ┌─────────────────┬────────┬─────────────────────────────────────────────────┐
 │    Attribute    │  Type  │                      Notes                      │
 ├─────────────────┼────────┼─────────────────────────────────────────────────┤
 │ span.type       │ string │ "tool"                                          │
 ├─────────────────┼────────┼─────────────────────────────────────────────────┤
 │ tool_name       │ string │ Tool name (e.g., Bash, Read, mcp__server__tool) │
 ├─────────────────┼────────┼─────────────────────────────────────────────────┤
 │ file_path       │ string │ For Read/Write/Edit tools (optional)            │
 ├─────────────────┼────────┼─────────────────────────────────────────────────┤
 │ bash_command    │ string │ First word of Bash command (optional)           │
 ├─────────────────┼────────┼─────────────────────────────────────────────────┤
 │ full_command    │ string │ Full Bash command (optional)                    │
 ├─────────────────┼────────┼─────────────────────────────────────────────────┤
 │ mcp_server_name │ string │ MCP server name (for MCP tools)                 │
 ├─────────────────┼────────┼─────────────────────────────────────────────────┤
 │ mcp_tool_name   │ string │ MCP tool name (for MCP tools)                   │
 ├─────────────────┼────────┼─────────────────────────────────────────────────┤
 │ skill_name      │ string │ Skill name (if invoked via skill)               │
 └─────────────────┴────────┴─────────────────────────────────────────────────┘

 End attributes:

 ┌───────────────┬──────┬────────────────────────────────────┐
 │   Attribute   │ Type │               Notes                │
 ├───────────────┼──────┼────────────────────────────────────┤
 │ duration_ms   │ int  │ Tool execution wall-clock duration │
 ├───────────────┼──────┼────────────────────────────────────┤
 │ result_tokens │ int  │ Token count of tool result         │
 └───────────────┴──────┴────────────────────────────────────┘

 Enhanced telemetry only:

 ┌─────────────────────────────┬────────┬───────────────────────────────┐
 │          Attribute          │  Type  │             Notes             │
 ├─────────────────────────────┼────────┼───────────────────────────────┤
 │ tool_input                  │ string │ Truncated tool input          │
 ├─────────────────────────────┼────────┼───────────────────────────────┤
 │ tool_input_truncated        │ bool   │ Whether input was truncated   │
 ├─────────────────────────────┼────────┼───────────────────────────────┤
 │ tool_input_original_length  │ int    │ Original input length         │
 ├─────────────────────────────┼────────┼───────────────────────────────┤
 │ new_context                 │ string │ Truncated tool result content │
 ├─────────────────────────────┼────────┼───────────────────────────────┤
 │ new_context_truncated       │ bool   │ Whether result was truncated  │
 ├─────────────────────────────┼────────┼───────────────────────────────┤
 │ new_context_original_length │ int    │ Original result length        │
 └─────────────────────────────┴────────┴───────────────────────────────┘

 Tool output events (via addEvent, enhanced telemetry + OTEL_LOG_TOOL_CONTENT):

 ┌─────────────┬─────────────────────────────────────────────────────────────────┐
 │ Event name  │                           Attributes                            │
 ├─────────────┼─────────────────────────────────────────────────────────────────┤
 │ tool.output │ file_path, content, diff, output, bash_command (varies by tool) │
 └─────────────┴─────────────────────────────────────────────────────────────────┘

 claude_code.tool.blocked_on_user (child of tool, permission wait)

 ┌─────────────┬────────┬────────────────────────────────────────────────────────────────┐
 │  Attribute  │  Type  │                             Notes                              │
 ├─────────────┼────────┼────────────────────────────────────────────────────────────────┤
 │ span.type   │ string │ "tool.blocked_on_user"                                         │
 ├─────────────┼────────┼────────────────────────────────────────────────────────────────┤
 │ duration_ms │ int    │ Time spent waiting for user permission                         │
 ├─────────────┼────────┼────────────────────────────────────────────────────────────────┤
 │ decision    │ string │ "accept" or "reject"                                           │
 ├─────────────┼────────┼────────────────────────────────────────────────────────────────┤
 │ source      │ string │ Decision source (e.g., "user_permanent", "hook", "classifier") │
 └─────────────┴────────┴────────────────────────────────────────────────────────────────┘

 claude_code.tool.execution (child of tool, actual execution)

 ┌─────────────┬────────┬──────────────────────────────────┐
 │  Attribute  │  Type  │              Notes               │
 ├─────────────┼────────┼──────────────────────────────────┤
 │ span.type   │ string │ "tool.execution"                 │
 ├─────────────┼────────┼──────────────────────────────────┤
 │ duration_ms │ int    │ Actual execution wall-clock time │
 ├─────────────┼────────┼──────────────────────────────────┤
 │ success     │ bool   │ Whether execution succeeded      │
 ├─────────────┼────────┼──────────────────────────────────┤
 │ error       │ string │ Error message (if failed)        │
 └─────────────┴────────┴──────────────────────────────────┘

 claude_code.hook (child of tool, hook execution)

 Start attributes:

 ┌──────────────────┬────────┬────────────────────────────────────────────────┐
 │    Attribute     │  Type  │                     Notes                      │
 ├──────────────────┼────────┼────────────────────────────────────────────────┤
 │ span.type        │ string │ "hook"                                         │
 ├──────────────────┼────────┼────────────────────────────────────────────────┤
 │ hook_event       │ string │ Event name (e.g., "PreToolUse", "PostToolUse") │
 ├──────────────────┼────────┼────────────────────────────────────────────────┤
 │ hook_name        │ string │ Hook script name                               │
 ├──────────────────┼────────┼────────────────────────────────────────────────┤
 │ num_hooks        │ int    │ Number of hooks registered for this event      │
 ├──────────────────┼────────┼────────────────────────────────────────────────┤
 │ hook_definitions │ string │ Hook definition details                        │
 └──────────────────┴────────┴────────────────────────────────────────────────┘

 End attributes:

 ┌────────────────────────┬──────┬────────────────────────────────┐
 │       Attribute        │ Type │             Notes              │
 ├────────────────────────┼──────┼────────────────────────────────┤
 │ duration_ms            │ int  │ Hook execution duration        │
 ├────────────────────────┼──────┼────────────────────────────────┤
 │ num_success            │ int  │ Hooks that succeeded           │
 ├────────────────────────┼──────┼────────────────────────────────┤
 │ num_blocking           │ int  │ Hooks that blocked             │
 ├────────────────────────┼──────┼────────────────────────────────┤
 │ num_non_blocking_error │ int  │ Hooks with non-blocking errors │
 ├────────────────────────┼──────┼────────────────────────────────┤
 │ num_cancelled          │ int  │ Hooks that were cancelled      │
 └────────────────────────┴──────┴────────────────────────────────┘

 OTEL Counters (metrics, from 0122.js)

 ┌─────────────────────────────────────┬─────────┬───────────────────────────┬───────────────────────────────────────┐
 │             Metric name             │  Unit   │        Description        │              Attributes               │
 ├─────────────────────────────────────┼─────────┼───────────────────────────┼───────────────────────────────────────┤
 │ claude_code.session.count           │ count   │ CLI sessions started      │ resource attrs                        │
 ├─────────────────────────────────────┼─────────┼───────────────────────────┼───────────────────────────────────────┤
 │ claude_code.lines_of_code.count     │ count   │ Lines modified            │ type (added/removed)                  │
 ├─────────────────────────────────────┼─────────┼───────────────────────────┼───────────────────────────────────────┤
 │ claude_code.pull_request.count      │ count   │ PRs created               │ resource attrs                        │
 ├─────────────────────────────────────┼─────────┼───────────────────────────┼───────────────────────────────────────┤
 │ claude_code.commit.count            │ count   │ Git commits               │ resource attrs                        │
 ├─────────────────────────────────────┼─────────┼───────────────────────────┼───────────────────────────────────────┤
 │ claude_code.cost.usage              │ USD     │ Session cost              │ resource attrs                        │
 ├─────────────────────────────────────┼─────────┼───────────────────────────┼───────────────────────────────────────┤
 │ claude_code.token.usage             │ tokens  │ Tokens used               │ resource attrs                        │
 ├─────────────────────────────────────┼─────────┼───────────────────────────┼───────────────────────────────────────┤
 │ claude_code.code_edit_tool.decision │ count   │ Edit permission decisions │ decision, source, tool_name, language │
 ├─────────────────────────────────────┼─────────┼───────────────────────────┼───────────────────────────────────────┤
 │ claude_code.active_time.total       │ seconds │ Total active time         │ resource attrs                        │
 └─────────────────────────────────────┴─────────┴───────────────────────────┴───────────────────────────────────────┘

 Hook Events (from warden hooks -> collector)

 ┌─────────────────────┬──────────────────────────────┬────────────────────────────────────────────────────┐
 │     Event type      │         Source hook          │                     Key fields                     │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ session_start       │ session-start                │ session_id, cwd, session_label                     │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ session_end         │ session-end                  │ session_id, duration, tool_count, cost             │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ session_stop        │ stop                         │ session_id                                         │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ blocked             │ pre-tool-use                 │ tool, rule, command, tokens_saved                  │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ allowed             │ pre-tool-use / post-tool-use │ tool, output_bytes                                 │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ truncated           │ post-tool-use                │ tool, original_bytes, final_bytes, rule            │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ tool_output_size    │ post-tool-use                │ tool, output_bytes, output_lines, estimated_tokens │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ tool_error          │ tool-error                   │ tool, error                                        │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ subagent_start      │ subagent-start               │ agent_id, agent_type, session_id                   │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ subagent_stop       │ subagent-stop                │ agent_id, duration, calls, bytes                   │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ compaction          │ pre-compact                  │ session_id                                         │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ mcp_tool_start      │ pre-tool-use                 │ tool, mcp_server, mcp_tool                         │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ config_change       │ config-change                │ session_id                                         │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ elicitation         │ elicitation                  │ mcp_server, mode, elicitation_id                   │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ elicitation_result  │ elicitation-result           │ elicitation_id, action, content_fields             │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ instructions_loaded │ instructions-loaded          │ file_path, memory_type, load_reason                │
 ├─────────────────────┼──────────────────────────────┼────────────────────────────────────────────────────┤
 │ quiet_override      │ pre-tool-use                 │ tool, rule, original_cmd, quiet_cmd                │
 └─────────────────────┴──────────────────────────────┴────────────────────────────────────────────────────┘

 Capture Wrapper Records (from capture/logger.py)

 ┌──────────────┬──────────────────────────────┐
 │ Record type  │          Key fields          │
 ├──────────────┼──────────────────────────────┤
 │ stream_start │ request method, url, headers │
 ├──────────────┼──────────────────────────────┤
 │ stream_chunk │ chunk data                   │
 ├──────────────┼──────────────────────────────┤
 │ stream_end   │ status, duration             │
 ├──────────────┼──────────────────────────────┤
 │ exchange     │ request, response, duration  │
 └──────────────┴──────────────────────────────┘

 Security Hardening

 1. Loopback-only TCP (127.0.0.1:4319 for OTLP -- Claude Code requires TCP)
 2. Unix domain socket as primary for hooks + API + viewer
   - $XDG_STATE_HOME/claude-warden/collector.sock
   - 0600 permissions on socket file
 3. DB file permissions: 0600 on SQLite, 0700 on state dir
 4. Input sanitization: session IDs [a-zA-Z0-9_-] validated server-side
 5. Request limits: 10MB OTLP, 64KB hooks
 6. PID file with /proc verification
 7. Viewer: localhost-only, no CDN (inline htmx), no external resources

 Phased Migration

 Phase 1: Required OTEL + Collector Auto-Start

 - Remove --logging flag from install.sh. Collector build is default (requires Go 1.23+)
 - Set OTEL env vars always: CLAUDE_CODE_ENABLE_TELEMETRY=1, OTEL_EXPORTER_OTLP_ENDPOINT (localhost:4319), OTEL_EXPORTER_OTLP_PROTOCOL=http/json
 - Remove WARDEN_COLLECTOR_ENABLED env var
 - common.sh:538: remove WARDEN_COLLECTOR_ENABLED guard from _warden_ensure_collector
 - common.sh:597: remove WARDEN_COLLECTOR_ENABLED guard from _warden_post_to_collector

 Files: install.sh, hooks/lib/common.sh, config/defaults.json, docs/env-vars.md

 Phase 2: Unix Domain Socket Transport

 - Collector: add UDS listener (net.Listen("unix", sockPath), default $XDG_STATE_HOME/claude-warden/collector.sock)
 - OTLP stays TCP (Claude Code requirement), API defaults UDS-only (--tcp flag for TCP)
 - _warden_post_to_collector(): use --unix-socket
 - statusline.sh: query via UDS

 Files: collector/main.go, hooks/lib/common.sh, statusline.sh

 Phase 3: Remove Redundant Hook Logic

 Remove from hooks (~450 lines):
 - Latency tracking: _warden_record_tool_start, _warden_compute_tool_latency, _warden_emit_latency
 - Token estimation: _warden_fire_token_count, hooks/_token-count-bg
 - OTEL trace: hooks/lib/otel-trace.sh (DELETE entire file)
 - State files: all per-session files (session-*, state-*, latency-*, peak-*, clears-*, saved-*)
 - Events.jsonl: all >> "$WARDEN_EVENTS_FILE" writes
 - Prom textfiles: _warden_write_budget_prom

 Async deny-file pattern for subagent budget:
 - Hook POSTs {"event_type":"tool_call","agent_id":"..."} async
 - Collector evaluates budget, writes $STATE_DIR/budget-deny-{agent_id} when exceeded
 - Next pre-tool-use: [[ -f "$STATE_DIR/budget-deny-$AGENT_ID" ]] (<0.1ms)
 - subagent-stop: collector removes deny file

 Files: hooks/pre-tool-use, hooks/post-tool-use, hooks/lib/common.sh, hooks/lib/otel-trace.sh (DELETE), hooks/_token-count-bg (DELETE), collector/api.go,
 collector/store.go, collector/schema.sql

 Phase 4: Warden Viewer

 Fork /home/zack/dev/hotbar/tools/trace-viewer.py (1620 lines) into viewer/warden-viewer.py.

 Design principles (carried from hotbar trace-viewer):

 The hotbar viewer channels iconic 1980s-90s business software aesthetics that made complex data feel approachable:

 - DeltaGraph Professional (IRIS Graphics, 1986): The namesake. Known for its translucent bar pedestal effect (CSS gradient overlays on all chart bars), serif chart
 titles, and muted-but-rich color palette. The viewer replicates the bar ::after gradient overlays, ruled chart title borders, and chart frame titling pattern.
 - Lotus 1-2-3 (Lotus Development, 1983): The heatmap view uses Lotus-style cell references (A1, B2...), a formula bar, column/row headers with distinct styling, and
 green-on-dark cell shading. The data grid uses notebook-style row numbers.
 - Harvard Graphics (Software Publishing Corp, 1986): The sparkline trend view uses Harvard's ruled title style (double-rule border top), grid line overlays, and
 threshold line markers. The pie chart uses Harvard's signature 3D drop-shadow effect.
 - Mac System 7 (Apple, 1991): Window chrome with title bar, traffic light buttons (close/min/max), toolbar with tab-style buttons, and a bottom status bar. The
 sidebar follows System 7's list view pattern.

 Apple HIG principles observed in the hotbar viewer:

 1. Information hierarchy: Title bar > toolbar > sidebar > content. Each layer has distinct background shade.
 2. Consistent spacing: 12px padding in panels, 6px in toolbar, 3px in dense data grids. Fixed rhythm.
 3. Progressive disclosure: Sidebar shows session summary, content reveals detail. Toolbar switches views without losing sidebar context.
 4. Direct manipulation: Click session = immediate content update. No modal dialogs, no page transitions.
 5. Feedback: .htmx-added fade-in animation, hover states on all interactive elements, active state on toolbar buttons.
 6. Typography: Single monospace font family throughout. Size hierarchy: 13px body, 11px data, 10px labels, 9px axis/legend.
 7. Color as meaning: Component type colors (green=daemon, amber=panel), level badges (blue=DEBUG, green=INFO, amber=WARN, red=ERROR).
 8. Status bar: Persistent context (brand, DB info, current state) -- always visible, never blocking.

 Warden viewer theme adaptation (blue palette replacing burgundy):

 --warden-blue:      #1a4a7a    (replaces --burgundy: #8B1A2B)
 --warden-blue-l:    #2a6aaa    (replaces --burgundy-l: #a52a3a)
 --warden-blue-d:    #0a2a4a    (replaces --burgundy-d: #6a1020)
 --warden-accent:    #2d8c9e    (keep teal as accent -- good contrast with blue)

 All other colors (amber warnings, red errors, green success) stay -- they communicate meaning, not brand.

 Views to implement:

 ┌─────────────────┬──────────────────────┬───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │      View       │  Hotbar equivalent   │                                              Warden-specific adaptation                                               │
 ├─────────────────┼──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Session list    │ render_sessions()    │ Session ID (last 6), model, context %, cost, tool count, duration. Active session highlighted. Auto-refresh via htmx  │
 │ (sidebar)       │                      │ poll.                                                                                                                 │
 ├─────────────────┼──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Context gauge   │ NEW                  │ Real-time context % bar (like DeltaGraph horizontal bar). Shows: input tokens, cache read, cache create, pending      │
 │                 │                      │ output, output tokens as stacked segments. Compact threshold marked with dashed line.                                 │
 ├─────────────────┼──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Tool waterfall  │ render_waterfall()   │ Gantt-style: interaction > llm_request > tool > tool.execution > hook spans. Color by span type. Shows tool names,    │
 │                 │                      │ durations, nesting.                                                                                                   │
 ├─────────────────┼──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Events log      │ render_events()      │ Hook events in data grid. Columns: timestamp, event_type, tool, rule, bytes saved. Filter by type                     │
 │                 │                      │ (blocked/allowed/truncated). Level badges reused for event types.                                                     │
 ├─────────────────┼──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Token trend     │ render_sparkline()   │ Sparkline of context % over time (one bar per llm_request). Threshold line at compact_pct. Harvard Graphics ruled     │
 │                 │                      │ title.                                                                                                                │
 ├─────────────────┼──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Cost chart      │ render_performance() │ Bar chart: cost per session. Pie chart: cost by model. DeltaGraph pedestal bars.                                      │
 ├─────────────────┼──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Tool heatmap    │ render_heatmap()     │ Lotus 1-2-3 grid: rows = tools, columns = time buckets. Cell color = call frequency. Formula bar shows selected cell  │
 │                 │                      │ detail.                                                                                                               │
 ├─────────────────┼──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Top tools       │ render_top_spans()   │ Table: slowest tool calls, largest outputs, most blocked. Sortable columns.                                           │
 ├─────────────────┼──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Subagent view   │ NEW                  │ Active subagents with call/byte budgets as progress bars. Budget status (ok/warning/denied). Agent type badges.       │
 ├─────────────────┼──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ TTFT analysis   │ NEW                  │ Sparkline of ttft_ms from llm_request spans. Shows model latency trends.                                              │
 ├─────────────────┼──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Budget overview │ NEW                  │ Session cost over time, cumulative spend line, per-model cost breakdown.                                              │
 └─────────────────┴──────────────────────┴───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

 Data source: Read $XDG_STATE_HOME/claude-warden/collector.db directly via SQLite WAL (read-only connection, no collector API needed for viewer).

 New file: viewer/warden-viewer.py (~1500-2000 lines)
 New file: viewer/warden-viewer.sh (launcher, 7 lines like hotbar's)

 Phase 5: Statusline Simplification

 - statusline.sh queries collector exclusively via UDS
 - Remove all fallback calculation paths, state file reads
 - Single source: /v1/sessions/$SID/context
 - Falls back to used_percentage from JSON only if collector unreachable

 Extend SessionContext in collector/store.go:44:
 - compact_threshold_pct (from env or default 85)
 - effective_window (context_window - 20000)
 - compact_threshold (min(floor(effective_window * pct/100), effective_window - 13000))
 - last_tool (most recent tool span name)
 - last_tool_duration_ms (most recent tool span duration)
 - subagent_count (active subagents)

 Files: statusline.sh (~500 lines removed), collector/store.go, collector/api.go

 Phase 6: Cleanup

 - Save feature/go-collector branch as legacy reference
 - Remove state file directories from install/uninstall
 - Remove dead code from common.sh (~300 lines)
 - Update CLAUDE.md, env-vars.md
 - Remove monitoring/ Docker dependency for default install (keep as optional)

 Install Flow (Final)

 ./install.sh
   1. Symlink hooks into ~/.claude/hooks/
   2. Symlink statusline.sh into ~/.claude/
   3. Build Go collector from source (Go 1.23+ required)
   4. Install to ~/.local/bin/warden-collector
   5. Write settings.hooks.json with OTEL env vars
   6. Install warden-viewer.py
   7. Optional: --monitoring for legacy Docker stack

 Verification

 Each phase verified independently:
 - Phase 1: ./install.sh builds collector, OTEL spans arrive in SQLite
 - Phase 2: Hooks POST via UDS, statusline queries via UDS
 - Phase 3: bash tests/run.sh, no state files in ~/.claude/.statusline/
 - Phase 4: python3 viewer/warden-viewer.py shows sessions, spans, events
 - Phase 5: Statusline context % matches Claude Code native display
 - Phase 6: Clean install on fresh system, no leftover state
