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
	// Write normal-density content (50 bytes/line, ~10000 lines = 500KB)
	if err := os.WriteFile(small, makeNormalFile(500*1024, 50), 0o644); err != nil {
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
	// Write normal-density content (50 bytes/line)
	if err := os.WriteFile(path, makeNormalFile(3*1024*1024, 50), 0o644); err != nil {
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

// --- Dense content detection tests ---

func TestReadGuardReroutesSingleLineBlob(t *testing.T) {
	_, collector := setupReadGuardTest(t)
	path := filepath.Join(t.TempDir(), "data.json")
	// 50KB single-line JSON blob (no newlines)
	blob := make([]byte, 50*1024)
	for i := range blob {
		blob[i] = 'x'
	}
	if err := os.WriteFile(path, blob, 0o644); err != nil {
		t.Fatal(err)
	}

	out, code, stderr := runReadGuard(t, HookInput{SessionID: "sid", ToolInput: mustRawJSON(t, ReadToolInput{FilePath: path})})
	if code != 0 {
		t.Fatalf("code=%d want 0 (reroute, not block)", code)
	}
	if stderr != "" {
		t.Fatalf("stderr=%q want empty (reroute does not write stderr)", stderr)
	}
	if len(out) == 0 {
		t.Fatal("out is empty, want JSON reroute")
	}

	var envelope hookEnvelope
	if err := json.Unmarshal(out, &envelope); err != nil {
		t.Fatalf("parse reroute JSON: %v", err)
	}
	if envelope.HookSpecificOutput.PermissionDecision != "allow" {
		t.Fatalf("permissionDecision=%q want allow", envelope.HookSpecificOutput.PermissionDecision)
	}
	if envelope.HookSpecificOutput.UpdatedInput == nil {
		t.Fatal("updatedInput is nil")
	}
	if envelope.HookSpecificOutput.UpdatedInput.Limit != 100 {
		t.Fatalf("limit=%d want 100", envelope.HookSpecificOutput.UpdatedInput.Limit)
	}
	if envelope.HookSpecificOutput.UpdatedInput.FilePath != path {
		t.Fatalf("file_path=%q want %q", envelope.HookSpecificOutput.UpdatedInput.FilePath, path)
	}
	if !strings.Contains(envelope.HookSpecificOutput.AdditionalContext, "Dense file") {
		t.Fatalf("additionalContext=%q want 'Dense file' substring", envelope.HookSpecificOutput.AdditionalContext)
	}

	assertReadGuardAllowedEvent(t, collector.events, path, "read_dense_reroute")
}

func TestReadGuardReroutesDenseMultilineFile(t *testing.T) {
	_, collector := setupReadGuardTest(t)
	path := filepath.Join(t.TempDir(), "records.jsonl")
	// 200KB with 10 lines = 20000 bpl
	lineLen := 20 * 1024
	var content []byte
	for i := 0; i < 10; i++ {
		line := make([]byte, lineLen)
		for j := range line {
			line[j] = 'a'
		}
		line[lineLen-1] = '\n'
		content = append(content, line...)
	}
	if err := os.WriteFile(path, content, 0o644); err != nil {
		t.Fatal(err)
	}

	out, code, _ := runReadGuard(t, HookInput{SessionID: "sid", ToolInput: mustRawJSON(t, ReadToolInput{FilePath: path})})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(out) == 0 {
		t.Fatal("out is empty, want JSON reroute")
	}

	var envelope hookEnvelope
	if err := json.Unmarshal(out, &envelope); err != nil {
		t.Fatalf("parse: %v", err)
	}
	if envelope.HookSpecificOutput.UpdatedInput == nil || envelope.HookSpecificOutput.UpdatedInput.Limit != 100 {
		t.Fatalf("expected limit=100")
	}
	assertReadGuardAllowedEvent(t, collector.events, path, "read_dense_reroute")
}

func TestReadGuardRespectsModelSetLimit(t *testing.T) {
	_, collector := setupReadGuardTest(t)
	path := filepath.Join(t.TempDir(), "data.json")
	blob := make([]byte, 50*1024)
	for i := range blob {
		blob[i] = 'x'
	}
	if err := os.WriteFile(path, blob, 0o644); err != nil {
		t.Fatal(err)
	}

	// Model already set limit=50, which is <= 100 cap -> pass through
	out, code, stderr := runReadGuard(t, HookInput{SessionID: "sid", ToolInput: mustRawJSON(t, ReadToolInput{FilePath: path, Limit: 50})})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(out) != 0 {
		t.Fatalf("out=%q want empty (model limit respected)", out)
	}
	if stderr != "" {
		t.Fatalf("stderr=%q want empty", stderr)
	}
	if len(collector.events) != 0 {
		t.Fatalf("events=%#v want none (pass through)", collector.events)
	}
}

func TestReadGuardAllowsSmallDenseFile(t *testing.T) {
	_, collector := setupReadGuardTest(t)
	path := filepath.Join(t.TempDir(), "tiny.json")
	// 4KB single-line (under 8KB threshold)
	blob := make([]byte, 4*1024)
	for i := range blob {
		blob[i] = 'z'
	}
	if err := os.WriteFile(path, blob, 0o644); err != nil {
		t.Fatal(err)
	}

	out, code, stderr := runReadGuard(t, HookInput{SessionID: "sid", ToolInput: mustRawJSON(t, ReadToolInput{FilePath: path})})
	if code != 0 || len(out) != 0 || stderr != "" {
		t.Fatalf("code=%d out=%q stderr=%q — want allow (under min bytes)", code, out, stderr)
	}
	if len(collector.events) != 0 {
		t.Fatalf("events=%#v want none", collector.events)
	}
}

func TestReadGuardAllowsNormalDensityLargeFile(t *testing.T) {
	_, collector := setupReadGuardTest(t)
	path := filepath.Join(t.TempDir(), "source.rs")
	// 500KB, 10000 lines = 50 bpl (normal source code)
	lineLen := 50
	var content []byte
	for i := 0; i < 10000; i++ {
		line := make([]byte, lineLen)
		for j := range line {
			line[j] = 'a'
		}
		line[lineLen-1] = '\n'
		content = append(content, line...)
	}
	if err := os.WriteFile(path, content, 0o644); err != nil {
		t.Fatal(err)
	}

	out, code, stderr := runReadGuard(t, HookInput{SessionID: "sid", ToolInput: mustRawJSON(t, ReadToolInput{FilePath: path})})
	if code != 0 || len(out) != 0 || stderr != "" {
		t.Fatalf("code=%d out=%q stderr=%q — want allow (normal density)", code, out, stderr)
	}
	if len(collector.events) != 0 {
		t.Fatalf("events=%#v want none", collector.events)
	}
}

func TestReadGuardPreservesExistingOffset(t *testing.T) {
	_, _ = setupReadGuardTest(t)
	path := filepath.Join(t.TempDir(), "data.json")
	blob := make([]byte, 50*1024)
	for i := range blob {
		blob[i] = 'x'
	}
	if err := os.WriteFile(path, blob, 0o644); err != nil {
		t.Fatal(err)
	}

	// Model set offset=200 but no limit -> should reroute with offset preserved
	out, code, _ := runReadGuard(t, HookInput{SessionID: "sid", ToolInput: mustRawJSON(t, ReadToolInput{FilePath: path, Offset: 200})})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}

	var envelope hookEnvelope
	if err := json.Unmarshal(out, &envelope); err != nil {
		t.Fatalf("parse: %v", err)
	}
	if envelope.HookSpecificOutput.UpdatedInput.Offset != 200 {
		t.Fatalf("offset=%d want 200", envelope.HookSpecificOutput.UpdatedInput.Offset)
	}
	if envelope.HookSpecificOutput.UpdatedInput.Limit != 100 {
		t.Fatalf("limit=%d want 100", envelope.HookSpecificOutput.UpdatedInput.Limit)
	}
}

// --- helpers ---

// makeNormalFile creates content with normal line density (lineLen bytes per line).
func makeNormalFile(totalSize, lineLen int) []byte {
	buf := make([]byte, 0, totalSize)
	for len(buf) < totalSize {
		line := make([]byte, lineLen)
		for j := range line {
			line[j] = 'a'
		}
		line[lineLen-1] = '\n'
		buf = append(buf, line...)
	}
	return buf[:totalSize]
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

func assertReadGuardAllowedEvent(t *testing.T, events []map[string]any, path, rule string) {
	t.Helper()
	if len(events) != 1 {
		t.Fatalf("events=%#v want 1 event", events)
	}
	evt := events[0]
	if evt["event_type"] != "allowed" || evt["tool"] != "Read" || evt["rule"] != rule {
		b, _ := json.Marshal(evt)
		t.Fatalf("unexpected event: %s", b)
	}
	if evt["original_cmd"] != path {
		t.Fatalf("original_cmd=%q want %q", evt["original_cmd"], path)
	}
}
