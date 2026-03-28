package hooks

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestHookToolResponseUnmarshalMCPArray(t *testing.T) {
	var input HookInput
	raw := []byte(`{"tool_name":"mcp__llmx__llmx_search","tool_response":[{"type":"text","text":"{\"results\":[1]}"}]}`)
	if err := json.Unmarshal(raw, &input); err != nil {
		t.Fatal(err)
	}
	if got := extractToolResponseText(input); got != `{"results":[1]}` {
		t.Fatalf("extractToolResponseText=%q", got)
	}
}

func TestMCPOutputCompressIgnoreAndPassThrough(t *testing.T) {
	ctx := newPostToolUseContext(postToolUseInput("Bash", "echo hi", "ok", ""))
	if out, handled := ctx.handleMCPOutputCompress(); handled || len(out) != 0 {
		t.Fatalf("non-MCP handled=%v out=%q", handled, out)
	}

	_, collector := setupPostToolUseTest(t)
	out, code := handlePostToolUse(postToolUseInput("mcp__server__tool", "ignored", "small", ""))
	if code != 0 || len(out) != 0 {
		t.Fatalf("code=%d out=%q", code, out)
	}
	if hasRuleEvent(collector.events, "mcp_noise_strip", "mcp_file_offload") {
		t.Fatalf("unexpected mcp truncation events: %#v", collector.events)
	}
}

func TestMCPOutputCompressEmptyOutput(t *testing.T) {
	ctx := newPostToolUseContext(postToolUseInput("mcp__server__tool", "ignored", "", ""))
	if out, handled := ctx.handleMCPOutputCompress(); !handled || len(out) != 0 {
		t.Fatalf("handled=%v out=%q", handled, out)
	}
}

func TestMCPOutputCompressInlineCleanup(t *testing.T) {
	_, collector := setupPostToolUseTest(t)
	res := runPostToolUse(t, postToolUseInput("mcp__llmx__llmx_search", "ignored", string(mustJSONResults(t, 24, 240, false)), ""))
	if res.ModifyOutput == "" || res.HookSpecificOutput.AdditionalContext != "" {
		t.Fatalf("unexpected response: %#v", res)
	}
	if strings.Contains(res.ModifyOutput, "chunk_id") || strings.Contains(res.ModifyOutput, "score") || strings.Contains(res.ModifyOutput, "truncated_ids") || strings.Contains(res.ModifyOutput, "embedding") || strings.Contains(res.ModifyOutput, "vector") {
		t.Fatalf("noise fields still present: %s", res.ModifyOutput)
	}
	hash := strings.Repeat("a", 64)
	if strings.Contains(res.ModifyOutput, `"doc_id":"`+hash+`"`) {
		t.Fatalf("hash field not removed: %s", res.ModifyOutput)
	}
	if !strings.Contains(res.ModifyOutput, `"index_id":"`+hash+`"`) {
		t.Fatalf("index_id not preserved: %s", res.ModifyOutput)
	}
	assertEventRule(t, collector.events, "truncated", "mcp_noise_strip")
}

func TestMCPOutputCompressOffloadsJSONAndIncrementsSequence(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	_, collector := setupPostToolUseTest(t)

	first := runPostToolUse(t, postToolUseInputWithSession("mcp__github__search", "abcdefgh1234", "ignored", string(mustJSONResults(t, 40, 700, true)), ""))
	path1 := extractOffloadPath(t, first.ModifyOutput)
	if !strings.HasSuffix(path1, filepath.Join("claude-mcp-output", "abcdefgh-github-search-001.txt")) {
		t.Fatalf("path1=%q", path1)
	}
	if _, err := os.Stat(filepath.Dir(path1)); err != nil {
		t.Fatalf("offload dir missing: %v", err)
	}
	data1, err := os.ReadFile(path1)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(data1, []byte(`"results"`)) || bytes.Contains(data1, []byte(`"score"`)) {
		t.Fatalf("unexpected offloaded content: %s", data1[:min(200, len(data1))])
	}
	if !strings.Contains(first.ModifyOutput, "returned 40 results") || !strings.Contains(first.ModifyOutput, "Files referenced:\n/file-000.txt") {
		t.Fatalf("summary=%q", first.ModifyOutput)
	}
	if !strings.Contains(first.HookSpecificOutput.AdditionalContext, "limit<=5") {
		t.Fatalf("guidance=%q", first.HookSpecificOutput.AdditionalContext)
	}

	second := runPostToolUse(t, postToolUseInputWithSession("mcp__github__search", "abcdefgh1234", "ignored", string(mustJSONResults(t, 40, 700, true)), ""))
	path2 := extractOffloadPath(t, second.ModifyOutput)
	if !strings.HasSuffix(path2, filepath.Join("claude-mcp-output", "abcdefgh-github-search-002.txt")) {
		t.Fatalf("path2=%q", path2)
	}
	assertEventRule(t, collector.events, "truncated", "mcp_file_offload")
}

