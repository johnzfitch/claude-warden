# Budget System Removal Analysis

## Executive Summary

Claude-warden implements two distinct budget systems:
1. **Global Token Budget** - Session-wide token consumption tracking and enforcement
2. **Per-Subagent Call/Byte Limits** - Individual subagent tool call count and output size limits

This document maps all components, interdependencies, and analyzes the trade-offs of removal.

---

## System 1: Global Token Budget

### Overview
Tracks cumulative token consumption across a session. Blocks subagent creation when exhausted.
Estimates tokens from tool output bytes (not actual API token counts).

### Components

#### State Files
- `~/.claude/.warden/budget.state` - Single integer (consumed tokens)
- `~/.claude/.session-budgets/<session_id>.start.json` - Session start snapshot
- `~/.claude/.statusline/budget-export` - Cached JSON for statusline reads
- `~/.claude/.monitoring/session-costs.csv` - Session-level cost history

#### Environment Variables
- `WARDEN_BUDGET_TOTAL` (default: 280000) - Total token limit per session
- Configured in `config/defaults.json` as `warden.budget_total`

#### Functions (hooks/lib/common.sh)
- `_warden_budget_read()` - Read consumed count from state file
- `_warden_budget_write()` - Write consumed count to state file
- `_warden_budget_update(tokens)` - Add tokens to consumed count (with locking)
- `_warden_budget_check()` - Return 0 if budget available, 1 if exhausted
- `_warden_budget_export()` - Export full JSON with consumed/total/util/remaining
- `_warden_budget_reset()` - Zero out consumed count
- `_warden_write_budget_prom()` - Write Prometheus textfile metrics

#### Hook Integration Points

**session-start** (hooks/session-start:25-27)
```bash
# Snapshot budget at session start
_warden_budget_export > "$WARDEN_SESSION_BUDGET_DIR/$SESSION_ID.start.json"
_warden_write_budget_prom
```

**session-end** (hooks/session-end:51-74)
```bash
# Track budget delta for this session
START_CONSUMED=$(jq -r '.consumed // 0' "$START_BUDGET_FILE")
END_JSON=$(_warden_budget_export)
END_CONSUMED=$(echo "$END_JSON" | jq -r '.consumed // 0')
DELTA=$((END_CONSUMED - START_CONSUMED))
# Write to session-costs.csv
# Cleanup budget snapshot
```

**subagent-start** (hooks/subagent-start:24-47, 84)
```bash
# === BUDGET ENFORCEMENT ===
if ! _warden_budget_check; then
  # Block subagent creation with stopReason
  jq -n --arg reason "Budget exhausted (${UTIL}% used)..."
  exit 0
fi

# Alert thresholds
if [ "$UTIL" -ge 90 ]; then
  _warden_notify critical "Claude Budget Alert" "Budget at ${UTIL}%!"
elif [ "$UTIL" -ge 75 ]; then
  _warden_notify normal "Claude Budget Warning" "Budget at ${UTIL}%"
fi

_warden_write_budget_prom
```

**subagent-stop** (hooks/subagent-stop:21-29, 72)
```bash
# === BUDGET TRACKING ===
# Estimate tokens from subagent output bytes
_warden_budget_update $(( _TOTAL_BYTES * 10 / 35 ))

_warden_write_budget_prom
```

**post-tool-use** (hooks/post-tool-use:88-101)
```bash
# Budget check every 50 calls (infrequent)
if (( $(( CALL_COUNT % 50 )) == 0 )); then
  UTIL=$(_warden_budget_export | jq -r '.utilization // 0')
  if (( UTIL >= 90 )); then
    _warden_notify critical "Claude Budget" "${UTIL}%!"
  elif (( UTIL >= 75 )); then
    _warden_notify normal "Claude Budget" "${UTIL}%"
  fi
fi
```

**pre-compact** (hooks/pre-compact:44-56)
```bash
# Budget state
BUDGET_JSON=$(_warden_budget_export)
UTIL=$(echo "$BUDGET_JSON" | jq -r '.utilization // 0')
CONSUMED=$(echo "$BUDGET_JSON" | jq -r '.consumed // 0')
TOTAL=$(echo "$BUDGET_JSON" | jq -r '.total_limit // 0')
BUDGET_STATUS="${UTIL}% (${CONSUMED}/${TOTAL})"

# Include in compaction summary
- Budget: $BUDGET_STATUS
```

