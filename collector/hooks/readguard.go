package hooks

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
)

var readGuardBundledRE = regexp.MustCompile(`(node_modules/|/dist/|/build/|\.min\.js$|\.bundle\.js$|expo-downloads/|\.chunk\.js$|/vendor/|/__generated__/|package-lock\.json$|yarn\.lock$|pnpm-lock\.yaml$|Cargo\.lock$|poetry\.lock$|composer\.lock$|Gemfile\.lock$|go\.sum$)`)

func init() {
	hookHandlers["read-guard"] = handleReadGuard
}

func handleReadGuard(input HookInput) ([]byte, int) {
	filePath := readGuardFilePath(input.ToolInput)
	if filePath == "" {
		return nil, 0
	}

	ctx := &readGuardContext{
		input:         input,
		filePath:      filePath,
		sessionStartS: resolveSessionStart(input.SessionID),
		collector:     newEventPoster(),
	}

	if readGuardBundledRE.MatchString(filePath) {
		ctx.emitBlocked("read_bundled", 8000)
		_, _ = fmt.Fprintf(os.Stderr, "Blocked: '%s' is a bundled/generated file; find the source\n", filePath)
		return nil, 2
	}

	fi, err := os.Stat(filePath)
	if err != nil || !fi.Mode().IsRegular() {
		return nil, 0
	}

	maxMB := getEnvInt("WARDEN_READ_GUARD_MAX_MB", 2)
	maxBytes := int64(maxMB) * 1024 * 1024
	if fi.Size() <= maxBytes {
		return nil, 0
	}

	sizeMB := float64(fi.Size()) / 1024.0 / 1024.0
	ctx.emitBlocked("read_oversize", 25000)
	_, _ = fmt.Fprintf(os.Stderr, "Blocked: '%s' is %.1fMB (max %dMB)\n", filePath, sizeMB, maxMB)
	return nil, 2
}

func readGuardFilePath(raw json.RawMessage) string {
	var input ReadToolInput
	if err := json.Unmarshal(raw, &input); err != nil {
		return ""
	}
	return input.FilePath
}

type readGuardContext struct {
	input         HookInput
	filePath      string
	sessionStartS int64
	collector     eventPoster
}

func (c *readGuardContext) emitBlocked(rule string, tokensSaved int) {
	if c.collector == nil {
		return
	}
	b, err := json.Marshal(map[string]any{
		"timestamp":    relativeTimestamp(c.sessionStartS),
		"event_type":   "blocked",
		"tool":         "Read",
		"session_id":   c.input.SessionID,
		"original_cmd": scrubSecrets(c.filePath),
		"rule":         rule,
		"tokens_saved": tokensSaved,
	})
	if err != nil {
		return
	}
	c.collector.PostEvent(b)
}
