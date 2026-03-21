package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// OTLP JSON types -- minimal subset for trace ingestion.

type ExportTraceRequest struct {
	ResourceSpans []ResourceSpans `json:"resourceSpans"`
}

type ResourceSpans struct {
	Resource   Resource     `json:"resource"`
	ScopeSpans []ScopeSpans `json:"scopeSpans"`
}

type Resource struct {
	Attributes []KeyValue `json:"attributes"`
}

type ScopeSpans struct {
	Scope Scope  `json:"scope"`
	Spans []Span `json:"spans"`
}

type Scope struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

type Span struct {
	TraceID      string     `json:"traceId"`
	SpanID       string     `json:"spanId"`
	ParentSpanID string     `json:"parentSpanId"`
	Name         string     `json:"name"`
	Kind         int        `json:"kind"`
	StartTimeNS  string     `json:"startTimeUnixNano"`
	EndTimeNS    string     `json:"endTimeUnixNano"`
	Attributes   []KeyValue `json:"attributes"`
	Status       SpanStatus `json:"status"`
}

type SpanStatus struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type KeyValue struct {
	Key   string         `json:"key"`
	Value AttributeValue `json:"value"`
}

type AttributeValue struct {
	StringValue string  `json:"stringValue,omitempty"`
	IntValue    string  `json:"intValue,omitempty"`
	BoolValue   bool    `json:"boolValue,omitempty"`
	DoubleValue float64 `json:"doubleValue,omitempty"`
}

type ExportMetricsRequest struct {
	ResourceMetrics []ResourceMetrics `json:"resourceMetrics"`
}

type ResourceMetrics struct {
	Resource     Resource       `json:"resource"`
	ScopeMetrics []ScopeMetrics `json:"scopeMetrics"`
}

type ScopeMetrics struct {
	Scope   Scope    `json:"scope"`
	Metrics []Metric `json:"metrics"`
}

type Metric struct {
	Name        string      `json:"name"`
	Description string      `json:"description"`
	Unit        string      `json:"unit"`
	Sum         *MetricSum  `json:"sum,omitempty"`
	Gauge       *MetricData `json:"gauge,omitempty"`
}

type MetricSum struct {
	DataPoints []NumberDataPoint `json:"dataPoints"`
}

type MetricData struct {
	DataPoints []NumberDataPoint `json:"dataPoints"`
}

type NumberDataPoint struct {
	Attributes      []KeyValue `json:"attributes"`
	StartTimeUnixNS string     `json:"startTimeUnixNano,omitempty"`
	TimeUnixNS      string     `json:"timeUnixNano,omitempty"`
	AsInt           string     `json:"asInt,omitempty"`
	AsDouble        float64    `json:"asDouble,omitempty"`
}

func (kv KeyValue) StringVal() string {
	return kv.Value.StringValue
}

func (kv KeyValue) IntVal() int {
	if kv.Value.IntValue == "" {
		return 0
	}
	v, _ := strconv.Atoi(kv.Value.IntValue)
	return v
}

func (kv KeyValue) BoolVal() bool {
	return kv.Value.BoolValue
}

func (dp NumberDataPoint) FloatVal() float64 {
	if dp.AsInt != "" {
		v, _ := strconv.ParseFloat(dp.AsInt, 64)
		return v
	}
	return dp.AsDouble
}

// contextWindowForModel returns the context window size.
// Priority: CLAUDE_CODE_AUTO_COMPACT_WINDOW env > model suffix detection > default 200k.
// This is inherently a guess — Claude Code doesn't export context_window in OTEL spans.
// The env var override is the only reliable source when context windows change.
func contextWindowForModel(model string) int {
	if envWin := os.Getenv("CLAUDE_CODE_AUTO_COMPACT_WINDOW"); envWin != "" {
		if v, err := strconv.Atoi(envWin); err == nil && v > 0 {
			return v
		}
	}
	// 1M context detection
	if os.Getenv("CLAUDE_CODE_DISABLE_1M_CONTEXT") != "1" {
		m := strings.ToLower(model)
		if strings.Contains(m, "[1m]") || strings.Contains(m, "-1m") {
			return 1000000
		}
	}
	return 200000
}

