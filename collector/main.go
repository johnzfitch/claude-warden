package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
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
		debug    bool
	)

	defaultDB := defaultDBPath()

	flag.StringVar(&dbPath, "db", defaultDB, "SQLite database path")
	flag.StringVar(&otlpAddr, "otlp-addr", "127.0.0.1:4319", "OTLP HTTP listen address")
	flag.StringVar(&apiAddr, "api-addr", "127.0.0.1:9464", "API HTTP listen address")
	flag.BoolVar(&debug, "debug", false, "Enable debug logging")
	flag.Parse()

	level := slog.LevelInfo
	if debug {
		level = slog.LevelDebug
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level})))

	// Ensure DB directory exists
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		slog.Error("create db dir", "err", err)
		os.Exit(1)
	}

	store, err := OpenStore(dbPath)
	if err != nil {
		slog.Error("open database", "err", err)
		os.Exit(1)
	}
	defer store.Close()

	otlpHandler := NewOTLPHandler(store)
	apiHandler := NewAPIHandler(store)

	// OTLP server (receives traces from Claude Code)
	otlpMux := http.NewServeMux()
	otlpMux.HandleFunc("/v1/traces", otlpHandler.HandleTraces)
	// Accept metrics and logs too (store raw, extract later)
	otlpMux.HandleFunc("/v1/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "{}")
	})
	otlpMux.HandleFunc("/v1/logs", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "{}")
	})

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
		Addr:         apiAddr,
		Handler:      apiMux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 5 * time.Second,
	}

	// Start servers
	errCh := make(chan error, 2)

	go func() {
		slog.Info("OTLP server listening", "addr", otlpAddr)
		errCh <- otlpServer.ListenAndServe()
	}()

	go func() {
		slog.Info("API server listening", "addr", apiAddr)
		errCh <- apiServer.ListenAndServe()
	}()

	// Wait for shutdown signal
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-sigCh:
		slog.Info("shutting down", "signal", sig)
	case err := <-errCh:
		slog.Error("server error", "err", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	otlpServer.Shutdown(ctx)
	apiServer.Shutdown(ctx)
	store.Close()

	slog.Info("collector stopped")
}

func defaultDBPath() string {
	stateDir := os.Getenv("XDG_STATE_HOME")
	if stateDir == "" {
		home, _ := os.UserHomeDir()
		stateDir = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(stateDir, "claude-warden", "collector.db")
}
