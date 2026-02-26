[repo]: https://github.com/johnzfitch/claude-warden
[hooks-docs]: https://docs.anthropic.com/en/docs/claude-code/hooks
[claude-code]: https://docs.anthropic.com/en/docs/claude-code
[token-api]: https://docs.anthropic.com/en/docs/build-with-claude/token-counting

[icon-shield]: .github/assets/icons/shield-security-protection-16x16.png
[icon-lock]: .github/assets/icons/lock-16x16.png
[icon-terminal]: .github/assets/icons/application-terminal-16x16.png
[icon-chart]: .github/assets/icons/chart-16x16.png
[icon-alert]: .github/assets/icons/alert-16x16.png
[icon-lightning]: .github/assets/icons/lightning-16x16.png
[icon-monitor]: .github/assets/icons/application-monitor-16x16.png
[icon-folder]: .github/assets/icons/blue-folder-16x16.png
[icon-stack]: .github/assets/icons/applications-stack-16x16.png
[icon-wrench]: .github/assets/icons/wrench-16x16.png
[icon-clock]: .github/assets/icons/alarm-clock-16x16.png
[icon-cross]: .github/assets/icons/cross-16x16.png
[icon-run]: .github/assets/icons/application-run-16x16.png
[icon-book]: .github/assets/icons/blue-document-view-book-16x16.png
[icon-key]: .github/assets/icons/blue-key-16x16.png
[icon-network]: .github/assets/icons/building-network-16x16.png
[icon-flow]: .github/assets/icons/application-network-16x16.png
[icon-metrics]: .github/assets/icons/chart-arrow-16x16.png

# claude-warden

Token-saving hooks + observability for [Claude Code][claude-code]. Prevents verbose output, blocks binary reads, enforces subagent budgets, truncates large outputs, and provides a rich statusline &mdash; saving thousands of tokens per session.

## ![lightning][icon-lightning] Quickstart

1. Install prerequisites: `jq` (required). Optional: `rg`, `fd`.
2. Install hooks into `~/.claude/` (symlink mode):
   ```bash
   ./install.sh
   ```
3. Choose a profile when prompted (or pass `--profile standard`).
4. Start a new Claude Code session. Hooks run automatically.

Dry-run (no changes to `~/.claude/`):

```bash
./install.sh --dry-run
```

## ![stack][icon-stack] Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/architecture-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="assets/architecture-light.png">
  <img alt="Architecture: claude-warden hooks intercept tool calls for token governance and observability" src="assets/architecture-dark.png" width="800">
</picture>

## ![shield][icon-shield] What it does

claude-warden installs a set of shell hooks that intercept Claude Code tool calls at every stage of execution. Each hook enforces token-efficient patterns and blocks common waste.

### Guard catalog

| Hook | Event | What it guards |
|---|---|---|
| `pre-tool-use` | PreToolUse | Blocks verbose commands (<code>npm&nbsp;install</code>, <code>cargo&nbsp;build</code>, <code>pip</code>, <code>curl</code>, <code>wget</code>, <code>docker</code> without quiet flags). Blocks binary reads. Enforces subagent budgets. Blocks recursive grep/find without limits. Blocks oversized Write/Edit/NotebookEdit. Blocks minified file access. |
| `post-tool-use` | PostToolUse | Strips `<system-reminder>` blocks. Compresses Task output &gt;6KB to structured lines. Truncates Bash output &gt;20KB to 10KB. Suppresses output &gt;500KB. Detects binary output via <abbr title="POSIX octal dump">od</abbr>. Tracks session stats. Budget alerts at 75%/90%. |
| `read-guard` | PreToolUse (Read) | Blocks reads on bundled/generated files (<code>node_modules/</code>, <code>/dist/</code>, <code>.min.js</code>). Blocks files exceeding size limit (configurable, default 2MB). |
| `read-compress` | PostToolUse (Read) | Strips `<system-reminder>` blocks. Extracts structural signatures (imports, functions, classes) from large reads. Subagents: &gt;300 lines. Main agent: &gt;500 lines. |
| `permission-request` | PermissionRequest | Auto-denies dangerous commands (<code>rm&nbsp;-rf&nbsp;/</code>, <code>mkfs</code>, <code>curl&nbsp;\|&nbsp;bash</code>). Auto-allows safe read-only commands. |
| `stop` | Stop | Logs session stop events with duration. |
| `session-lifecycle` | SessionStart/End | Initializes session timing and budget snapshots. Logs duration, budget delta, subagent counts. |
| `subagent-start` | SubagentStart | Enforces budget limits. Tracks active subagent count. Injects type-specific guidance with output budgets. |
| `subagent-stop` | SubagentStop | Reclaims budget. Logs subagent metrics (duration, type, worktree). |
| `tool-error` | PostToolUseFailure | Logs errors with context. Provides recovery hints. |
| `statusline.sh` | StatusLine | Model, context&nbsp;%, IO tokens, cache stats, tool count, hottest output, active subagents, budget utilization. |

