# Security Policy

## Scope and Security Model

claude-warden is primarily a **token-efficiency and workflow-quality** tool for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). It is **not** a security sandbox.

Important implications:

- Hook scripts run locally as **your user** on your workstation.
- Most protections are **pattern-based guards** intended to reduce token waste and prevent common footguns.
- The primary security boundary is **Claude Code’s own permission system** (prompts + allow/deny rules), not claude-warden’s heuristics.

## Data Handling

claude-warden writes local state and logs under `~/.claude/` to support metrics and statusline rendering. Typical files/directories include:

- `~/.claude/.statusline/events.jsonl`
  - Append-only JSONL events (blocked commands, truncations, compression events).
  - Includes best-effort redaction of common secret patterns in command strings.
- `~/.claude/.statusline/state`
  - Pipe-delimited snapshot used by `statusline.sh`.
- `~/.claude/.statusline/session-$SESSION_ID`, `~/.claude/.statusline/peak-$SESSION_ID`, etc.
  - Per-session counters and peak tracking.
- `~/.claude/agent-stats.csv`, `~/.claude/session-log.txt`, `~/.claude/errors.log`
  - Local logs for debugging and aggregate reporting.

If you work in environments with strict confidentiality requirements, treat these files as sensitive local artifacts.

## Network / External Services

By default, claude-warden does **not** send telemetry to third-party services.

Exception: **Optional API token counting**.

If you set:

```bash
export WARDEN_TOKEN_COUNT=api
```

then `hooks/post-tool-use` and `hooks/read-compress` may spawn a background process (`hooks/_token-count-bg`) that calls the Anthropic **token counting API** to compute exact token deltas. This transmits the relevant tool output text to Anthropic’s API.

Do not enable `WARDEN_TOKEN_COUNT=api` if tool outputs may contain secrets or sensitive data.

## Reporting a Vulnerability

If you believe you’ve found a security issue:

1. Prefer filing a **GitHub Security Advisory** (private disclosure) if available.
2. If that is not available, open an issue with a minimal reproduction and **redact all secrets** (API keys, tokens, cookies, Authorization headers, `.env` contents).

Please include:

- A clear description of the impact (for example secret exposure, unintended command allow, unsafe file write).
- Exact version/commit SHA if possible.
- The relevant hook(s) and the matching rule.

## Hardening Tips

- Prefer **symlink mode** installs (`./install.sh`) so your installed hooks track the repo and are easy to audit.
- Keep `~/.claude/` permissions user-only.
- Avoid adding broadly permissive `permissions.allow` entries for commands that can print secrets (for example dumping environments).
- The `permission-request` hook intentionally avoids auto-allowing secret-dumping commands. `echo` is only auto-allowed when it is a constant literal (no `$`, backticks, `$(`, globbing, or redirects); otherwise it falls back to prompting (`ask`).
