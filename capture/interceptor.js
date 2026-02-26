// capture/interceptor.js — injected via NODE_OPTIONS='--require .../interceptor.js'
//
// Patches two HTTP surfaces to capture Claude Code API traffic without a proxy:
//   1. globalThis.fetch  — Node 18+ undici-backed global (primary path for Claude Code)
//   2. https/http.request — legacy path used by older dependencies
//
// Same JSONL schema as capture/logger.py:
//   stream_start  — request + response headers (SSE)
//   stream_chunk  — per-chunk data with elapsed_ms
//   stream_end    — total_chunks + duration_ms
//   exchange      — full request + response (non-streaming)
//
// Environment:
//   WARDEN_CAPTURE_BODIES=1   Full body logging (default: truncate to 200 chars)
//                             Even when enabled, system/messages keys are redacted.
//   WARDEN_CAPTURE_DIR        Override capture directory (default: ~/claude-captures)

'use strict';

const fs   = require('fs');
const path = require('path');
const os   = require('os');
const crypto = require('crypto');
const https  = require('https');
const http   = require('http');

// ── Config ──────────────────────────────────────────────────────────────────
const CAPTURE_DIR    = process.env.WARDEN_CAPTURE_DIR
  ? path.resolve(process.env.WARDEN_CAPTURE_DIR)
  : path.join(os.homedir(), 'claude-captures');
const CAPTURE_BODIES  = process.env.WARDEN_CAPTURE_BODIES === '1';
const MAX_PREVIEW     = 200;
const SCRUB_HDRS      = new Set(['x-api-key', 'authorization', 'proxy-authorization']);
const SCRUB_BODY_KEYS = ['system', 'messages'];
const ANTHROPIC_HOST  = 'api.anthropic.com';

// ── Log file (one per process, created on first write) ──────────────────────
let _stream = null;

function logStream() {
  if (_stream) return _stream;
  try {
    const now     = new Date();
    const dateStr = now.toISOString().slice(0, 10);
    const timeStr = now.toTimeString().slice(0, 8).replace(/:/g, '');
    const dir     = path.join(CAPTURE_DIR, dateStr);
    fs.mkdirSync(dir, { recursive: true });
    const filePath = path.join(dir, `capture-${timeStr}.jsonl`);
    _stream = fs.createWriteStream(filePath, { flags: 'a' });
    fs.chmodSync(filePath, 0o600);
    process.stderr.write(`[claude-interceptor] Writing to ${filePath}\n`);
  } catch (e) {
    // If we can't open the file, return a null sink so we never crash Claude Code
    _stream = { write: () => {} };
  }
  return _stream;
}

function emit(record) {
  try { logStream().write(JSON.stringify(record) + '\n'); } catch (_) {}
}

// ── Helpers ──────────────────────────────────────────────────────────────────
const nowIso = () => new Date().toISOString();
const newId  = () => crypto.randomUUID();

function scrubHeaders(headers) {
  if (!headers) return {};
  const pairs = typeof headers.entries === 'function'
    ? [...headers.entries()]
    : Object.entries(headers);
  const out = {};
  for (const [k, v] of pairs) {
    out[k] = SCRUB_HDRS.has(k.toLowerCase()) ? '[REDACTED]' : v;
  }
  return out;
}

function scrubBody(text) {
  if (typeof text !== 'string') text = String(text ?? '');
  if (!CAPTURE_BODIES) {
    return text.length > MAX_PREVIEW ? text.slice(0, MAX_PREVIEW) + '...' : text;
  }
  try {
    const obj = JSON.parse(text);
    if (obj && typeof obj === 'object' && !Array.isArray(obj)) {
      for (const key of SCRUB_BODY_KEYS) {
        if (key in obj) {
          obj[key] = `[REDACTED: ${JSON.stringify(obj[key]).length} chars]`;
        }
      }
      return JSON.stringify(obj);
    }
  } catch (_) {}
  return text;
}

function isAnthropic(input) {
  try {
    const str = typeof input === 'string' ? input
      : input instanceof URL ? input.href
      : (input?.url ?? String(input));
    return new URL(str).hostname === ANTHROPIC_HOST;
  } catch (_) { return false; }
}

function toUrlString(input) {
  if (typeof input === 'string') return input;
  if (input instanceof URL) return input.href;
  return input?.url ?? String(input);
}