### Hook lifecycle

```
PreToolUse ──> [tool executes] ──> PostToolUse
     │                                  │
     ├─ pre-tool-use (all tools)        ├─ post-tool-use (all tools)
     └─ read-guard (Read only)          └─ read-compress (Read only)
```

## ![wrench][icon-wrench] Requirements

<dl>
  <dt><strong>Required</strong></dt>
  <dd><code>jq</code> &mdash; JSON processing</dd>
  <dt><strong>Recommended</strong></dt>
  <dd><code>rg</code> (ripgrep), <code>fd</code> (fd-find)</dd>
  <dt><strong>Optional</strong></dt>
  <dd><code>python3</code> with <code>anthropic</code> package &mdash; exact token counting via API (see <a href="#chart-token-savings-accounting">Token savings accounting</a>)</dd>
  <dd><code>mitmdump</code> &mdash; only for the <a href="#flow-api-capture">API capture</a> tool</dd>
</dl>

## ![run][icon-run] Install

### Quick install (latest release)

```bash
curl -fsSL https://raw.githubusercontent.com/johnzfitch/claude-warden/master/install-remote.sh | bash
```

The remote installer downloads a release tarball, verifies its <abbr title="Secure Hash Algorithm 256-bit">SHA-256</abbr> checksum (hard-fails if missing), validates tarball contents, then runs `install.sh --copy`.

To pin a version:

```bash
curl -fsSL https://raw.githubusercontent.com/johnzfitch/claude-warden/master/install-remote.sh | bash -s -- v0.2.0
```

### Install from source (development)

```bash
git clone https://github.com/johnzfitch/claude-warden.git ~/dev/claude-warden
cd ~/dev/claude-warden
./install.sh
```

### ![key][icon-key] Profiles

The installer applies a configuration profile that sets token limits, tool permissions, and internal thresholds. Choose one during install or pass `--profile`:

| Profile | What it sets |
|---|---|
| `minimal` | Hooks only. No env or permission changes. For users who manage `settings.json` themselves. |
| `standard` | Token/output limits, <abbr title="OpenTelemetry">OTEL</abbr> monitoring, 40 safe tool permissions (read-only git, search, inspection). <strong>Recommended.</strong> |
| `strict` | ~40% tighter limits across the board. Fewer pre-approved tools (19). Lower subagent budgets. |

```bash
./install.sh --profile standard
```

Profiles live in `config/profiles/`. Create `config/user.json` (gitignored) for personal overrides:

```bash
cp config/user.json.template config/user.json
# Edit config/user.json, then re-install:
./install.sh --profile standard
```

Merge order: `config/defaults.json` &larr; profile &larr; `config/user.json` &larr; existing `settings.json` (non-warden keys preserved).

### Install modes

