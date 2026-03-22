[repo]: https://github.com/johnzfitch/claude-warden
[hooks-docs]: https://docs.anthropic.com/en/docs/claude-code/hooks
[claude-code]: https://docs.anthropic.com/en/docs/claude-code
[token-api]: https://docs.anthropic.com/en/docs/build-with-claude/token-counting

[badge-version]: https://img.shields.io/badge/version-v0.6.1-blue
[badge-license]: https://img.shields.io/badge/license-MIT-green
[badge-platform]: https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20WSL-lightgrey
[releases]: https://github.com/johnzfitch/claude-warden/releases
[license-file]: https://github.com/johnzfitch/claude-warden/blob/master/LICENSE
![claude-warden](https://github.com/user-attachments/assets/f801bd2f-8945-4ba1-9e5d-ff2174cc3a83)
# claude-warden

[![version][badge-version]][releases] [![license][badge-license]][license-file] [![platform][badge-platform]][repo]

<ruby>claude-warden<rp>(</rp><rt>token guardian</rt><rp>)</rp></ruby> is a hook system for [Claude Code][claude-code] that intercepts every tool call before and after execution. It silences verbose commands, compresses large outputs, blocks unsafe network calls, enforces subagent budgets, and surfaces a live statusline &mdash; saving <mark>tens of thousands of tokens per session</mark> with negligible added latency.

## <img src=".github/assets/icons/lightning-16x16.png" height="20" alt=""> Quickstart

1. Install prerequisites: `jq` (required). Optional: `rg`, `fd`.
2. Install hooks into `~/.claude/` (symlink mode):
   ```bash
   ./install.sh
   ```
3. Choose a profile when prompted (or pass `--profile standard`).
4. Start a new Claude Code session. Hooks run automatically.

> [!TIP]
> Run `./install.sh --dry-run` first to preview every change before anything touches <samp>~/.claude/</samp>.

```bash
./install.sh --dry-run
```

## <img src=".github/assets/icons/applications-stack-16x16.png" height="20" alt=""> Architecture

<figure>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/architecture-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/architecture-light.png">
    <img alt="3D architecture: Claude Code → Hook Membrane (bash) → warden-collector (Go) → SQLite + OTLP, with colored data-flow connectors" src="assets/architecture-dark.png" width="840">
  </picture>
  <figcaption>Three-layer architecture: <strong>Claude Code</strong> tool calls pass through the <strong><dfn>Hook Membrane</dfn></strong> (bash enforcement) into the <strong>warden-collector</strong> Go backbone, which stores spans in <abbr title="Write-Ahead Log">WAL</abbr>-mode SQLite and enforces subagent budgets via sub-millisecond <code>stat()</code> checks. Native <abbr title="OpenTelemetry Protocol">OTLP</abbr> telemetry flows directly from Claude Code to the collector on <code>:4319</code>.</figcaption>
</figure>

<figure>
  <img alt="WardenPipelineFlow — animated token savings walkthrough showing data flowing through all three layers" src="https://github.com/user-attachments/assets/7baf19c2-91f4-45e9-84fe-76120db9a49b" width="840">
  <figcaption>Token savings pipeline &mdash; tool calls enter the hook membrane, get silenced/compressed/blocked, and exit with dramatically fewer tokens.</figcaption>
</figure>

## <img src=".github/assets/icons/shield-security-protection-16x16.png" height="20" alt=""> What it does

claude-warden installs a set of shell hooks that intercept Claude Code tool calls at every stage of execution. Each hook enforces token-efficient patterns and blocks common waste.

<img alt="HookDimensions — 3D visualization of the hook enforcement layers" src="https://github.com/user-attachments/assets/d688ac7a-1e94-483e-af01-2dc08b15207e" width="840">

### Guard catalog

<img alt="Guard catalog — 15 hooks organized by lifecycle phase: pre-execution, post-execution, lifecycle, and observation" src="assets/guard-catalog.svg" width="840">

## <img src=".github/assets/icons/wrench-16x16.png" height="20" alt=""> Requirements

<dl>
  <dt><strong>Required</strong></dt>
  <dd><code>jq</code> &mdash; JSON processing</dd>
  <dd><code>Go 1.23+</code> &mdash; builds the warden-collector binary</dd>
  <dt><strong>Recommended</strong></dt>
  <dd><code>rg</code> (ripgrep), <code>fd</code> (fd-find)</dd>
  <dt><strong>Optional</strong></dt>
  <dd><code>python3</code> &mdash; warden-viewer web UI</dd>
  <dd><code>mitmdump</code> &mdash; only for the <a href="#-api-capture">API capture</a> tool</dd>
</dl>

## <img src=".github/assets/icons/application-run-16x16.png" height="20" alt=""> Install

### Quick install (latest release)

```bash
curl -fsSL https://raw.githubusercontent.com/johnzfitch/claude-warden/master/install-remote.sh | bash
```

The remote installer downloads a release tarball, verifies its <abbr title="Secure Hash Algorithm 256-bit">SHA-256</abbr> checksum (hard-fails if missing), validates tarball contents, then runs `install.sh --copy`.

To pin a version:

```bash
curl -fsSL https://raw.githubusercontent.com/johnzfitch/claude-warden/master/install-remote.sh | bash -s -- v0.6.1
```

<details>
<summary>Install from source (development)</summary>

```bash
git clone https://github.com/johnzfitch/claude-warden.git ~/dev/claude-warden
cd ~/dev/claude-warden
./install.sh
```

</details>

### <img src=".github/assets/icons/blue-key-16x16.png" height="20" alt=""> Profiles

The installer applies a configuration profile that sets token limits, tool permissions, and internal thresholds. Choose one during install or pass `--profile`:

| Profile | What it sets |
|:---|:---|
| `minimal` | Hooks only. No env or permission changes. For users who manage <samp>settings.json</samp> themselves. |
| `standard` | Token/output limits, <abbr title="OpenTelemetry">OTEL</abbr> monitoring, 40 safe tool permissions (read-only git, search, inspection). <mark><strong>Recommended.</strong></mark> |
| `strict` | ~40% tighter limits across the board. Fewer pre-approved tools (19). Lower subagent budgets. |

```bash
./install.sh --profile standard
```

Profiles live in <samp>config/profiles/</samp>. Create <samp>config/user.json</samp> (gitignored) for personal overrides:

```bash
cp config/user.json.template config/user.json
# Edit config/user.json, then re-install:
./install.sh --profile standard
```

Merge order: <samp>config/defaults.json</samp> &larr; profile &larr; <samp>config/user.json</samp> &larr; existing <samp>settings.json</samp> (non-warden keys preserved).

<details>
<summary>Install modes &amp; what install.sh does</summary>

<dl>
  <dt><strong>Symlink</strong> (default)</dt>
  <dd>Edits to the repo take effect immediately. <code>./install.sh</code></dd>
  <dt><strong>Copy</strong></dt>
  <dd>Files are independent of the repo. <code>./install.sh --copy</code></dd>
  <dt><strong>Dry run</strong></dt>
  <dd>See what would happen without writing anything. <code>./install.sh --dry-run</code></dd>
</dl>

**What install.sh does**

<dl>
  <dt><strong>Detect &amp; prepare</strong></dt>
  <dd>Checks prerequisites (<code>jq</code> required, warns if <code>rg</code>/<code>fd</code> missing). Detects platform (Linux, macOS, <abbr title="Windows Subsystem for Linux">WSL</abbr>). Backs up existing hooks and <code>settings.json</code>.</dd>
  <dt><strong>Build configuration</strong></dt>
  <dd>Prompts for a profile (or uses <code>--profile</code>). Deep-merges <code>defaults.json</code> + profile + <code>user.json</code>.</dd>
  <dt><strong>Install hooks</strong></dt>
  <dd>Symlinks (or copies) hook scripts + <code>lib/</code> + <code>statusline.sh</code> into <samp>~/.claude/</samp>. Sets executable permissions.</dd>
  <dt><strong>Build collector</strong></dt>
  <dd>Compiles the Go collector (<code>warden-collector</code>) and installs it to <samp>~/.local/bin/</samp>. The collector starts automatically on <code>session-start</code> and provides SQLite-backed session tracking, subagent budget enforcement, and an <abbr title="OpenTelemetry Protocol">OTLP</abbr> span receiver.</dd>
  <dt><strong>Apply configuration</strong></dt>
  <dd>Generates <samp>~/.claude/.warden/warden.env</samp> (hook thresholds). Merges env vars and permissions into <samp>settings.json</samp> (union for permissions, preserves plugins/model/etc). Generates <samp>warden.env.sh</samp> for shell sourcing.</dd>
  <dt><strong>Validate</strong></dt>
  <dd>Checks JSON validity and shell syntax for every installed script.</dd>
</dl>

</details>

## <img src=".github/assets/icons/cross-16x16.png" height="20" alt=""> Uninstall

```bash
./uninstall.sh
```

Restores your most recent <samp>settings.json</samp> backup. Removes <samp>~/.claude/.warden/</samp> config. Hook backups remain in <samp>~/.claude/hooks.bak.*/</samp>.

## <img src=".github/assets/icons/wrench-16x16.png" height="20" alt=""> Configuration

### <img src=".github/assets/icons/chart-arrow-16x16.png" height="20" alt=""> Tuning thresholds

All thresholds are configurable via <samp>config/defaults.json</samp>, profiles, or <samp>config/user.json</samp>. After editing, re-run `./install.sh` to regenerate <samp>~/.claude/.warden/warden.env</samp>.

| Threshold | Config key | Default | Strict |
|:---|:---|---:|---:|
| Output truncation | <samp>warden.truncate_bytes</samp> | 20KB | 10KB |
| Subagent read cap | <samp>warden.subagent_read_bytes</samp> | 10KB | 6KB |
| Output suppression | <samp>warden.suppress_bytes</samp> | 512KB | 256KB |
| Read file size limit | <samp>warden.read_guard_max_mb</samp> | 2MB | 1MB |
| Write max size | <samp>warden.write_max_bytes</samp> | 100KB | 50KB |
| Edit max size | <samp>warden.edit_max_bytes</samp> | 50KB | 25KB |
| Subagent call limits | <samp>warden.subagent_call_limits.*</samp> | 15&ndash;40 | 10&ndash;25 |
| Subagent byte limits | <samp>warden.subagent_byte_limits.*</samp> | 80&ndash;150KB | 50&ndash;100KB |

Token limits and tool permissions are set in the `env` and `permissions` sections of the config files and merged into <samp>settings.json</samp> during install.

- **Read compression**: <code>read-compress</code> &mdash; subagent threshold at 300 lines, main agent at 500 lines
- **Binary detection**: <code>post-tool-use</code> &mdash; POSIX <code>od</code> + <code>grep</code> for <abbr title="null byte">NUL</abbr> bytes (full-stream scan)

<details>
<summary>Shell environment, token accounting, disabling guards, custom allow-list</summary>

**Shell environment**

Add to <samp>~/.zshrc</samp> or <samp>~/.bashrc</samp>:

```bash
# claude-warden env
source "$HOME/.claude/.warden/warden.env.sh"
```

This exports <abbr title="OpenTelemetry">OTEL</abbr>, token limit, timeout, and sandbox vars from your chosen profile into every new shell. Re-running `install.sh` regenerates it.

**Token savings accounting**

All hooks report savings to <samp>~/.claude/.statusline/events.jsonl</samp> at ~3.5&nbsp;bytes/token (estimated). For exact counts:

```bash
export WARDEN_TOKEN_COUNT=api
```

Each truncation event spawns a background call to the [Anthropic token counting API][token-api] (free, separate rate limits) and appends a correction event. Zero added latency.

<dl>
  <dt>Requirements for <abbr title="Application Programming Interface">API</abbr> mode</dt>
  <dd><code>ANTHROPIC_API_KEY</code> in environment; <code>python3</code> with <code>anthropic</code> installed</dd>
  <dt>Custom Python path</dt>
  <dd>Set <code>WARDEN_PYTHON=/path/to/venv/bin/python3</code> if needed</dd>
  <dt>Graceful degradation</dt>
  <dd>Missing key, missing package, or network failure &rarr; silently exits, estimate stands</dd>
</dl>

**Disabling specific guards**

Remove the corresponding matcher from <samp>settings.hooks.json</samp> and re-run `./install.sh`. Example &mdash; disable read compression:

```json
{
  "matcher": "Read",
  "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/read-compress", "timeout": 7}]
}
```

**Adding your own permission allow-list**

```bash
cp config/user.json.template config/user.json
```

```json
{
  "permissions": {
    "allow": ["Bash(gh api:*)", "Bash(pacman -Q:*)", "mcp__filesystem__list_directory"]
  }
}
```

Re-run `./install.sh` to merge. User permissions are unioned with profile permissions &mdash; nothing is removed.

</details>

## <img src=".github/assets/icons/building-network-16x16.png" height="20" alt=""> Platform support

| Platform | Status | Notes |
|:---|:---|:---|
| Linux | Full support | Primary development platform |
| macOS | Full support | Uses <code>gtimeout</code> fallback, <code>osascript</code> for notifications, macOS <code>stat</code> flags |
| <abbr title="Windows Subsystem for Linux">WSL</abbr> | Full support | Detected via <samp>/proc/version</samp> |

<details>
<summary>Cross-platform details</summary>

- **`timeout`**: Falls back to `gtimeout` (coreutils), then no-timeout
- **`stat`**: Uses `-c%s` (Linux) with `-f%z` (macOS) fallback
- **`flock`**: Replaced with `mkdir`-based locking (atomic on all POSIX)
- **`notify-send`**: Falls back to `osascript` (macOS), silently skips if neither available
- **`rg`**: Falls back to `grep` where used
- **Binary detection**: Uses `od -An -tx1 | grep ' 00'` (POSIX, works on macOS/Linux/BSD)

</details>

## <img src=".github/assets/icons/applications-stack-16x16.png" height="20" alt=""> Go Collector

The **warden-collector** is a lightweight Go service that acts as the central backbone for all observation and state. It starts automatically when a Claude Code session begins (via the <code>session-start</code> hook) and stops when idle.

<details>
<summary>Collector internals, data storage &amp; viewer</summary>

<dl>
  <dt><strong>Session tracking</strong></dt>
  <dd>Stores per-session token counts, model info, context window size, and estimated context utilization in SQLite (<abbr title="Write-Ahead Log">WAL</abbr> mode).</dd>
  <dt><strong><abbr title="OpenTelemetry Protocol">OTLP</abbr> span receiver</strong></dt>
  <dd>Listens on <code>:4319</code> for HTTP/JSON traces from Claude Code. Extracts <code>llm_request</code> spans to populate session token data (input, output, cache read/create).</dd>
  <dt><strong>Subagent budget enforcement</strong></dt>
  <dd>Tracks per-agent call counts and byte totals. When a budget is exceeded, writes a deny file (<samp>budget-deny-{agent_id}</samp>) that <code>pre-tool-use</code> checks via sub-millisecond <code>stat</code>.</dd>
  <dt><strong>Hook event ingestion</strong></dt>
  <dd>Accepts hook events via <code>POST /v1/ingest/hook</code> over a Unix domain socket (<samp>collector.sock</samp>). All hooks post events here instead of managing local state files.</dd>
  <dt><strong>Query <abbr title="Application Programming Interface">API</abbr></strong></dt>
  <dd><code>GET /v1/sessions</code> lists sessions. <code>GET /v1/sessions/{id}/context</code> returns token counts, context percentage, and compact threshold. The statusline queries this endpoint.</dd>
</dl>

**Data storage** &mdash; <samp>${XDG_STATE_HOME:-~/.local/state}/claude-warden/</samp>:

| File | Purpose |
|:---|:---|
| <samp>collector.db</samp> | SQLite database (sessions, hook events, subagent budgets, <abbr title="OpenTelemetry Protocol">OTLP</abbr> spans) |
| <samp>collector.sock</samp> | Unix domain socket for hook &rarr; collector communication |
| <samp>collector.pid</samp> | <abbr title="Process ID">PID</abbr> file for lifecycle management |
| <samp>budget-deny-*</samp> | Deny files written when subagent budgets are exceeded |

**Viewer** &mdash; optional <dfn>htmx</dfn> web UI on port 8477 (context gauge, request waterfall, event log, cost tracking, tool breakdown, token trend):

```bash
python3 viewer/warden-viewer.py
```

</details>

## <img src=".github/assets/icons/application-monitor-16x16.png" height="20" alt=""> Monitoring stack (optional)

Warden includes an optional Docker-based observability stack in <samp>monitoring/</samp> for persistent log aggregation, metrics, and distributed tracing. This supplements the Go collector with long-term storage and Grafana dashboards.

> [!NOTE]
> The Go collector is the primary observability backbone and is always installed. The Docker monitoring stack is optional and provides additional visualization via Grafana, long-term log storage via Loki, and distributed tracing via Tempo.

<details>
<summary>Components, setup, data flow, dashboards</summary>

| Service | Image | Port | Purpose |
|:---|:---|---:|:---|
| Loki | `grafana/loki:3.4.2` | 3100 | Log aggregation (30-day retention, <abbr title="Time Series Database">TSDB</abbr> storage) |
| <abbr title="OpenTelemetry">OTEL</abbr> Collector | `otel/opentelemetry-collector-contrib` | 4317/4318 | Receives <abbr title="OpenTelemetry Protocol">OTLP</abbr> logs + traces, tails <samp>events.jsonl</samp>, exports to Loki + Tempo |
| Prometheus | `prom/prometheus` | 9090 | Metrics (<abbr title="OpenTelemetry Protocol">OTLP</abbr> + warden textfile fallbacks) |
| Node Exporter | `prom/node-exporter` | 9101 | Textfile collector for budget and session metrics |
| Tempo | `grafana/tempo:2.7.2` | 3200/3205 | Distributed trace storage and visualization |
| Grafana | `grafana/grafana` | 3000 | Dashboards (<samp>admin</samp>/<samp>admin</samp>) |

**Start** (Linux):

```bash
cd monitoring && docker compose up -d
```

**macOS / Docker Desktop**:

```bash
cd monitoring && docker compose -f docker-compose.yml -f docker-compose.macos.yml up -d
```

**Dashboards** &mdash; four provisioned in <samp>monitoring/grafana/dashboards/</samp>: cost/tokens/budget (<samp>claude-code-otel</samp>), tool latency/traces (<samp>warden-tool-latency</samp>), output size/tokens (<samp>warden-output-size</samp>), subagent/session lifecycle (<samp>warden-subagent-lifecycle</samp>).

**Verification**:

```bash
curl -s http://localhost:3100/ready   # Loki
curl -s http://localhost:3200/ready   # Tempo
grep tool_latency ~/.claude/.statusline/events.jsonl | tail -5
```

</details>

<details>
<summary><img src=".github/assets/icons/application-network-16x16.png" height="20" alt=""> API capture</summary>

The <samp>capture/</samp> directory contains a <abbr title="man-in-the-middle">MITM</abbr> proxy wrapper for recording full Claude Code <abbr title="Application Programming Interface">API</abbr> traffic.

```bash
capture/claude                          # interactive session
capture/claude -p "prompt"             # non-interactive
```

Logs land in <samp>~/claude-captures/YYYY-MM-DD/capture-HHMMSS.jsonl</samp>. Each line is a JSON record: `stream_start`, `stream_chunk`, `stream_end` (for <abbr title="Server-Sent Events">SSE</abbr>), or `exchange` (for non-streaming).

> [!IMPORTANT]
> Request and response bodies are **truncated to 200 characters by default**. To enable full body capture, set <code>WARDEN_CAPTURE_BODIES=1</code>. Even with full capture enabled, sensitive JSON keys (<code>system</code>, <code>messages</code>) are redacted.

<dl>
  <dt>Prerequisites</dt>
  <dd><code>mitmdump</code> (from <code>mitmproxy</code>) and a trusted <abbr title="Certificate Authority">CA</abbr> cert at <samp>~/.mitmproxy/mitmproxy-ca-cert.pem</samp></dd>
  <dt>Log permissions</dt>
  <dd>Capture <abbr title="JSON Lines">JSONL</abbr> files and the proxy log (<samp>~/.claude/capture-mitm.log</samp>) are created with mode <kbd>600</kbd></dd>
  <dt>Header scrubbing</dt>
  <dd><code>x-api-key</code>, <code>authorization</code>, and <code>proxy-authorization</code> headers are redacted in both streaming and non-streaming paths</dd>
</dl>

</details>

<details>
<summary><img src=".github/assets/icons/blue-folder-16x16.png" height="20" alt=""> Project layout</summary>

| Path | Purpose |
|:---|:---|
| <samp>hooks/</samp> | Claude Code hook scripts (bash) |
| <samp>hooks/lib/common.sh</samp> | Shared library: input parsing, event emission, latency tracking, cross-platform shims |
| <samp>hooks/lib/otel-trace.sh</samp> | Lightweight <abbr title="OpenTelemetry Protocol over HTTP">OTLP/HTTP</abbr> trace span emitter (bash + curl) |
| <samp>config/defaults.json</samp> | Baseline warden config: <abbr title="OpenTelemetry">OTEL</abbr>, thresholds, subagent budgets |
| <samp>config/profiles/</samp> | Named configuration profiles (<code>minimal</code>, <code>standard</code>, <code>strict</code>) |
| <samp>config/user.json.template</samp> | Template for user overrides (copy to <samp>config/user.json</samp>) |
| <samp>collector/</samp> | Go collector: SQLite store, <abbr title="OpenTelemetry Protocol">OTLP</abbr> receiver, hook event <abbr title="Application Programming Interface">API</abbr>, budget enforcement |
| <samp>viewer/</samp> | htmx web UI for viewing collector data (sessions, tokens, events) |
| <samp>capture/</samp> | <abbr title="man-in-the-middle">MITM</abbr> proxy wrapper + mitmproxy addon for <abbr title="Application Programming Interface">API</abbr> traffic capture |
| <samp>statusline.sh</samp> | Claude Code statusline script (bash) |
| <samp>settings.hooks.json</samp> | Hook + statusline config template merged into <samp>~/.claude/settings.json</samp> |
| <samp>install.sh</samp> | Installs hooks, merges config profile into <samp>settings.json</samp>, generates <samp>warden.env</samp> |
| <samp>install-remote.sh</samp> | Downloads a release tarball, verifies checksum, runs <code>install.sh --copy</code> |
| <samp>uninstall.sh</samp> | Removes hooks/statusline/config and restores the most recent settings backup |
| <samp>monitoring/</samp> | Optional Docker Compose observability stack (Loki, <abbr title="OpenTelemetry">OTEL</abbr> Collector, Prometheus, Tempo, Grafana) |
| <samp>monitoring/docker-compose.macos.yml</samp> | Bridge networking override for Docker Desktop (macOS/Windows) |
| <samp>monitoring/grafana/</samp> | Grafana provisioning (datasources, dashboards) |
| <samp>tests/</samp> | Fixture-driven test harness (<code>bash tests/run.sh</code>) |
| <samp>.github/</samp> | Issue templates (<abbr title="YAML Ain't Markup Language">YAML</abbr> forms), <abbr title="Pull Request">PR</abbr> template, community health files |
| <samp>CITATION.cff</samp> | Repository citation metadata (enables &ldquo;Cite this repository&rdquo; on GitHub) |
| <samp>VERSION</samp> | Current release version |
| <samp>assets/</samp> | README images (architecture diagram, guard catalog) |
| <samp>demo/mock-inputs/</samp> | Small JSON fixtures for exercising hooks locally |

</details>

## <img src=".github/assets/icons/blue-document-view-book-16x16.png" height="20" alt=""> How it works

Claude Code supports [hooks][hooks-docs] &mdash; shell commands that run at specific points in the tool-use lifecycle. Hooks receive JSON on stdin describing the tool call and can:

- **Exit 0**: Allow the tool call (optionally with `{"suppressOutput":true}`)
- **Exit 2**: Block the tool call (stderr message is fed back to Claude as feedback)
- **Output JSON**: Modify tool output (`{"modifyOutput":"..."}`) or suppress it

claude-warden hooks are pure bash with a single dependency (`jq`). They run in milliseconds and add negligible latency to tool calls. All paths use `$HOME` for portability &mdash; no hardcoded user directories. Every filtering decision (block, truncate, compress, strip) is logged to <samp>~/.claude/.statusline/events.jsonl</samp> with token savings estimates for downstream consumers.

## <img src=".github/assets/icons/application-run-16x16.png" height="20" alt=""> Testing

Run the test harness:

```bash
bash tests/run.sh
```

It runs shell syntax checks, validates JSON fixtures, and executes fixture-driven behavioral assertions covering pre-tool-use blocking/allow, post-tool-use output tracking/truncation, read-compress, permission-request, and statusline rendering.

<details>
<summary>Manual checks</summary>

```bash
# Shell syntax
find hooks -maxdepth 1 -type f -print0 | xargs -0 bash -n
bash -n install.sh uninstall.sh statusline.sh

# JSON validity
jq . settings.hooks.json config/defaults.json config/profiles/*.json >/dev/null

# Exercise post-tool-use fixture (system reminder stripping)
cat demo/mock-inputs/post-tool-use-reminder-bash.json | hooks/post-tool-use | jq -r '.modifyOutput'
```

</details>

## <img src=".github/assets/icons/alert-16x16.png" height="20" alt=""> Troubleshooting

<details>
<summary>Hooks don&rsquo;t seem to run</summary>

1. Confirm <samp>~/.claude/settings.json</samp> contains the <code>hooks</code> key (install merges <samp>settings.hooks.json</samp> into it).
2. Start a <strong>fresh</strong> Claude Code session &mdash; hooks load at startup, not mid-session.
3. If a command appears in your <code>permissions.allow</code> list, it bypasses the <code>permission-request</code> hook entirely.

> [!NOTE]
> Run `jq '.hooks | keys' ~/.claude/settings.json` to verify the hook keys are present.

</details>

<details>
<summary>Read is being blocked unexpectedly</summary>

<code>read-guard</code> blocks common bundled/generated patterns (<samp>node_modules/</samp>, <samp>dist/</samp>, minified JS) and blocks files larger than the configured limit (default 2MB, configurable via <samp>warden.read_guard_max_mb</samp>). Search for the original source file or use a bounded read (smaller slices).

</details>

<details>
<summary>macOS Docker Desktop networking issues</summary>

The base <samp>docker-compose.yml</samp> uses `network_mode: host`, which Docker Desktop does not support. Use the macOS override:

```bash
docker compose -f docker-compose.yml -f docker-compose.macos.yml up -d
```

This switches to bridge networking and mounts config files that replace `localhost` with Docker service <abbr title="Domain Name System">DNS</abbr> names.

</details>

<details>
<summary>Hooks don&rsquo;t run in a specific project directory</summary>

Claude Code gates hook execution on <em>workspace trust</em>. A workspace is trusted once its project-level <samp>CLAUDE.md</samp> has been accepted at launch. Until then, all hooks are skipped &mdash; including those defined globally in <samp>~/.claude/settings.json</samp>. Symptom in the debug log (<samp>~/.claude/debug/&lt;session-id&gt;.txt</samp>):

```
Skipping PreToolUse:Bash hook execution - workspace trust not accepted
```

**Fix**: create a <samp>CLAUDE.md</samp> in the project root (contents can be a single comment). Claude Code will prompt you to accept it on the next session start &mdash; press <kbd>Enter</kbd> to trust it. Once accepted, all hooks fire normally.

> [!NOTE]
> This is a Claude Code behavior, not a warden limitation. Even user-global hooks in <samp>~/.claude/settings.json</samp> are gated by per-workspace trust.

</details>

## Contributing

See `CONTRIBUTING.md`.

## <img src=".github/assets/icons/lock-16x16.png" height="20" alt=""> Security

See `SECURITY.md` for security assumptions, data handling notes, and reporting guidance.

## License

MIT
