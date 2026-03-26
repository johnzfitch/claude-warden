# Token Waste Audit — 2026-03-25

Scanned 425 conversation JSONL files across all projects in `~/.claude/projects`.

## Executive Summary

| Metric | Value |
|--------|-------|
| Total large outputs (>2KB) | 8,286 |
| Total bytes wasted | 60,707,065 (57.9 MB) |
| Estimated wasted tokens | ~17.3M input tokens |
| Top waste source | Read tool (33.8 MB, 55.7%) |
| Second | Bash tool (18.4 MB, 30.2%) |

Approximately **6 root causes** cover **~90%** of the waste. Each maps to a
concrete hook patch or CLAUDE.md enforcement.

---

## Root Cause Analysis

### 1. UNBOUNDED READ — no offset/limit on large files
**Impact**: 33.8 MB across 3,596 occurrences (avg 9.4 KB each)
**Status**: `read-compress` exists but has major bypass gaps

**Sub-problem A: Non-code files bypass compression entirely**
- `read-compress` exits early for `.md`, `.txt`, `.log`, `.csv`, `.env`, `.conf`
- 223 reads >10KB bypassed this way = **5.06 MB** wasted
- Worst: `.md` files alone: 166 reads, 3.6 MB
- Example: `analysis.md` (53 KB), `report.md` (45 KB), `README.md` (20 KB)

**Sub-problem B: Code files >500 lines still pass through**
- 684 unbounded code reads >10KB = **16.0 MB** wasted
- `read-compress` threshold is 500 lines — many files just under or extraction yields ~same size
- Worst offenders: `.rs` files (8 reads >56KB), `.js` files (6 reads >50KB)
- Same file read multiple times: `mcp/tools.rs` read 8 times at 87KB each

**Patch**: Lower `read-compress` threshold to 350 lines for main agent.
Add head+tail truncation (8KB head + 2KB tail) for non-code files >15KB.
Add file-level dedup cache (hash file path, skip if read within last 5 turns).

---

### 2. BASH grep/rg WITHOUT OUTPUT BOUNDS
**Impact**: 4.1 MB across 816 occurrences (avg 5.0 KB)
**Status**: No hook enforcement. grep outputs fly through uncapped.

The model frequently runs `grep -n "pattern" file` or `rg pattern dir` without
piping to `head`. Even with `post-tool-use` truncation at 20KB, the 2-20KB range
is unpatched and each output persists in context for the entire session.

Top patterns:
- `grep -n "multi|pattern|search"` on large JS bundles (23 KB)
- `rg 'pattern' dir/ --type rust -n -C 1` with context lines (18 KB)
- `journalctl | grep` without `--since` bounds (19 KB)

**Patch**: In `post-tool-use`, if tool=Bash and command matches `grep|rg` and
output >4KB, truncate to 4KB head + 1KB tail with count of omitted lines.
This is safe because grep output is line-oriented and the model rarely needs
the middle of a large grep result.

---

### 3. BASH `cat` WITHOUT BOUNDS
**Impact**: 3.0 MB across 484 occurrences (avg 6.3 KB)
**Status**: No pre-tool-use enforcement. Post-tool-use truncation catches >20KB only.

Model uses `cat file` instead of `Read` or bounded `head`/`bat -r`. SSH variants
(`ssh host "cat file"`) bypass Read hooks entirely.

Top patterns:
- `cat ~/dev/*/README.md` (20 KB)
- `ssh adept "cat /etc/nixos/modules/*.nix"` (20 KB)
- `cat -n *.html` (18 KB)
- `cat ~/.claude/skills/*/SKILL.md` (19 KB x2)

**Patch**: In `pre-tool-use`, if command is `cat <file>` without pipe, rewrite to
`head -c 8192 <file>` with a note: `[warden: cat -> head -c 8192. Use Read with
offset/limit for full content.]`. Exception: `cat > file` (write redirect) and
`cat file | pipeline` (piped) should pass through.

---

### 4. `git diff` WITHOUT `--stat` or bounds
**Impact**: 1.3 MB across 215 occurrences (avg 5.8 KB)
**Status**: `post-tool-use` strips git hints but doesn't truncate diff body.

Model runs `git diff HEAD`, `git diff <file>`, `git diff branch..branch` and gets
full patch output. Useful lines are usually the first ~100 and file summary.

Top patterns:
- `git diff HEAD` — full working tree diff (24 KB)
- `git diff HEAD~1..HEAD` — entire last commit (22 KB)
- `git diff <file>` — single file diffs (14-18 KB)

**Patch**: In `pre-tool-use`, for standalone `git diff` commands without `--stat`,
pipe, redirect, or compound operators: append `--no-color | head -200` to cap
output at ~200 lines. Only applies to simple invocations — chained commands
(`&&`, `||`, `;`) and redirects are left untouched to avoid misapplying the pipe.

---

### 5. MCP TOOL OUTPUTS — no truncation pathway
**Impact**: 4.7 MB across 408 occurrences across 30+ MCP tools
**Status**: MCP outputs bypass both `read-compress` and `post-tool-use` truncation.