#### Monitoring Integration

**Prometheus Metrics** (written by `_warden_write_budget_prom`)
- `claude_budget_total_tokens` - Total token budget limit
- `claude_budget_consumed_tokens` - Tokens consumed in current session
- `claude_budget_remaining_tokens` - Tokens remaining in budget
- `claude_budget_utilization_percent` - Budget utilization percentage
- `claude_budget_active_subagents` - Number of active subagents

**Grafana Dashboard** (monitoring/grafana/dashboards/working-dashboard.json)
- Budget utilization gauge panel (expr: `claude_budget_utilization_percent / 100`)
- Consumed tokens panel (expr: `claude_budget_consumed_tokens`)
- Remaining tokens panel (expr: `claude_budget_remaining_tokens`)
- Active subagents panel (expr: `claude_budget_active_subagents`)
- Budget vs token usage ratio panel
- Historical budget consumed time series

**Statusline** (statusline.sh:661-666)
```bash
BUDGET_CACHE="$STATE_DIR/budget-export"
_budget_raw=$(<"$BUDGET_CACHE")
if [[ "$_budget_raw" =~ \"utilization\":([0-9]+) ]]; then
  # Display budget % in statusline
fi
```

#### Test Coverage
- `tests/run.sh:557-559` - Statusline budget byte length test
- `tests/test-hooks.sh:407` - Pre-compact budget info assertion
- `tests/test-hooks.sh:708-709` - Budget directory setup in fixtures

---

## System 2: Per-Subagent Call/Byte Limits

### Overview
Enforces maximum tool call count and cumulative output bytes per individual subagent.
Prevents runaway subagents from consuming excessive resources.

### Components

#### State Files
- `~/.claude/.statusline/subagent-<id>/call-count` - Tool call counter per subagent
- `~/.claude/.statusline/subagent-<id>/total-bytes` - Cumulative output bytes per subagent

#### Environment Variables
- `WARDEN_DEFAULT_CALL_LIMIT` (default: 30)
- `WARDEN_DEFAULT_BYTE_LIMIT` (default: 102400 = 100KB)
- `WARDEN_CALL_LIMIT_<type>` - Per-type call limit override
- `WARDEN_BYTE_LIMIT_<type>` - Per-type byte limit override

#### Configuration (config/defaults.json)

**Call Limits** (warden.subagent_call_limits)
```json
{
  "Explore": 30,
  "Plan": 30,
  "general-purpose": 35,
  "code-reviewer": 25,
  "security-auditor": 30,
  "deep-debugger": 40,
  "architect": 35,
  "strategist": 35,
  "nix-expert": 35,
  "git-ops": 25,
  "test-runner": 30,
  "refactor": 30,
  "Bash": 20,
  "statusline-setup": 15,
  "claude-code-guide": 25
}
```

**Byte Limits** (warden.subagent_byte_limits)
```json
{
  "Explore": 81920,         // 80KB
  "Plan": 81920,            // 80KB
  "general-purpose": 122880, // 120KB
  "architect": 122880,
  "strategist": 122880,
  "nix-expert": 122880,
  "deep-debugger": 153600,  // 150KB
  "code-reviewer": 102400,  // 100KB
  "security-auditor": 102400
}
```

#### Functions (hooks/lib/common.sh:347-357)
```bash
_warden_call_limit() {
    local type="${1//-/_}"
    local var="WARDEN_CALL_LIMIT_${type}"
    echo "${!var:-$WARDEN_DEFAULT_CALL_LIMIT}"
}

_warden_byte_limit() {
    local type="${1//-/_}"
    local var="WARDEN_BYTE_LIMIT_${type}"
    echo "${!var:-$WARDEN_DEFAULT_BYTE_LIMIT}"
}
```

#### Hook Integration Points

