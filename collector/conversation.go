package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// ConversationTailer watches Claude Code conversation JSONL files for new turns.
// It discovers files from ~/.claude/projects/*/  and polls for new lines,
// inserting relevant turns (user, assistant, system, queue-operation) into the
// hook_events table with source="conversation".
//
// This enables full turn-level observability without depending on the Docker
// OTEL monitoring stack.
type ConversationTailer struct {
	store    *Store
	baseDir  string            // ~/.claude/projects
	offsets  map[string]int64  // path -> last read offset
	interval time.Duration
}

func NewConversationTailer(store *Store) *ConversationTailer {
	home, _ := os.UserHomeDir()
	return &ConversationTailer{
		store:    store,
		baseDir:  filepath.Join(home, ".claude", "projects"),
		offsets:  make(map[string]int64),
		interval: 2 * time.Second,
	}
}

// Run polls for new conversation JSONL lines until ctx is cancelled.
func (ct *ConversationTailer) Run(ctx context.Context) {
	slog.Info("conversation tailer started", "dir", ct.baseDir)
	ticker := time.NewTicker(ct.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			slog.Info("conversation tailer stopped")
			return
		case <-ticker.C:
			ct.poll(ctx)
		}
	}
}

func (ct *ConversationTailer) poll(ctx context.Context) {
	// Find all session JSONL files (not subagent files)
	pattern := filepath.Join(ct.baseDir, "*", "*.jsonl")
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return
	}

	for _, path := range matches {
		// Skip subagent transcripts
		if strings.Contains(path, "/subagents/") {
			continue
		}
		ct.tailFile(ctx, path)
	}
}

// conversationLine represents a parsed conversation JSONL entry.
type conversationLine struct {
	Type      string `json:"type"`
	SessionID string `json:"sessionId"`
	Timestamp string `json:"timestamp"`
	UUID      string `json:"uuid"`

	// User message fields
	Origin *struct {
		Kind string `json:"kind"`
	} `json:"origin"`

	// Assistant message fields
	Message *struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
	} `json:"message"`
	RequestID string `json:"requestId"`

	// Queue operation fields
	Operation string `json:"operation"`
}

// interestingType returns true for conversation turns we want to store.
func interestingType(t string) bool {
	switch t {
	case "user", "assistant", "system", "queue-operation":
		return true
	}
	return false
}

func (ct *ConversationTailer) tailFile(ctx context.Context, path string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()

	// Seek to last known offset
	offset := ct.offsets[path]
	if offset == 0 {
		// First time seeing this file: start from end (don't replay history)
		info, err := f.Stat()
		if err != nil {
			return
		}
		ct.offsets[path] = info.Size()
		return
	}

	if _, err := f.Seek(offset, 0); err != nil {
		return
	}

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 256*1024), 256*1024) // 256KB line buffer

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var cl conversationLine
		if err := json.Unmarshal(line, &cl); err != nil {
			continue
		}

		if !interestingType(cl.Type) {
			continue
		}

		// Build a summary payload for the hook_events table
		eventType := fmt.Sprintf("conv_%s", cl.Type)
		toolName := cl.Type

		payload := map[string]any{
			"message_type": cl.Type,
			"uuid":         cl.UUID,
		}

		if cl.Origin != nil {
			payload["origin_kind"] = cl.Origin.Kind
		}
		if cl.RequestID != "" {
			payload["request_id"] = cl.RequestID
		}
		if cl.Message != nil && len(cl.Message.Content) > 0 {
			text := cl.Message.Content[0].Text
			if len(text) > 200 {
				text = text[:200]
			}
			payload["text_preview"] = text
		}
		if cl.Operation != "" {
			payload["operation"] = cl.Operation
		}

		payloadJSON, _ := json.Marshal(payload)

		if err := ct.store.InsertHookEvent(ctx, cl.SessionID, eventType, toolName, string(payloadJSON)); err != nil {
			slog.Debug("conversation insert failed", "err", err)
		}
	}

	// Update offset to current position
	newOffset, _ := f.Seek(0, 1) // current position after scanning
	ct.offsets[path] = newOffset
}
