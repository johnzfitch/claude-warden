#!/usr/bin/env bash
# Smoke test for warden-collector
set -euo pipefail

DB="/tmp/warden-smoke-test.db"
BINARY="./warden-collector"
cleanup() { kill "$PID" 2>/dev/null; rm -f "$DB" "$DB-wal" "$DB-shm"; }
trap cleanup EXIT

OTLP_PORT=14318
API_PORT=19464

"$BINARY" -db "$DB" -debug -otlp-addr "127.0.0.1:$OTLP_PORT" -api-addr "127.0.0.1:$API_PORT" &
PID=$!
sleep 1

echo "=== healthz ==="
curl -sf "http://127.0.0.1:$API_PORT/healthz" | jq .

echo "=== empty sessions ==="
curl -sf http://127.0.0.1:$API_PORT/v1/sessions | jq .

echo "=== send llm_request + tool span ==="
curl -sf -X POST http://127.0.0.1:$OTLP_PORT/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{
    "resourceSpans": [{
      "resource": {
        "attributes": [
          {"key": "session.id", "value": {"stringValue": "test-001"}},
          {"key": "service.name", "value": {"stringValue": "claude-code"}}
        ]
      },
      "scopeSpans": [{
        "scope": {"name": "com.anthropic.claude_code"},
        "spans": [
          {
            "traceId": "aaaa0000bbbb1111cccc2222dddd3333",
            "spanId": "1111222233334444",
            "name": "claude_code.llm_request",
            "kind": 3,
            "startTimeUnixNano": "1710000000000000000",
            "endTimeUnixNano": "1710000002000000000",
            "attributes": [
              {"key": "model", "value": {"stringValue": "claude-opus-4-6"}},
              {"key": "input_tokens", "value": {"intValue": "500"}},
              {"key": "output_tokens", "value": {"intValue": "1200"}},
              {"key": "cache_read_tokens", "value": {"intValue": "150000"}},
              {"key": "cache_creation_tokens", "value": {"intValue": "25000"}}
            ],
            "status": {"code": 0}
          },
          {
            "traceId": "aaaa0000bbbb1111cccc2222dddd3333",
            "spanId": "5555666677778888",
            "parentSpanId": "1111222233334444",
            "name": "claude_code.tool",
            "kind": 3,
            "startTimeUnixNano": "1710000002000000000",
            "endTimeUnixNano": "1710000003000000000",
            "attributes": [
              {"key": "tool_name", "value": {"stringValue": "Read"}},
              {"key": "result_tokens", "value": {"intValue": "3500"}}
            ],
            "status": {"code": 0}
          }
        ]
      }]
    }]
  }' && echo " OK"

echo "=== session context (should show 175500 input + 3500 pending) ==="
curl -sf http://127.0.0.1:$API_PORT/v1/sessions/test-001/context | jq .

echo "=== send 2nd tool span (8000 more tokens) ==="
curl -sf -X POST http://127.0.0.1:$OTLP_PORT/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{
    "resourceSpans": [{
      "resource": {
        "attributes": [
          {"key": "session.id", "value": {"stringValue": "test-001"}}
        ]
      },
      "scopeSpans": [{
        "scope": {"name": "com.anthropic.claude_code"},
        "spans": [{
          "traceId": "aaaa0000bbbb1111cccc2222dddd4444",
          "spanId": "9999aaaabbbbcccc",
          "name": "claude_code.tool",
          "kind": 3,
          "startTimeUnixNano": "1710000004000000000",
          "endTimeUnixNano": "1710000005000000000",
          "attributes": [
            {"key": "tool_name", "value": {"stringValue": "Bash"}},
            {"key": "result_tokens", "value": {"intValue": "8000"}}
          ],
          "status": {"code": 0}
        }]
      }]
    }]
  }' && echo " OK"

echo "=== after 2nd tool (pending should be 11500, estimated ~187000) ==="
curl -sf http://127.0.0.1:$API_PORT/v1/sessions/test-001/context | jq .

echo "=== sessions list ==="
curl -sf http://127.0.0.1:$API_PORT/v1/sessions | jq .

echo "PASS"