**pre-tool-use** (hooks/pre-tool-use:57-108)
```bash
# === SUBAGENT BUDGET ENFORCEMENT (applies to ALL tools) ===
if [[ "$IS_SUBAGENT" == "true" ]]; then
    CALL_BUDGET=$(_warden_call_limit "$AGENT_TYPE")
    BYTE_BUDGET=$(_warden_byte_limit "$AGENT_TYPE")

    WARN_CALL_AT=$((CALL_BUDGET * 80 / 100))
    WARN_BYTE_AT=$((BYTE_BUDGET * 80 / 100))

    # Read current counters
    NEW_CALLS=$((CURRENT_CALLS + 1))

    # Enforce call count budget
    if (( NEW_CALLS >= CALL_BUDGET )); then
        _warden_emit_block "budget_calls_exceeded" 2000
        _warden_deny "Budget exceeded: $AGENT_TYPE calls $NEW_CALLS/$CALL_BUDGET. Stop and report findings."
    elif (( NEW_CALLS >= WARN_CALL_AT )); then
        echo "WARNING: Tool call #$NEW_CALLS/$CALL_BUDGET for $AGENT_TYPE agent." >&2
    fi

    # Enforce cumulative output bytes budget
    if (( CURRENT_BYTES >= BYTE_BUDGET )); then
        _warden_emit_block "budget_bytes_exceeded" $((CURRENT_BYTES / 4))
        _warden_deny "Budget exceeded: $AGENT_TYPE output ${CURRENT_BYTES}B/${BYTE_BUDGET}B. Stop and report findings."
    elif (( CURRENT_BYTES >= WARN_BYTE_AT )); then
        echo "WARNING: ${CURRENT_BYTES}B/$((BYTE_LIMIT/1024))KB cumulative output for $AGENT_TYPE agent." >&2
    fi
fi
```

**subagent-start** (hooks/subagent-start:90-105)
```bash
# Inject guidance strings with budget info
case "$AGENT_TYPE" in
    Explore)
        GUIDANCE="Pattern: tree -> Glob -> Grep -> Read. Budget: 30 calls / 80KB output. ..."
        ;;
    Plan)
        GUIDANCE="Pattern: structure -> patterns -> proposal. Budget: 30 calls / 80KB output. ..."
        ;;
    general-purpose)
        GUIDANCE="Pattern: explore -> plan -> execute. Budget: 35 calls / 120KB output. ..."
        ;;
    code-reviewer)
        GUIDANCE="Pattern: scope -> grep -> read. Budget: 25-30 calls / 100KB output. ..."
        ;;
    deep-debugger)
        GUIDANCE="Pattern: reproduce -> narrow -> instrument. Budget: 40 calls / 150KB output. ..."
        ;;
    *)
        GUIDANCE="Follow agent-specific workflow. Budget: 25-35 calls / 100-120KB output. ..."
        ;;
esac
```

#### Events Emitted
- `budget_calls_exceeded` - Call count limit reached (event_type: blocked)
- `budget_bytes_exceeded` - Output byte limit reached (event_type: blocked)

#### Documentation
- `docs/env-vars.md:59-94` - Full table of per-subagent budgets
- `README.md:68` - "Enforces subagent budgets"
- `README.md:78` - "Injects type-specific guidance with output budgets"

---

## Interdependencies

### Global Budget <-> Subagent Limits
- **Independent**: Global budget blocks subagent *creation*, call/byte limits block subagent *tools*
- **No shared state**: Different state files, different enforcement points
- **Distinct purposes**: Global = session-wide cost control, Per-agent = runaway prevention

### Budget <-> Monitoring Stack
- **Prometheus metrics**: Global budget writes 5 metrics to textfile collector
- **Grafana dashboards**: 7 panels display budget metrics
- **Session costs CSV**: Tracks budget deltas across sessions
- **Statusline**: Displays budget utilization %

### Budget <-> Notification System
- Calls `_warden_notify` for 75%/90% thresholds
- Tracks alert state in `$WARDEN_STATE_DIR/budget-alert`

### Subagent Limits <-> Guidance System
- Limits embedded in guidance strings shown to agents
- Agents receive budget context at spawn time

---

## Removal Analysis

### Option 1: Remove Global Token Budget Only

#### Files to Modify
1. **hooks/lib/common.sh**
   - Remove: `_warden_budget_read`, `_warden_budget_write`, `_warden_budget_update`, `_warden_budget_check`, `_warden_budget_export`, `_warden_budget_reset`, `_warden_write_budget_prom`
   - Remove: `WARDEN_BUDGET_TOTAL`, `WARDEN_BUDGET_STATE`, `WARDEN_BUDGET_CACHE`, `WARDEN_SESSION_BUDGET_DIR` exports

