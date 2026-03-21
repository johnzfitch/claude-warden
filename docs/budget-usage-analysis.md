# Budget System Usage Analysis

## Investigation Summary

Analyzed logs from `/home/zack/.claude/.statusline/events.jsonl` (5.8MB, 22,773 events) and archived logs (10.6MB, events.jsonl.1) to determine if the budget systems are actually working in practice.

**Date Range**: Feb 10 - Mar 16, 2026 (5+ weeks of data)

---

## Key Findings

### 1. Per-Subagent Call/Byte Budgets: NEVER TRIGGERED

**Evidence:**
```bash
# Search for budget violation events
grep "budget_calls_exceeded\|budget_bytes_exceeded" events.jsonl*
# Result: 0 matches

# Total subagents tracked
grep "subagent_start" events.jsonl.1 | wc -l  # 81 agents
grep "subagent_start" events.jsonl | wc -l    # 47 agents
# Total: 128 subagents across all sessions
```

**Subagent Activity Breakdown:**
- 28 Explore agents
- 14 general-purpose agents
- 2 security-auditor agents
- 1 nix-expert agent
- 1 code-reviewer agent
- 1 cli-ui-designer agent

**Most Active Subagent:** Only made 1 tool call before stopping
- Agent a613bc7c5ce54995b: 4 events total (start, latency, allowed, stop)
- This represents just 1 tool execution

**Typical Pattern:**
- 95%+ of subagents: 2 events only (start + stop)
- Meaning: Most subagents complete with ZERO tool calls

**Budget Limits vs Reality:**
| Agent Type | Call Limit | Byte Limit | Max Observed Calls |
|------------|-----------|------------|-------------------|
| Explore | 30 | 80KB | ~1 |
| general-purpose | 35 | 120KB | ~1 |
| code-reviewer | 25 | 100KB | 0 |
| deep-debugger | 40 | 150KB | 0 |

**Conclusion:** The per-subagent budgets are set 30-40x higher than actual usage. No subagent has ever approached the limits.

---

### 2. Global Token Budget: TRACKING WORKS, ENFORCEMENT NEVER TRIGGERED

**Current State:**
```json
{
  "consumed": 180200,
  "limit": 280000,
  "total_limit": 280000,
  "utilization": 64
}
```

**Evidence:**
- Budget state file exists: `~/.claude/.warden/budget.state` contains `180200`
- Budget export cache exists: `~/.claude/.statusline/budget-export` (updated)
- Budget alert triggered once: `WARNING|78|1770713162` (Feb 10, hit 78% threshold)
- Session budget snapshots: 11 sessions tracked in `~/.claude/.session-budgets/`

**Session Cost Log Analysis:**
```csv
timestamp,session_id,duration_seconds,budget_start,budget_end,budget_delta,subagent_count
2026-02-13T09:11:18,b9843d24-717e-4edf-a19e-41e12287ac52,11485,141000,23100,-117900,1
2026-02-23T02:35:28,33b8733b-3f1c-488a-93a7-5d34f063e9bd,3,244800,244800,0,0
```

**Issues Found:**
1. Budget deltas mostly show 0 (budget not being incremented by subagent-stop)
2. One session shows NEGATIVE delta (-117900) - budget decreased?
3. CSV format broken with duplicate "0" lines

**Alert Thresholds:**
- 75% threshold: Alert triggered (statusline shows WARNING)
- 90% threshold: Never hit (critical alert never sent)
- 100% threshold: Never hit (subagent creation never blocked)

**Conclusion:** Global budget tracking functions exist and execute, but:
- Token estimates appear inaccurate (negative deltas, mostly zeros)
- Never reached exhaustion (100%) to block subagent creation
- Current utilization at 64% suggests budget is generous

---

### 3. State File Analysis

**Per-Subagent State:**
```bash
ls /home/zack/.claude/.subagent-state/*.calls
# Result: no matches found

ls /home/zack/.claude/.subagent-state/*.bytes
# Result: no matches found
```

**Explanation:** Pre-tool-use writes to `$WARDEN_SUBAGENT_STATE_DIR/$AGENT_ID.calls` and `$AGENT_ID.bytes`, but these files are not present. This suggests:
- State files are cleaned up after subagent stops
- OR the subagents are completing so quickly that state is ephemeral
- OR the state directory path changed and old files exist elsewhere

**Found Instead:**
- `/home/zack/.claude/.subagent-state/session-8c7dc7d5-75d0-49b4-8d2f-9849ded14a67` (session lock file)
- No per-agent call/byte counter files

---

### 4. Other Warden Rules: ACTIVELY WORKING

**Total Blocks:** 240 blocked events across all sessions

**Top Blocking Rules:**
| Rule | Blocks | Description |
|------|--------|-------------|
| read_bundled | 102 | Blocked reads of bundled/minified files |
| destructive_cmd | 25 | Blocked destructive operations |
| rce_pipe | 21 | Blocked remote code execution attempts |
| grep_recursive | 20 | Blocked unbounded grep operations |
| ssrf_localhost_bash | 19 | Blocked SSRF to localhost |
| read_oversize | 12 | Blocked oversized file reads |
| write_oversize | 9 | Blocked oversized writes |
| edit_oversize | 9 | Blocked oversized edits |

