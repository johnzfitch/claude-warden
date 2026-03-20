# Hook: observability (tool-error, elicitation, elicitation-result, instructions-loaded, pre-compact)

## What this does

Five hooks that emit observability events to the collector. Minimal logic — mostly parse, sanitize, emit.

## Bash sources (ground truth)

- `go/reference/tool-error`
- `go/reference/elicitation`
- `go/reference/elicitation-result`
- `go/reference/instructions-loaded`
- `go/reference/pre-compact`

## Files to create

- `collector/hooks/observability.go`
- `collector/hooks/observability_test.go`

---

## tool-error

### Input
```json
{"tool_name": "Bash", "session_id": "abc123", "tool_error": "command not found: foo", "error": ""}
```

### Behavior rules
1. Extract tool_name, session_id, error message (prefer tool_error, fallback to error).
2. Log to `~/.claude/errors.log` with timestamp, tool, error, PWD, git branch.
3. Emit `tool_error` event to collector.
4. Rotate error log if >1500 lines (keep last 1000) — atomic via temp file + rename.
5. Emit hints to stderr for specific error patterns:
   - "permission denied" → "Hint: May need sudo or file permissions check"
   - "command not found" → "Hint: Check if command is installed or PATH is set"
   - "read-only" (Edit/Write tools) → "Hint: File may be read-only or in a protected directory"

---

## elicitation

### Input
```json
{"mcp_server_name": "server", "mode": "form", "elicitation_id": "uuid", "message": "Please enter..."}
```

### Behavior rules
1. Extract and sanitize fields.
2. Scrub secrets from message.
3. Emit `elicitation` event to collector.
4. Exit 0 (allow elicitation to proceed).

---

## elicitation-result

### Input
```json
{"mcp_server_name": "server", "elicitation_id": "uuid", "action": "accept", "mode": "form", "content": {"field1": "value1"}}
```

### Behavior rules
1. Extract and sanitize fields.
2. Count content fields (if content is an object, get length).
3. Emit `elicitation_result` event to collector.
4. Exit 0 (allow result to be sent).

---

## instructions-loaded

### Input
```json
{"file_path": "/home/user/.claude/CLAUDE.md", "memory_type": "User", "load_reason": "session_start", "globs": ["*.md", "*.txt"]}
```

### Behavior rules
1. Extract and escape fields.
2. Count globs array length.
3. Emit `instructions_loaded` event to collector.
4. Exit 0 (purely observational).

---

## pre-compact

### Input
```json
{"session_id": "abc123"}
```

### Output
```json
{"systemMessage": "[Warden Session State]\n- Tool calls: 42\n- Duration: 15m\n- Active subagents: 2\n- Budget: 45% (450/1000)"}
```

### Behavior rules
1. Query collector for session context: GET `http://localhost/v1/sessions/{sid}/context` via UDS.
   Extract tool_count and subagent_count.
2. Calculate duration from session start file.
3. Get budget state (budget export).
4. Build summary string.
5. Emit `compaction` event to collector.
6. Return summary via `{"systemMessage": summary}`.

---

## Collector events emitted

- `tool_error`: tool_name, session_id, error_message
- `elicitation`: mcp_server, mode, elicitation_id, message
- `elicitation_result`: mcp_server, elicitation_id, action, mode, content_fields
- `instructions_loaded`: file_path, memory_type, load_reason, glob_count
- `compaction`: session_id, tool_count

## Test cases

### tool-error
- Permission denied error → hint emitted to stderr
- Command not found → hint emitted
- Error log rotation at >1500 lines
- Event emitted with truncated error message (200 chars max)

### elicitation / elicitation-result
- Fields correctly sanitized and emitted
- Secret scrubbing applied to message field

### instructions-loaded
- Glob count correctly calculated
- Empty globs → count = 0

### pre-compact
- Collector available → summary includes tool count
- Collector unavailable → summary shows defaults (0s)
- Budget state included in summary

### Edge cases
- Missing session start file → duration "unknown"
- Missing collector socket → graceful fallback
- Empty error message → "unknown error"

## Guardrails

- DO NOT add new hint patterns to tool-error
- Error log rotation must be atomic (temp file + rename)
- Pre-compact must query the collector via UDS GET, not read SQLite directly
- Secret scrubbing must be applied to all user-facing strings in events
- All hooks exit 0 — none of these block