<dl>
  <dt><strong>Symlink</strong> (default)</dt>
  <dd>Edits to the repo take effect immediately. <code>./install.sh</code></dd>
  <dt><strong>Copy</strong></dt>
  <dd>Files are independent of the repo. <code>./install.sh --copy</code></dd>
  <dt><strong>Dry run</strong></dt>
  <dd>See what would happen without writing anything. <code>./install.sh --dry-run</code></dd>
</dl>

### What install.sh does

<dl>
  <dt><strong>Detect &amp; prepare</strong></dt>
  <dd>Checks prerequisites (<code>jq</code> required, warns if <code>rg</code>/<code>fd</code> missing). Detects platform (Linux, macOS, <abbr title="Windows Subsystem for Linux">WSL</abbr>). Backs up existing hooks and <code>settings.json</code>.</dd>
  <dt><strong>Build configuration</strong></dt>
  <dd>Prompts for a profile (or uses <code>--profile</code>). Deep-merges <code>defaults.json</code> + profile + <code>user.json</code>.</dd>
  <dt><strong>Install hooks</strong></dt>
  <dd>Symlinks (or copies) hook scripts + <code>lib/</code> + <code>statusline.sh</code> into <code>~/.claude/</code>. Sets executable permissions.</dd>
  <dt><strong>Apply configuration</strong></dt>
  <dd>Generates <code>~/.claude/.warden/warden.env</code> (hook thresholds). Merges env vars and permissions into <code>settings.json</code> (union for permissions, preserves plugins/model/etc). Generates <code>warden.env.sh</code> for shell sourcing.</dd>
  <dt><strong>Validate</strong></dt>
  <dd>Checks JSON validity and shell syntax for every installed script.</dd>
</dl>

## ![cross][icon-cross] Uninstall

```bash
./uninstall.sh
```

Restores your most recent `settings.json` backup. Removes `~/.claude/.warden/` config. Hook backups remain in `~/.claude/hooks.bak.*/`.

## ![wrench][icon-wrench] Configuration

### ![metrics][icon-metrics] Tuning thresholds

All thresholds are configurable via `config/defaults.json`, profiles, or `config/user.json`. After editing, re-run `./install.sh` to regenerate `~/.claude/.warden/warden.env`.

| Threshold | Config key | Default | Strict |
|---|---|---|---|
| Output truncation | `warden.truncate_bytes` | 20KB | 10KB |
| Subagent read cap | `warden.subagent_read_bytes` | 10KB | 6KB |
| Output suppression | `warden.suppress_bytes` | 512KB | 256KB |
| Read file size limit | `warden.read_guard_max_mb` | 2MB | 1MB |
| Write max size | `warden.write_max_bytes` | 100KB | 50KB |
| Edit max size | `warden.edit_max_bytes` | 50KB | 25KB |
| Subagent call limits | `warden.subagent_call_limits.*` | 15&ndash;40 | 10&ndash;25 |
| Subagent byte limits | `warden.subagent_byte_limits.*` | 80&ndash;150KB | 50&ndash;100KB |

Token limits and tool permissions are set in the `env` and `permissions` sections of the config files and merged into `settings.json` during install.

- **Read compression**: `read-compress` &mdash; subagent threshold at 300 lines, main agent at 500 lines
- **Binary detection**: `post-tool-use` &mdash; POSIX `od` + `grep` for <abbr title="null byte">NUL</abbr> bytes (full-stream scan)

### ![terminal][icon-terminal] Shell environment

The installer generates `warden.env.sh` and prints the line to add to your shell RC. Add it to `~/.zshrc`, `~/.bashrc`, or both:

```bash
# claude-warden env
source "$HOME/dev/claude-warden/warden.env.sh"
```

This exports <abbr title="OpenTelemetry">OTEL</abbr>, token limit, timeout, and sandbox vars from your chosen profile into every new shell. Re-running `install.sh` regenerates `warden.env.sh` with the current profile&rsquo;s values.

