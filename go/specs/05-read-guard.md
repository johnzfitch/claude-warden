# Hook: read-guard

## What this does

Runs before Read tool calls (PreToolUse for Read). Three-tier defense:
1. Blocks reads of bundled/generated files (node_modules, dist, .min.js, lock files)
2. Blocks files over a size threshold
3. Reroutes reads of dense/minified files (high bytes-per-line) by capping the `limit` via `updatedInput`

**Exit codes**: 0 = allow (or reroute via JSON stdout), 2 = block.

## Bash source (ground truth)

Path: `go/reference/read-guard`

## Input JSON schema

```json
{
  "session_id": "abc123",
  "tool_name": "Read",
  "tool_input": {
    "file_path": "/home/user/project/data.json",
    "offset": 0,
    "limit": 0
  }
}
```

## Output JSON schema

- **Allow**: exit 0, no output
- **Block**: exit 2, message to stderr
- **Reroute (dense)**: exit 0, JSON stdout with `updatedInput` + `additionalContext`:
  ```json
  {
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "allow",
      "updatedInput": {
        "file_path": "/path/to/file",
        "offset": 0,
        "limit": 100
      },
      "additionalContext": "[warden] Dense file: 885KB, 0 lines, ~906364 bytes/line. Capped to 100 lines. Use offset+limit to page through, or Bash jq/head -c for structured extraction."
    }
  }
  ```

## Behavior rules (ordered)

1. Parse input. Extract file_path from tool_input.
2. If file_path is empty, allow (exit 0).
3. **Bundled pattern check**: match file_path against compiled regex:
   ```
   ((^|/)node_modules/|(^|/)dist/|(^|/)build/|\.min\.js$|\.bundle\.js$|(^|/)expo-downloads/|\.chunk\.js$|(^|/)vendor/|(^|/)__generated__/|package-lock\.json$|yarn\.lock$|pnpm-lock\.yaml$|Cargo\.lock$|poetry\.lock$|composer\.lock$|Gemfile\.lock$|go\.sum$)
   ```
   If match: emit `read_bundled` block event (8000 tokens saved), print message to stderr, exit 2.
4. **File size check**: if file exists, stat it.
   - Max size: WARDEN_READ_GUARD_MAX_MB (default 2) * 1024 * 1024 bytes.
   - If over max: emit `read_oversize` block event (25000 tokens saved), print size to stderr, exit 2.
5. **Dense content detection**: if file > WARDEN_DENSE_MIN_BYTES (default 8192):
   - Count lines with `wc -l` (Go: count newlines in file).
   - Compute bytes_per_line = file_size / line_count.
   - If line_count == 0 (single-line blob) or bytes_per_line > WARDEN_DENSE_BPL_THRESHOLD (default 500):
     - Extract existing offset/limit from tool_input.
     - If model already set a limit <= WARDEN_DENSE_LINE_CAP (default 100), respect it (exit 0).
     - Otherwise: emit `allowed` event with rule `read_dense_reroute`, output JSON with `updatedInput` capping limit to WARDEN_DENSE_LINE_CAP, include `additionalContext` with file stats and guidance, exit 0.
6. Allow (exit 0).

## Config (env vars)

| Variable | Default | Purpose |
|----------|---------|---------|
| WARDEN_READ_GUARD_MAX_MB | 2 | Max file size in MB before blocking |
| WARDEN_DENSE_MIN_BYTES | 8192 | Min file size to check density |
| WARDEN_DENSE_BPL_THRESHOLD | 500 | Bytes/line threshold for dense detection |
| WARDEN_DENSE_LINE_CAP | 100 | Line limit injected via updatedInput |

## Test cases

### Must-block (bundled)
- `/project/node_modules/express/index.js` -> block read_bundled
- `/project/dist/bundle.js` -> block read_bundled
- `/project/build/static/main.chunk.js` -> block read_bundled
- `/project/app.min.js` -> block read_bundled
- `/project/package-lock.json` -> block read_bundled
- `/project/yarn.lock` -> block read_bundled
- `/project/Cargo.lock` -> block read_bundled
- `/project/go.sum` -> block read_bundled
- `/project/vendor/lib.js` -> block read_bundled
- `/project/__generated__/types.ts` -> block read_bundled
- 3MB file -> block read_oversize

### Must-reroute (dense)
- 50KB single-line JSON (0 newlines) -> reroute, limit=100
- 200KB file with 10 lines (20000 bpl) -> reroute, limit=100
- 12KB JSONL with 5 lines (2400 bpl) -> reroute, limit=100

### Must-allow
- `/project/src/main.js` -> allow (normal source)
- `/project/package.json` -> allow (not package-lock.json)
- `/project/go.mod` -> allow (not go.sum)
- `/project/Cargo.toml` -> allow (not Cargo.lock)
- 500KB file with 10000 lines (50 bpl) -> allow (normal density)
- 4KB single-line file -> allow (under WARDEN_DENSE_MIN_BYTES)
- Empty file_path -> allow
- Non-existent file -> allow (stat fails gracefully)
- 50KB dense file with model-set limit=50 -> allow (model already bounded it)

### Edge cases
- File path with spaces -> handle correctly
- Relative vs absolute paths -> regex matches substrings, both work
- File_path is a directory -> stat returns directory, skip size/density check
- wc -l returns 0 for files with no trailing newline -> treat as single-line blob
- macOS wc -l pads with spaces -> strip leading whitespace

## Guardrails

- DO NOT add new bundled patterns not in the bash regex
- DO NOT change the default size threshold (2MB) or density defaults
- Exit code 2 is critical -- Claude Code uses this to indicate blocking
- Stderr messages are shown to the model -- keep them concise and actionable
- The block event must include tokens_saved estimate (8000 for bundled, 25000 for oversize)
- Dense reroute uses exit 0 with JSON stdout, NOT exit 2 -- model should see a successful read, not a block
- The updatedInput JSON must include all three fields: file_path, offset, limit
- Respect model-set limits: if tool_input already has limit <= WARDEN_DENSE_LINE_CAP, pass through
