package hooks

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var (
	fridaBannerRes = []*regexp.Regexp{
		regexp.MustCompile(`^[\t ]*____$`),
		regexp.MustCompile(`^[\t ]*/ _  \|`),
		regexp.MustCompile(`^[\t ]*\| \(_\| \|`),
		regexp.MustCompile(`^[\t ]*> _  \|`),
		regexp.MustCompile(`^[\t ]*/_/ \|_\|`),
		regexp.MustCompile(`^[\t ]*help[\t ]*->`),
		regexp.MustCompile(`^[\t ]*object[\t ]*->`),
		regexp.MustCompile(`^[\t ]*quit[\t ]*->`),
		regexp.MustCompile(`^[\t ]*exit[/\t ]`),
		regexp.MustCompile(`^[\t ]*export[\t ]*->`),
		regexp.MustCompile(`^[\t ]*eval[\t ]*->`),
		regexp.MustCompile(`^[\t ]*resume[\t ]*->`),
		regexp.MustCompile(`^[\t ]*load[\t ]*->`),
		regexp.MustCompile(`^[\t ]*reload[\t ]*->`),
		regexp.MustCompile(`^[\t ]*import[\t ]*->`),
	}
	gitDetachedHeadRE  = regexp.MustCompile(`^You are in .detached HEAD. state`)
	gitExampleBranchRE = regexp.MustCompile(`^ \(e\.g\. .git switch -c <new-branch-name>.\), then`)
	grepCommandRE      = regexp.MustCompile(`(^|[\t ;|&])(grep|rg|ripgrep)[\t ]`)
	taskNumberedRE     = regexp.MustCompile(`^[0-9]+[.)]`)
	taskHeaderRE       = regexp.MustCompile(`^#{1,4} `)
	taskFileLineRE     = regexp.MustCompile(`^[a-zA-Z_.\/ ]*\.[a-z]{1,4}:[0-9]`)
	ipsThreadsRE       = regexp.MustCompile(`"threads"[\t ]*:`)
	gitQuietRuleRE     = regexp.MustCompile(`git[\t ]+(commit|clone|fetch|pull)`)
	npmQuietRuleRE     = regexp.MustCompile(`npm[\t ]+(install|i|ci)`)
	pipQuietRuleRE     = regexp.MustCompile(`pip3?[\t ]+(install|download)`)
	dockerQuietRuleRE  = regexp.MustCompile(`docker[\t ]+(build|pull)`)
)

func init() {
	hookHandlers["post-tool-use"] = handlePostToolUse
	hookHandlers["mcp-output-compress"] = handlePostToolUse
}

type postToolUseContext struct {
	input          HookInput
	collector      eventPoster
	toolName       string
	sessionID      string
	command        string
	output         string
	outputSize     int
	sessionStartS  int64
	isSubagentCall bool
	agentID        string
	outputChanged  bool
	finalSize      int
}

