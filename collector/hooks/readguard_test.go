package hooks

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadGuardBlocksBundledPatterns(t *testing.T) {
	_, collector := setupReadGuardTest(t)
	cases := []string{
		"/project/node_modules/express/index.js",
		"/project/dist/bundle.js",
		"/project/build/static/main.chunk.js",
		"/project/app.min.js",
		"/project/package-lock.json",
		"/project/yarn.lock",
		"/project/Cargo.lock",
		"/project/go.sum",
		"/project/vendor/lib.js",
		"/project/__generated__/types.ts",
	}

	for _, path := range cases {
		t.Run(path, func(t *testing.T) {
			collector.events = nil
			out, code, stderr := runReadGuard(t, HookInput{SessionID: "sid", ToolInput: mustRawJSON(t, ReadToolInput{FilePath: path})})
			if code != 2 {
				t.Fatalf("code=%d want 2", code)
			}
			if len(out) != 0 {
				t.Fatalf("out=%q want empty", out)
			}
			want := "Blocked: '" + path + "' is a bundled/generated file; find the source"
			if strings.TrimSpace(stderr) != want {
				t.Fatalf("stderr=%q want %q", strings.TrimSpace(stderr), want)
			}
			assertReadGuardEvent(t, collector.events, path, "read_bundled", 8000)
		})
	}
}

func TestReadGuardBlocksOversizeAndUsesDefaultThreshold(t *testing.T) {
	_, collector := setupReadGuardTest(t)
	path := filepath.Join(t.TempDir(), "dir with spaces", "big file.txt")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, 3*1024*1024), 0o644); err != nil {
		t.Fatal(err)
	}

	out, code, stderr := runReadGuard(t, HookInput{SessionID: "sid", ToolInput: mustRawJSON(t, ReadToolInput{FilePath: path})})
	if code != 2 {
		t.Fatalf("code=%d want 2", code)
	}
	if len(out) != 0 {
		t.Fatalf("out=%q want empty", out)
	}
	want := "Blocked: '" + path + "' is 3.0MB (max 2MB)"
	if strings.TrimSpace(stderr) != want {
		t.Fatalf("stderr=%q want %q", strings.TrimSpace(stderr), want)
	}
	assertReadGuardEvent(t, collector.events, path, "read_oversize", 25000)
}

func TestReadGuardAllowsSpecifiedNonTriggers(t *testing.T) {
	_, collector := setupReadGuardTest(t)
	small := filepath.Join(t.TempDir(), "small.txt")
	if err := os.WriteFile(small, make([]byte, 500*1024), 0o644); err != nil {
		t.Fatal(err)
	}

	cases := []HookInput{
		{ToolInput: mustRawJSON(t, ReadToolInput{FilePath: "/project/src/main.js"})},
		{ToolInput: mustRawJSON(t, ReadToolInput{FilePath: "/project/package.json"})},
		{ToolInput: mustRawJSON(t, ReadToolInput{FilePath: "/project/go.mod"})},
		{ToolInput: mustRawJSON(t, ReadToolInput{FilePath: "/project/Cargo.toml"})},
		{ToolInput: mustRawJSON(t, ReadToolInput{FilePath: small})},
		{ToolInput: mustRawJSON(t, ReadToolInput{FilePath: ""})},
		{ToolInput: mustRawJSON(t, ReadToolInput{FilePath: filepath.Join(t.TempDir(), "missing.txt")})},
	}

	for _, input := range cases {
		collector.events = nil
		out, code, stderr := runReadGuard(t, input)
		if code != 0 {
			t.Fatalf("input=%s code=%d want 0", input.ToolInput, code)
		}
		if len(out) != 0 {
			t.Fatalf("input=%s out=%q want empty", input.ToolInput, out)
		}
		if stderr != "" {
			t.Fatalf("input=%s stderr=%q want empty", input.ToolInput, stderr)
		}
		if len(collector.events) != 0 {
			t.Fatalf("input=%s events=%#v want none", input.ToolInput, collector.events)
		}
	}
}

func TestReadGuardEdgeCases(t *testing.T) {
	_, collector := setupReadGuardTest(t)

	t.Run("relative path matches bundled regex", func(t *testing.T) {
		collector.events = nil
		_, code, stderr := runReadGuard(t, HookInput{ToolInput: mustRawJSON(t, ReadToolInput{FilePath: "node_modules/express/index.js"})})
		if code != 2 {
			t.Fatalf("code=%d want 2", code)
		}
		if !strings.Contains(stderr, "bundled/generated file") {
			t.Fatalf("stderr=%q", stderr)
		}
		assertReadGuardEvent(t, collector.events, "node_modules/express/index.js", "read_bundled", 8000)
	})

	t.Run("directory skips size check", func(t *testing.T) {
		collector.events = nil
		dir := filepath.Join(t.TempDir(), "some-dir")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		out, code, stderr := runReadGuard(t, HookInput{ToolInput: mustRawJSON(t, ReadToolInput{FilePath: dir})})
		if code != 0 || len(out) != 0 || stderr != "" {
			t.Fatalf("code=%d out=%q stderr=%q", code, out, stderr)
		}
		if len(collector.events) != 0 {
			t.Fatalf("events=%#v want none", collector.events)
		}
	})
}

func TestReadGuardRespectsConfiguredMaxSizeMB(t *testing.T) {
	_, collector := setupReadGuardTest(t)
	unsetEnv(t, "WARDEN_READ_GUARD_MAX_MB")
	if err := os.Setenv("WARDEN_READ_GUARD_MAX_MB", "4"); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "bigger.txt")
	if err := os.WriteFile(path, make([]byte, 3*1024*1024), 0o644); err != nil {
		t.Fatal(err)
	}

	out, code, stderr := runReadGuard(t, HookInput{ToolInput: mustRawJSON(t, ReadToolInput{FilePath: path})})
	if code != 0 || len(out) != 0 || stderr != "" {
		t.Fatalf("code=%d out=%q stderr=%q", code, out, stderr)
	}
	if len(collector.events) != 0 {
		t.Fatalf("events=%#v want none", collector.events)
	}
}

func setupReadGuardTest(t *testing.T) (string, *recordedCollector) {
	t.Helper()
	home := t.TempDir()
	withHomeDir(t, home)
	collector := &recordedCollector{}
	prevPoster := newEventPoster
	newEventPoster = func() eventPoster { return collector }
	t.Cleanup(func() { newEventPoster = prevPoster })
	return home, collector
}

func runReadGuard(t *testing.T, input HookInput) ([]byte, int, string) {
	t.Helper()
	var out []byte
	var code int
	stderr := captureStderr(t, func() {
		out, code = handleReadGuard(input)
	})
	return out, code, stderr
}

func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	prev := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stderr = w
	defer func() { os.Stderr = prev }()

	fn()
	_ = w.Close()
	b, err := io.ReadAll(r)
	_ = r.Close()
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func assertReadGuardEvent(t *testing.T, events []map[string]any, path, rule string, tokensSaved int) {
	t.Helper()
	if len(events) != 1 {
		t.Fatalf("events=%#v want 1 event", events)
	}
	evt := events[0]
	if evt["event_type"] != "blocked" || evt["tool"] != "Read" || evt["rule"] != rule || evt["tokens_saved"] != float64(tokensSaved) {
		b, _ := json.Marshal(evt)
		t.Fatalf("unexpected event: %s", b)
	}
	if evt["original_cmd"] != path {
		t.Fatalf("original_cmd=%q want %q", evt["original_cmd"], path)
	}
}