The `post-tool-use` hook only truncates Bash/Grep/Glob/Task outputs (line 311:
`case "$TOOL_NAME" in Bash|Grep|Glob|Task)`). All MCP tools pass through untruncated.

Worst MCP offenders:

| MCP Tool | Count >10KB | Total | Avg | Fix |
|----------|-------------|-------|-----|-----|
| `llmx_search` | 79 | 1.6 MB | 20 KB | Add `limit` param, server-side truncation |
| `github/pull_request_read` | 4 | 146 KB | 37 KB | Truncate patch content |
| `binary-intel/search_reports` | 5 | 98 KB | 20 KB | Server-side limit |
| `binary-intel/compare` | 3 | 83 KB | 28 KB | Summary mode |
| `github/list_releases` | 2 | 80 KB | 40 KB | Limit release body length |
| `chrome/read_page` | 4 | 77 KB | 19 KB | Depth/filter defaults |
| `chrome/get_page_text` | 3 | 50 KB | 17 KB | Truncate body |

**Patch**: Extend `post-tool-use` truncation case to include MCP tools:
```bash
case "$TOOL_NAME" in
    Bash|Grep|Glob|Task|mcp__*)
```
This gives all MCP outputs the same 20KB truncation + head/tail treatment.
Individual MCP servers should also add server-side limits, but the hook is
the universal safety net.

---

### 6. `head`/`tail` THAT AREN'T BOUNDED ENOUGH
**Impact**: 1.9 MB across 380 occurrences (avg 5.0 KB)
**Status**: No enforcement — model uses `head -200` on dense files.

The model applies bounds but they're too generous:
- `gh run view --log-failed 2>&1 | head -200` (23 KB — CI logs are wide)
- `head -n 100 <minified-js>` (lines are 50KB+ each)
- `tail -n 50 <log>` with very long lines

**Patch**: This is partially addressed by `post-tool-use` generic truncation at
20KB, but the 5-20KB range is still wasteful. Consider lowering
`WARDEN_TRUNCATE_BYTES` from 20KB to 12KB for Bash outputs.

---

## Consolidated Patch Plan

These 6 root causes collapse into **4 hook patches**:

### Patch 1: `post-tool-use` — extend truncation to MCP + lower threshold
- Add `mcp__*` to the truncation case statement
- Lower `WARDEN_TRUNCATE_BYTES` from 20KB to 12KB
- Add grep-specific truncation: 4KB head + 1KB tail for grep/rg outputs >4KB
- **Estimated savings**: ~8 MB across current corpus

### Patch 2: `read-compress` — handle non-code files + lower threshold
- Add head+tail truncation (8KB head + 2KB tail) for `.md`, `.txt`, `.log` >15KB
- Lower main-agent code threshold from 500 to 300 lines
- **Estimated savings**: ~7 MB across current corpus

### Patch 3: `pre-tool-use` — rewrite unbounded cat and git diff
- `cat <file>` (no pipe) -> `head -c 8192 <file>` with note
- `git diff` (no --stat, no pipe) -> `git diff --stat && git diff | head -200`
- **Estimated savings**: ~3 MB across current corpus

### Patch 4: `post-tool-use` — tool_output_size tracking for all tools
- Currently only 2 events ever logged (both Agent outputs)
- Extend `_warden_emit_output_size` to fire for ALL tools, not just Bash
- Required for ongoing monitoring and threshold tuning
- **Estimated savings**: N/A (observability, not truncation)

### Total estimated savings: ~18 MB (~30% of total waste)

The remaining ~42 MB is legitimate large outputs that are either:
- Already truncated by the 20KB cap (but were >2KB pre-truncation)
- Necessary for the task (code files the model needed to read in full)
- From tools with bounded outputs that just happen to be >2KB

---

## Size Distribution (current state)

| Bracket | Count | Total Bytes | Top Sources |
|---------|-------|-------------|-------------|
| 2-5 KB | 4,869 | 14.9 MB | Bash(2356), Read(1873), Grep(296) |
| 5-10 KB | 1,739 | 12.2 MB | Read(725), Bash(653), Grep(102) |
| 10-20 KB | 1,041 | 14.6 MB | Read(488), Bash(393), llmx(50) |
| 20-40 KB | 560 | 15.2 MB | Read(438), Bash(68), llmx(28) |
| 40-80 KB | 75 | 3.6 MB | Read(70), github(2) |
| 80-200 KB | 2 | 174 KB | Read(2) |

The 2-5 KB bracket is high volume but individually small. The 10-40 KB bracket
is where the biggest bang-for-buck patches live (1,601 outputs, 29.8 MB).

---

## Monitoring Gaps

1. **`tool_output_size` events**: Only 2 ever recorded. The hook only fires for
   Bash+Grep with `_warden_emit_output_size`. Must extend to Read, MCP, Glob.

2. **No per-session waste tracking**: Can't answer "which session wasted the
   most tokens?" without aggregating across conversation JSONLs.

3. **No dedup detection**: Same file read 8 times (mcp/tools.rs at 87KB) generates
   no alert. A dedup detector in `read-compress` could warn or cache.

4. **MCP output tracking**: `mcp_tool_start` events exist but no corresponding
   `mcp_tool_complete` with output size. Need a post-tool-use MCP output tracker.
