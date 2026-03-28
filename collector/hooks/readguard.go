package hooks

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
)

var readGuardBundledRE = regexp.MustCompile(`((^|/)node_modules/|(^|/)dist/|(^|/)build/|\.min\.js$|\.bundle\.js$|(^|/)expo-downloads/|\.chunk\.js$|(^|/)vendor/|(^|/)__generated__/|package-lock\.json$|yarn\.lock$|pnpm-lock\.yaml$|Cargo\.lock$|poetry\.lock$|composer\.lock$|Gemfile\.lock$|go\.sum$)`)

func init() {
	hookHandlers["read-guard"] = handleReadGuard
}

func handleReadGuard(input HookInput) ([]byte, int) {
	var readInput ReadToolInput
	if err := json.Unmarshal(input.ToolInput, &readInput); err != nil || readInput.FilePath == "" {
		return nil, 0
	}
	filePath := readInput.FilePath

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
	fileSize := fi.Size()

	maxMB := getEnvInt("WARDEN_READ_GUARD_MAX_MB", 2)
	maxBytes := int64(maxMB) * 1024 * 1024
	if fileSize > maxBytes {
		sizeMB := float64(fileSize) / 1024.0 / 1024.0
		ctx.emitBlocked("read_oversize", 25000)
		_, _ = fmt.Fprintf(os.Stderr, "Blocked: '%s' is %.1fMB (max %dMB)\n", filePath, sizeMB, maxMB)
		return nil, 2
	}

	// Dense content detection: high bytes-per-line ratio.
	denseMinBytes := int64(getEnvInt("WARDEN_DENSE_MIN_BYTES", 8192))
	denseBPL := int64(getEnvInt("WARDEN_DENSE_BPL_THRESHOLD", 500))
	denseLineCap := getEnvInt("WARDEN_DENSE_LINE_CAP", 100)

	if fileSize > denseMinBytes {
		lineCount := countFileLines(filePath)
		var bpl int64
		isDense := false

		if lineCount > 0 {
			bpl = fileSize / int64(lineCount)
			isDense = bpl > denseBPL
		} else if fileSize > denseMinBytes {
			// 0 lines = single-line blob
			bpl = fileSize
			isDense = true
		}

		if isDense {
			// If model already set a reasonable limit, respect it.
			if readInput.Limit > 0 && readInput.Limit <= denseLineCap {
				return nil, 0
			}

			ctx.emitAllowed("read_dense_reroute")

			sizeKB := fileSize / 1024
			guidance := fmt.Sprintf(
				"[warden] Dense file: %dKB, %d lines, ~%d bytes/line. Capped to %d lines. Use offset+limit to page through, or Bash jq/head -c for structured extraction.",
				sizeKB, lineCount, bpl, denseLineCap,
			)

			offset := readInput.Offset
			return ReadReroute(filePath, offset, denseLineCap, guidance), 0
		}
	}

	return nil, 0
}

// countFileLines counts newline characters in a file. Returns 0 on error.
func countFileLines(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	return bytes.Count(data, []byte{'\n'})
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

func (c *readGuardContext) emitAllowed(rule string) {
	if c.collector == nil {
		return
	}
	b, err := json.Marshal(map[string]any{
		"timestamp":            relativeTimestamp(c.sessionStartS),
		"event_type":           "allowed",
		"tool":                 "Read",
		"session_id":           c.input.SessionID,
		"original_cmd":         scrubSecrets(c.filePath),
		"rule":                 rule,
		"original_output_bytes": 0,
		"final_output_bytes":   0,
	})
	if err != nil {
		return
	}
	c.collector.PostEvent(b)
}