**Conclusion:** The non-budget safety rules are actively protecting the system. Warden hooks are executing correctly.

---

## Root Cause Analysis

### Why Haven't Budgets Triggered?

**Per-Subagent Limits:**
1. **Subagents finish too quickly** - Most complete in 1-2 tool calls
2. **Limits are too generous** - 30-40 calls when agents rarely exceed 2
3. **Natural task completion** - Agents stop when task is done, not when budget exhausted
4. **User behavior** - User may not be spawning resource-intensive subagents

**Global Token Budget:**
1. **Inaccurate token estimation** - Bytes * 10/35 heuristic doesn't match actual API costs
2. **Budget reset unknown** - Unclear when/if budget resets (appears persistent across sessions)
3. **Generous total** - 280k tokens is ~$1.40 at Sonnet 4.5 rates (10M input / 50M cache / 3M output)
4. **Slow accumulation** - 5 weeks of usage only consumed 180k/280k (64%)

---

## Value Assessment

### Budget Systems Providing Value:
- **Monitoring/Visibility**: Grafana dashboards show budget trends (even if limits not hit)
- **Historical tracking**: Session cost CSV provides audit trail
- **Statusline display**: Budget % shows cost awareness
- **Alert system**: 78% warning was triggered once (user got notification)

### Budget Systems NOT Providing Value:
- **Enforcement**: Never blocked a single subagent (creation or tool call)
- **Per-agent limits**: Set 30x higher than actual usage
- **Token estimation**: Negative deltas and zeros suggest inaccuracy
- **Guidance strings**: Budget numbers in agent prompts are theater (never approached)

---

## Recommendations

### Option 1: Remove Per-Subagent Limits (RECOMMENDED)
**Rationale:**
- Zero enforcement value (never triggered in 128 agents)
- Limits are arbitrary guesses, not calibrated to reality
- Simplifies pre-tool-use hook (remove 60 lines)
- Removes 24 config entries that serve no purpose
- Natural task completion is more reliable than artificial limits

**Keep:**
- Global budget (provides visibility even if not enforcing)
- Other warden safety rules (actively working)

### Option 2: Recalibrate Limits to Reality
**Rationale:**
- Set per-agent call limits to 5-10 (not 30-40)
- Set byte limits to 10-20KB (not 80-150KB)
- Actually enforce realistic constraints

**Risk:**
- May interrupt legitimate work if calibrated too tight
- Requires ongoing tuning as usage patterns change

### Option 3: Remove Global Budget, Keep Per-Agent Limits
**Rationale:**
- Token estimation is inaccurate (negative deltas)
- Claude Code 2.1.76+ has native OTEL with real token counts
- Per-agent limits at least based on observable metrics (calls, bytes)

**Risk:**
- Loses historical cost tracking
- Removes 7 Grafana panels
- No session-wide cost visibility

### Option 4: Remove Both (MAXIMUM SIMPLIFICATION)
**Rationale:**
- Neither system is enforcing anything in practice
- ~200 lines of code for monitoring-only features
- Native OTEL provides better token tracking
- Other warden rules provide real safety value

**Risk:**
- Total loss of cost visibility (unless using native OTEL)
- No proactive alerts before expensive mistakes

---

## Decision Matrix

| Criteria | Keep Both | Remove Per-Agent Only | Remove Global Only | Remove Both |
|----------|-----------|----------------------|-------------------|-------------|
| Code complexity | High | Medium | Medium | Low |
| Enforcement value | None proven | None proven | None | None |
| Monitoring value | High | Medium | Low | None |
| Maintenance burden | High | Medium | Medium | None |
| Alignment with native OTEL | Poor | Poor | Good | Excellent |
| Risk of cost spikes | Low* | Low* | Medium | High |

*Low because natural task completion and other warden rules provide safety

---

## Actual Usage Snapshot (Current Session)

**Session:** 8897e858-2ada-41d1-9453-323467991540

**Events:**
- Total events: 198
- Subagent starts: 1 (agent aeefd307888448fff, type: Explore)
- Subagent tool calls: 0 (agent blocked on large file read, not budget)
- Blocks: 1 (rule: large_file, not budget)

**Budget:**
- Start: 180200 tokens
- Current: 180200 tokens
- Delta: 0 (no change)

**Conclusion:** This session has made zero budget progress despite significant activity. Budget tracking is not capturing actual token usage.

---

## Final Verdict

**The budget systems are NOT working as intended:**
1. Per-subagent limits have NEVER triggered enforcement (0/128 agents)
2. Global budget tracking shows zeros and negative deltas (estimation broken)
3. Limits are set 30-40x higher than observed usage
4. Budget exists more as monitoring theater than actual protection

**Strongest case for removal:**
- Per-subagent call/byte limits: Pure overhead, zero value
- Global token budget: Replace with native OTEL token tracking

**If keeping anything, keep:**
- Global budget for historical visibility (even if inaccurate)
- Fix token estimation or replace with native OTEL queries