// attrMap converts a slice of KeyValue into a lookup map.
func attrMap(attrs []KeyValue) map[string]KeyValue {
	m := make(map[string]KeyValue, len(attrs))
	for _, kv := range attrs {
		m[kv.Key] = kv
	}
	return m
}

// OTLPHandler processes incoming OTLP trace exports.
type OTLPHandler struct {
	store *Store
}

func NewOTLPHandler(store *Store) *OTLPHandler {
	return &OTLPHandler{store: store}
}

// HandleTraces is the HTTP handler for POST /v1/traces.
func (h *OTLPHandler) HandleTraces(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	ct := r.Header.Get("Content-Type")
	if strings.Contains(ct, "protobuf") {
		// Phase 1: JSON only. Tell the sender to use JSON.
		http.Error(w, "protobuf not supported; set OTEL_EXPORTER_OTLP_PROTOCOL=http/json", http.StatusUnsupportedMediaType)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 10<<20)) // 10MB limit
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}

	var req ExportTraceRequest
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "parse json: "+err.Error(), http.StatusBadRequest)
		return
	}

	ctx := r.Context()
	spanCount, llmCount := h.processSpans(ctx, &req)

	slog.Debug("traces received", "spans", spanCount, "llm_requests", llmCount)

	// OTLP success response
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "{}")
}

func (h *OTLPHandler) HandleMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	ct := r.Header.Get("Content-Type")
	if strings.Contains(ct, "protobuf") {
		http.Error(w, "protobuf not supported; set OTEL_EXPORTER_OTLP_PROTOCOL=http/json", http.StatusUnsupportedMediaType)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 10<<20))
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}

	var req ExportMetricsRequest
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "parse json: "+err.Error(), http.StatusBadRequest)
		return
	}

	points, err := h.processMetrics(r.Context(), &req)
	if err != nil {
		slog.Warn("metrics processing failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if err := forwardOTLP(r.Context(), "/v1/metrics", ct, body); err != nil {
		slog.Debug("metrics forward skipped", "err", err)
	}

	slog.Debug("metrics received", "datapoints", points)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "{}")
}

func (h *OTLPHandler) HandleLogs(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	ct := r.Header.Get("Content-Type")
	if strings.Contains(ct, "protobuf") {
		http.Error(w, "protobuf not supported; set OTEL_EXPORTER_OTLP_PROTOCOL=http/json", http.StatusUnsupportedMediaType)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 10<<20))
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}

	if len(body) > 0 {
		if err := forwardOTLP(r.Context(), "/v1/logs", ct, body); err != nil {
			slog.Debug("logs forward skipped", "err", err)
		}
	}

	slog.Debug("logs received", "bytes", len(body))
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "{}")
}

func metricDataPoints(metric Metric) []NumberDataPoint {
	if metric.Sum != nil {
		return metric.Sum.DataPoints
	}
	if metric.Gauge != nil {
		return metric.Gauge.DataPoints
	}
	return nil
}

func (h *OTLPHandler) processMetrics(ctx context.Context, req *ExportMetricsRequest) (int, error) {
	points := 0

	for _, rm := range req.ResourceMetrics {
		resAttrs := attrMap(rm.Resource.Attributes)
		resourceSessionID := ""
		if kv, ok := resAttrs["session.id"]; ok {
			resourceSessionID = kv.StringVal()
		}

		for _, sm := range rm.ScopeMetrics {
			for _, metric := range sm.Metrics {
				dataPoints := metricDataPoints(metric)
				points += len(dataPoints)

				if metric.Name != "claude_code_cost_usage_USD_total" {
					continue
				}

				for _, dp := range dataPoints {
					dpAttrs := attrMap(dp.Attributes)
					sessionID := resourceSessionID
					if kv, ok := dpAttrs["session.id"]; ok && kv.StringVal() != "" {
						sessionID = kv.StringVal()
					}
					if sessionID == "" {
						continue
					}

					model := ""
					if kv, ok := dpAttrs["model"]; ok {
						model = kv.StringVal()
					}
					if err := h.store.UpsertSessionCost(ctx, sessionID, model, dp.FloatVal()); err != nil {
						return points, err
					}
				}
			}
		}
	}

	return points, nil
}

func forwardOTLPEndpoint() string {
	if endpoint := strings.TrimRight(os.Getenv("WARDEN_OTLP_FORWARD_ENDPOINT"), "/"); endpoint != "" {
		return endpoint
	}
	return "http://127.0.0.1:4318"
}

