# Spec: Shared Types & Infrastructure

## What this does

Defines the foundational types, collector client, and helper functions that all hook handlers depend on. This must be built first — every other spec imports from this.

## Bash source (ground truth)

- `go/reference/lib/common.sh` — all shared functions
- Every hook in `go/reference/` — for input/output JSON shape examples

## Files to create

- `collector/hooks/types.go` — HookInput, ToolInput subtypes, output builders
- `collector/hooks/dispatch.go` — stdin reader, hook name routing, stdout writer
- `collector/hooks/client.go` — CollectorClient (UDS POST)
- `collector/hooks/helpers.go` — sanitizeID, isSubagent, getAgentID, resolveSessionStart, scrubSecrets, getEnvInt
- `collector/hooks/helpers_test.go` — tests for all helpers

## Architecture reference

Read `go/specs/00-overview.md` for complete type definitions, output JSON shapes, and conventions.

## Behavior rules

### dispatch.go

1. Read all of stdin into bytes (with 5-second timeout matching bash `read -t 5`)
2. If stdin is empty, exit 0 (allow)
3. Unmarshal into HookInput
4. Route by hook name to handler function
5. Handler returns (output []byte, exitCode int)
6. Write output to stdout, exit with code

```go
func Dispatch(hookName string, stdin io.Reader, stdout io.Writer) int
```

### client.go

1. Socket path: `${XDG_STATE_HOME:-$HOME/.local/state}/claude-warden/collector.sock`
2. POST to `http://localhost/v1/ingest/hook` via UDS
3. Content-Type: application/json
4. Timeout: 100ms
5. Fire-and-forget: launch goroutine, ignore all errors
6. If socket file doesn't exist (os.Stat), skip silently

```go
func NewCollectorClient() *CollectorClient
func (c *CollectorClient) PostEvent(payload []byte)
```

### helpers.go

1. `sanitizeID(s string) string` — return s if `^[a-zA-Z0-9_-]+$`, else empty string
2. `isSubagent(transcriptPath string) bool` — true if path contains `/subagents/` (NOT `/tmp/` — TMPDIR is user-configurable via CLAUDE_CODE_TMPDIR)
3. `getAgentID(transcriptPath string) string` — extract from path, sanitize
4. `getAgentType(agentID string) string` — read from state file `~/.claude/.statusline/subagents/{agentID}`, grep `AGENT_TYPE=`
5. `resolveSessionStart(sid string) int64` — read `~/.claude/.statusline/.session_start-{sid}`, parse float, return seconds
6. `relativeTimestamp(sessionStartS int64) int64` — `time.Now().Unix() - sessionStartS`
7. `scrubSecrets(s string) string` — strip bearer tokens, API keys from strings before event emission
8. `getEnvInt(key string, fallback int) int` — read env var as int with default
9. `getEnvStr(key string, fallback string) string` — read env var with default

### Output builders (types.go)

```go
func AllowOutput() []byte                              // suppress_ok equivalent
func DenyOutput(hookEvent, message string) []byte       // deny with userFacingMessage
func ModifyOutput(text string) []byte                   // {"modifyOutput": text}
func QuietOverride(modifiedCmd string) []byte           // allow + updatedInput
func AdditionalContext(hookEvent, ctx string) []byte    // additionalContext
func SystemMessage(msg string) []byte                   // {"systemMessage": msg}
func SuppressOutput() []byte                            // {"suppressOutput": true}
func PermissionAllow() []byte
func PermissionDeny(message string) []byte
func StopSummary(summary string) []byte
```

## Test cases

### helpers_test.go

```
sanitizeID("abc-123_def") -> "abc-123_def"
sanitizeID("abc/../etc") -> ""
sanitizeID("") -> ""
sanitizeID("a b c") -> ""

isSubagent("/home/user/.claude/subagents/agent-abc.jsonl") -> true
isSubagent("/tmp/claude-agent-xyz.jsonl") -> false  # no /subagents/ in path
isSubagent("/home/user/tmp/subagents/agent-xyz.jsonl") -> true  # custom TMPDIR but /subagents/ present
isSubagent("/home/user/.claude/transcript.jsonl") -> false

getAgentID("/path/subagents/agent-abc123.jsonl") -> "abc123"
getAgentID("/path/transcript.jsonl") -> ""

resolveSessionStart with existing file -> parsed value
resolveSessionStart with missing file -> fallback to time.Now()
resolveSessionStart with float "1234567890.123" -> 1234567890

getEnvInt("WARDEN_TRUNCATE_BYTES", 20480) with env set -> env value
getEnvInt("WARDEN_TRUNCATE_BYTES", 20480) without env -> 20480
getEnvInt("WARDEN_TRUNCATE_BYTES", 20480) with non-numeric -> 20480
```

### dispatch_test.go

```
Dispatch with empty stdin -> exit 0
Dispatch with valid JSON, unknown hook -> exit 0
Dispatch with invalid JSON -> exit 0 (fail-open)
```

### client_test.go

```
PostEvent with running UDS server -> event received
PostEvent with no socket file -> no panic, no error
PostEvent with unreachable socket -> no panic, no error (timeout)
```

## Guardrails

- DO NOT add features not in common.sh
- DO NOT import third-party packages
- DO NOT create a cmd/ directory — this is a library package
- Output builder functions must produce byte-exact JSON matching the bash equivalents
- Test with `json.Valid()` that all output builders produce valid JSON
- CollectorClient must never block the hook (fire-and-forget only)
- All file reads must handle ENOENT gracefully (return zero value, not error)
