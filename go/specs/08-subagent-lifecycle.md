# Hook: subagent-lifecycle (subagent-start, subagent-stop)

## What this does

- **subagent-start**: Emits budget initialization event to collector, injects type-specific guidance
- **subagent-stop**: Emits stop event to collector (triggers deny file cleanup)

## Bash sources (ground truth)

- `go/reference/subagent-start`
- `go/reference/subagent-stop`

## Files to create

- `collector/hooks/subagent.go`
- `collector/hooks/subagent_test.go`

---

## subagent-start

### Input
```json
{"agent_id": "abc123", "agent_type": "Explore", "session_id": "def456"}
```

### Output
```json
{"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":"Pattern: tree -> Glob -> ..."}}
```

### Behavior rules
1. Parse input, extract agent_id, agent_type, session_id.
2. Sanitize IDs.
3. Look up call budget and byte budget for agent_type (from env vars WARDEN_CALL_LIMIT_{type} and WARDEN_BYTE_LIMIT_{type}, with defaults).
4. Emit `subagent_start` event to collector with agent_id, agent_type, session_id, call_limit, byte_limit.
5. Inject type-specific guidance via additionalContext:
   - **Explore**: "Pattern: tree -> Glob -> Grep -> Read. Budget: 30 calls / 80KB output. Native tools only. BATCH: issue multiple Read/Glob/Grep calls in a single response when targets are independent. OUTPUT: max 1500 tokens..."
   - **Plan**: "Pattern: structure -> patterns -> proposal. Budget: 30 calls / 80KB..."
   - **general-purpose**: "Pattern: explore -> plan -> execute. Budget: 35 calls / 120KB..."
   - **code-reviewer|security-auditor**: "Pattern: scope -> grep -> read. Budget: 25-30 calls / 100KB..."
   - **deep-debugger**: "Pattern: reproduce -> narrow -> instrument. Budget: 40 calls / 150KB..."
   - **refactor|architect|strategist|nix-expert|git-ops|test-runner**: "Follow agent-specific workflow. Budget: 25-35 calls / 100-120KB..."
6. If no matching type, no additionalContext.

---

## subagent-stop

### Input
```json
{"agent_id": "abc123", "session_id": "def456", "worktree_path": ""}
```

### Output
None (exit 0).

### Behavior rules
1. Parse input, extract agent_id, session_id, worktree_path.
2. Sanitize IDs.
3. Emit `subagent_stop` event to collector with agent_id, session_id, has_worktree (bool).

---

## Collector events emitted

- `subagent_start`: `{event_type, session_id, agent_id, agent_type, call_limit, byte_limit}`
- `subagent_stop`: `{event_type, session_id, agent_id, has_worktree}`

## Test cases

### subagent-start
- agent_type "Explore" → guidance includes "Glob -> Grep -> Read"
- agent_type "code-reviewer" → guidance includes "scope -> grep -> read"
- agent_type "unknown-type" → no additionalContext
- Budget limits read from env vars when set
- Budget limits use defaults when env vars missing

### subagent-stop
- Normal stop → event emitted, exit 0
- With worktree_path → has_worktree = true
- Without worktree_path → has_worktree = false

### Edge cases
- Empty agent_id → sanitized to "unknown"
- Empty session_id → empty string in event

## Guardrails

- DO NOT change guidance text — copy exactly from the bash source
- DO NOT add new agent type guidance not in the bash
- Budget env var names: WARDEN_CALL_LIMIT_{type} and WARDEN_BYTE_LIMIT_{type} (type is uppercase, hyphens replaced with underscores)
- The guidance strings are large blocks of text — use raw string literals in Go