func handlePostToolUse(input HookInput) ([]byte, int) {
	ctx := newPostToolUseContext(input)
	if ctx.outputSize == 0 {
		return nil, 0
	}
	defer ctx.postSubagentBytes()

	ctx.emitOutputSize()

	if ctx.stripSystemReminders() {
		switch {
		case ctx.toolName == "Bash", ctx.toolName == "Grep", ctx.toolName == "Glob", ctx.toolName == "Task", strings.HasPrefix(ctx.toolName, "mcp__"):
		default:
			return ModifyOutput(ctx.output), 0
		}
	}

	if out, handled := ctx.handleMCPOutputCompress(); handled {
		return out, 0
	}

	ctx.cleanSSHOutput()
	ctx.stripGitHints()

	if reminder, ok := ctx.consumeQuietOverrideReminder(); ok {
		if ctx.finalSize < 0 {
			ctx.finalSize = ctx.outputSize
		}
		return AdditionalContext("PostToolUse", reminder), 0
	}

	switch {
	case ctx.toolName == "Bash", ctx.toolName == "Grep", ctx.toolName == "Glob", ctx.toolName == "Task", strings.HasPrefix(ctx.toolName, "mcp__"):
	case ctx.toolName == "Read":
		if !ctx.isSubagentCall {
			ctx.emitEvent("allowed", ctx.outputSize, ctx.outputSize, "")
			return ctx.cleanedOrSuppress(), 0
		}
	default:
		ctx.emitEvent("allowed", ctx.outputSize, ctx.outputSize, "")
		return ctx.cleanedOrSuppress(), 0
	}

	if ctx.toolName == "Task" && ctx.outputSize > 6144 {
		if structured, ok := extractStructuredTaskOutput(ctx.output); ok {
			final := fmt.Sprintf("%s\n\n[Agent output compressed: %dKB -> %dKB structured lines]", structured, ctx.outputSize/1024, len(structured)/1024)
			ctx.emitEvent("truncated", ctx.outputSize, len(final), "task_structured")
			return ModifyOutput(final), 0
		}
	}

	if ctx.toolName == "Bash" && grepCommandRE.MatchString(ctx.command) && ctx.outputSize > 4096 {
		head := sliceRunes(ctx.output, 0, 4000)
		tail := lastRunes(ctx.output, 1000)
		final := fmt.Sprintf("%s\n... [%dKB grep output truncated to 5KB] ...\n%s", head, ctx.outputSize/1024, tail)
		ctx.emitEvent("truncated", ctx.outputSize, len(final), "grep_truncated")
		return ModifyOutput(final), 0
	}

	threshold := getEnvInt("WARDEN_TRUNCATE_BYTES", 12288)
	if ctx.isSubagentCall && ctx.toolName == "Read" {
		threshold = getEnvInt("WARDEN_SUBAGENT_READ_BYTES", 10240)
	}
	suppressBytes := getEnvInt("WARDEN_SUPPRESS_BYTES", 524288)
	if threshold > suppressBytes {
		threshold = suppressBytes
	}
	if ctx.outputSize <= threshold {
		ctx.emitEvent("allowed", ctx.outputSize, ctx.outputSize, "")
		return ctx.cleanedOrSuppress(), 0
	}

	if strings.IndexByte(ctx.output, 0) >= 0 {
		final := fmt.Sprintf("[Binary output: %dKB. Use 'file' or redirect.]", ctx.outputSize/1024)
		ctx.emitEvent("truncated", ctx.outputSize, len(final), "binary_output")
		return ModifyOutput(final), 0
	}

	if ctx.outputSize > suppressBytes {
		final := fmt.Sprintf("[Output too large: %dMB. Use | head or redirect.]", ctx.outputSize/1048576)
		ctx.emitEvent("truncated", ctx.outputSize, len(final), "output_suppressed")
		return ModifyOutput(final), 0
	}

	head := sliceRunes(ctx.output, 0, 8000)
	if isHeadOnlyCommand(ctx.command) {
		ctx.emitEvent("truncated", ctx.outputSize, len(head), "head-only")
		return ModifyOutput(head), 0
	}

	tail := lastRunes(ctx.output, 2000)
	final := fmt.Sprintf("%s\n... [%dKB truncated to 10KB] ...\n%s", head, ctx.outputSize/1024, tail)
	ctx.emitEvent("truncated", ctx.outputSize, len(final), "output_truncated")
	return ModifyOutput(final), 0
}

func newPostToolUseContext(input HookInput) *postToolUseContext {
	ctx := &postToolUseContext{
		input:          input,
		collector:      newEventPoster(),
		toolName:       input.ToolNameOrDefault(),
		sessionID:      sanitizeID(input.SessionID),
		command:        truncateString(extractToolInputString(input.ToolInput), 200),
		output:         extractToolResponseText(input),
		sessionStartS:  resolveSessionStart(input.SessionID),
		isSubagentCall: isSubagent(input.TranscriptPath),
		agentID:        getAgentID(input.TranscriptPath),
		finalSize:      -1,
	}
	ctx.outputSize = len(ctx.output)
	return ctx
}

func extractToolResponseText(input HookInput) string {
	if len(input.ToolResponse.Content) == 0 {
		return ""
	}
	return input.ToolResponse.Content[0].Text
}

