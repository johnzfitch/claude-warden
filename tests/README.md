# Claude-Warden Test Suite

## Running Tests

```bash
bash tests/run.sh
```

The test harness validates shell syntax, JSON fixtures, and runs fixture-driven behavioral assertions.

## Test Coverage

### Current tests (`run.sh`)

**What these tests verify:**
- Hooks source shared library correctly from deployment paths
- Hooks produce correct JSON output formats and exit codes
- All blocking rules fire on matching input
- Allow rules pass through non-matching input
- Quiet overrides emit `updatedInput` with injected flags
- Post-tool-use emits correct `additionalContext` reminders
- System reminder stripping works across tool types
- Output size tracking emits `tool_output_size` events
- Large output truncation produces `modifyOutput` with size markers
- Security denials emit to both stdout (structured JSON) and stderr (`warden:` prefix)

**Security scenario coverage:**
- Destructive commands (`rm -rf /`, fork bombs, `curl | bash`)
- Environment dumps (`env`, `printenv`, `/proc/*/environ`)
- Data exfiltration (`curl -d`, `curl --data=`, `curl -F`, `wget --post-data`)
- <abbr title="Server-Side Request Forgery">SSRF</abbr> (metadata endpoints, localhost, RFC&nbsp;1918 private ranges)
- Raw sockets (`nc`, `ncat`, `socat`)
- Settings tampering (Write/Edit to `.claude/settings`)
- Oversize payloads (Write &gt;100KB, NotebookEdit &gt;50KB)

**Test execution method:**
```bash
cat fixture.json | hooks/pre-tool-use
```

**Limitations:**
- Tests use direct bash pipes, not Claude Code&rsquo;s hook runner
- Does not test Claude Code&rsquo;s timeout handling or JSON response processing
- Does not verify Claude Code&rsquo;s environment variable setup
- No concurrent hook invocation tests

## Deny Message Token Cost

The `tests/verbosity/measure-deny-tokens.sh` script measures byte and token cost of every security deny message, including cumulative cost projections for multi-turn sessions.

```bash
bash tests/verbosity/measure-deny-tokens.sh
```

## Test Architecture

```
tests/
├── run.sh                          # Main test harness (syntax + fixtures + behavioral)
├── verbosity/
│   └── measure-deny-tokens.sh      # Deny message token cost analysis
└── README.md                       # This file

Testing layers:
1. Syntax validation (bash -n, python3 -m py_compile, jq)
2. Hook output tests (JSON format, exit codes, structured deny)
3. Security scenario tests (SSRF, exfil, env dump, injection)
4. Post-tool-use behavior (truncation, reminders, size tracking)
```

## Future Improvements

- [ ] Integration test harness that runs outside Claude Code
- [ ] Performance benchmarking with hyperfine
- [ ] CI/CD pipeline integration
- [ ] Hook timeout testing
- [ ] Concurrent hook invocation tests (race condition verification)
