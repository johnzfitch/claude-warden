# llmx MCP Server: Lean Output Format

Prompt for a model tasked with modifying the llmx MCP server to reduce token waste.

---

## Context

llmx is a codebase indexing and semantic search MCP server. Its `llmx_search` tool
returns results that include several fields the consuming model never references,
burning context window tokens on every call.

A downstream hook (claude-warden `mcp-output-compress`) strips these fields after
the fact, but the cleaner fix is to stop emitting them.

## Problem Fields

These fields appear in `llmx_search` results and waste tokens:

| Field | Location | Size | Used by model? |
|-------|----------|------|----------------|
| `chunk_id` | per result | 64-char hex hash | Never |
| `score` | per result | float | Never |
| `truncated_ids` | top-level array | 15-30 x 64-char hashes | Never |
| `index_id` | returned from `llmx_index` | 64-char hex hash | Yes, passed to search |

## Requested Changes

### 1. `llmx_search` response format

**Current:**
```json
{
  "results": [
    {
      "chunk_id": "0ff3a0ac...(64 chars)",
      "score": 14.296957,
      "path": "/home/user/src/app.rs",
      "start_line": 845,
      "end_line": 878,
      "content": "...",
      "heading_path": []
    }
  ],
  "truncated_ids": ["561f2f9d...", "756ca18b...", ...],
  "total_matches": 40
}
```

**Desired:**
```json
{
  "results": [
    {
      "path": "/home/user/src/app.rs",
      "start_line": 845,
      "end_line": 878,
      "content": "...",
      "heading_path": []
    }
  ],
  "total_matches": 40
}
```

- Remove `chunk_id` from each result
- Remove `score` from each result
- Remove `truncated_ids` array entirely
- Keep `total_matches` (useful signal for "are there more results?")

### 2. `llmx_index` response format

The `index_id` IS needed (passed to `llmx_search`), but consider:
- Using a shorter alias (8-12 chars) instead of a 64-char SHA256
- Or: auto-associate indexes with directory paths so the model doesn't need
  to manage IDs at all (e.g., search by path instead of ID)

### 3. Optional: `compact` parameter

If backwards compatibility matters, add an optional `compact: true` parameter
to `llmx_search` that omits the noise fields. Default to compact.

## Token Impact

A typical search with 10 results and 20 truncated IDs wastes:
- `chunk_id`: 10 x ~70 chars = ~700 chars (~200 tokens)
- `score`: 10 x ~20 chars = ~200 chars (~57 tokens)
- `truncated_ids`: 20 x ~70 chars = ~1400 chars (~400 tokens)
- **Total waste per call: ~657 tokens**

Over a session with 4-5 searches, that's ~3000 tokens of pure noise --
roughly 1.5% of usable context, or the equivalent of a medium code file
that could have been read instead.

## Implementation Notes

- The llmx server is a Rust MCP server
- Search for the response serialization in the search handler
- The `chunk_id` and `score` are from the index lookup -- just skip serializing them
- The `truncated_ids` is built from results that didn't fit the token budget --
  the count in `total_matches` already conveys this information

## Score Ordering Decision

Strip score floats but preserve array ordering (most relevant first). Position is
the ranking. The downstream hook (`mcp-output-compress`) relies on this: it removes
`score` fields but keeps the results array intact, so the model can trust that
result[0] is the best match without needing to parse floats.
