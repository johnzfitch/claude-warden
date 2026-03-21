# Hook: session-lifecycle (session-start, session-end, stop)

## What this does

Three hooks that bracket a Claude Code session:
- **session-start**: Boots collector, records timestamps, snapshots budget, emits git context
- **session-end**: Calculates duration, logs budget delta, cleans up state files, reaps ghost subagents
- **stop**: Logs stop reason, emits stop event, returns summary

## Bash sources (ground truth)

- `go/reference/session-start`
- `go/reference/session-end`
- `go/reference/stop`

## Files to create

- `collector/hooks/session.go` — all three handlers
- `collector/hooks/session_test.go`

---

## session-start

### Input
```json
{"session_id": "abc123"}
```

### Output
```json
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"[Git] main (2 dirty), last: abc1234 fix typo"}}
```

### Behavior rules
1. Ensure collector is running (POST a health check or just proceed — the bash calls `_warden_ensure_collector` which starts the binary).
   **In Go**: The hook IS the collector binary. If invoked as a hook, the daemon should already be running (session-start is the first hook). If not running, the Go hook should attempt to start it. For now, just POST the session_start event — if the collector isn't up, it's a no-op.
2. Write session start timestamp to `~/.claude/.session-times/{sid}.start` and `~/.claude/.statusline/.session_start-{sid}`.
3. Snapshot budget state to `~/.claude/.warden/session-budgets/{sid}.start.json` (call `_warden_budget_export` equivalent — read budget from `claude` CLI or the budget JSON file).
4. Initialize agent-stats CSV if needed (`~/.claude/agent-stats.csv`).
5. Log terminal agent start to agent-stats CSV.
6. Emit `session_start` event to collector with session_id, cwd, session_label.
7. **Git context**: If in a git repo, collect branch, dirty count, last commit. Return as additionalContext: `[Git] {branch} ({dirty} dirty), last: {hash} {subject}`.

### Collector events
- `session_start` with session_id, cwd, session_label

---

## session-end

### Input
```json
{"session_id": "abc123", "reason": "user_cancelled"}
```

### Output
None (exit 0).

### Behavior rules
1. Calculate duration from session start file.
2. Log terminal agent completion to agent-stats CSV.
3. Emit `session_end` event to collector.
4. Calculate budget delta (start vs current), log to `~/.claude/.monitoring/session-costs.csv`.
5. Count subagents for this session from agent-stats CSV.
6. **Ghost subagent reaper**: Remove orphaned subagent state files for this session only.
7. **State file cleanup**: Remove stale files (>24h) from statusline dir: tool-count-*, tool-top-*, session-*, state-*, .tool-start-*, .quiet-override-*, clears-*, peak-*, .session_start-*, subagent-count-*, stale locks.
8. Log session end to `~/.claude/session-log.txt`.
9. Record reset reason to `~/.claude/.statusline/reset-reason`.
10. Clean up per-session state files.
11. Delay Prometheus prom file deletion (60s background — in Go, use a goroutine with time.Sleep, or just delete immediately since the Go hook exits).

### Special reasons
- `bypass_permissions_disabled` → display as "bypass mode disabled"

---

## stop

### Input
```json
{"session_id": "abc123", "reason": "user_cancelled", "tool_name": "Bash", "stop_hook_active": false}
```

### Output
```json
{"stop_hook_summary": "Session: 120s | reason: user_cancelled"}
```

### Behavior rules
1. If `stop_hook_active` is true, exit 0 (prevent infinite loops).
2. Calculate duration from session start file.
3. Log stop event to `~/.claude/session-log.txt`.
4. Emit `session_stop` event to collector.
5. Return stop_hook_summary.

---

## Test cases

### session-start
- In git repo → additionalContext includes branch and commit
- Not in git repo → no additionalContext (or minimal)
- Session start files created correctly

### session-end
- Duration calculated correctly from start file
- Cleanup removes per-session state files
- Budget delta logged
- Ghost subagent reaper only removes this session's agents

### stop
- stop_hook_active=true → exit 0 immediately
- Duration calculated from start file
- Summary format matches: "Session: {N}s | reason: {reason}"

### Edge cases
- Missing session start file → duration = "unknown"
- Missing budget files → skip budget delta
- Session ID with special characters → sanitized

## Guardrails

- DO NOT start the collector daemon from the hook — the hook IS the collector binary in hook mode
- Git commands (branch, status, log) must use exec.Command — they're external
- File cleanup must only target the current session's files (no globbing other sessions)
- CSV writes must be append-only, never truncate
- The Prometheus prom file delay (60s) can be simplified in Go — just delete immediately or use a short timer
