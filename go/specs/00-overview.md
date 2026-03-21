# Architecture Overview — Go Hook Port

## Why

Bash hooks spawn 4-7 subprocesses (jq, sed, awk, curl) per invocation at ~3-5ms each.
Combined pre+post latency is 31-61ms per tool call. Porting to Go eliminates all subprocess overhead.

## Package layout

```
collector/
├── main.go          # Existing — add "hook" subcommand dispatch
├── api.go           # Existing — HandleHookIngest receives event POSTs
├── store.go         # Existing — SQLite store
├── otlp.go          # Existing — OTLP receiver
└── hooks/           # NEW — all hook logic lives here
    ├── dispatch.go  # Reads stdin, routes by hook name, writes stdout
    ├── types.go     # HookInput, HookOutput, shared types
    ├── client.go    # CollectorClient (UDS POST, fire-and-forget)
    ├── helpers.go   # sanitizeID, isSubagent, resolveSessionStart, etc.
    ├── pretooluse.go
    ├── pretooluse_test.go
    ├── posttooluse.go
    ├── posttooluse_test.go
    ├── readcompress.go
    ├── readcompress_test.go
    ├── readguard.go
    ├── readguard_test.go
    ├── mcpcompress.go
    ├── mcpcompress_test.go
    ├── session.go         # session-start, session-end, stop
    ├── session_test.go
    ├── subagent.go        # subagent-start, subagent-stop
    ├── subagent_test.go
    ├── observability.go   # tool-error, elicitation, elicitation-result,
    │                      # instructions-loaded, pre-compact
    ├── observability_test.go
    ├── configchange.go
    ├── configchange_test.go
    ├── permission.go
    └── permission_test.go
```

## Invocation flow

Claude Code runs bash shim at `~/.claude/hooks/<name>`:

```bash
#!/usr/bin/env bash
exec "$HOME/.local/bin/warden-collector" hook "$(basename "$0")"
```

The collector binary dispatches:

```go
// In main.go, before flag.Parse():
if len(os.Args) >= 3 && os.Args[1] == "hook" {
    hookName := os.Args[2]
    os.Exit(hooks.Dispatch(hookName, os.Stdin, os.Stdout))
}
```

`hooks.Dispatch` reads stdin into `HookInput`, calls the appropriate handler, and writes the response JSON to stdout.

## Shared types

### HookInput

A union type covering all hook events. Not all fields are present for every hook — use `json:",omitempty"` and check for zero values.

```go
type HookInput struct {
    // Common fields (all hooks)
    SessionID      string `json:"session_id"`
    TranscriptPath string `json:"transcript_path"`

    // PreToolUse / PostToolUse / PermissionRequest
    ToolName  string          `json:"tool_name"`
    ToolInput json.RawMessage `json:"tool_input"`

    // PostToolUse
    ToolResponse struct {
        Content []struct {
            Text string `json:"text"`
        } `json:"content"`
    } `json:"tool_response"`

    // SessionEnd / Stop
    Reason string `json:"reason"`

    // SubagentStart / SubagentStop
    AgentID      string `json:"agent_id"`
    AgentType    string `json:"agent_type"`
    WorktreePath string `json:"worktree_path"`

    // Elicitation
    MCPServerName string `json:"mcp_server_name"`
    Mode          string `json:"mode"`
    ElicitationID string `json:"elicitation_id"`
    Message       string `json:"message"`

    // ElicitationResult
    Action  string          `json:"action"`
    Content json.RawMessage `json:"content"`

    // InstructionsLoaded
    FilePath   string   `json:"file_path"`
    MemoryType string   `json:"memory_type"`
    LoadReason string   `json:"load_reason"`
    Globs      []string `json:"globs"`

    // ConfigChange
    Source string `json:"source"`

    // ToolError
    ToolError string `json:"tool_error"`
    Error     string `json:"error"`

    // Stop
    StopHookActive bool `json:"stop_hook_active"`
}
```

### ToolInput subtypes

```go
type BashToolInput struct {
    Command string `json:"command"`
}

type WriteToolInput struct {
    FilePath string `json:"file_path"`
    Content  string `json:"content"`
}

type EditToolInput struct {
    FilePath  string `json:"file_path"`
    NewString string `json:"new_string"`
}

type ReadToolInput struct {
    FilePath string `json:"file_path"`
}

type GlobToolInput struct {
    Pattern string `json:"pattern"`
    Path    string `json:"path"`
}

type NotebookEditToolInput struct {
    NewSource string `json:"new_source"`
}

type WebToolInput struct {
    URL   string `json:"url"`
    Query string `json:"query"`
}
```

### HookOutput

Output is always JSON to stdout. Different hooks produce different shapes:

