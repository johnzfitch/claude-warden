package hooks

import (
	"bytes"
	"encoding/json"
	"io"
	"testing"
	"time"
)

func TestDispatchEmptyStdin(t *testing.T) {
	var stdout bytes.Buffer
	if code := Dispatch("pre-tool-use", bytes.NewBuffer(nil), &stdout); code != 0 {
		t.Fatalf("Dispatch(empty) code = %d, want 0", code)
	}
	if stdout.Len() != 0 {
		t.Fatalf("Dispatch(empty) wrote %q, want empty", stdout.String())
	}
}

func TestDispatchUnknownHook(t *testing.T) {
	var stdout bytes.Buffer
	input := mustMarshalInput(t, HookInput{SessionID: "sid"})
	if code := Dispatch("unknown-hook", input, &stdout); code != 0 {
		t.Fatalf("Dispatch(unknown) code = %d, want 0", code)
	}
	if stdout.Len() != 0 {
		t.Fatalf("Dispatch(unknown) wrote %q, want empty", stdout.String())
	}
}

func TestDispatchInvalidJSON(t *testing.T) {
	var stdout bytes.Buffer
	if code := Dispatch("pre-tool-use", bytes.NewBufferString("{"), &stdout); code != 0 {
		t.Fatalf("Dispatch(invalid) code = %d, want 0", code)
	}
	if stdout.Len() != 0 {
		t.Fatalf("Dispatch(invalid) wrote %q, want empty", stdout.String())
	}
}

func TestDispatchRoutesToHandler(t *testing.T) {
	prev := hookHandlers
	hookHandlers = map[string]hookHandler{
		"test-hook": func(input HookInput) ([]byte, int) {
			if input.SessionID != "sid" {
				t.Fatalf("handler saw session %q, want sid", input.SessionID)
			}
			return []byte(`{"ok":true}`), 7
		},
	}
	defer func() { hookHandlers = prev }()

	var stdout bytes.Buffer
	code := Dispatch("test-hook", mustMarshalInput(t, HookInput{SessionID: "sid"}), &stdout)
	if code != 7 {
		t.Fatalf("Dispatch(route) code = %d, want 7", code)
	}
	if stdout.String() != `{"ok":true}` {
		t.Fatalf("Dispatch(route) wrote %q", stdout.String())
	}
}

func TestDispatchReadTimeout(t *testing.T) {
	prevTimeout := dispatchReadTimeout
	dispatchReadTimeout = 20 * time.Millisecond
	defer func() { dispatchReadTimeout = prevTimeout }()

	r := &blockingReader{release: make(chan struct{})}
	var stdout bytes.Buffer
	start := time.Now()
	code := Dispatch("test-hook", r, &stdout)
	close(r.release)
	if code != 0 {
		t.Fatalf("Dispatch(timeout) code = %d, want 0", code)
	}
	if elapsed := time.Since(start); elapsed > 250*time.Millisecond {
		t.Fatalf("Dispatch(timeout) took %v", elapsed)
	}
}

type blockingReader struct {
	release chan struct{}
}

func (r *blockingReader) Read(_ []byte) (int, error) {
	<-r.release
	return 0, io.EOF
}

func mustMarshalInput(t *testing.T, input HookInput) io.Reader {
	t.Helper()
	b, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	return bytes.NewReader(b)
}