func TestMCPOutputCompressPlainTextAndInvalidJSONUseHeadTailSummary(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	setupPostToolUseTest(t)

	plain := strings.Repeat("HEAD", 3000) + "TAIL-END"
	res := runPostToolUse(t, postToolUseInputWithSession("mcp__repo__explore", "session99", "ignored", plain, ""))
	path := extractOffloadPath(t, res.ModifyOutput)
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.ModifyOutput, "... [") || !strings.Contains(res.ModifyOutput, "TAIL-END") {
		t.Fatalf("plain summary=%q", res.ModifyOutput)
	}
	if !strings.Contains(res.HookSpecificOutput.AdditionalContext, "path_filter") {
		t.Fatalf("guidance=%q", res.HookSpecificOutput.AdditionalContext)
	}

	invalid := "{" + strings.Repeat("broken", 2500) + "TAIL"
	res = runPostToolUse(t, postToolUseInputWithSession("mcp__repo__index", "session98", "ignored", invalid, ""))
	if !strings.Contains(res.ModifyOutput, "see file for full output") || !strings.Contains(res.ModifyOutput, "TAIL") {
		t.Fatalf("invalid summary=%q", res.ModifyOutput)
	}
	if !strings.Contains(res.HookSpecificOutput.AdditionalContext, "Index IDs are managed by the hook") {
		t.Fatalf("guidance=%q", res.HookSpecificOutput.AdditionalContext)
	}
}

func TestMCPGuidancePatterns(t *testing.T) {
	if got := buildMCPGuidance("s", "search_docs", 100); !strings.Contains(got, "limit<=5 and max_tokens<=4000") {
		t.Fatalf("search guidance=%q", got)
	}
	if got := buildMCPGuidance("s", "sync_index", 100); !strings.Contains(got, "Index IDs are managed by the hook") {
		t.Fatalf("index guidance=%q", got)
	}
	if got := buildMCPGuidance("s", "tree_explore", 100); !strings.Contains(got, "path_filter") {
		t.Fatalf("explore guidance=%q", got)
	}
}

func mustJSONResults(t *testing.T, count, bodyLen int, keepLargeBody bool) []byte {
	t.Helper()
	hash := strings.Repeat("a", 64)
	type result struct {
		Path         string  `json:"path"`
		Body         string  `json:"body"`
		ChunkID      string  `json:"chunk_id"`
		Score        float64 `json:"score"`
		TruncatedIDs []int   `json:"truncated_ids"`
		Embedding    []int   `json:"embedding"`
		Vector       []int   `json:"vector"`
		DocID        string  `json:"doc_id"`
		IndexID      string  `json:"index_id"`
	}
	out := struct {
		Results []result `json:"results"`
	}{Results: make([]result, 0, count)}
	body := strings.Repeat("b", bodyLen)
	if !keepLargeBody {
		body = "body"
	}
	for i := 0; i < count; i++ {
		out.Results = append(out.Results, result{
			Path:         filepath.ToSlash(filepath.Join("/", "file-"+leftPad3(i)+".txt")),
			Body:         body,
			ChunkID:      hash,
			Score:        float64(i) / 10,
			TruncatedIDs: []int{1, 2, 3, 4, 5},
			Embedding:    make([]int, 64),
			Vector:       make([]int, 64),
			DocID:        hash,
			IndexID:      hash,
		})
	}
	data, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func leftPad3(i int) string {
	if i < 10 {
		return "00" + strconv.Itoa(i)
	}
	if i < 100 {
		return "0" + strconv.Itoa(i)
	}
	return strconv.Itoa(i)
}

func extractOffloadPath(t *testing.T, summary string) string {
	t.Helper()
	const prefix = "[Full output saved to: "
	start := strings.Index(summary, prefix)
	if start < 0 {
		t.Fatalf("summary missing offload path: %q", summary)
	}
	start += len(prefix)
	end := strings.Index(summary[start:], "]")
	if end < 0 {
		t.Fatalf("summary missing path terminator: %q", summary)
	}
	return summary[start : start+end]
}

func hasRuleEvent(events []map[string]any, rules ...string) bool {
	for _, evt := range events {
		rule, _ := evt["rule"].(string)
		for _, want := range rules {
			if rule == want {
				return true
			}
		}
	}
	return false
}
