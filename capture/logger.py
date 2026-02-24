"""
logger.py - mitmproxy addon for capturing Claude Code API traffic.

Two capture modes:
  Streaming (SSE):    stream_start (request + response headers)
                      stream_chunk per chunk (chunk_index, elapsed_ms since first byte)
                      stream_end (total_chunks, duration_ms)
  Non-streaming:      exchange (full request + response)

Scrubs x-api-key and authorization headers.
Body capture is off by default (truncated to 200 chars). Set
WARDEN_CAPTURE_BODIES=1 to enable full body logging; sensitive
JSON keys (system, messages) are still redacted.

Writes JSONL to ~/claude-captures/YYYY-MM-DD/capture-HHMMSS.jsonl

Usage (via capture/claude wrapper, or manually):
    mitmdump -s /path/to/capture/logger.py
"""

import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

from mitmproxy import http

CAPTURE_DIR = Path.home() / "claude-captures"
SCRUB = {"x-api-key", "authorization", "proxy-authorization"}

CAPTURE_BODIES = os.environ.get("WARDEN_CAPTURE_BODIES", "0") == "1"
BODY_KEYS_SCRUB = {"system", "messages"}
MAX_BODY_PREVIEW = 200

_log_file = None


def _get_log_file():
    global _log_file
    if _log_file is not None:
        return _log_file
    today = datetime.now().strftime("%Y-%m-%d")
    d = CAPTURE_DIR / today
    d.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%H%M%S")
    path = d / f"capture-{ts}.jsonl"
    _log_file = open(path, "a", buffering=1)  # line-buffered
    os.chmod(path, 0o600)
    print(f"[claude-logger] Writing to {path}", flush=True)
    return _log_file


def _write(record: dict) -> None:
    _get_log_file().write(json.dumps(record) + "\n")


def _scrub(h) -> dict:
    return {k: ("[REDACTED]" if k.lower() in SCRUB else v) for k, v in h.items()}


def _decode(b: bytes) -> str:
    try:
        return b.decode("utf-8", errors="replace")
    except Exception:
        return f"<{len(b)} bytes binary>"


def _scrub_body(raw: bytes) -> str:
    text = _decode(raw)
    if not CAPTURE_BODIES:
        return text[:MAX_BODY_PREVIEW] + "..." if len(text) > MAX_BODY_PREVIEW else text
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            for key in BODY_KEYS_SCRUB:
                if key in obj:
                    obj[key] = f"[REDACTED: {len(json.dumps(obj[key]))} chars]"
            return json.dumps(obj)
    except (json.JSONDecodeError, TypeError):
        pass
    return text


def _scrub_chunk(chunk: bytes) -> str:
    text = _decode(chunk)
    if not CAPTURE_BODIES:
        return text[:MAX_BODY_PREVIEW] + "..." if len(text) > MAX_BODY_PREVIEW else text
    return text


def _is_anthropic(flow: http.HTTPFlow) -> bool:
    return "api.anthropic.com" in flow.request.pretty_host


# ── Streaming path (SSE) ──────────────────────────────────────────────────────

def responseheaders(flow: http.HTTPFlow) -> None:
    if not _is_anthropic(flow):
        return
    if "text/event-stream" not in flow.response.headers.get("content-type", ""):
        return

    # Log request + response headers now — body will follow as chunks
    _write({
        "type": "stream_start",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "flow_id": flow.id,
        "request": {
            "method": flow.request.method,
            "url": flow.request.pretty_url,
            "http_version": flow.request.http_version,
            "headers": _scrub(flow.request.headers),
            "body": _scrub_body(flow.request.content),
        },
        "response": {
            "status_code": flow.response.status_code,
            "http_version": flow.response.http_version,
            "headers": _scrub(flow.response.headers),
        },
    })

    t0 = time.monotonic()
    state = {"n": 0}

    def log_chunks(chunks):
        for chunk in chunks:
            _write({
                "type": "stream_chunk",
                "flow_id": flow.id,
                "chunk_index": state["n"],
                "elapsed_ms": round((time.monotonic() - t0) * 1000, 2),
                "data": _scrub_chunk(chunk),
            })
            state["n"] += 1
            yield chunk
        _write({
            "type": "stream_end",
            "flow_id": flow.id,
            "total_chunks": state["n"],
            "duration_ms": round((time.monotonic() - t0) * 1000, 2),
        })

    flow.response.stream = log_chunks


# ── Non-streaming path ────────────────────────────────────────────────────────

def response(flow: http.HTTPFlow) -> None:
    if not _is_anthropic(flow):
        return
    if "text/event-stream" in flow.response.headers.get("content-type", ""):
        return  # handled above

    _write({
        "type": "exchange",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "flow_id": flow.id,
        "request": {
            "method": flow.request.method,
            "url": flow.request.pretty_url,
            "http_version": flow.request.http_version,
            "headers": _scrub(flow.request.headers),
            "body": _scrub_body(flow.request.content),
        },
        "response": {
            "status_code": flow.response.status_code,
            "http_version": flow.response.http_version,
            "headers": _scrub(flow.response.headers),
            "body": _scrub_body(flow.response.content),
        },
    })