If you have existing Claude Code env vars in your shell RC, you can remove them after adding the source line &mdash; warden now manages those values.

### ![chart][icon-chart] Token savings accounting

All hooks report token savings to `~/.claude/.statusline/events.jsonl` using the standard warden event schema. By default, token counts are estimated at ~3.5 bytes/token (benchmarked against Claude&rsquo;s tokenizer across code, prose, and structured output).

For exact counts, set the `WARDEN_TOKEN_COUNT` environment variable:

```bash
export WARDEN_TOKEN_COUNT=api
```

When enabled, each truncation event spawns a background process that calls the [Anthropic token counting API][token-api] (free, separate rate limits) and appends a correction event to `events.jsonl`. The hook returns immediately &mdash; zero added latency.

<dl>
  <dt>Requirements for API mode</dt>
  <dd><code>ANTHROPIC_API_KEY</code> in environment (set automatically by Claude Code)</dd>
  <dd><code>python3</code> with the <code>anthropic</code> package installed</dd>
  <dt>Custom Python path</dt>
  <dd>If <code>python3</code> on your <var>PATH</var> doesn&rsquo;t have <code>anthropic</code>, set <code>WARDEN_PYTHON=/path/to/venv/bin/python3</code></dd>
  <dt>Graceful degradation</dt>
  <dd>If the API key is missing, <code>anthropic</code> isn&rsquo;t installed, or the network is unavailable, the background process silently exits and the estimate stands.</dd>
</dl>

### Disabling specific guards

To disable a specific guard category, remove or comment out the corresponding matcher in `settings.hooks.json` and re-run `./install.sh`. For example, to disable read compression:

```json
// Remove or comment this block from settings.hooks.json:
{
  "matcher": "Read",
  "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/read-compress", "timeout": 7}]
}
```

### ![key][icon-key] Adding your own permission allow-list

Profiles include a set of pre-approved tool permissions. To add your own, create `config/user.json` and add to the `permissions.allow` array:

```bash
cp config/user.json.template config/user.json
```

```json
{
  "permissions": {
    "allow": [
      "Bash(gh api:*)",
      "Bash(pacman -Q:*)",
      "mcp__filesystem__list_directory"
    ]
  }
}
```

Re-run `./install.sh` to merge. User permissions are unioned with the profile permissions &mdash; nothing is removed. Commands in the allow-list never reach the permission hook.

## ![network][icon-network] Platform support

| Platform | Status | Notes |
|---|---|---|
| Linux | Full support | Primary development platform |
| macOS | Full support | Uses `gtimeout` fallback, `osascript` for notifications, macOS `stat` flags |
| <abbr title="Windows Subsystem for Linux">WSL</abbr> | Full support | Detected via `/proc/version` |

<details>
<summary>Cross-platform details</summary>

- **`timeout`**: Falls back to `gtimeout` (coreutils), then no-timeout
- **`stat`**: Uses `-c%s` (Linux) with `-f%z` (macOS) fallback
- **`flock`**: Replaced with `mkdir`-based locking (atomic on all POSIX)
- **`notify-send`**: Falls back to `osascript` (macOS), silently skips if neither available
- **`rg`**: Falls back to `grep` where used
- **Binary detection**: Uses `od -An -tx1 | grep ' 00'` (POSIX, works on macOS/Linux/BSD)

</details>

## ![monitor][icon-monitor] Monitoring stack

Warden includes an optional observability stack in `monitoring/` that persists hook events, measures per-tool latency, and emits <abbr title="OpenTelemetry Protocol">OTLP</abbr> trace spans.

### Components

