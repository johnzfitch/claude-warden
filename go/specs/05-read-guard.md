# Hook: read-guard

## What this does

Runs before Read tool calls (PreToolUse for Read). Blocks reads of bundled/generated files (node_modules, dist, .min.js, lock files) and files over a size threshold. Prevents agents from wasting tokens on unreadable content.

**Exit codes**: 0 = allow, 2 = block.

## Bash source (ground truth)

Path: `go/reference/read-guard`

## Input JSON schema

```json
{
  "session_id": "abc123",
  "tool_name": "Read",
  "tool_input": {"file_path": "/home/user/project/node_modules/express/index.js"}
}
```

## Output JSON schema

- **Allow**: exit 0, no output
- **Block**: exit 2, message to stderr: `Blocked: '/path/to/file' is a bundled/generated file; find the source`

## Behavior rules (ordered)

1. Parse input. Extract file_path from tool_input.
2. If file_path is empty, allow (exit 0).
3. **Bundled pattern check**: match file_path against compiled regex:
   ```
   (node_modules/|/dist/|/build/|\.min\.js$|\.bundle\.js$|expo-downloads/|\.chunk\.js$|/vendor/|/__generated__/|package-lock\.json$|yarn\.lock$|pnpm-lock\.yaml$|Cargo\.lock$|poetry\.lock$|composer\.lock$|Gemfile\.lock$|go\.sum$)
   ```
   If match: emit `read_bundled` block event (8000 tokens saved), print message to stderr, exit 2.
4. **File size check**: if file exists, stat it.
   - Max size: WARDEN_READ_GUARD_MAX_MB (default 2) * 1024 * 1024 bytes.
   - If over max: emit `read_oversize` block event (25000 tokens saved), print size to stderr, exit 2.
5. Allow (exit 0).

## Test cases

### Must-pass (must block)
- `/project/node_modules/express/index.js` → block bundled
- `/project/dist/bundle.js` → block bundled
- `/project/build/static/main.chunk.js` → block bundled
- `/project/app.min.js` → block bundled
- `/project/package-lock.json` → block bundled
- `/project/yarn.lock` → block bundled
- `/project/Cargo.lock` → block bundled
- `/project/go.sum` → block bundled
- `/project/vendor/lib.js` → block bundled
- `/project/__generated__/types.ts` → block bundled
- 3MB file → block oversize

### Must-not-trigger (must allow)
- `/project/src/main.js` → allow
- `/project/package.json` → allow (not package-lock.json)
- `/project/go.mod` → allow (not go.sum)
- `/project/Cargo.toml` → allow (not Cargo.lock)
- 500KB file → allow (under 2MB)
- Empty file_path → allow
- Non-existent file → allow (stat fails gracefully)

### Edge cases
- File path with spaces → handle correctly
- Relative vs absolute paths → regex matches substrings, so both work
- File_path is a directory → stat returns directory, not file; skip size check

## Guardrails

- DO NOT add new bundled patterns not in the bash regex
- DO NOT change the default size threshold (2MB)
- Exit code 2 is critical — Claude Code uses this to indicate blocking
- Stderr messages are shown to the model — keep them concise and actionable
- The block event must include tokens_saved estimate (8000 for bundled, 25000 for oversize)