2. **hooks/session-start**
   - Remove: Budget snapshot creation (lines 25-27)
   - Remove: `mkdir -p "$WARDEN_SESSION_BUDGET_DIR"` (line 16)

3. **hooks/session-end**
   - Remove: Budget delta tracking (lines 51-74)
   - Remove: `SESSION_COST_LOG` budget columns

4. **hooks/subagent-start**
   - Remove: Budget exhaustion check (lines 24-33)
   - Remove: Alert threshold checks (lines 35-47)
   - Remove: `_warden_write_budget_prom` call (line 84)

5. **hooks/subagent-stop**
   - Remove: `_warden_budget_update` call (line 29)
   - Remove: `_warden_write_budget_prom` call (line 72)

6. **hooks/post-tool-use**
   - Remove: Budget alert logic (lines 88-101)

7. **hooks/pre-compact**
   - Remove: Budget status in summary (lines 44-49, 56)

8. **hooks/session-lifecycle**
   - Remove: Duplicate budget code (lines 29, 35-36, 69-90)

9. **statusline.sh**
   - Remove: Budget cache read and display (lines 661-666)

10. **config/defaults.json**
    - Remove: `"budget_total": 280000`

11. **monitoring/grafana/dashboards/working-dashboard.json**
    - Remove: 7 budget-related panels

12. **docs/env-vars.md**
    - Remove: `WARDEN_BUDGET_TOTAL` documentation

13. **README.md**
    - Update: Hook descriptions to remove budget references

14. **tests/run.sh, tests/test-hooks.sh**
    - Remove: Budget-related assertions and fixtures

#### State Cleanup
- Users must manually delete:
  - `~/.claude/.warden/budget.state`
  - `~/.claude/.session-budgets/`
  - `~/.claude/.statusline/budget-export`
  - `~/.claude/.monitoring/session-costs.csv`
  - `/var/lib/prometheus/node-exporter/budget.prom`

#### Pros
- Eliminates inaccurate token estimation (bytes * 10/35 is crude heuristic)
- Removes 6 functions, ~150 lines of code
- Simplifies session-start/end lifecycle
- Removes confusing "budget exhausted" blocks when estimate is wrong
- No more false budget alerts
- Aligns with Claude Code's built-in cost controls (native OTEL has actual token counts)

#### Cons
- Loses session-level cost visibility in Grafana (7 panels removed)
- No proactive subagent blocking before costs spiral
- Removes historical session cost tracking (CSV log)
- Statusline loses budget % display
- Users who rely on budget notifications lose guardrails
- Removes Node Exporter metrics (monitoring stack integration loss)

---

### Option 2: Remove Per-Subagent Call/Byte Limits Only

#### Files to Modify
1. **hooks/lib/common.sh**
   - Remove: `_warden_call_limit`, `_warden_byte_limit` functions
   - Remove: `WARDEN_DEFAULT_CALL_LIMIT`, `WARDEN_DEFAULT_BYTE_LIMIT` exports

2. **hooks/pre-tool-use**
   - Remove: Entire subagent budget enforcement block (lines 57-108)
   - Keep: Other validations (binary detection, file size guards, etc.)

3. **hooks/subagent-start**
   - Update: Remove budget numbers from guidance strings (lines 90-105)
   - Change "Budget: 30 calls / 80KB output" -> "BATCH: issue multiple..."

4. **config/defaults.json**
   - Remove: `"default_call_limit": 30`
   - Remove: `"default_byte_limit": 102400`
   - Remove: `"subagent_call_limits": {...}`
   - Remove: `"subagent_byte_limits": {...}`

5. **docs/env-vars.md**
   - Remove: Per-subagent budgets table (lines 80-94)

6. **README.md**
   - Update: Hook descriptions to remove "enforces subagent budgets"

#### State Cleanup
- Users must manually delete:
  - `~/.claude/.statusline/subagent-*/call-count`
  - `~/.claude/.statusline/subagent-*/total-bytes`

#### Pros
- Simplifies subagent enforcement logic
- Removes 15+ per-agent config entries
- No more artificial "stop and report" blocks mid-task
- Agents can complete work naturally without call count anxiety
- Reduces guidance string complexity
- Less tuning required (no per-agent limit calibration)