| Service | Image | Port | Purpose |
|---|---|---|---|
| Loki | `grafana/loki:3.4.2` | 3100 | Log aggregation (30-day retention, <abbr title="Time Series Database">TSDB</abbr> filesystem storage) |
| <abbr title="OpenTelemetry">OTEL</abbr> Collector | `otel/opentelemetry-collector-contrib` | 4317/4318 | Receives <abbr title="OpenTelemetry Protocol">OTLP</abbr> logs + traces, tails `events.jsonl`, exports to Loki + Tempo |
| Prometheus | `prom/prometheus` | 9090 | Metrics (Claude Code <abbr title="OpenTelemetry Protocol">OTLP</abbr> metrics + node-exporter textfiles) |
| Node Exporter | `prom/node-exporter` | 9101 | Textfile collector for warden budget metrics |
| Tempo | `grafana/tempo:2.7.2` | 3200/3205 | Distributed trace storage and visualization |
| Grafana | `grafana/grafana` | 3000 | Dashboards (<samp>admin</samp>/<samp>admin</samp>) |

### Setup

**Linux** (uses `network_mode: host`):

```bash
cd monitoring && docker compose up -d
```

**macOS / Docker Desktop** (uses bridge networking with service <abbr title="Domain Name System">DNS</abbr>):

```bash
cd monitoring && docker compose -f docker-compose.yml -f docker-compose.macos.yml up -d
```

> [!NOTE]
> Docker Desktop does not support `network_mode: host`. The macOS override switches to bridge networking and mounts config overrides that replace `localhost` references with Docker service names (`loki`, `prometheus`, `otel-collector`, etc.).

### ![flow][icon-flow] Data flow

```
Claude Code ──OTLP──> OTEL Collector ──> Loki (logs)
                           │              Prometheus (metrics)
                           │              Tempo (traces)
                           │
hooks/events.jsonl ──filelog──> OTEL Collector ──> Loki

hooks/pre-tool-use  ──records start timestamp──>  state file
hooks/post-tool-use ──computes latency──> events.jsonl (tool_latency)
                    ──curl OTLP/HTTP──> OTEL Collector (trace span)
```

### ![clock][icon-clock] Per-tool latency tracking

Every tool call gets wall-clock timing measured by the hooks:

1. `pre-tool-use` writes a nanosecond timestamp to <samp>$STATE_DIR/.tool-start-$TOOL-$$</samp>
2. `post-tool-use` reads it, computes <var>duration_ms</var>, emits a `tool_latency` event to `events.jsonl`
3. A trace span is fired to the <abbr title="OpenTelemetry">OTEL</abbr> collector via `hooks/lib/otel-trace.sh` (fire-and-forget curl)

Latency events flow through the collector into Loki and are queryable via LogQL:

```
{service_name="claude-code"} | json | event_type="tool_latency" | duration_ms > 2000
```

### Trace spans

`hooks/lib/otel-trace.sh` emits one <abbr title="OpenTelemetry Protocol">OTLP</abbr> span per tool call to `localhost:4318/v1/traces`:

<dl>
  <dt><code>trace_id</code></dt>
  <dd>Deterministic from session ID (md5, 32 hex chars)</dd>
  <dt><code>span_id</code></dt>
  <dd>Random 16 hex chars per call</dd>
  <dt><code>parent_span_id</code></dt>
  <dd>Deterministic root span from session ID</dd>
  <dt>Attributes</dt>
  <dd><code>tool.name</code>, <code>tool.command</code> (first 200 chars), <code>tool.output_bytes</code>, <code>tool.duration_ms</code></dd>
</dl>

Traces are stored in Tempo and can be explored in Grafana via the Tempo datasource. Loki log entries link to traces via the `trace_id` derived field.

### ![chart][icon-chart] Dashboards

Four provisioned dashboards in `monitoring/grafana/dashboards/`:

| Dashboard | <abbr title="Unique Identifier">UID</abbr> | What it shows |
|---|---|---|
| Working Dashboard | `claude-code-otel` | Cost, tokens, budget utilization, session duration, API metrics |
| Tool Latency &amp; Traces | `warden-tool-latency` | Latency scatter plot, per-tool avg/p95/max, call frequency, slow calls, tokens saved by rule |
| Output Size &amp; Tokens | `warden-output-size` | Per-tool output bytes, estimated tokens, large output table, cumulative token trend |
| Subagent &amp; Session Lifecycle | `warden-subagent-lifecycle` | Subagent duration by type, session stop reasons, blocked events by rule, worktree tracking |

