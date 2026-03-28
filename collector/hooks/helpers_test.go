package hooks

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSanitizeID(t *testing.T) {
	tests := []struct {
		in   string
		want string
	}{
		{"abc-123_def", "abc-123_def"},
		{"abc/../etc", ""},
		{"", ""},
		{"a b c", ""},
	}

	for _, tt := range tests {
		if got := sanitizeID(tt.in); got != tt.want {
			t.Fatalf("sanitizeID(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestIsSubagent(t *testing.T) {
	tests := []struct {
		path string
		want bool
	}{
		{"/home/user/.claude/subagents/agent-abc.jsonl", true},
		{"/tmp/claude-agent-xyz.jsonl", false},
		{"/home/user/tmp/subagents/agent-xyz.jsonl", true},
		{"/home/user/.claude/transcript.jsonl", false},
	}

	for _, tt := range tests {
		if got := isSubagent(tt.path); got != tt.want {
			t.Fatalf("isSubagent(%q) = %v, want %v", tt.path, got, tt.want)
		}
	}
}

func TestGetAgentID(t *testing.T) {
	tests := []struct {
		path string
		want string
	}{
		{"/path/subagents/agent-abc123.jsonl", "abc123"},
		{"/path/transcript.jsonl", ""},
		{"/path/subagents/agent-abc/../etc.jsonl", ""},
	}

	for _, tt := range tests {
		if got := getAgentID(tt.path); got != tt.want {
			t.Fatalf("getAgentID(%q) = %q, want %q", tt.path, got, tt.want)
		}
	}
}

func TestGetAgentType(t *testing.T) {
	home := t.TempDir()
	withHomeDir(t, home)

	stateDir := filepath.Join(home, ".claude", ".statusline", "subagents")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "agent123"), []byte("FOO=bar\nAGENT_TYPE=Explore\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	if got := getAgentType("agent123"); got != "Explore" {
		t.Fatalf("getAgentType() = %q, want %q", got, "Explore")
	}
	if got := getAgentType("missing"); got != "" {
		t.Fatalf("getAgentType(missing) = %q, want empty", got)
	}
}

func TestResolveSessionStart(t *testing.T) {
	home := t.TempDir()
	withHomeDir(t, home)

	stateDir := filepath.Join(home, ".claude", ".statusline")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, ".session_start-sid123"), []byte("1234567890.123\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	if got := resolveSessionStart("sid123"); got != 1234567890 {
		t.Fatalf("resolveSessionStart(existing) = %d, want %d", got, int64(1234567890))
	}

	start := time.Now().Unix()
	got := resolveSessionStart("missing")
	end := time.Now().Unix()
	if got < start || got > end {
		t.Fatalf("resolveSessionStart(missing) = %d, want between %d and %d", got, start, end)
	}
}

func TestRelativeTimestamp(t *testing.T) {
	prevNow := timeNow
	timeNow = func() time.Time { return time.Unix(200, 0) }
	defer func() { timeNow = prevNow }()

	if got := relativeTimestamp(150); got != 50 {
		t.Fatalf("relativeTimestamp() = %d, want 50", got)
	}
}

func TestScrubSecrets(t *testing.T) {
	input := "curl -H secret --header token Bearer abc api_key=xyz ghp_secret"
	got := scrubSecrets(input)
	checks := []string{
		"-H [REDACTED]",
		"--header [REDACTED]",
		"Bearer [REDACTED]",
		"api_key=[REDACTED]",
		"[REDACTED]",
	}
	for _, check := range checks {
		if !strings.Contains(got, check) {
			t.Fatalf("scrubSecrets(%q) = %q, want substring %q", input, got, check)
		}
	}
}

func TestGetEnvInt(t *testing.T) {
	const key = "WARDEN_TRUNCATE_BYTES"
	unsetEnv(t, key)

	if got := getEnvInt(key, 20480); got != 20480 {
		t.Fatalf("unset getEnvInt() = %d, want 20480", got)
	}

	if err := os.Setenv(key, "12345"); err != nil {
		t.Fatal(err)
	}
	if got := getEnvInt(key, 20480); got != 12345 {
		t.Fatalf("set getEnvInt() = %d, want 12345", got)
	}

	if err := os.Setenv(key, "abc"); err != nil {
		t.Fatal(err)
	}
	if got := getEnvInt(key, 20480); got != 20480 {
		t.Fatalf("invalid getEnvInt() = %d, want 20480", got)
	}
}

func TestGetEnvStr(t *testing.T) {
	const key = "WARDEN_TEST_STR"
	unsetEnv(t, key)

	if got := getEnvStr(key, "fallback"); got != "fallback" {
		t.Fatalf("unset getEnvStr() = %q, want fallback", got)
	}
	if err := os.Setenv(key, "value"); err != nil {
		t.Fatal(err)
	}
	if got := getEnvStr(key, "fallback"); got != "value" {
		t.Fatalf("set getEnvStr() = %q, want value", got)
	}
}

func withHomeDir(t *testing.T, home string) {
	t.Helper()
	prevEnv := os.Getenv("HOME")
	prevHomeDir := userHomeDir
	if err := os.Setenv("HOME", home); err != nil {
		t.Fatal(err)
	}
	userHomeDir = func() (string, error) { return home, nil }
	t.Cleanup(func() {
		userHomeDir = prevHomeDir
		if prevEnv == "" {
			_ = os.Unsetenv("HOME")
		} else {
			_ = os.Setenv("HOME", prevEnv)
		}
	})
}

func unsetEnv(t *testing.T, key string) {
	t.Helper()
	prev, ok := os.LookupEnv(key)
	_ = os.Unsetenv(key)
	t.Cleanup(func() {
		if ok {
			_ = os.Setenv(key, prev)
		} else {
			_ = os.Unsetenv(key)
		}
	})
}