// ── 1. globalThis.fetch (undici, Node 18+) ───────────────────────────────────
// This is the primary capture surface for Claude Code.
if (typeof globalThis.fetch === 'function') {
  const _fetch = globalThis.fetch;

  globalThis.fetch = async function warden_fetch(input, init = {}) {
    if (!isAnthropic(input)) return _fetch(input, init);

    const id     = newId();
    const url    = toUrlString(input);
    const method = (init.method ?? 'GET').toUpperCase();

    // Capture request body without consuming it (string/buffer forms only;
    // ReadableStream bodies are rare in Claude Code's own requests)
    let reqBody = '';
    if (init.body != null) {
      if (typeof init.body === 'string') {
        reqBody = init.body;
      } else if (init.body instanceof ArrayBuffer) {
        reqBody = Buffer.from(init.body).toString('utf8');
      } else if (ArrayBuffer.isView(init.body)) {
        reqBody = Buffer.from(
          init.body.buffer, init.body.byteOffset, init.body.byteLength
        ).toString('utf8');
      }
    }

    const resp = await _fetch(input, init);
    const contentType = resp.headers.get('content-type') ?? '';

    if (contentType.includes('text/event-stream')) {
      // ── Streaming (SSE) ──
      emit({
        type: 'stream_start', timestamp: nowIso(), flow_id: id,
        request: { method, url, headers: scrubHeaders(init.headers), body: scrubBody(reqBody) },
        response: { status_code: resp.status, headers: scrubHeaders(resp.headers) },
      });

      const [s1, s2] = resp.body.tee();
      const t0 = Date.now();
      let   n  = 0;

      // Drain s2 for logging; return s1 to caller untouched
      (async () => {
        try {
          const reader = s2.getReader();
          const dec    = new TextDecoder();
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            const text = dec.decode(value, { stream: true });
            emit({
              type: 'stream_chunk', flow_id: id,
              chunk_index: n++, elapsed_ms: Date.now() - t0,
              data: CAPTURE_BODIES
                ? text
                : text.slice(0, MAX_PREVIEW) + (text.length > MAX_PREVIEW ? '...' : ''),
            });
          }
          emit({ type: 'stream_end', flow_id: id, total_chunks: n, duration_ms: Date.now() - t0 });
        } catch (_) {}
      })();

      return new Response(s1, {
        status: resp.status, statusText: resp.statusText, headers: resp.headers,
      });
    } else {
      // ── Non-streaming ──
      const cloned = resp.clone();
      cloned.text().then(body => {
        emit({
          type: 'exchange', timestamp: nowIso(), flow_id: id,
          request: { method, url, headers: scrubHeaders(init.headers), body: scrubBody(reqBody) },
          response: { status_code: resp.status, headers: scrubHeaders(resp.headers), body: scrubBody(body) },
        });
      }).catch(() => {});
      return resp;
    }
  };
}

// ── 2. https/http.request (legacy deps) ──────────────────────────────────────
// Node 18+ fetch goes through undici, not https.request. This patch catches
// older dependencies that still call http.request directly.
function patchModule(mod) {
  const _req = mod.request.bind(mod);

  mod.request = function warden_request(options, callback) {
    let host = '';
    try {
      if (typeof options === 'string' || options instanceof URL) {
        host = new URL(options).hostname;
      } else {
        host = options.hostname ?? (options.host ?? '').split(':')[0];
      }
    } catch (_) {}

    if (host !== ANTHROPIC_HOST) return _req(options, callback);

    const id      = newId();
    const method  = (typeof options === 'object' ? options.method : null) ?? 'GET';
    const urlStr  = typeof options === 'string' ? options
      : options instanceof URL ? options.href
      : `https://${host}${options.path ?? '/'}`;
    const reqHdrs = typeof options === 'object' ? scrubHeaders(options.headers ?? {}) : {};

    const req    = _req(options, callback);
    const chunks = [];
    const _write = req.write.bind(req);
    const _end   = req.end.bind(req);

    req.write = (chunk, enc, cb) => {
      if (chunk) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, enc ?? 'utf8'));
      return _write(chunk, enc, cb);
    };

    req.end = (chunk, enc, cb) => {
      if (chunk) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, enc ?? 'utf8'));
      const reqBody = Buffer.concat(chunks).toString('utf8');

      req.once('response', (res) => {
        const isSSE    = (res.headers['content-type'] ?? '').includes('text/event-stream');
        const respHdrs = scrubHeaders(res.headers);

        if (isSSE) {
          emit({
            type: 'stream_start', timestamp: nowIso(), flow_id: id,
            request: { method, url: urlStr, headers: reqHdrs, body: scrubBody(reqBody) },
            response: { status_code: res.statusCode, headers: respHdrs },
          });
          const t0 = Date.now(); let n = 0;
          res.on('data', c => {
            const text = c.toString('utf8');
            emit({
              type: 'stream_chunk', flow_id: id,
              chunk_index: n++, elapsed_ms: Date.now() - t0,
              data: CAPTURE_BODIES ? text : text.slice(0, MAX_PREVIEW),
            });
          });
          res.on('end', () => emit({
            type: 'stream_end', flow_id: id, total_chunks: n, duration_ms: Date.now() - t0,
          }));
        } else {
          const rchunks = [];
          res.on('data', c => rchunks.push(c));
          res.on('end', () => emit({
            type: 'exchange', timestamp: nowIso(), flow_id: id,
            request: { method, url: urlStr, headers: reqHdrs, body: scrubBody(reqBody) },
            response: {
              status_code: res.statusCode, headers: respHdrs,
              body: scrubBody(Buffer.concat(rchunks).toString('utf8')),
            },
          }));
        }
      });

      return _end(chunk, enc, cb);
    };

    return req;
  };
}

patchModule(https);
patchModule(http);
