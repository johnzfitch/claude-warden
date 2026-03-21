package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func main() {
	var (
		dbPath   string
		otlpAddr string
		apiAddr  string
		apiTCP   bool
		debug    bool
	)

	defaultDB := defaultDBPath()
	defaultSock := defaultSocketPath()

	flag.StringVar(&dbPath, "db", defaultDB, "SQLite database path")
	flag.StringVar(&otlpAddr, "otlp-addr", "127.0.0.1:4319", "OTLP HTTP listen address (TCP)")
	flag.StringVar(&apiAddr, "api-addr", defaultSock, "API listen address (UDS path or host:port with -tcp)")
	flag.BoolVar(&apiTCP, "tcp", false, "Use TCP for API server instead of Unix socket")
	flag.BoolVar(&debug, "debug", false, "Enable debug logging")
	flag.Parse()

	level := slog.LevelInfo
	if debug {
		level = slog.LevelDebug
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level})))

	// Ensure DB directory exists
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o700); err != nil {
		slog.Error("create db dir", "err", err)
		os.Exit(1)
	}

	store, err := OpenStore(dbPath)
	if err != nil {
		slog.Error("open database", "err", err)
		os.Exit(1)
	}
	defer store.Close()

	// Write pidfile for cheap liveness checks from hooks
	pidFile := filepath.Join(filepath.Dir(dbPath), "collector.pid")
	if err := os.WriteFile(pidFile, []byte(fmt.Sprintf("%d", os.Getpid())), 0o600); err != nil {
		slog.Warn("write pidfile", "err", err)
	}
	defer os.Remove(pidFile)

	otlpHandler := NewOTLPHandler(store)
	apiHandler := NewAPIHandler(store)

	// OTLP server (receives traces from Claude Code)
	otlpMux := http.NewServeMux()
	otlpMux.HandleFunc("/v1/traces", otlpHandler.HandleTraces)
	otlpMux.HandleFunc("/v1/metrics", otlpHandler.HandleMetrics)
	otlpMux.HandleFunc("/v1/logs", otlpHandler.HandleLogs)

	otlpServer := &http.Server{
		Addr:         otlpAddr,
		Handler:      otlpMux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	// API server (queried by statusline, humans, dashboards)
	apiMux := http.NewServeMux()
	apiMux.HandleFunc("/healthz", apiHandler.HandleHealthz)
	apiMux.HandleFunc("/v1/sessions/", func(w http.ResponseWriter, r *http.Request) {
		// Route /v1/sessions/{id}/context vs /v1/sessions/
		path := strings.TrimPrefix(r.URL.Path, "/v1/sessions/")
		if path == "" {
			apiHandler.HandleSessions(w, r)
		} else if strings.HasSuffix(path, "/context") {
			apiHandler.HandleSessionContext(w, r)
		} else {
			http.NotFound(w, r)
		}
	})
	// Exact /v1/sessions without trailing slash
	apiMux.HandleFunc("/v1/sessions", apiHandler.HandleSessions)
	apiMux.HandleFunc("/v1/ingest/hook", apiHandler.HandleHookIngest)

	apiServer := &http.Server{
		Handler:      apiMux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 5 * time.Second,
	}

	// Start servers
	errCh := make(chan error, 2)

	go func() {
		slog.Info("OTLP server listening", "addr", otlpAddr)
		if err := otlpServer.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	// API server: UDS by default, TCP with -tcp flag
	go func() {
		var ln net.Listener
		var err error

		if apiTCP {
			slog.Info("API server listening", "addr", apiAddr, "transport", "tcp")
			ln, err = net.Listen("tcp", apiAddr)
		} else {
			// Remove stale socket file
			os.Remove(apiAddr)
			slog.Info("API server listening", "socket", apiAddr, "transport", "unix")
			ln, err = net.Listen("unix", apiAddr)
			if err == nil {
				// Secure socket: owner read/write only
				os.Chmod(apiAddr, 0o600)
			}
		}

		if err != nil {
			errCh <- err
			return
		}

		if err := apiServer.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	// Wait for shutdown signal or fatal server error
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-sigCh:
		slog.Info("shutting down", "signal", sig)
	case err := <-errCh:
		slog.Error("server error, shutting down", "err", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	otlpServer.Shutdown(ctx)
	apiServer.Shutdown(ctx)

	// Clean up UDS socket file
	if !apiTCP {
		os.Remove(apiAddr)
	}

	slog.Info("collector stopped")
}

func defaultDBPath() string {
	return filepath.Join(stateDir(), "collector.db")
}

func defaultSocketPath() string {
	return filepath.Join(stateDir(), "collector.sock")
}

func stateDir() string {
	dir := os.Getenv("XDG_STATE_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(dir, "claude-warden")
}