```go
// PreToolUse: allow (suppress output)
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}

// PreToolUse: deny
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","userFacingMessage":"reason"}}

// PreToolUse: allow with modified command (quiet override)
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"modified cmd"}}}

// PostToolUse: modify output
{"modifyOutput":"truncated content here"}

// PostToolUse: additionalContext (quiet override reminder)
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"message"}}

// SessionStart: additionalContext (git context)
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"[Git] main (2 dirty)"}}

// SubagentStart: additionalContext (guidance)
{"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":"guidance text"}}

// PreCompact: system message
{"systemMessage":"[Warden Session State]\n- Tool calls: 42\n..."}

// Stop: summary
{"stop_hook_summary":"Session: 120s | reason: user_cancelled"}

// PermissionRequest: allow/deny
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"reason"}}}

// ConfigChange: exit 0 = allow, exit 2 = block (stderr message)

// ReadGuard: exit 0 = allow, exit 2 = block (stderr message)

// Suppress (pass through, no modification):
{"suppressOutput":true}
```

## CollectorClient

```go
type CollectorClient struct {
    socketPath string
    httpClient *http.Client
}

func NewCollectorClient() *CollectorClient {
    // Socket at ${XDG_STATE_HOME:-$HOME/.local/state}/claude-warden/collector.sock
    // http.Client with unix socket transport
    // Timeout: 100ms (fire-and-forget)
}

func (c *CollectorClient) PostEvent(payload []byte) {
    // POST to http://localhost/v1/ingest/hook via UDS
    // Fire-and-forget: launch goroutine, ignore errors
    // If socket doesn't exist, silently skip
}
```

## Common helpers

All from `go/reference/lib/common.sh`:

| Bash function | Go equivalent | Notes |
|---|---|---|
| `_warden_sanitize_id` | `sanitizeID(s string) string` | `^[a-zA-Z0-9_-]+$` or empty |
| `_warden_is_subagent` | `isSubagent(transcriptPath string) bool` | Contains `/subagents/` |
| `_warden_get_agent_id` | `getAgentID(transcriptPath string) string` | basename minus `.jsonl` and `agent-` prefix |
| `_warden_resolve_session_start` | `resolveSessionStart(sid string) int64` | Read `~/.claude/.statusline/.session_start-{sid}` |
| `_warden_json_escape` | Not needed — Go's `json.Marshal` handles escaping | |
| `_warden_maybe_scrub` | `scrubSecrets(s string) string` | Strip bearer tokens, API keys from event payloads |

## State file paths

| File | Purpose | Used by |
|---|---|---|
| `~/.claude/.statusline/.session_start-{sid}` | Session start timestamp | All hooks (relative time) |
| `~/.claude/.statusline/.quiet-override-{tool}-{sid}` | Quiet override rule name | pre-tool-use writes, post-tool-use reads |
| `~/.claude/.session-times/{sid}.start` | Session start epoch | session-end, stop (duration calc) |
| `${XDG_STATE_HOME}/claude-warden/budget-deny-{agent_id}` | Budget exceeded marker | pre-tool-use checks existence |
| `${XDG_STATE_HOME}/claude-warden/collector.sock` | Collector UDS | All hooks POST events here |

## Environment variables (from warden.env)

Hooks read thresholds via env vars set in `~/.claude/.warden/warden.env`:

| Var | Default | Used by |
|---|---|---|
| `WARDEN_TRUNCATE_BYTES` | 20480 | post-tool-use |
| `WARDEN_SUPPRESS_BYTES` | 524288 | post-tool-use |
| `WARDEN_WRITE_MAX_BYTES` | 51200 | pre-tool-use |
| `WARDEN_EDIT_MAX_BYTES` | 25600 | pre-tool-use |
| `WARDEN_NOTEBOOK_MAX_BYTES` | 25600 | pre-tool-use |
| `WARDEN_SUBAGENT_READ_BYTES` | 10240 | post-tool-use |
| `WARDEN_READ_GUARD_MAX_MB` | 2 | read-guard |
| `WARDEN_MCP_THRESHOLD_BYTES` | 10500 | mcp-output-compress |

Read these via `os.Getenv` with fallback defaults. Do NOT read warden.env file directly.

## Exit codes

| Code | Meaning | Used by |
|---|---|---|
| 0 | Allow / success | All hooks |
| 2 | Block / deny | read-guard, config-change |

## Testing conventions

- Test files: `<hook>_test.go` in same package
- Use `testing.T`, no testify or third-party frameworks
- Table-driven tests for regex/pattern matching
- Helper: `func mustMarshalInput(t *testing.T, input HookInput) io.Reader`
- Helper: `func parseOutput(t *testing.T, stdout *bytes.Buffer) HookOutput`
- Test collector client with a mock HTTP server on a temp UDS