func extractToolInputString(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return ""
	}
	for _, key := range []string{"command", "file_path", "pattern", "prompt"} {
		if s, _ := m[key].(string); s != "" {
			return s
		}
	}
	return ""
}

func (c *postToolUseContext) emitOutputSize() {
	lines := 0
	if c.outputSize <= 51200 {
		lines = countLines(c.output)
	} else {
		sample := c.output
		if len(sample) > 51200 {
			sample = sample[:51200]
		}
		lines = countLines(sample)
		lines = lines * c.outputSize / 51200
	}
	c.postJSON(map[string]any{
		"timestamp":        relativeTimestamp(c.sessionStartS),
		"event_type":       "tool_output_size",
		"tool":             c.toolName,
		"session_id":       c.sessionID,
		"output_bytes":     c.outputSize,
		"output_lines":     lines,
		"estimated_tokens": c.outputSize * 10 / 35,
		"original_cmd":     scrubSecrets(c.command),
	})
}

func countLines(s string) int {
	if s == "" {
		return 0
	}
	lines := strings.Count(s, "\n")
	if !strings.HasSuffix(s, "\n") {
		lines++
	}
	return lines
}

func (c *postToolUseContext) emitEvent(eventType string, origBytes, finalBytes int, rule string) {
	saved := (origBytes - finalBytes) * 10 / 35
	if saved < 0 {
		saved = 0
	}
	evt := map[string]any{
		"timestamp":             relativeTimestamp(c.sessionStartS),
		"event_type":            eventType,
		"tool":                  c.toolName,
		"session_id":            c.sessionID,
		"original_cmd":          scrubSecrets(c.command),
		"tokens_saved":          saved,
		"original_output_bytes": origBytes,
		"final_output_bytes":    finalBytes,
	}
	if rule != "" {
		evt["rule"] = rule
	}
	c.finalSize = finalBytes
	c.postJSON(evt)
}

func (c *postToolUseContext) postSubagentBytes() {
	if !c.isSubagentCall || c.agentID == "" {
		return
	}
	finalBytes := c.finalSize
	if finalBytes < 0 {
		finalBytes = c.outputSize
	}
	c.postJSON(map[string]any{
		"event_type": "subagent_bytes",
		"agent_id":   c.agentID,
		"session_id": c.sessionID,
		"bytes":      finalBytes,
	})
}

func (c *postToolUseContext) postJSON(v any) {
	if c.collector == nil {
		return
	}
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	c.collector.PostEvent(b)
}

func (c *postToolUseContext) stripSystemReminders() bool {
	if !strings.Contains(c.output, "<system-reminder>") {
		return false
	}
	cleaned := stripSystemReminderBlocks(c.output)
	if cleaned == c.output {
		return false
	}
	origSize := c.outputSize
	c.output = cleaned
	c.outputSize = len(cleaned)
	c.outputChanged = true
	c.emitEvent("truncated", origSize, c.outputSize, "system_reminder")
	return true
}

func stripSystemReminderBlocks(s string) string {
	lines := strings.Split(s, "\n")
	out := make([]string, 0, len(lines))
	inBlock := false
	for _, line := range lines {
		switch line {
		case "<system-reminder>":
			inBlock = true
			continue
		case "</system-reminder>":
			inBlock = false
			continue
		}
		if !inBlock {
			out = append(out, line)
		}
	}
	for len(out) > 0 && strings.TrimSpace(out[len(out)-1]) == "" {
		out = out[:len(out)-1]
	}
	return strings.Join(out, "\n")
}

