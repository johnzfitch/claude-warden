# Hook: mcp-output-compress

## What this does

Runs after MCP tool calls (PostToolUse for mcp__* tools). When MCP output exceeds a threshold, strips noise fields from JSON, and if still too large, offloads to a temp file and returns a compact summary with file path.

## Bash source (ground truth)

Path: `go/reference/mcp-output-compress`

## Input JSON schema

MCP tool responses use a different structure than regular tools:

```json
{
  "tool_name": "mcp__llmx__llmx_search",
  "session_id": "abc123",
  "tool_response": [{"type": "text", "text": "{\"results\":[...]}"}]
}
```

Note: `tool_response` for MCP is an array `[{type, text}]`, not `{content: [{text}]}`.

## Output JSON schema

- **Pass through**: exit 0 (under threshold)
- **Cleaned inline**: `{"modifyOutput":"cleaned json"}`
- **Offloaded**: `{"modifyOutput":"summary with file path","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"guidance"}}`

## Behavior rules (ordered)

1. Parse input. If tool_name doesn't start with `mcp__`, exit 0.
2. Extract MCP server name and operation from tool_name pattern `mcp__{server}__{operation}`.
3. Extract output text from tool_response (MCP format: `[0].text`).
4. If output is empty, exit 0.
5. If output size <= WARDEN_MCP_THRESHOLD_BYTES (default 10500), exit 0.
6. **JSON noise cleanup**: If output is valid JSON, remove fields recursively:
   - Delete keys: `chunk_id`, `score`, `truncated_ids`, `embedding`, `vector`
   - Delete entries whose string values are 64-char hex hashes (except `index_id`)
   - Use Go's encoding/json — do NOT use a recursive `walk()` equivalent. Instead, unmarshal to `any`, walk the structure in Go (much faster than jq walk).
7. If cleaned output <= threshold, return cleaned inline via modifyOutput.
8. **File offload**: Save cleaned output to `/tmp/claude-mcp-output/{session_short}-{server}-{op}-{seq}.txt`.
   - Session short = first 8 chars of session_id.
   - Sequence counter: read/increment from `/tmp/claude-mcp-output/.seq-{session_short}`.
9. **Build summary**: For JSON content, extract result count, file paths (from `.path` fields), and 2KB preview. For plain text, use head 2KB + tail 512B.
10. **Build guidance**: Tool-specific hints based on operation name pattern:
    - `*search*` → "use limit<=5 and max_tokens<=4000"
    - `*index*` → "Index IDs are managed by the hook"
    - `*explore*` → "Consider using path_filter"
11. Return summary via modifyOutput + guidance via additionalContext.

## Collector events emitted

- `truncated` with rules: `mcp_noise_strip` (inline cleanup), `mcp_file_offload` (file saved)

## Test cases

### Must-pass
- Non-MCP tool → exit 0 (ignored)
- MCP output under 10500 bytes → pass through
- MCP output 15KB with score/chunk_id fields → cleaned to under 10500 → inline return
- MCP output 50KB → offloaded to file, summary returned
- MCP output with 64-char hex hash values → removed (except index_id)
- Search operation → guidance includes "limit<=5"

### Must-not-trigger
- Tool name "Bash" → ignored
- Tool name "mcp__server__tool" with small output → pass through
- index_id field with 64-char hex → preserved (not removed)

### Edge cases
- Non-JSON MCP output → skip JSON cleanup, use head+tail for summary
- Invalid JSON → treat as plain text
- Empty output → exit 0
- Missing /tmp/claude-mcp-output directory → create it
- Sequence file missing → start at 1

## Guardrails

- DO NOT use a recursive walk that could stack overflow on deeply nested JSON
- Use iterative traversal or bounded recursion (max depth 20)
- The JSON cleanup must be MUCH faster than jq's walk() — that's the whole point of porting
- DO NOT add new noise fields to strip — match the bash list exactly
- Temp file paths must match the exact naming convention in the bash
- Sequence counter must be atomic (or best-effort — matching bash's non-atomic behavior is fine)
