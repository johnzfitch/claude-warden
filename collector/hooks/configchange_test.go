package hooks

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestConfigChangeBlocksDisableAllHooks(t *testing.T) {
	for _, source := range []string{"project_settings", "user_settings", "unknown_source"} {
		t.Run(source, func(t *testing.T) {
			home, collector := setupConfigChangeTest(t)
			writeSessionStart(t, home, "sid-disable", "100")
			freezeHookTime(t, 130)

			path := writeConfigChangeFile(t, `{"disableAllHooks":true}`)
			out, code, stderr := runConfigChange(t, HookInput{SessionID: "sid-disable", Source: source, FilePath: path})
			if code != 2 {
				t.Fatalf("code=%d want 2", code)
			}
			if len(out) != 0 {
				t.Fatalf("out=%q want empty", out)
			}
			wantStderr := "warden: blocked config change — disableAllHooks=true in " + path
			if strings.TrimSpace(stderr) != wantStderr {
				t.Fatalf("stderr=%q want %q", strings.TrimSpace(stderr), wantStderr)
			}
			assertConfigChangeEvent(t, collector.events, map[string]any{
				"timestamp":    float64(30),
				"event_type":   "blocked",
				"tool":         "unknown",
				"session_id":   "sid-disable",
				"original_cmd": "disableAllHooks in " + source,
				"rule":         "config_disable_hooks",
				"tokens_saved": float64(0),
			})
		})
	}
}

func TestConfigChangeBlocksHooksForNonUserSources(t *testing.T) {
	for _, source := range []string{"project_settings", "unknown_source"} {
		t.Run(source, func(t *testing.T) {
			home, collector := setupConfigChangeTest(t)
			writeSessionStart(t, home, "sid-hooks", "200")
			freezeHookTime(t, 260)

			path := writeConfigChangeFile(t, `{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[]}]}}`)
			out, code, stderr := runConfigChange(t, HookInput{SessionID: "sid-hooks", Source: source, FilePath: path})
			if code != 2 {
				t.Fatalf("code=%d want 2", code)
			}
			if len(out) != 0 {
				t.Fatalf("out=%q want empty", out)
			}
			wantStderr := "warden: blocked config change — hooks modified in " + source + " (" + path + ")"
			if strings.TrimSpace(stderr) != wantStderr {
				t.Fatalf("stderr=%q want %q", strings.TrimSpace(stderr), wantStderr)
			}
			assertConfigChangeEvent(t, collector.events, map[string]any{
				"timestamp":    float64(60),
				"event_type":   "blocked",
				"tool":         "unknown",
				"session_id":   "sid-hooks",
				"original_cmd": "hooks in " + source,
				"rule":         "config_hooks_modified",
				"tokens_saved": float64(0),
			})
		})
	}
}

func TestConfigChangeAllowsPolicySettingsAlways(t *testing.T) {
	_, collector := setupConfigChangeTest(t)
	path := writeConfigChangeFile(t, `{"disableAllHooks":true,"hooks":{"PreToolUse":[1]}}`)

	out, code, stderr := runConfigChange(t, HookInput{SessionID: "sid", Source: "policy_settings", FilePath: path})
	if code != 0 || len(out) != 0 || stderr != "" {
		t.Fatalf("code=%d out=%q stderr=%q", code, out, stderr)
	}
	if len(collector.events) != 0 {
		t.Fatalf("events=%#v want none", collector.events)
	}
}

func TestConfigChangeAllowsUserManagedHooks(t *testing.T) {
	_, collector := setupConfigChangeTest(t)
	path := writeConfigChangeFile(t, `{"hooks":{"PreToolUse":[{"matcher":"*"}]}}`)

	out, code, stderr := runConfigChange(t, HookInput{SessionID: "sid", Source: "user_settings", FilePath: path})
	if code != 0 || len(out) != 0 || stderr != "" {
		t.Fatalf("code=%d out=%q stderr=%q", code, out, stderr)
	}
	if len(collector.events) != 0 {
		t.Fatalf("events=%#v want none", collector.events)
	}
}

func TestConfigChangeAllowsSafeInputs(t *testing.T) {
	_, collector := setupConfigChangeTest(t)
	safePath := writeConfigChangeFile(t, `{"theme":"dark"}`)
	falsePath := writeConfigChangeFile(t, `{"disableAllHooks":false}`)
	emptyHooksPath := writeConfigChangeFile(t, `{"hooks":{}}`)
	missingPath := filepath.Join(t.TempDir(), "missing.json")

	cases := []struct {
		name  string
		input HookInput
	}{
		{name: "no disableAllHooks and no hooks", input: HookInput{Source: "project_settings", FilePath: safePath}},
		{name: "disableAllHooks false", input: HookInput{Source: "project_settings", FilePath: falsePath}},
		{name: "empty hooks section", input: HookInput{Source: "project_settings", FilePath: emptyHooksPath}},
		{name: "empty file path", input: HookInput{Source: "project_settings"}},
		{name: "file does not exist", input: HookInput{Source: "project_settings", FilePath: missingPath}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			collector.events = nil
			out, code, stderr := runConfigChange(t, tc.input)
			if code != 0 || len(out) != 0 || stderr != "" {
				t.Fatalf("code=%d out=%q stderr=%q", code, out, stderr)
			}
			if len(collector.events) != 0 {
				t.Fatalf("events=%#v want none", collector.events)
			}
		})
	}
}