func (c *postToolUseContext) cleanSSHOutput() {
	if c.toolName != "Bash" {
		return
	}
	if !strings.Contains(c.command, "ssh") && !strings.Contains(c.command, "scp") && !strings.Contains(c.command, "frida") {
		return
	}
	orig := c.output
	lines := strings.Split(c.output, "\n")
	filtered := make([]string, 0, len(lines))
	for _, line := range lines {
		if isFridaBannerLine(line) {
			continue
		}
		if strings.HasPrefix(line, "Warning: Permanently added") || strings.HasPrefix(line, "Pseudo-terminal will not be allocated") || strings.HasPrefix(line, "X11 forwarding request failed") {
			continue
		}
		filtered = append(filtered, line)
	}
	lines = filtered
	if strings.Contains(strings.Join(lines, "\n"), "UNIX authentication refused") || strings.Contains(strings.Join(lines, "\n"), "Host key verification failed") {
		filtered = filtered[:0]
		authSeen := false
		hostSeen := false
		for _, line := range lines {
			switch {
			case strings.Contains(line, "UNIX authentication refused"):
				if !authSeen {
					filtered = append(filtered, "[SSH: auth refused]")
					authSeen = true
				}
			case strings.Contains(line, "Permission denied, please try again"):
			case strings.Contains(line, "Host key verification failed"):
				if !hostSeen {
					filtered = append(filtered, "[SSH: host key verification failed]")
					hostSeen = true
				}
			case strings.Contains(line, "scp: Connection closed"):
			case strings.HasPrefix(line, "Connection closed by"):
			default:
				filtered = append(filtered, line)
			}
		}
		lines = filtered
	}
	if len(lines) > 0 && strings.HasPrefix(lines[0], `{"app_name":`) {
		body := make([]string, 0, len(lines))
		body = append(body, lines[0])
		threadsFound := false
		for _, line := range lines[1:] {
			if ipsThreadsRE.MatchString(line) {
				body = append(body, `  "threads": [... omitted ...]`)
				threadsFound = true
				break
			}
			body = append(body, line)
		}
		if threadsFound {
			body = append(body, `[crash log: threads array omitted]`)
			lines = body
		}
	}
	cleaned := strings.Join(lines, "\n")
	if cleaned != orig {
		c.output = cleaned
		c.outputSize = len(cleaned)
		c.outputChanged = true
		c.emitEvent("truncated", len(orig), c.outputSize, "ssh_noise")
	}
}

func isFridaBannerLine(line string) bool {
	for _, re := range fridaBannerRes {
		if re.MatchString(line) {
			return true
		}
	}
	return false
}

func (c *postToolUseContext) stripGitHints() {
	if c.toolName != "Bash" {
		return
	}
	if !strings.Contains(c.output, "hint: ") && !strings.Contains(c.output, "Note: switching to") && !strings.Contains(c.output, "warning: refs/tags/") && !strings.Contains(c.output, "detached HEAD") {
		return
	}
	orig := c.output
	lines := strings.Split(c.output, "\n")
	filtered := make([]string, 0, len(lines))
	for _, line := range lines {
		switch {
		case strings.HasPrefix(line, "hint: "):
		case strings.HasPrefix(line, "warning: refs/tags/"):
		case strings.HasPrefix(line, "Note: switching to "):
		case gitDetachedHeadRE.MatchString(line):
		case strings.HasPrefix(line, "HEAD is now at "):
		case strings.HasPrefix(line, "If you want to create a new branch to retain commits"):
		case gitExampleBranchRE.MatchString(line):
		case strings.HasPrefix(line, "Or if you want to keep this update but want to use it"):
		case strings.HasPrefix(line, " then, discard"):
		default:
			filtered = append(filtered, line)
		}
	}
	cleaned := strings.Join(filtered, "\n")
	if len(cleaned) < len(orig) {
		c.output = cleaned
		c.outputSize = len(cleaned)
		c.outputChanged = true
		c.emitEvent("truncated", len(orig), c.outputSize, "git_hints")
	}
}

