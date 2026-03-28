package hooks

import (
	"bytes"
	"context"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

type CollectorClient struct {
	socketPath string
	httpClient *http.Client
}

func NewCollectorClient() *CollectorClient {
	socketPath := filepath.Join(stateDir(), "collector.sock")
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

func (c *CollectorClient) PostEvent(payload []byte) {
	if c == nil || c.httpClient == nil || c.socketPath == "" {
		return
	}

	payload = append([]byte(nil), payload...)
	go func() {
		if _, err := os.Stat(c.socketPath); err != nil {
			return
		}

		req, err := http.NewRequest(http.MethodPost, "http://localhost/v1/ingest/hook", bytes.NewReader(payload))
		if err != nil {
			return
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := c.httpClient.Do(req)
		if err != nil {
			return
		}
		_ = resp.Body.Close()
	}()
}

func stateDir() string {
	if dir := os.Getenv("XDG_STATE_HOME"); dir != "" {
		return filepath.Join(dir, "claude-warden")
	}
	return filepath.Join(homeDir(), ".local", "state", "claude-warden")
}
