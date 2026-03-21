# Other Bugs Found in Log Analysis

## 1. Session Cost CSV Corruption (CRITICAL - PARTIALLY FIXED)

**File:** `/home/zack/.claude/.monitoring/session-costs.csv`

**Problem:** Standalone "0" lines appearing after CSV rows

**Example:**
```
2026-03-15T14:23:35-07:00,f3cfb8b9-f406-45f3-b42e-8164b855f692,61849,180200,180200,0,0
0
2026-03-15T14:23:37-07:00,043ce34e-5e86-4f88-a529-9c5969c956d0,57664,180200,180200,0,0
0
```

**Impact:**
- 321 corrupted lines out of 699 total lines (46% of file is garbage)
- CSV parsers will fail or skip rows
- Historical session cost data is partially unusable

**Status:** FIXED as of 2026-03-15 22:13:07
- Last corrupted entry at 15:37:40
- First clean entry at 22:13:07 (after commit 75a1017)
- All entries since then are clean (no standalone "0" lines)

**Root Cause:** Unknown - likely fixed in Phase 2+3 concurrency fixes
- Both session-end and session-lifecycle installed (deprecated one should be removed)
- Possible race condition or double-write fixed in 75a1017

**Recommendation:**
1. Remove session-lifecycle symlink from ~/.claude/hooks/ (it's deprecated)
2. Clean up the CSV file (remove standalone "0" lines)
3. Or regenerate from clean sessions forward

---

## 2. Budget Delta Tracking Broken

**File:** Budget tracking in session-end hook

**Problem:** Session budget deltas show mostly zeros or negative values

**Examples from session-costs.csv:**
```
# Most sessions show 0 delta despite activity
2026-03-15T14:23:35,f3cfb8b9-f406-45f3-b42e-8164b855f692,61849,180200,180200,0,0

# One session shows NEGATIVE delta (impossible!)
2026-02-13T09:11:18,b9843d24-717e-4edf-a19e-41e12287ac52,11485,141000,23100,-117900,1
```

**Root Cause:** Budget not being incremented properly
- subagent-stop calls `_warden_budget_update` to add tokens
- But session budget remains constant across sessions (180200)
- Token estimation formula (bytes * 10/35) may be inaccurate
- Budget state file may be reset improperly

**Impact:**
- Historical cost tracking is useless (all deltas show 0)
- Cannot determine actual token usage per session
- Negative delta (-117900) suggests budget was RESET mid-session

**Status:** ACTIVE BUG - still happening

**Recommendation:**
- Fix budget increment logic in subagent-stop
- OR remove global budget entirely (replace with native OTEL)
- Investigate why budget decreased by 117k tokens in one session

---

## 3. Subagent State Files Missing

**Location:** `~/.claude/.subagent-state/`

**Expected Files:**
- `$AGENT_ID.calls` - Call counter for each subagent
- `$AGENT_ID.bytes` - Byte counter for each subagent

**Actual State:**
```bash
ls /home/zack/.claude/.subagent-state/
# Result: Only session lock files, no *.calls or *.bytes files
```

**Impact:**
- Per-subagent call/byte budget enforcement creates state files on each tool call
- These files are never found (either cleaned up too aggressively or not created)
- Budget enforcement code runs but operates on missing/zero state

**Possible Causes:**
1. State files cleaned up immediately after subagent stops
2. State directory path changed and files exist elsewhere
3. Files created in temp location that's cleaned on session end

**Status:** State files ephemeral or missing - unclear if this is by design

**Recommendation:**
- If by design: Document that state is ephemeral
- If bug: Fix cleanup logic to preserve state during subagent lifetime
- OR remove per-subagent budget system entirely (it's not triggering anyway)

---

## 4. Subagent Duration Field Inconsistency

**Location:** events.jsonl subagent_stop events

**Problem:** Some events have duration_seconds, some have duration_ms, some have null

**Examples:**
```json
{"agent_id": "a6c286a5c40169628", "duration_s": 524, "duration_ms": null}
{"agent_id": "a8944d027712c1fd9", "duration_s": 101, "duration_ms": null}
{"agent_id": null, "duration_s": null, "duration_ms": 23}
{"agent_id": null, "duration_s": null, "duration_ms": null}
```

**Impact:**
- Inconsistent data model makes querying difficult
- Some events have no agent_id (how is that possible?)
- Cannot reliably query subagent duration metrics

**Root Cause:** Likely different code paths or hook versions
- Older events use duration_seconds
- Newer events use duration_ms
- Some events have no agent_id (malformed?)

**Status:** ACTIVE - inconsistent schema

**Recommendation:**
- Standardize on one duration field (duration_ms preferred)
- Add schema validation to ensure agent_id is always present
- Document the event schema properly

---

## 5. Deprecated session-lifecycle Hook Still Installed

**Location:** `~/.claude/hooks/session-lifecycle`

**Problem:**
- Hook file marked as "DEPRECATED" in comments
- Still symlinked in ~/.claude/hooks/
- Could be causing duplicate writes to session-costs.csv

**From hook header:**
```bash
# session-lifecycle: DEPRECATED — not registered in settings.hooks.json.
# The separate session-start and session-end hooks are the active implementations.
# This file is kept for backward compatibility...
```

**Impact:**
- Confusing to users (which hook is actually running?)
- Potential for duplicate event emissions
- Possible cause of CSV corruption issue #1

**Status:** ACTIVE - deprecated code still installed

**Recommendation:**
- Remove symlink: `rm ~/.claude/hooks/session-lifecycle`
- Or move to hooks/deprecated/ directory
- Update install.sh to skip deprecated hooks

---

## 6. Negative Budget Delta

**Specific Instance:** Session b9843d24-717e-4edf-a19e-41e12287ac52

**Data:**
```csv
timestamp,session_id,duration_seconds,budget_start,budget_end,budget_delta,subagent_count
2026-02-13T09:11:18,b9843d24-717e-4edf-a19e-41e12287ac52,11485,141000,23100,-117900,1
```

**Details:**
- Session lasted 11485 seconds (~3.2 hours)
- Budget START: 141000 tokens
- Budget END: 23100 tokens
- Delta: -117900 tokens (budget DECREASED by 117k)
- Had 1 subagent

**This Should Never Happen:**
- Budget can only increase (tokens consumed)
- A negative delta means either:
  1. Budget was manually reset during session
  2. Budget state file was corrupted/overwritten
  3. Calculation bug in session-end hook
  4. Multiple sessions sharing same budget state

**Status:** Historical anomaly - needs investigation

**Recommendation:**
- Add validation: delta should always be >= 0
- Log warning if negative delta detected
- Investigate if budget state is shared across sessions (should be global)

---

## Summary Table

| Issue | Severity | Status | Fixed? |
|-------|----------|--------|--------|
| CSV corruption (standalone "0" lines) | HIGH | Partially fixed | YES (as of 2026-03-15) |
| Budget delta always zero | MEDIUM | Active | NO |
| Negative budget delta | HIGH | Historical anomaly | Unknown if fixed |
| Subagent state files missing | LOW | Unknown | N/A (may be by design) |
| Subagent duration field inconsistency | LOW | Active | NO |
| Deprecated hook still installed | LOW | Active | NO |

---

## Recommended Actions

### Immediate
1. **Remove session-lifecycle symlink** (deprecated, possibly causing issues)
2. **Clean up session-costs.csv** (remove standalone "0" lines or regenerate)
3. **Add budget delta validation** (warn on negative or impossible values)

### Medium Term
1. **Fix budget increment logic** (deltas should reflect actual usage)
2. **Standardize event schema** (consistent duration field, always include agent_id)
3. **Document per-subagent state lifecycle** (when are .calls/.bytes files created/cleaned?)

### Long Term
1. **Remove budget systems** (if not providing value, see budget-removal-analysis.md)
2. **Replace with native OTEL** (actual API token counts, not estimates)
3. **Add automated CSV validation** (detect corruption on session-end)

---

## Testing Recommendations

To verify these issues are fixed:

1. **CSV Corruption Test:**
   ```bash
   tail -50 ~/.claude/.monitoring/session-costs.csv | grep "^0$"
   # Should return no results
   ```

2. **Budget Delta Test:**
   ```bash
   tail -10 ~/.claude/.monitoring/session-costs.csv | awk -F',' '{print $6}'
   # Should show non-zero values if budget tracking is working
   ```

3. **Subagent State Test:**
   ```bash
   # Spawn a subagent, make a tool call
   ls ~/.claude/.subagent-state/*.calls
   # Should show at least one .calls file
   ```

4. **Event Schema Test:**
   ```bash
   cat ~/.claude/.statusline/events.jsonl | grep subagent_stop | tail -5 | \
     jq 'select(.agent_id == null or (.duration_seconds == null and .duration_ms == null))'
   # Should return no results (all events should have agent_id and duration)
   ```