func (c *postToolUseContext) consumeQuietOverrideReminder() (string, bool) {
	if c.toolName != "Bash" || c.sessionID == "" {
		return "", false
	}
	path := filepath.Join(statuslineDir(), fmt.Sprintf(".quiet-override-%s-%s", c.toolName, c.sessionID))
	b, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	_ = os.Remove(path)
	rule := strings.TrimSpace(string(b))
	if rule == "" {
		return "", false
	}
	switch rule {
	case "git_quiet_override":
		if m := gitQuietRuleRE.FindStringSubmatch(c.command); len(m) > 1 {
			return fmt.Sprintf("[warden: ran as git %s -q — next time include -q yourself]", m[1]), true
		}
	case "npm_quiet_override":
		if m := npmQuietRuleRE.FindStringSubmatch(c.command); len(m) > 1 {
			return fmt.Sprintf("[warden: ran with --silent — next time use npm %s --silent]", m[1]), true
		}
		return "[warden: ran with --silent — next time use npm install --silent]", true
	case "cargo_quiet_override":
		return "[warden: ran as cargo build -q — next time include -q yourself]", true
	case "make_quiet_override":
		return "[warden: ran as make -s — next time include -s yourself]", true
	case "pip_quiet_override":
		if m := pipQuietRuleRE.FindStringSubmatch(c.command); len(m) > 1 {
			return fmt.Sprintf("[warden: ran with -q — next time use pip %s -q]", m[1]), true
		}
		return "[warden: ran with -q — next time use pip install -q]", true
	case "wget_quiet_override":
		return "[warden: ran as wget -q — next time include -q yourself]", true
	case "docker_quiet_override":
		if m := dockerQuietRuleRE.FindStringSubmatch(c.command); len(m) > 1 {
			return fmt.Sprintf("[warden: ran with -q — next time use docker %s -q]", m[1]), true
		}
	case "ffmpeg_quiet_override":
		return "[warden: ran with -nostats -loglevel error — next time include these flags yourself]", true
	case "curl_sanitized":
		return "[warden: curl sanitized — added -sS/--max-time, stripped verbose flags]", true
	case "git_diff_bounded":
		return "[warden: git diff piped through head -200 — use --stat for summary or specify file paths to narrow output]", true
	case "cat_to_head":
		return "[warden: cat -> head -c 8192 (file too large) — use Read tool with offset/limit for full content]", true
	}
	return "", false
}

func (c *postToolUseContext) cleanedOrSuppress() []byte {
	if c.outputChanged {
		if c.finalSize < 0 {
			c.finalSize = c.outputSize
		}
		return ModifyOutput(c.output)
	}
	if c.finalSize < 0 {
		c.finalSize = c.outputSize
	}
	return SuppressOutput()
}

func extractStructuredTaskOutput(output string) (string, bool) {
	lines := strings.Split(output, "\n")
	structured := make([]string, 0, 120)
	for _, line := range lines {
		switch {
		case strings.HasPrefix(line, "- "), strings.HasPrefix(line, "* "):
			structured = append(structured, line)
		case taskNumberedRE.MatchString(line):
			structured = append(structured, line)
		case taskHeaderRE.MatchString(line):
			structured = append(structured, line)
		case strings.HasPrefix(line, "|"):
			structured = append(structured, line)
		case strings.HasPrefix(line, " - "), strings.HasPrefix(line, " * "), strings.HasPrefix(line, "\t- "), strings.HasPrefix(line, "\t* "):
			structured = append(structured, line)
		case taskFileLineRE.MatchString(line):
			structured = append(structured, line)
		}
		if len(structured) >= 120 {
			break
		}
	}
	joined := strings.Join(structured, "\n")
	if len(joined) > 200 && len(joined) < len(output) {
		return joined, true
	}
	return "", false
}

func isHeadOnlyCommand(command string) bool {
	return strings.Contains(command, "nm ") || strings.HasSuffix(command, " nm") || strings.Contains(command, "strings ") || strings.Contains(command, "otool") || strings.Contains(command, "jtool") || strings.Contains(command, "class-dump")
}

func sliceRunes(s string, start, length int) string {
	if length <= 0 {
		return ""
	}
	r := []rune(s)
	if start >= len(r) {
		return ""
	}
	end := start + length
	if end > len(r) {
		end = len(r)
	}
	return string(r[start:end])
}

func lastRunes(s string, length int) string {
	if length <= 0 {
		return ""
	}
	r := []rune(s)
	if len(r) <= length {
		return s
	}
	return string(r[len(r)-length:])
}

func sampleLineEstimate(s string) int {
	if len(s) <= 51200 {
		return countLines(s)
	}
	sample := s[:51200]
	return countLines(sample) * len(s) / 51200
}

func hasNullByte(s string) bool {
	return bytes.IndexByte([]byte(s), 0) >= 0
}
