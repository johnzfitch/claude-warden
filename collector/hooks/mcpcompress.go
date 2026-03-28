package hooks

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var (
	mcpNoiseKeySet = map[string]struct{}{
		"chunk_id":      {},
		"score":         {},
		"truncated_ids": {},
		"embedding":     {},
		"vector":        {},
	}
	mcpHexHashRE = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

const mcpJSONMaxDepth = 20

func (c *postToolUseContext) handleMCPOutputCompress() ([]byte, bool) {
	if !strings.HasPrefix(c.toolName, "mcp__") {
		return nil, false
	}

	if c.output == "" {
		return nil, true
	}

	threshold := getEnvInt("WARDEN_MCP_THRESHOLD_BYTES", 10500)
	if c.outputSize <= threshold {
		if c.outputChanged {
			if c.finalSize < 0 {
				c.finalSize = c.outputSize
			}
			return ModifyOutput(c.output), true
		}
		return nil, true
	}

	server, op := parseMCPToolName(c.toolName)
	origSize := c.outputSize
	cleaned, isJSON := mcpCleanOutput(c.output)
	if len(cleaned) <= threshold {
		c.output = cleaned
		c.outputSize = len(cleaned)
		c.outputChanged = true
		c.emitEvent("truncated", origSize, c.outputSize, "mcp_noise_strip")
		return ModifyOutput(cleaned), true
	}

	offloadPath, err := mcpOffloadFilePath(c.sessionID, server, op)
	if err != nil {
		return nil, true
	}
	if err := os.WriteFile(offloadPath, []byte(cleaned), 0o644); err != nil {
		return nil, true
	}

	summary := buildMCPOffloadSummary(server, op, offloadPath, cleaned, isJSON)
	guidance := buildMCPGuidance(server, op, origSize)
	c.emitEvent("truncated", origSize, len(summary), "mcp_file_offload")
	return marshalModifyOutputWithContext(summary, guidance), true
}

func parseMCPToolName(toolName string) (string, string) {
	rest := strings.TrimPrefix(toolName, "mcp__")
	parts := strings.SplitN(rest, "__", 2)
	if len(parts) != 2 {
		return rest, ""
	}
	return parts[0], parts[1]
}

func mcpCleanOutput(output string) (string, bool) {
	var root any
	if err := json.Unmarshal([]byte(output), &root); err != nil {
		return output, false
	}

	type node struct {
		value any
		depth int
	}
	stack := []node{{value: root, depth: 0}}
	for len(stack) > 0 {
		cur := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if cur.depth >= mcpJSONMaxDepth {
			continue
		}

		switch v := cur.value.(type) {
		case map[string]any:
			for key, child := range v {
				if _, drop := mcpNoiseKeySet[key]; drop {
					delete(v, key)
					continue
				}
				if s, ok := child.(string); ok && key != "index_id" && mcpHexHashRE.MatchString(s) {
					delete(v, key)
					continue
				}
				switch child := child.(type) {
				case map[string]any, []any:
					stack = append(stack, node{value: child, depth: cur.depth + 1})
				}
			}
		case []any:
			for _, child := range v {
				switch child := child.(type) {
				case map[string]any, []any:
					stack = append(stack, node{value: child, depth: cur.depth + 1})
				}
			}
		}
	}

	data, err := json.Marshal(root)
	if err != nil {
		return output, false
	}
	return string(data), true
}

func mcpOffloadFilePath(sessionID, server, op string) (string, error) {
	sessionShort := sessionID
	if len(sessionShort) > 8 {
		sessionShort = sessionShort[:8]
	}
	if sessionShort == "" {
		sessionShort = "nosess"
	}

	dir := filepath.Join(os.TempDir(), "claude-mcp-output")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}

	seqFile := filepath.Join(dir, ".seq-"+sessionShort)
	seq := 1
	if data, err := os.ReadFile(seqFile); err == nil {
		if n, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil && n > 0 {
			seq = n + 1
		}
	}
	if err := os.WriteFile(seqFile, []byte(strconv.Itoa(seq)), 0o644); err != nil {
		return "", err
	}

	name := fmt.Sprintf("%s-%s-%s-%03d.txt", sessionShort, server, op, seq)
	return filepath.Join(dir, name), nil
}

