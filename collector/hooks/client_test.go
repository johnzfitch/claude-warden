package hooks

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestNewCollectorClientSocketPath(t *testing.T) {
	state := t.TempDir()
	prev := os.Getenv("XDG_STATE_HOME")
	if err := os.Setenv("XDG_STATE_HOME", state); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if prev == "" {
			_ = os.Unsetenv("XDG_STATE_HOME")
		} else {
			_ = os.Setenv("XDG_STATE_HOME", prev)
		}
	}()

	client := NewCollectorClient()
	want := filepath.Join(state, "claude-warden", "collector.sock")
	if client.socketPath != want {
		t.Fatalf("socketPath = %q, want %q", client.socketPath, want)
	}
	if client.httpClient == nil || client.httpClient.Timeout != 100*time.Millisecond {
		t.Fatalf("http client timeout = %v, want 100ms", client.httpClient.Timeout)
	}
}

func TestCollectorClientPostEvent(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "collector.sock")
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		skipIfUnixSocketUnavailable(t, err)
		t.Fatal(err)
	}
	defer func() {
		_ = ln.Close()
		_ = os.Remove(socketPath)
	}()

	received := make(chan []byte, 1)
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		_ = r.Body.Close()
		received <- body
		w.WriteHeader(http.StatusNoContent)
	})}
	defer server.Close()
	go server.Serve(ln)

	client := newTestCollectorClient(socketPath)
	payload := []byte(`{"event_type":"test"}`)
	client.PostEvent(payload)

	select {
	case got := <-received:
		if !bytes.Equal(got, payload) {
			t.Fatalf("received %s, want %s", got, payload)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for payload")
	}
}

func TestCollectorClientPostEventNoSocket(t *testing.T) {
	client := newTestCollectorClient(filepath.Join(t.TempDir(), "missing.sock"))
	client.PostEvent([]byte(`{"event_type":"test"}`))
	time.Sleep(50 * time.Millisecond)
}

func TestCollectorClientPostEventUnreachableSocket(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "collector.sock")
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		skipIfUnixSocketUnavailable(t, err)
		t.Fatal(err)
	}
	_ = ln.Close()
	defer os.Remove(socketPath)

	client := newTestCollectorClient(socketPath)
	start := time.Now()
	client.PostEvent([]byte(`{"event_type":"test"}`))
	if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
		t.Fatalf("PostEvent blocked for %v", elapsed)
	}
	time.Sleep(150 * time.Millisecond)
}

func newTestCollectorClient(socketPath string) *CollectorClient {
	return &CollectorClient{
		socketPath: socketPath,
		httpClient: &http.Client{
			Timeout: 100 * time.Millisecond,
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					var d net.Dialer
					return d.DialContext(ctx, "unix", socketPath)
				},
			},
		},
	}
}

func skipIfUnixSocketUnavailable(t *testing.T, err error) {
	t.Helper()
	if errors.Is(err, syscall.EPERM) || errors.Is(err, syscall.ENOTSUP) || errors.Is(err, syscall.EACCES) {
		t.Skipf("unix sockets unavailable in sandbox: %v", err)
	}
}