The latency and output-size dashboards include session and tool filter variables. Tool filtering operates on parsed JSON fields (not stream labels) since only `session_id` is a Loki index label.

<details>
<summary>Verification commands</summary>

```bash
# Loki healthy
curl -s http://localhost:3100/ready

# Query tool latency events
curl -sG http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={service_name="claude-code"} | json | event_type="tool_latency"' \
  --data-urlencode 'limit=5' \
  --data-urlencode "start=$(date -d '1 hour ago' +%s)" \
  --data-urlencode "end=$(date +%s)"

# Check trace spans in Tempo
curl -s http://localhost:3200/ready

# Check latency events in events.jsonl
grep tool_latency ~/.claude/.statusline/events.jsonl | tail -5
```

</details>

## ![flow][icon-flow] API capture

The `capture/` directory contains a <abbr title="man-in-the-middle">MITM</abbr> proxy wrapper for recording full Claude Code API traffic.

```bash
capture/claude                          # interactive session
capture/claude -p "prompt"             # non-interactive
```

Logs land in <samp>~/claude-captures/YYYY-MM-DD/capture-HHMMSS.jsonl</samp>. Each line is a JSON record: `stream_start`, `stream_chunk`, `stream_end` (for <abbr title="Server-Sent Events">SSE</abbr>), or `exchange` (for non-streaming).

> [!IMPORTANT]
> Request and response bodies are **truncated to 200 characters by default**. To enable full body capture, set `WARDEN_CAPTURE_BODIES=1`. Even with full capture enabled, sensitive JSON keys (`system`, `messages`) are redacted.

<dl>
  <dt>Prerequisites</dt>
  <dd><code>mitmdump</code> (from <code>mitmproxy</code>) and a trusted CA cert at <code>~/.mitmproxy/mitmproxy-ca-cert.pem</code></dd>
  <dt>Log permissions</dt>
  <dd>Capture JSONL files and the proxy log (<code>~/.claude/capture-mitm.log</code>) are created with mode <code>600</code></dd>
  <dt>Header scrubbing</dt>
  <dd><code>x-api-key</code>, <code>authorization</code>, and <code>proxy-authorization</code> headers are redacted in both streaming and non-streaming paths</dd>
</dl>

## ![folder][icon-folder] Project layout

| Path | Purpose |
|---|---|
| `hooks/` | Claude Code hook scripts (bash) |
| `hooks/lib/common.sh` | Shared library: input parsing, event emission, latency tracking, cross-platform shims |
| `hooks/lib/otel-trace.sh` | Lightweight <abbr title="OpenTelemetry Protocol over HTTP">OTLP/HTTP</abbr> trace span emitter (bash + curl) |
| `config/defaults.json` | Baseline warden config: <abbr title="OpenTelemetry">OTEL</abbr>, thresholds, subagent budgets |
| `config/profiles/` | Named configuration profiles (`minimal`, `standard`, `strict`) |
| `config/user.json.template` | Template for user overrides (copy to `config/user.json`) |
| `capture/` | <abbr title="man-in-the-middle">MITM</abbr> proxy wrapper + mitmproxy addon for API traffic capture |
| `statusline.sh` | Claude Code statusline script (bash) |
| `settings.hooks.json` | Hook + statusline config template merged into `~/.claude/settings.json` |
| `install.sh` | Installs hooks, merges config profile into `settings.json`, generates `warden.env` |
| `install-remote.sh` | Downloads a release tarball, verifies checksum, runs `install.sh --copy` |
| `uninstall.sh` | Removes hooks/statusline/config and restores the most recent settings backup |
| `monitoring/` | Docker Compose observability stack (Loki, <abbr title="OpenTelemetry">OTEL</abbr> Collector, Prometheus, Tempo, Grafana) |
| `monitoring/docker-compose.macos.yml` | Bridge networking override for Docker Desktop (macOS/Windows) |
| `monitoring/grafana/` | Grafana provisioning (datasources, dashboards) |
| `tests/` | Fixture-driven test harness (`bash tests/run.sh`) |
| `.github/workflows/release.yml` | GitHub Actions: builds tarball + checksum on tag push |
| `VERSION` | Current release version |
| `assets/` | README images (architecture diagram) |
| `demo/mock-inputs/` | Small JSON fixtures for exercising hooks locally |