func buildMCPOffloadSummary(server, op, offloadPath, cleaned string, isJSON bool) string {
	if !isJSON {
		return fmt.Sprintf("[MCP output offloaded: %s/%s returned %d chars]\n[Full output saved to: %s]\n[Use Read tool on the file to access specific sections.]\n\n%s\n... [%d chars, see file for full output] ...\n%s",
			server, op, len(cleaned), offloadPath, headBytes(cleaned, 2048), len(cleaned), tailBytes(cleaned, 512))
	}

	var root any
	if err := json.Unmarshal([]byte(cleaned), &root); err != nil {
		return buildMCPOffloadSummary(server, op, offloadPath, cleaned, false)
	}

	summary := fmt.Sprintf("[MCP output offloaded: %s/%s returned %s results, %d chars]\n[Full output saved to: %s]\n[Results are ranked most-relevant first. Use Read tool on the file to access specific sections.]",
		server, op, mcpResultCount(root), len(cleaned), offloadPath)

	paths := mcpCollectPaths(root)
	if len(paths) > 0 {
		summary += "\n\nFiles referenced:\n" + strings.Join(paths, "\n")
	}

	summary += "\n\nPreview (first 2KB):\n" + headBytes(cleaned, 2048)
	return summary
}

func mcpResultCount(root any) string {
	switch v := root.(type) {
	case map[string]any:
		if results, ok := v["results"].([]any); ok {
			return strconv.Itoa(len(results))
		}
	case []any:
		return strconv.Itoa(len(v))
	}
	return "1"
}

func mcpCollectPaths(root any) []string {
	type node struct {
		value any
		depth int
	}
	stack := []node{{value: root, depth: 0}}
	seen := map[string]struct{}{}
	paths := make([]string, 0, 16)
	for len(stack) > 0 {
		cur := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if cur.depth >= mcpJSONMaxDepth {
			continue
		}
		switch v := cur.value.(type) {
		case map[string]any:
			if path, ok := v["path"].(string); ok && path != "" {
				seen[path] = struct{}{}
			}
			for _, child := range v {
				switch child := child.(type) {
				case map[string]any, []any:
					stack = append(stack, node{value: child, depth: cur.depth + 1})
				}
			}
		case []any:
			for _, child := range v {
				switch child := child.(type) {
				case map[string]any, []any:
					stack = append(stack, node{value: child, depth: cur.depth + 1})
				}
			}
		}
	}

	for path := range seen {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	if len(paths) > 15 {
		paths = paths[:15]
	}
	return paths
}

func buildMCPGuidance(server, op string, outputSize int) string {
	guidance := fmt.Sprintf("[warden] MCP output from %s/%s was %d chars (~%d tokens). Offloaded to file to save context window. Results are ordered most-relevant first.", server, op, outputSize, outputSize*10/35)
	switch {
	case strings.Contains(op, "search"):
		guidance += " Next time: use limit<=5 and max_tokens<=4000 for search calls. Use Grep for known files."
	case strings.Contains(op, "index"):
		guidance += " Index IDs are managed by the hook -- you don't need to track them."
	case strings.Contains(op, "explore"):
		guidance += " Consider using path_filter to narrow results."
	}
	return guidance + " Read the offloaded file selectively if you need specific results."
}

func headBytes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

func tailBytes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}

func marshalModifyOutputWithContext(text, ctx string) []byte {
	return mustJSON(struct {
		ModifyOutput       string             `json:"modifyOutput"`
		HookSpecificOutput hookSpecificOutput `json:"hookSpecificOutput"`
	}{
		ModifyOutput: text,
		HookSpecificOutput: hookSpecificOutput{
			HookEventName:     "PostToolUse",
			AdditionalContext: ctx,
		},
	})
}