func forwardOTLP(ctx context.Context, path, contentType string, body []byte) error {
	endpoint := forwardOTLPEndpoint()
	if endpoint == "" {
		return nil
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	} else {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := (&http.Client{Timeout: 1500 * time.Millisecond}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))

	if resp.StatusCode >= http.StatusMultipleChoices {
		return fmt.Errorf("forward %s returned %s", path, resp.Status)
	}
	return nil
}

func (h *OTLPHandler) processSpans(ctx context.Context, req *ExportTraceRequest) (total, llmRequests int) {
	for _, rs := range req.ResourceSpans {
		resAttrs := attrMap(rs.Resource.Attributes)
		sessionID := ""
		if kv, ok := resAttrs["session.id"]; ok {
			sessionID = kv.StringVal()
		}

		resourceJSON, _ := json.Marshal(rs.Resource.Attributes)

		for _, ss := range rs.ScopeSpans {
			for _, span := range ss.Spans {
				total++

				startNS, _ := strconv.ParseInt(span.StartTimeNS, 10, 64)
				endNS, _ := strconv.ParseInt(span.EndTimeNS, 10, 64)
				durationMS := (endNS - startNS) / 1_000_000

				attrsJSON, _ := json.Marshal(span.Attributes)

				inserted, err := h.store.InsertSpan(ctx,
					span.TraceID, span.SpanID, span.ParentSpanID,
					sessionID, span.Name, span.Kind,
					startNS, endNS, durationMS,
					string(attrsJSON), string(resourceJSON),
				)
				if err != nil {
					slog.Warn("insert span failed", "err", err, "name", span.Name)
					continue
				}
				if !inserted {
					continue // duplicate span (OTLP retry), skip accumulation
				}

				// Extract llm_request spans to update session context
				if span.Name == "claude_code.llm_request" {
					llmRequests++
					h.processLLMRequest(ctx, sessionID, span, resAttrs)
				}

				// Track tool spans — accumulate result_tokens for context estimation
				if span.Name == "claude_code.tool" && sessionID != "" {
					resultTokens := 0
					toolAttrs := attrMap(span.Attributes)
					if kv, ok := toolAttrs["result_tokens"]; ok {
						resultTokens = kv.IntVal()
					}
					if err := h.store.AccumulateToolTokens(ctx, sessionID, resultTokens); err != nil {
						slog.Warn("accumulate tool tokens failed", "err", err)
					}
				}
			}
		}
	}
	return
}

func (h *OTLPHandler) processLLMRequest(ctx context.Context, sessionID string, span Span, resAttrs map[string]KeyValue) {
	if sessionID == "" {
		return
	}

	attrs := attrMap(span.Attributes)

	model := ""
	if kv, ok := attrs["model"]; ok {
		model = kv.StringVal()
	}

	inputTokens := 0
	if kv, ok := attrs["input_tokens"]; ok {
		inputTokens = kv.IntVal()
	}

	outputTokens := 0
	if kv, ok := attrs["output_tokens"]; ok {
		outputTokens = kv.IntVal()
	}

	cacheRead := 0
	if kv, ok := attrs["cache_read_tokens"]; ok {
		cacheRead = kv.IntVal()
	}

	cacheCreate := 0
	if kv, ok := attrs["cache_creation_tokens"]; ok {
		cacheCreate = kv.IntVal()
	}

	// input_tokens from the API is the non-cached new input.
	// Store raw input_tokens separately so the stacked context gauge
	// can show input, cache_read, and cache_create as distinct segments.
	totalContext := inputTokens + cacheRead + cacheCreate

	contextWindow := contextWindowForModel(model)

	slog.Info("llm_request",
		"session", sessionID,
		"model", model,
		"context_tokens", totalContext,
		"input", inputTokens,
		"output", outputTokens,
		"cache_read", cacheRead,
		"cache_create", cacheCreate,
		"pct", fmt.Sprintf("%.1f%%", float64(totalContext)/float64(contextWindow)*100),
	)

	if err := h.store.UpsertSessionFromSpan(ctx,
		sessionID, model, contextWindow,
		inputTokens, outputTokens, cacheRead, cacheCreate,
	); err != nil {
		slog.Warn("upsert session failed", "err", err, "session", sessionID)
	}
}
