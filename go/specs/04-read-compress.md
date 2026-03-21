# Hook: read-compress

## What this does

Runs after Read tool calls (PostToolUse for Read). Compresses large file reads by extracting structural elements (imports, function signatures, class definitions, config keys) instead of passing full content. Reduces tokens while preserving navigability.

## Bash source (ground truth)

Path: `go/reference/read-compress`

## Input JSON schema

Same as post-tool-use. Tool name will be "Read".

```json
{
  "tool_name": "Read",
  "session_id": "abc123",
  "tool_input": {"file_path": "/home/user/project/main.py"},
  "tool_response": {"content": [{"text": "import os\nimport sys\n\nclass Foo:\n    def bar(self):\n        pass\n..."}]},
  "transcript_path": "/home/user/.claude/transcript.jsonl"
}
```

## Output JSON schema

- **Pass through**: exit 0 (no output)
- **Modify output**: `{"modifyOutput":"extracted structure\n\n[Structure extracted: 500 lines -> 45 signatures]"}`

## Behavior rules (ordered)

1. Parse input. If not Read tool, exit 0.
2. Detect subagent (transcript_path patterns).
3. Extract file content from tool_response.
4. Strip system reminders if present.
5. Get file extension from file_path.
6. **Skip non-code files**: txt, md, markdown, rst, log, csv, tsv, env, conf, gitignore, dockerignore → pass through.
7. **Line count threshold**: subagent = 300 lines, main agent = 500 lines. If under threshold, pass through.
8. **Config file extraction** (by extension):
   - `json`: extract lines matching top-level and one-deep keys (indent ≤ 4 spaces + quoted key + colon).
   - `yml/yaml`: extract top-level keys (`^[a-zA-Z_]...:`) and document markers (`^---`).
   - `toml/cfg/ini`: extract section headers (`^\[`) and root-level keys.
   - `xml/svg/html`: extract opening tags with attributes.
   - If extraction produced results AND fewer lines than original, emit with `[Structure extracted: N lines -> M keys/sections]`.
9. **Code structural extraction** (all other extensions): extract lines matching:
   - Python: `import`, `from ... import`, `class`, `def`, `async def`
   - JS/TS: `import ... from`, `export`, `const ... =`, `function`, `async function`, `class`, `interface`, `type`
   - Rust: `use`, `pub fn/struct/enum/trait/mod/type/use/const`, `fn`, `impl`, `struct`, `enum`, `trait`, `mod`
   - Go: `package`, `import (`, `func`, `type`
   - PHP: `<?php`, `namespace`, `class`, `function`, `interface`, `trait`
   - Markdown: `## ` and deeper (not single `#`)
   - Indented definitions: method signatures in classes
   - Limit to 200 lines.
10. If extraction produced fewer lines than original, emit with `[Structure extracted: N lines -> M signatures]`.
11. If extraction yielded same or more lines (unlikely), pass through.

## Test cases

### Must-pass
- 600-line Python file → extract imports, classes, functions
- 800-line TypeScript file → extract imports, exports, interfaces, types
- 400-line JSON config → extract top-level keys
- 1000-line YAML → extract root keys
- 200-line Python file (under threshold) → pass through unchanged
- `.md` file → pass through (non-code skip)
- `.log` file → pass through (non-code skip)

### Must-not-trigger
- Main agent, 499-line file → pass through (under 500 threshold)
- Subagent, 299-line file → pass through (under 300 threshold)
- File with only comments → extraction yields 0 lines → pass through

### Edge cases
- Empty file content → pass through
- File with no recognizable patterns → extraction yields 0 → pass through
- File with system-reminder in content → stripped before extraction
- Unknown file extension → falls through to code extraction (tries all patterns)

## Guardrails

- DO NOT change line thresholds (300 subagent, 500 main)
- DO NOT add new extraction patterns not in the bash awk script
- Extraction patterns must match the awk regexes exactly — same anchoring, same fields
- The 200-line head limit on extraction results must be preserved
- Non-code file extension list must match exactly