## ![book][icon-book] How it works

Claude Code supports [hooks][hooks-docs] &mdash; shell commands that run at specific points in the tool-use lifecycle. Hooks receive JSON on stdin describing the tool call and can:

- **Exit 0**: Allow the tool call (optionally with `{"suppressOutput":true}`)
- **Exit 2**: Block the tool call (stderr message is fed back to Claude as feedback)
- **Output JSON**: Modify tool output (`{"modifyOutput":"..."}`) or suppress it

claude-warden hooks are pure bash with a single dependency (`jq`). They run in milliseconds and add negligible latency to tool calls. All paths use `$HOME` for portability &mdash; no hardcoded user directories. Every filtering decision (block, truncate, compress, strip) is logged to `~/.claude/.statusline/events.jsonl` with token savings estimates for downstream consumers.

## ![run][icon-run] Testing

Run the test harness:

```bash
bash tests/run.sh
```

It runs shell syntax checks, validates JSON fixtures, and executes fixture-driven behavioral assertions covering pre-tool-use blocking/allow, post-tool-use output tracking/truncation, read-compress, permission-request, and statusline rendering.

<details>
<summary>Manual checks</summary>

```bash
# Shell syntax
find hooks -maxdepth 1 -type f ! -name '_token-count-bg' -print0 | xargs -0 bash -n
bash -n install.sh uninstall.sh statusline.sh

# Optional: validate the Python helper used only for API token counting mode
command -v python3 >/dev/null 2>&1 && python3 -m py_compile hooks/_token-count-bg

# JSON validity
jq . settings.hooks.json config/defaults.json config/profiles/*.json >/dev/null

# Exercise post-tool-use fixture (system reminder stripping)
cat demo/mock-inputs/post-tool-use-reminder-bash.json | hooks/post-tool-use | jq -r '.modifyOutput'
```

</details>

## ![alert][icon-alert] Troubleshooting

<details>
<summary>Hooks don&rsquo;t seem to run</summary>

1. Confirm `~/.claude/settings.json` contains the `hooks` configuration (install merges `settings.hooks.json`).
2. Start a fresh Claude Code session after installing.
3. If a command is in your `permissions.allow` list, it will not reach the `permission-request` hook.

</details>

<details>
<summary>Read is being blocked unexpectedly</summary>

`read-guard` blocks common bundled/generated patterns (`node_modules/`, `dist/`, minified JS) and blocks files larger than the configured limit (default 2MB, configurable via `warden.read_guard_max_mb`). Search for the original source file or use a bounded read (smaller slices).

</details>

<details>
<summary>macOS Docker Desktop networking issues</summary>

The base `docker-compose.yml` uses `network_mode: host`, which Docker Desktop does not support. Use the macOS override:

```bash
docker compose -f docker-compose.yml -f docker-compose.macos.yml up -d
```

This switches to bridge networking and mounts config files that replace `localhost` with Docker service <abbr title="Domain Name System">DNS</abbr> names.

</details>

## Contributing

See `CONTRIBUTING.md`.

## ![lock][icon-lock] Security

See `SECURITY.md` for security assumptions, data handling notes, and reporting guidance.

## License

MIT
