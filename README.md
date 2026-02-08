# claude-warden

Token-saving hooks for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Prevents verbose output, blocks binary reads, enforces subagent budgets, truncates large outputs, and provides a rich statusline -- saving thousands of tokens per session.

Pair with [claude-usage-helper](https://github.com/johnzfitch/claude-usage-helper) for budget tracking, cost telemetry, and session analytics. Warden enforces; usage-helper accounts.

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/architecture-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="assets/architecture-light.png">
  <img alt="Architecture: claude-warden (enforcement) feeds into claude-usage-helper (accounting) in a closed loop" src="assets/architecture-dark.png" width="800">
</picture>

## What it does

claude-warden installs a set of shell hooks that intercept Claude Code tool calls at every stage of execution. Each hook enforces token-efficient patterns and blocks common waste.

### Guard catalog

| Hook | Event | What it guards |
|---|---|---|
| `pre-tool-use` | PreToolUse | Blocks verbose commands (`npm install` without `--silent`, `cargo build` without `-q`, `pip install` without `-q`, `curl` without `-s`, `wget` without `-q`, `docker build/pull` without `-q`). Blocks binary file reads. Enforces subagent tool budgets. Blocks recursive grep/find without limits. Blocks Write >100KB, Edit >50KB. Blocks minified file access. |
| `post-tool-use` | PostToolUse | Truncates Bash output >20KB to 10KB (8KB head + 2KB tail). Suppresses output >500KB entirely. Detects binary output. Tracks session stats. Budget alerts at 75%/90%. |
| `read-guard` | PreToolUse (Read) | Blocks Read on bundled/generated files (`node_modules/`, `/dist/`, `.min.js`, etc.). Blocks files >2MB. |
| `read-compress` | PostToolUse (Read) | Extracts structural signatures (imports, functions, classes) from large file reads. Subagents: >100 lines. Main agent: >500 lines. |
| `permission-request` | PermissionRequest | Auto-denies dangerous commands (`rm -rf /`, `mkfs`, `curl \| bash`). Auto-allows safe read-only commands. |
| `stop` | Stop | Logs session stop events with duration. |
| `session-start` | SessionStart | Initializes session timing and budget snapshots. |
| `session-end` | SessionEnd | Logs session duration, budget delta, subagent counts. |
| `subagent-start` | SubagentStart | Enforces budget-cli limits. Tracks active subagent count. Injects type-specific guidance. |
| `subagent-stop` | SubagentStop | Reclaims budget. Logs subagent metrics (duration, type). |
| `tool-error` | ToolError | Logs errors with context. Provides recovery hints. |
| `statusline.sh` | StatusLine | Displays model, context %, IO tokens, cache stats, tool count, hottest output, active subagents, budget utilization. |

### Hook lifecycle

```
PreToolUse ──> [tool executes] ──> PostToolUse
     │                                  │
     ├─ pre-tool-use (all tools)        ├─ post-tool-use (all tools)
     └─ read-guard (Read only)          └─ read-compress (Read only)
```

## Requirements

- **Required**: `jq` (JSON processing)
- **Recommended**: `rg` (ripgrep), `fd` (fd-find)
- **Optional**: `budget-cli` (token budget tracking -- from [claude-usage-helper](https://github.com/johnzfitch/claude-usage-helper))

## Install

```bash
git clone https://github.com/johnzfitch/claude-warden.git ~/dev/claude-warden
cd ~/dev/claude-warden
./install.sh
```

### Install modes

**Symlink** (default) -- edits to the repo take effect immediately:

```bash
./install.sh
```

**Copy** -- files are independent of the repo:

```bash
./install.sh --copy
```

**Dry run** -- see what would happen:

```bash
./install.sh --dry-run
```

### What install.sh does

1. Checks prerequisites (`jq` required, warns if `rg`/`fd` missing)
2. Detects platform (Linux, macOS, WSL)
3. Backs up existing `~/.claude/hooks/` and `~/.claude/settings.json`
4. Symlinks (or copies) all hook scripts to `~/.claude/hooks/`
5. Symlinks (or copies) `statusline.sh` to `~/.claude/statusline.sh`
6. Merges hook config into `~/.claude/settings.json` (preserves your permissions, plugins, model, etc.)
7. Sets executable permissions
8. Validates JSON and shell syntax

## Uninstall

```bash
./uninstall.sh
```

Restores your most recent settings.json backup. Hook backups remain in `~/.claude/hooks.bak.*/`.

## Configuration

### Tuning thresholds

Edit the hook scripts directly (in symlink mode, edit the repo files):

- **Output truncation**: `post-tool-use` line 77 -- `20480` bytes (20KB) threshold
- **Read compression**: `read-compress` -- subagent threshold at 100 lines, main agent at 500 lines
- **File size limit**: `read-guard` -- `MAX_SIZE_MB=2`
- **Subagent budgets**: `pre-tool-use` -- `BUDGET_LIMITS` associative array
- **Binary detection**: `pre-tool-use` -- regex pattern for `file` command output

### Disabling specific guards

To disable a specific guard category, remove or comment out the corresponding matcher in `settings.hooks.json` and re-run `./install.sh`. For example, to disable read compression:

```json
// Remove or comment this block from settings.hooks.json:
{
  "matcher": "Read",
  "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/read-compress", "timeout": 7}]
}
```

### Adding your own permission allow-list

The `permission-request` hook handles auto-deny/allow. For tools you use frequently, add them to the `permissions.allow` array in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(rg:*)",
      "Bash(fd:*)",
      "Bash(git status:*)"
    ]
  }
}
```

Commands in the allow-list never reach the permission hook.

## Platform support

| Platform | Status | Notes |
|---|---|---|
| Linux | Full support | Primary development platform |
| macOS | Full support | Uses `gtimeout` fallback, `osascript` for notifications, macOS `stat` flags |
| WSL | Full support | Detected via `/proc/version` |

### Cross-platform details

- **`timeout`**: Falls back to `gtimeout` (coreutils), then no-timeout
- **`stat`**: Uses `-c%s` (Linux) with `-f%z` (macOS) fallback
- **`flock`**: Replaced with `mkdir`-based locking (atomic on all POSIX)
- **`notify-send`**: Falls back to `osascript` (macOS), silently skips if neither available
- **`rg`**: Falls back to `grep` where used

## How it works

Claude Code supports [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) -- shell commands that run at specific points in the tool-use lifecycle. Hooks receive JSON on stdin describing the tool call and can:

- **Exit 0**: Allow the tool call (optionally with `{"suppressOutput":true}`)
- **Exit 2**: Block the tool call (stderr message is fed back to Claude as feedback)
- **Output JSON**: Modify tool output (`{"modifyOutput":"..."}`) or suppress it

claude-warden hooks are pure bash with a single dependency (`jq`). They run in milliseconds and add negligible latency to tool calls. All paths use `$HOME` for portability -- no hardcoded user directories.

## Related

| Project | What it does |
|---|---|
| [claude-usage-helper](https://github.com/johnzfitch/claude-usage-helper) | Budget tracking, context compression, cost telemetry. Provides `budget-cli` that warden hooks call for budget enforcement. |

## License

MIT
