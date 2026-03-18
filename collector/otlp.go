package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
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

// contextWindowForModel returns the context window size for known models.
// Models with [1m] suffix or explicit 1M configurations get 1M window.
func contextWindowForModel(model string) int {
	m := strings.ToLower(model)
	switch {
	case strings.Contains(m, "[1m]"), strings.Contains(m, "-1m"):
		return 1000000
	default:
		return 200000
	}
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
	// Total context = input_tokens + cache_read + cache_create.
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
		totalContext, outputTokens, cacheRead, cacheCreate,
	); err != nil {
		slog.Warn("upsert session failed", "err", err, "session", sessionID)
	}
}