#### Cons
- Removes runaway subagent protection
- Subagents can issue unlimited tool calls (cost spiral risk)
- Subagents can accumulate GB of output (context pollution risk)
- Loses per-agent type behavioral constraints
- No early warning when agent is approaching limits
- Could lead to API rate limit hits without call throttling

---

### Option 3: Remove Both Systems

#### Combined Impact
- **Code reduction**: ~200 lines, 8 functions, 15+ config entries
- **State cleanup**: All budget-related state files and directories
- **Monitoring loss**: 7 Grafana panels, 5 Prometheus metrics, session cost CSV
- **Enforcement loss**: No session-wide or per-agent cost controls

#### Pros (Cumulative)
- Drastic simplification of hook logic
- No token estimation errors
- Aligns fully with native OTEL (which has real token counts)
- Removes all budget-related notifications and alerts
- Reduces cognitive load for users (fewer knobs to tune)
- Faster hook execution (fewer state file reads/writes)
- Less lock contention (budget state lock removed)

#### Cons (Cumulative)
- Total loss of cost guardrails (both session and agent level)
- No proactive intervention before expensive mistakes
- No historical cost tracking
- Monitoring stack loses all budget visibility
- Users must rely entirely on external cost controls
- Higher risk of accidental cost spikes from runaway agents
- Statusline loses budget display component

---

## Recommendation Matrix

| Use Case | Keep Global? | Keep Per-Agent? | Rationale |
|----------|--------------|-----------------|-----------|
| Trusting claude-warden on personal projects | NO | YES | Session budget is inaccurate; agent limits prevent runaways |
| Production/team use with cost sensitivity | YES | YES | Defense-in-depth: both layers provide safety |
| Using Claude Code's native OTEL cost tracking | NO | NO | Native tracking makes both obsolete |
| Debugging/experimentation with agents | NO | NO | Limits interfere with exploration |
| Strict cost control without native OTEL | YES | YES | Only defense available |
| Simplicity-first philosophy | NO | NO | Remove all custom budget systems |

---

## Migration Path (If Removing)

### Phase 1: Deprecation Warning
1. Add deprecation notices to hooks that use budget functions
2. Log warnings when budget env vars are set
3. Document removal plan in CHANGELOG

### Phase 2: Make Optional
1. Add `WARDEN_ENABLE_BUDGET_TRACKING=1` flag (default: disabled)
2. Wrap all budget code in conditional checks
3. Update docs to mark as optional/deprecated

### Phase 3: Removal
1. Delete budget functions and state management
2. Remove config entries
3. Clean up Grafana dashboards
4. Add migration script to clean user state dirs

### Phase 4: Native OTEL Replacement (Optional)
1. Query native OTEL collector for actual token counts
2. Build alerts on real API metrics instead of estimates
3. Use native `claude_code.tool` span duration for latency

---

## Questions to Answer Before Deciding

1. **Accuracy**: How wrong are the token estimates? (Compare budget vs actual API costs)
2. **Usage**: Do any users rely on budget alerts? (Check logs for budget_exhausted events)
3. **Native OTEL**: Is Claude Code's native token tracking sufficient? (Does it provide alerts/limits?)
4. **Alternatives**: Can we replace with simpler heuristics? (e.g., wall-time limits instead of token estimates)
5. **Value**: Have the budgets ever prevented a costly mistake? (Evidence from session logs)

---

## Codebase Metrics (Current State)

- **Lines of budget-specific code**: ~200
- **Functions**: 8 (global), 2 (per-agent)
- **State files created**: 4 types
- **Config entries**: 1 global limit + 15 agent call limits + 9 agent byte limits
- **Grafana panels**: 7
- **Prometheus metrics**: 5
- **Hook integration points**: 8 hooks, 12 locations
- **Event types**: 2 (`budget_calls_exceeded`, `budget_bytes_exceeded`)

---

## Final Question for User

**Do you want to remove:**
- **A)** Global token budget only (simpler removal, keeps runaway protection)
- **B)** Per-subagent limits only (keeps session visibility, removes agent constraints)
- **C)** Both systems (maximum simplification, total reliance on external controls)
- **D)** Neither, but make both optional behind feature flags

Please specify before proceeding with implementation.
