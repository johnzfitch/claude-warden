# Hook: post-tool-use

## What this does

Runs after every tool call. Tracks output size, strips system reminders, cleans SSH/git noise, injects quiet override reminders, truncates large outputs (head+tail), compresses agent task results, and reports subagent byte usage to the collector.

## Bash source (ground truth)

Path: `go/reference/post-tool-use`
Read this file completely. Every behavior must be ported.

## Input JSON schema

```json
{
  "tool_name": "Bash",
  "session_id": "abc123",
  "tool_input": {"command": "git status"},
  "tool_response": {
    "content": [{"text": "On branch main\nnothing to commit"}]
  },
  "transcript_path": "/home/user/.claude/transcript.jsonl"
}
```

## Output JSON schema

- **Pass through**: no output (exit 0 silently) or `{"suppressOutput":true}`
- **Modify output**: `{"modifyOutput":"truncated text"}`
- **Additional context**: `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"message"}}`

## Behavior rules (ordered)

### Phase 0: Setup
1. Read stdin, parse. If empty/invalid, exit 0.
2. Extract tool_name, session_id, output_size (length of tool_response text), command (truncated to 200 chars).
3. Resolve session start timestamp.

### Phase 1: Output size tracking
4. If output_size > 0, count lines (fast path for <=50KB, extrapolate for larger), emit `tool_output_size` event to collector.

### Phase 2: Subagent detection + byte tracking
5. Detect subagent via transcript_path.
6. If subagent: on EXIT, POST `subagent_bytes` event to collector with final output size. Use the final (possibly truncated) size, not original.

### Phase 3: System reminder strip
7. If output contains `<system-reminder>`, strip all `<system-reminder>...</system-reminder>` blocks.
8. For Bash/Grep/Glob/Task: keep stripped content for downstream processing.
9. For all other tools: emit stripped content via modifyOutput and exit.

### Phase 4: SSH output cleaning (Bash only, command contains ssh/scp/frida)
10. Strip frida ASCII banner lines (specific patterns).
11. Strip SSH connection noise (Warning: Permanently added, Pseudo-terminal, X11 forwarding).
12. Collapse repeated auth failure messages into single lines.
13. IPS crash log compression: keep JSON header, omit threads array.

### Phase 5: Git hint strip (Bash only)
14. If output contains `hint: ` or `Note: switching to` or `warning: refs/tags/` or `detached HEAD`:
    Strip git hint lines, switching notes, detached HEAD warnings.

### Phase 6: Quiet override reminders
15. Check for state file `~/.claude/.statusline/.quiet-override-{tool}-{sid}`.
16. If found, read rule name, delete file, return appropriate reminder via additionalContext:
    - `git_quiet_override` → `[warden: ran as git {subcmd} -q — next time include -q yourself]`
    - `npm_quiet_override` → `[warden: ran with --silent — next time use npm {subcmd} --silent]`
    - `cargo_quiet_override` → `[warden: ran as cargo build -q ...]`
    - `make_quiet_override` → `[warden: ran as make -s ...]`
    - `pip_quiet_override` → `[warden: ran with -q ...]`
    - `wget_quiet_override` → `[warden: ran as wget -q ...]`
    - `docker_quiet_override` → `[warden: ran with -q ...]`
    - `ffmpeg_quiet_override` → `[warden: ran with -nostats -loglevel error ...]`
    - `curl_to_aurl` → `[warden: curl routed through aurl (safe wrapper) — localhost allowed, remote POST/PUT/PATCH/DELETE blocked]`
    - `git_diff_bounded` → `[warden: git diff piped through head -200 — use --stat for summary or specify file paths to narrow output]`
    - `cat_to_head` → `[warden: cat -> head -c 8192 (file too large) — use Read tool with offset/limit for full content]`
17. If reminder found, return it and exit (skip truncation).

### Phase 7: Tool routing
18. Bash/Grep/Glob/Task: continue to truncation.
19. **mcp__\***: continue to truncation (MCP tools fall through). **Important**: the system-reminder stripping (Phase 3) must also continue processing for `mcp__*` tools, not early-exit via the catch-all branch.
20. Read (non-subagent): emit allowed event, pass through.
21. Read (subagent): continue to truncation (safety net).
22. All other tools: emit allowed event, pass through.

### Phase 8: Task structured extraction
23. If tool_name == "Task" and output > 6144 bytes: extract bullet points, numbered items, headers, table rows, file:line references via line-pattern matching. If extraction yields 200+ chars and less than original, emit compressed output.

### Phase 8a: Grep-specific truncation
24. If tool_name == "Bash" and command matches `grep|rg|ripgrep` at command position, and output > 4096 bytes: truncate to 4KB head + 1KB tail with notice `[{KB}KB grep output truncated to 5KB]`. This is tighter than the generic threshold because grep output is line-oriented and models rarely need the middle of a large search result.

### Phase 9: Truncation threshold
25. Threshold = WARDEN_TRUNCATE_BYTES (default 12288). For subagent Reads, use WARDEN_SUBAGENT_READ_BYTES (default 10240). Clamp to WARDEN_SUPPRESS_BYTES.
26. If output <= threshold, pass through (with any reminder-stripped content).

### Phase 10: Binary detection
25. Check for null bytes in output (portable: scan for 0x00). If binary, emit `[Binary output: {KB}KB. Use 'file' or redirect.]`.

### Phase 11: Suppress oversized
26. If output > WARDEN_SUPPRESS_BYTES (default 524288), emit `[Output too large: {MB}MB. Use | head or redirect.]`.

### Phase 12: Head+tail truncation
27. RE tools (nm, strings, otool, jtool, class-dump): head-only (8000 chars).
28. Everything else: 8000 char head + 2000 char tail with truncation notice.

## Collector events emitted

- `tool_output_size` (every tool call with output)
- `subagent_bytes` (subagent exit trap)
- `truncated` with rules: `system_reminder`, `ssh_noise`, `git_hints`, `task_structured`, `binary_output`, `output_suppressed`, `head-only`, `output_truncated`
- `allowed` (pass-through)

## Test cases

### Must-pass
- Output with `<system-reminder>` blocks → stripped
- Output > 20KB → truncated to 8K head + 2K tail
- Output > 512KB → suppressed entirely
- Binary output (contains 0x00) → replaced with notice
- Quiet override state file exists → reminder returned, file deleted
- Task output > 6KB with bullet points → structural extraction
- SSH output with frida banner → banner stripped
- Git output with `hint:` lines → hints stripped

### Must-not-trigger
- Output < 20KB without reminders → pass through unchanged
- Non-Bash tool output → pass through (no truncation)
- Read tool (main agent) → pass through

### Edge cases
- Empty output → exit 0
- Output exactly at threshold → pass through (<=, not <)
- Subagent Read at 10KB threshold vs main agent Read at 20KB
- Multiple system-reminder blocks → all stripped
- Quiet override file missing → no reminder, continue to truncation

## Guardrails

- DO NOT add new truncation rules not in the bash
- DO NOT change threshold defaults
- System reminder stripping must handle multiline blocks
- Subagent byte tracking must use FINAL size (after truncation), not original
- Quiet override file deletion must be atomic (remove before returning)
- Head+tail truncation: chars, not bytes (for UTF-8 safety, but match bash behavior which uses byte offsets)