func TestConfigChangeAllowsMalformedOrNonJSONFiles(t *testing.T) {
	_, collector := setupConfigChangeTest(t)
	invalidPath := writeConfigChangeFile(t, `{"disableAllHooks":`)
	emptyPath := writeConfigChangeFile(t, "")
	textPath := writeConfigChangeFile(t, "definitely not json")

	for _, tc := range []struct {
		name string
		path string
	}{
		{name: "invalid json", path: invalidPath},
		{name: "empty file", path: emptyPath},
		{name: "non-json file", path: textPath},
	} {
		t.Run(tc.name, func(t *testing.T) {
			collector.events = nil
			out, code, stderr := runConfigChange(t, HookInput{Source: "project_settings", FilePath: tc.path})
			if code != 0 || len(out) != 0 || stderr != "" {
				t.Fatalf("code=%d out=%q stderr=%q", code, out, stderr)
			}
			if len(collector.events) != 0 {
				t.Fatalf("events=%#v want none", collector.events)
			}
		})
	}
}

func TestConfigChangeDisableAllHooksTakesPrecedenceOverHooks(t *testing.T) {
	home, collector := setupConfigChangeTest(t)
	writeSessionStart(t, home, "sid-precedence", "10")
	freezeHookTime(t, 25)

	path := writeConfigChangeFile(t, `{"disableAllHooks":true,"hooks":{"PreToolUse":[1]}}`)
	_, code, stderr := runConfigChange(t, HookInput{SessionID: "sid-precedence", Source: "project_settings", FilePath: path})
	if code != 2 {
		t.Fatalf("code=%d want 2", code)
	}
	if !strings.Contains(stderr, "disableAllHooks=true") {
		t.Fatalf("stderr=%q", stderr)
	}
	assertConfigChangeEvent(t, collector.events, map[string]any{
		"timestamp":    float64(15),
		"event_type":   "blocked",
		"tool":         "unknown",
		"session_id":   "sid-precedence",
		"original_cmd": "disableAllHooks in project_settings",
		"rule":         "config_disable_hooks",
		"tokens_saved": float64(0),
	})
}

func TestHasNonEmptyHooks(t *testing.T) {
	cases := []struct {
		name string
		in   any
		want bool
	}{
		{name: "empty object", in: map[string]any{}, want: false},
		{name: "non-empty object", in: map[string]any{"x": 1}, want: true},
		{name: "empty array", in: []any{}, want: false},
		{name: "non-empty array", in: []any{1}, want: true},
		{name: "empty string", in: "", want: false},
		{name: "non-empty string", in: "x", want: true},
		{name: "bool", in: true, want: false},
	}

	for _, tc := range cases {
		if got := hasNonEmptyHooks(tc.in); got != tc.want {
			t.Fatalf("%s: got %v want %v", tc.name, got, tc.want)
		}
	}
}

func setupConfigChangeTest(t *testing.T) (string, *recordedCollector) {
	t.Helper()
	home := t.TempDir()
	withHomeDir(t, home)
	collector := &recordedCollector{}
	prevPoster := newEventPoster
	newEventPoster = func() eventPoster { return collector }
	t.Cleanup(func() { newEventPoster = prevPoster })
	return home, collector
}

func runConfigChange(t *testing.T, input HookInput) ([]byte, int, string) {
	t.Helper()
	var out []byte
	var code int
	stderr := captureStderr(t, func() {
		out, code = handleConfigChange(input)
	})
	return out, code, stderr
}

func writeConfigChangeFile(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "settings.json")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func freezeHookTime(t *testing.T, unixSeconds int64) {
	t.Helper()
	prevNow := timeNow
	timeNow = func() time.Time { return time.Unix(unixSeconds, 0) }
	t.Cleanup(func() { timeNow = prevNow })
}

func assertConfigChangeEvent(t *testing.T, events []map[string]any, want map[string]any) {
	t.Helper()
	if len(events) != 1 {
		t.Fatalf("events=%#v want 1 event", events)
	}
	for key, wantValue := range want {
		if got := events[0][key]; got != wantValue {
			t.Fatalf("event[%s]=%v want %v (event=%#v)", key, got, wantValue, events[0])
		}
	}
}
