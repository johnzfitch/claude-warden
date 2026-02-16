#!/usr/bin/env bash
# otel-trace.sh -- Lightweight OTLP/HTTP trace span emitter for warden hooks
# Emits a single span per tool call to the OTEL collector via curl.
# Designed to be sourced and called fire-and-forget from post-tool-use.

OTEL_TRACE_ENDPOINT="${OTEL_TRACE_ENDPOINT:-http://localhost:4318/v1/traces}"

# Derive a deterministic 32-hex-char trace ID from session ID
# Uses md5sum for speed (not cryptographic -- just needs uniqueness)
_warden_trace_id_from_session() {
    local session_id="$1"
    printf '%s' "warden-trace-${session_id}" | md5sum | cut -c1-32
}

# Generate a random 16-hex-char span ID
_warden_random_span_id() {
    head -c8 /dev/urandom | xxd -p
}

# Derive a deterministic parent span ID from session (root span)
_warden_root_span_id() {
    local session_id="$1"
    printf '%s' "warden-root-${session_id}" | md5sum | cut -c1-16
}

# Emit a single OTLP trace span for a tool call
# Usage: _warden_emit_trace_span TOOL_NAME START_NS END_NS SESSION_ID COMMAND OUTPUT_BYTES
_warden_emit_trace_span() {
    local tool_name="$1"
    local start_ns="$2"
    local end_ns="$3"
    local session_id="$4"
    local command="${5:-}"
    local output_bytes="${6:-0}"

    # Require curl
    command -v curl &>/dev/null || return 0

    # Require valid timestamps
    [[ "$start_ns" =~ ^[0-9]+$ && "$end_ns" =~ ^[0-9]+$ ]] || return 0

    local trace_id
    trace_id=$(_warden_trace_id_from_session "$session_id")
    local span_id
    span_id=$(_warden_random_span_id)
    local parent_span_id
    parent_span_id=$(_warden_root_span_id "$session_id")

    # Sanitize command for JSON embedding (first 200 chars)
    local cmd_safe="${command:0:200}"
    cmd_safe="${cmd_safe//$'\n'/ }"
    cmd_safe="${cmd_safe//\\/\\\\}"
    cmd_safe="${cmd_safe//\"/\\\"}"
    cmd_safe="${cmd_safe//$'\t'/ }"

    # Build OTLP protobuf-JSON payload (ExportTraceServiceRequest)
    local payload
    payload=$(cat <<ENDJSON
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "claude-warden"}},
        {"key": "session.id", "value": {"stringValue": "${session_id}"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name": "warden-hooks", "version": "1.0.0"},
      "spans": [{
        "traceId": "${trace_id}",
        "spanId": "${span_id}",
        "parentSpanId": "${parent_span_id}",
        "name": "tool:${tool_name}",
        "kind": 3,
        "startTimeUnixNano": "${start_ns}",
        "endTimeUnixNano": "${end_ns}",
        "attributes": [
          {"key": "tool.name", "value": {"stringValue": "${tool_name}"}},
          {"key": "tool.command", "value": {"stringValue": "${cmd_safe}"}},
          {"key": "tool.output_bytes", "value": {"intValue": "${output_bytes}"}},
          {"key": "tool.duration_ms", "value": {"intValue": "$(( (end_ns - start_ns) / 1000000 ))"}}
        ],
        "status": {"code": 1}
      }]
    }]
  }]
}
ENDJSON
)

    # Fire-and-forget POST to OTEL collector
    curl -s -o /dev/null \
        --max-time 2 \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$OTEL_TRACE_ENDPOINT" 2>/dev/null || true
}
