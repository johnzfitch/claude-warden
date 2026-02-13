# Contributing

claude-warden is a collection of lightweight [Claude Code](https://docs.anthropic.com/en/docs/claude-code) hook scripts written in bash. The project goal is to reduce token waste without breaking normal Claude Code workflows.

## Development Setup

Requirements:

- `bash` (hooks are bash scripts; they should remain POSIX-ish where practical)
- `jq` (required at runtime)

Recommended:

- `shellcheck` (static analysis for shell scripts)
- `shfmt` (consistent formatting)
- `rg` / `fd` (used by some guard suggestions, not required)

## Repository Layout

| Path | Purpose |
|---|---|
| `hooks/` | Hook scripts invoked by Claude Code |
| `statusline.sh` | Statusline renderer invoked by Claude Code |
| `settings.hooks.json` | Hook + statusline config template merged into `~/.claude/settings.json` |
| `install.sh` / `uninstall.sh` | Install/remove scripts (touch `~/.claude/`) |
| `demo/mock-inputs/` | Small JSON fixtures for exercising hook behavior locally |

## Safety Notes (Local State)

`install.sh` and `uninstall.sh` modify files under `~/.claude/` (hooks, statusline, `settings.json`). When iterating on hook behavior, prefer:

```bash
./install.sh --dry-run
```

If you do run `./install.sh`, use a real Claude Code session to validate changes. Do not run install/uninstall scripts in CI.

## Quick Checks

Run these before submitting changes:

```bash
# Minimal test harness (syntax + fixtures)
bash tests/run.sh

# Shell syntax checks
find hooks -maxdepth 1 -type f ! -name '_token-count-bg' -print0 | xargs -0 bash -n
bash -n install.sh uninstall.sh statusline.sh

# Optional: validate the Python helper used only for API token counting mode
command -v python3 >/dev/null 2>&1 && python3 -m py_compile hooks/_token-count-bg

# JSON validity
jq . settings.hooks.json >/dev/null
```

If you have `shellcheck` installed:

```bash
find hooks -maxdepth 1 -type f ! -name '_token-count-bg' -print0 | xargs -0 shellcheck
shellcheck install.sh uninstall.sh statusline.sh
```

## Manual Hook Fixtures

The `demo/mock-inputs/` directory contains small JSON payloads that mimic Claude Code hook inputs. You can use them to sanity-check behavior without opening Claude Code:

```bash
# Example: system reminder stripping in post-tool-use
cat demo/mock-inputs/post-tool-use-reminder-bash.json | hooks/post-tool-use | jq -r '.modifyOutput'

# Example: read-compress should pass through small reads (or only strip reminders)
cat demo/mock-inputs/post-tool-use-clean-read.json | hooks/read-compress
```

## Coding Standards (Shell)

Goals:

- Hooks must be fast (run on every tool call).
- Hooks must be resilient: malformed JSON or missing optional fields should not crash Claude Code.
- Avoid leaking secrets into logs or stdout/stderr.

Guidelines:

- Quote variables (`"$var"`) unless you are intentionally relying on word splitting.
- Prefer `printf` over `echo` for untrusted strings.
- When logging, scrub likely secrets (Authorization headers, bearer tokens, `*_KEY`, `*_TOKEN`, `*_SECRET`, passwords).
- Any new guard that blocks a command should include a clear remediation message.
- If a change affects user-visible behavior, update `README.md` (guard catalog and/or configuration notes).

## Pull Requests

Please include:

- What problem you are solving (token waste pattern, guard bypass, bug fix).
- Evidence: the relevant hook event + the exact guard behavior before/after.
- Any portability considerations (Linux/macOS/WSL differences).
