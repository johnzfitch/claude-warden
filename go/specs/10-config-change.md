# Hook: config-change

## What this does

Runs when Claude Code detects a settings file change. Blocks unauthorized modifications that could disable hooks or inject malicious hook commands. Allows policy_settings and user_settings (with restrictions).

**Exit codes**: 0 = allow, 2 = block.

## Bash source (ground truth)

Path: `go/reference/config-change`

## Input JSON schema

```json
{"session_id": "abc123", "source": "project_settings", "file_path": "/home/user/project/.claude/settings.json"}
```

`source` values: `policy_settings`, `user_settings`, `project_settings`, etc.

## Output JSON schema

- **Allow**: exit 0, no output
- **Block**: exit 2, message to stderr

## Behavior rules (ordered)

1. Parse input. Extract source and file_path.
2. If source == "policy_settings", allow (exit 0). Policy settings are admin-managed.
3. If file_path is non-empty and file exists:
   a. Parse the JSON file.
   b. If `disableAllHooks` is `true`, block. Emit `config_disable_hooks` event. Exit 2.
   c. If `hooks` section is present and non-empty:
      - If source != "user_settings", block. Emit `config_hooks_modified` event. Exit 2.
      - If source == "user_settings", allow (user manages their own hooks).
4. Allow (exit 0).

## Test cases

### Must-block
- `disableAllHooks: true` in any source → block
- `hooks` section present in project_settings → block
- `hooks` section present in unknown source → block

### Must-allow
- source = "policy_settings" → always allow
- source = "user_settings" with hooks → allow (user-managed)
- No disableAllHooks, no hooks section → allow
- `disableAllHooks: false` → allow
- Empty or missing file_path → allow
- File doesn't exist → allow

### Edge cases
- Invalid JSON in file → allow (can't parse, fail-open)
- Empty file → allow
- file_path pointing to non-JSON file → allow

## Guardrails

- Exit code 2 is critical for blocking
- Stderr messages are shown in Claude Code UI
- DO NOT add new blocking rules
- The "user manages their own hooks" exception for user_settings must be preserved
- JSON parsing must handle malformed files gracefully (fail-open)
