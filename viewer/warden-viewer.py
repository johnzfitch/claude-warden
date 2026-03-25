#!/usr/bin/env python3
"""
Warden Viewer — Claude Code Monitoring Dashboard

A retro-styled web UI for browsing claude-warden collector data.
Adapted from hotbar trace-viewer with blue theme and warden-specific views.

Usage:
    python viewer/warden-viewer.py [--port 8477] [--db path/to/collector.db]
    Then open http://localhost:8477 in your browser.
"""

import http.server
import json
import os
import sqlite3
import sys
import webbrowser
from datetime import datetime
from html import escape as h
from urllib.parse import parse_qs, urlparse

DEFAULT_PORT = 8477
XDG_STATE_HOME = os.environ.get('XDG_STATE_HOME', os.path.expanduser('~/.local/state'))
DEFAULT_DB = os.path.join(XDG_STATE_HOME, 'claude-warden', 'collector.db')

# ── Color palette (Warden blue theme) ────────────────────────────────

COLORS = {
    "warden_blue": "#1a4a7a",
    "warden_blue_light": "#2a6aaa",
    "warden_blue_dark": "#0a2a4a",
    "teal": "#2d8c9e",
    "teal_dark": "#1a5e6e",
    "amber": "#cc8822",
    "orange": "#cc5522",
    "red_hot": "#cc2222",
    "green": "#44aa66",
    "blue": "#4488cc",
    "purple": "#8866bb",
}

SPAN_COLORS = [
    "#1a4a7a", "#2d8c9e", "#cc8822", "#44aa66",
    "#cc5522", "#4488cc", "#8866bb", "#cc2222",
]

# ── HTML Template ────────────────────────────────────────────────────

HTML_PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Warden Viewer — Claude Code Monitor</title>
<script src="https://unpkg.com/htmx.org@2.0.4"></script>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root {
  --bg: #0c0a0e; --bg-panel: #141218; --bg-cell: #1a1720;
  --bg-hover: #221f28; --bg-active: #2a2530;
  --border: #2a2630; --border-light: #3a3540;
  --text: #d0ccd6; --text-dim: #6a6670; --text-bright: #eee8f0;
  --warden-blue: #1a4a7a; --warden-blue-l: #2a6aaa; --warden-blue-d: #0a2a4a;
  --teal: #2d8c9e; --teal-d: #1a5e6e; --teal-l: #3da8bc;
  --amber: #cc8822; --orange: #cc5522; --red: #cc2222;
  --green: #44aa66; --blue: #4488cc; --purple: #8866bb;
  --font: "Berkeley Mono", "SF Mono", "Fira Code", "JetBrains Mono", "Cascadia Code", monospace;
  --radius: 2px;
}
html,body { background:var(--bg); color:var(--text); font:13px/1.5 var(--font);
  height:100%; overflow:hidden; }

/* ── Mac System 7 Window Chrome ── */
.window { display:flex; flex-direction:column; height:100vh; border:1px solid var(--border-light); }
.title-bar {
  display:flex; align-items:center; gap:10px;
  padding:6px 12px; background:var(--warden-blue);
  border-bottom:3px solid var(--teal);
  user-select:none; flex-shrink:0;
}
.title-bar .diamond { color:var(--teal-l); font-size:16px; }
.title-bar h1 { font-size:13px; font-weight:600; color:#fff; letter-spacing:1.5px; text-transform:uppercase; }
.title-bar .subtitle { color:rgba(255,255,255,.55); font-size:11px; letter-spacing:3px; margin-left:auto; }
.title-bar .win-btns { display:flex; gap:4px; margin-left:12px; }
.title-bar .win-btn {
  width:12px; height:12px; border-radius:50%;
  border:1px solid rgba(255,255,255,.2);
}
.win-btn.close { background:#cc4444; }
.win-btn.min { background:#ccaa22; }
.win-btn.max { background:#44aa44; }

/* ── Toolbar ── */
.toolbar {
  display:flex; gap:4px; padding:6px 12px;
  background:var(--bg-panel); border-bottom:1px solid var(--border);
  flex-shrink:0; overflow-x:auto; overflow-y:hidden;
}
.toolbar button {
  background:var(--bg-cell); color:var(--text-dim);
  border:1px solid var(--border); border-bottom:2px solid transparent;
  padding:4px 14px; font:11px var(--font); cursor:pointer;
  letter-spacing:0.5px; transition:all 0.15s; white-space:nowrap; flex-shrink:0;
}
.toolbar button:hover { background:var(--bg-hover); color:var(--text); border-color:var(--border-light); border-bottom-color:var(--border-light); }
.toolbar button.active {
  background:var(--warden-blue-d); color:var(--text-bright);
  border-color:var(--warden-blue); border-bottom:2px solid var(--teal);
}
.toolbar .spacer { flex:1; min-width:8px; }
.toolbar .db-info { color:var(--text-dim); font-size:10px; align-self:center; letter-spacing:1px; white-space:nowrap; }

/* ── Layout ── */
.main { display:flex; flex:1; overflow:hidden; }
.sidebar {
  width:240px; min-width:240px; background:var(--bg-panel);
  border-right:1px solid var(--border); display:flex; flex-direction:column;
  overflow-y:auto;
}
.content { flex:1; overflow-y:auto; padding:0; min-width:0; }

/* ── Sidebar Sections ── */
.sidebar-section { padding:12px 10px 10px; border-bottom:1px solid var(--border); }
.sidebar-section h3 {
  font-size:10px; letter-spacing:2px; color:var(--teal);
  margin-bottom:6px; text-transform:uppercase;
}
.session-item {
  display:block; padding:8px 10px; margin:3px 0;
  background:var(--bg-cell); border:1px solid transparent;
  cursor:pointer; text-decoration:none; color:inherit;
  transition:all 0.12s;
}
.session-item:hover { border-color:var(--border-light); background:var(--bg-hover); }
.session-item.active { border-color:var(--warden-blue); background:var(--bg-active);
  border-left:3px solid var(--teal); }
.session-id { font-size:11px; font-weight:600; font-family:monospace; }
.session-model { font-size:10px; color:var(--blue); }
.session-meta { font-size:10px; color:var(--text-dim); }

.stat-row { display:flex; justify-content:space-between; padding:3px 0; font-size:11px; }
.stat-label { color:var(--text-dim); }
.stat-value { color:var(--text-bright); font-weight:600; }

/* ── Status Bar ── */
.status-bar {
  display:flex; align-items:center; padding:3px 12px; gap:16px;
  background:var(--bg-panel); border-top:1px solid var(--border);
  font-size:10px; color:var(--text-dim); letter-spacing:1.5px;
  flex-shrink:0; white-space:nowrap; overflow:hidden;
}
.status-bar .brand { color:var(--warden-blue-l); letter-spacing:3px; flex-shrink:0; }
.status-bar .spacer { flex:1; min-width:8px; }

/* ── Content Views ── */
.view-header {
  padding:12px 16px 10px; border-bottom:1px solid var(--border);
  display:flex; align-items:baseline; gap:12px; flex-wrap:wrap;
}
.view-header h2 { font-size:13px; color:var(--teal-l); letter-spacing:1.5px; text-transform:uppercase; white-space:nowrap; }
.view-header .count { font-size:11px; color:var(--text-dim); min-width:0; }

/* ── Context Gauge ── */
.context-gauge {
  padding:16px; border-bottom:1px solid var(--border);
}
.gauge-title { font-size:11px; color:var(--teal); letter-spacing:1px; margin-bottom:8px; text-transform:uppercase; }
.gauge-bar {
  height:32px; background:var(--bg-cell); border:1px solid var(--border);
  position:relative; overflow:hidden;
}
.gauge-segment {
  height:100%; float:left; position:relative;
}
.gauge-segment::after {
  content:''; position:absolute; inset:0;
  background:linear-gradient(180deg, rgba(255,255,255,0.15) 0%, transparent 40%, rgba(0,0,0,0.2) 100%);
}
.gauge-threshold {
  position:absolute; top:0; bottom:0; width:2px;
  background:var(--amber); opacity:0.6;
  border-left:2px dashed var(--amber);
}
.gauge-legend {
  display:flex; gap:12px; margin-top:8px; font-size:10px;
  flex-wrap:wrap;
}
.gauge-legend-item { display:flex; align-items:center; gap:4px; }
.gauge-legend-swatch { width:12px; height:12px; border:1px solid var(--border); }

/* ── Timeline/Waterfall View ── */
.timeline { padding:12px 16px; }
.timeline-row {
  display:flex; align-items:center; gap:8px; padding:3px 0;
  border-bottom:1px solid rgba(42,38,48,0.5);
  font-size:11px; transition:background 0.1s;
}
.timeline-row:hover { background:var(--bg-hover); }
.timeline-name { width:200px; min-width:200px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.timeline-bar-container { flex:1; height:18px; position:relative; }
.timeline-bar {
  height:100%; min-width:2px;
  border-radius:1px; position:relative; overflow:hidden;
  transition:width 0.3s ease;
}
.timeline-bar::after {
  content:''; position:absolute; inset:0;
  background:linear-gradient(180deg, rgba(255,255,255,0.15) 0%, transparent 40%, rgba(0,0,0,0.2) 100%);
}
.timeline-dur { width:80px; text-align:right; color:var(--text-dim); font-size:10px; font-variant-numeric:tabular-nums; }
.timeline-indent { display:inline-block; }
.timeline-tree { color:var(--border-light); margin-right:4px; }

/* ── Data Grid ── */
.data-grid { width:100%; border-collapse:collapse; font-size:11px; }
.data-grid thead { position:sticky; top:0; z-index:2; }
.data-grid th {
  background:var(--bg-panel); color:var(--teal);
  padding:6px 10px; text-align:left; font-weight:600;
  border-bottom:2px solid var(--border-light);
  font-size:10px; letter-spacing:1px; text-transform:uppercase;
}
.data-grid td {
  padding:4px 10px; border-bottom:1px solid var(--border);
  font-variant-numeric:tabular-nums;
}
.data-grid tr:hover td { background:var(--bg-hover); }
.data-grid .col-num { color:var(--text-dim); text-align:right; width:40px; }
.data-grid .col-ts { color:var(--text-dim); font-size:10px; width:80px; }

/* ── Event badges ── */
.badge {
  display:inline-block; padding:2px 6px; border-radius:2px;
  font-size:9px; font-weight:600; letter-spacing:0.5px;
  text-transform:uppercase;
}
.badge.blocked { background:var(--red); color:#fff; }
.badge.allowed { background:var(--green); color:#fff; }
.badge.truncated { background:var(--amber); color:#000; }
.badge.tool_output_size { background:var(--blue); color:#fff; }
.badge.session_start { background:var(--teal); color:#fff; }
.badge.session_end { background:var(--text-dim); color:#fff; }
.badge.autonomousresponse { background:#cc2222; color:#fff; animation:pulse 2s infinite; }
.badge.user { background:var(--teal); color:#fff; }
.badge.assistant { background:var(--warden-blue-l); color:#fff; }
.badge.system { background:var(--text-dim); color:#fff; }
.badge.queueoperation { background:var(--amber); color:#000; }
@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.6} }
.response-preview { font-size:11px; color:var(--text-dim); max-width:500px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.origin-tag { font-size:9px; padding:1px 4px; border-radius:2px; background:var(--red); color:#fff; margin-left:4px; }

/* ── Chart containers ── */
.chart-row { display:flex; gap:16px; padding:16px; flex-wrap:wrap; }
.chart-box {
  flex:1; min-width:300px; background:var(--bg-panel);
  border:1px solid var(--border); padding:12px;
}
.chart-title {
  font-size:11px; color:var(--teal); letter-spacing:1px;
  text-transform:uppercase; margin-bottom:10px;
  border-bottom:2px solid var(--border); padding-bottom:4px;
}

/* ── Bar chart (DeltaGraph style) ── */
.bar-chart { display:flex; flex-direction:column; gap:4px; }
.bar-item { display:flex; align-items:center; gap:8px; }
.bar-label { width:120px; font-size:10px; overflow:hidden; text-overflow:ellipsis; }
.bar-visual {
  flex:1; height:20px; background:var(--bg-cell);
  position:relative; overflow:hidden; border:1px solid var(--border);
}
.bar-fill {
  height:100%; position:relative;
}
.bar-fill::after {
  content:''; position:absolute; inset:0;
  background:linear-gradient(180deg, rgba(255,255,255,0.15) 0%, transparent 40%, rgba(0,0,0,0.2) 100%);
}
.bar-value { width:60px; text-align:right; font-size:10px; color:var(--text-dim); }

/* ── Sparkline (Harvard Graphics style) ── */
.sparkline-container {
  height:80px; position:relative; background:var(--bg-cell);
  border:1px solid var(--border); margin-top:8px;
}
.sparkline-canvas {
  width:100%; height:100%; display:flex; align-items:flex-end; gap:2px;
  padding:4px;
}
.sparkline-bar {
  flex:1; min-width:4px; background:var(--warden-blue);
  position:relative;
}
.sparkline-bar::after {
  content:''; position:absolute; inset:0;
  background:linear-gradient(180deg, rgba(255,255,255,0.2) 0%, transparent 50%);
}
.sparkline-threshold {
  position:absolute; left:0; right:0; height:1px;
  background:var(--amber); opacity:0.7;
  border-top:1px dashed var(--amber);
}

/* ── htmx animations ── */
.htmx-added { animation:fadeIn 0.3s; }
@keyframes fadeIn { from{opacity:0} to{opacity:1} }

/* ── Empty states ── */
.empty-state {
  padding:40px 20px; text-align:center; color:var(--text-dim);
  font-size:11px; letter-spacing:1px;
}
</style>
</head>
<body>
<div class="window">
  <div class="title-bar">
    <span class="diamond">◆</span>
    <h1>Warden Viewer</h1>
    <span class="subtitle">Claude Code Monitor</span>
    <div class="win-btns">
      <div class="win-btn close"></div>
      <div class="win-btn min"></div>
      <div class="win-btn max"></div>
    </div>
  </div>

  <div class="toolbar">
    <button hx-get="/view/context" hx-target="#content" class="active">Context</button>
    <button hx-get="/view/waterfall" hx-target="#content">Waterfall</button>
    <button hx-get="/view/events" hx-target="#content">Events</button>
    <button hx-get="/view/cost" hx-target="#content">Cost</button>
    <button hx-get="/view/tools" hx-target="#content">Top Tools</button>
    <button hx-get="/view/trend" hx-target="#content">Trend</button>
    <button hx-get="/view/conversation" hx-target="#content">Conv</button>
    <div class="spacer"></div>
    <span class="db-info">DB: %(db_path)s</span>
  </div>

  <div class="main">
    <div class="sidebar" hx-get="/sidebar" hx-trigger="load, every 5s" hx-swap="innerHTML">
      <div class="empty-state">Loading sessions...</div>
    </div>
    <div id="content" class="content" hx-get="/view/context" hx-trigger="load" hx-swap="innerHTML">
      <div class="empty-state">Loading...</div>
    </div>
  </div>

  <div class="status-bar">
    <span class="brand">WARDEN</span>
    <span class="spacer"></span>
    <span>Claude Code Session Monitor</span>
  </div>
</div>
</body>
</html>
"""

# ── View Rendering Functions ─────────────────────────────────────────

def render_sidebar(db, active_session=None):
    """Render session list sidebar."""
    sessions = db.execute("""
        SELECT session_id, model, context_window, input_tokens, output_tokens,
               cache_read_tokens, cost_usd, tool_count, updated_at_ns
        FROM sessions
        ORDER BY updated_at_ns DESC
        LIMIT 50
    """).fetchall()

    if not sessions:
        return '<div class="empty-state">No sessions found</div>'

    html = '<div class="sidebar-section"><h3>Sessions</h3>'
    for row in sessions:
        sid, model, ctx_win, inp, out, cache_read, cost, tools, updated = row
        sid_short = sid[-6:] if len(sid) > 6 else sid

        active_class = " active" if sid == active_session else ""
        ctx_total = inp + out + cache_read
        ctx_pct = int((ctx_total / ctx_win * 100)) if ctx_win > 0 else 0

        html += f'''
        <a href="?session={h(sid)}" class="session-item{active_class}"
           hx-get="/view/context?session={h(sid)}" hx-target="#content">
          <div class="session-id">{h(sid_short)}</div>
          <div class="session-model">{h(model or "unknown")}</div>
          <div class="session-meta">
            {ctx_pct}% · ${cost:.2f} · {tools} tools
          </div>
        </a>
        '''
    html += '</div>'
    return html


def render_context_view(db, session_id=None):
    """Render context gauge view showing token usage."""
    if not session_id:
        # Get most recent session
        row = db.execute("SELECT session_id FROM sessions ORDER BY updated_at_ns DESC LIMIT 1").fetchone()
        if not row:
            return '<div class="empty-state">No sessions available</div>'
        session_id = row[0]

    # Get session data
    row = db.execute("""
        SELECT model, context_window, input_tokens, output_tokens,
               cache_read_tokens, cache_creation_tokens, pending_output_tokens,
               cost_usd, tool_count
        FROM sessions WHERE session_id = ?
    """, (session_id,)).fetchone()

    if not row:
        return '<div class="empty-state">Session not found</div>'

    model, ctx_win, inp, out, cache_read, cache_create, pending, cost, tools = row

    # Calculate context usage
    estimated_ctx = inp + pending
    ctx_pct = (estimated_ctx / ctx_win * 100) if ctx_win > 0 else 0

    # Effective window and threshold (from plan)
    effective_win = ctx_win - 20000 if ctx_win > 20000 else ctx_win
    compact_pct = 85
    compact_threshold = min(effective_win * compact_pct // 100, effective_win - 13000)
    threshold_pct = (compact_threshold / ctx_win * 100) if ctx_win > 0 else 0

    # Segment widths (proportional to token counts)
    inp_pct = (inp / ctx_win * 100) if ctx_win > 0 else 0
    cache_r_pct = (cache_read / ctx_win * 100) if ctx_win > 0 else 0
    cache_c_pct = (cache_create / ctx_win * 100) if ctx_win > 0 else 0
    out_pct = (out / ctx_win * 100) if ctx_win > 0 else 0
    pending_pct = (pending / ctx_win * 100) if ctx_win > 0 else 0

    html = f'''
    <div class="view-header">
      <h2>Context Usage</h2>
      <span class="count">Session: {h(session_id[-8:])}</span>
    </div>
    <div class="context-gauge">
      <div class="gauge-title">Token Allocation</div>
      <div class="gauge-bar">
    '''

    if inp_pct > 0:
        html += f'<div class="gauge-segment" style="width:{inp_pct:.2f}%; background:{COLORS["warden_blue"]};"></div>'
    if cache_r_pct > 0:
        html += f'<div class="gauge-segment" style="width:{cache_r_pct:.2f}%; background:{COLORS["green"]};"></div>'
    if cache_c_pct > 0:
        html += f'<div class="gauge-segment" style="width:{cache_c_pct:.2f}%; background:{COLORS["teal"]};"></div>'
    if pending_pct > 0:
        html += f'<div class="gauge-segment" style="width:{pending_pct:.2f}%; background:{COLORS["amber"]};"></div>'
    if out_pct > 0:
        html += f'<div class="gauge-segment" style="width:{out_pct:.2f}%; background:{COLORS["blue"]};"></div>'

    html += f'<div class="gauge-threshold" style="left:{threshold_pct:.2f}%;"></div>'
    html += '</div>'

    html += '''
      <div class="gauge-legend">
        <div class="gauge-legend-item">
          <div class="gauge-legend-swatch" style="background:#1a4a7a;"></div>
          <span>Input</span>
        </div>
        <div class="gauge-legend-item">
          <div class="gauge-legend-swatch" style="background:#44aa66;"></div>
          <span>Cache Read</span>
        </div>
        <div class="gauge-legend-item">
          <div class="gauge-legend-swatch" style="background:#2d8c9e;"></div>
          <span>Cache Create</span>
        </div>
        <div class="gauge-legend-item">
          <div class="gauge-legend-swatch" style="background:#cc8822;"></div>
          <span>Pending</span>
        </div>
        <div class="gauge-legend-item">
          <div class="gauge-legend-swatch" style="background:#4488cc;"></div>
          <span>Output</span>
        </div>
      </div>
    </div>
    '''

    # Stats table
    html += '<div style="padding:16px;">'
    html += '<table class="data-grid"><thead><tr>'
    html += '<th>Metric</th><th>Value</th></tr></thead><tbody>'

    stats = [
        ("Model", model or "unknown"),
        ("Context Window", f"{ctx_win:,} tokens"),
        ("Used", f"{estimated_ctx:,} tokens ({ctx_pct:.1f}%)"),
        ("Input Tokens", f"{inp:,}"),
        ("Output Tokens", f"{out:,}"),
        ("Cache Read", f"{cache_read:,}"),
        ("Cache Create", f"{cache_create:,}"),
        ("Pending Output", f"{pending:,}"),
        ("Compact Threshold", f"{compact_threshold:,} tokens"),
        ("Tool Calls", f"{tools}"),
        ("Cost", f"${cost:.4f}"),
    ]

    for label, value in stats:
        html += f'<tr><td>{h(label)}</td><td>{h(value)}</td></tr>'

    html += '</tbody></table></div>'
    return html


def render_waterfall_view(db, session_id=None):
    """Render tool waterfall (Gantt-style span timeline)."""
    if not session_id:
        row = db.execute("SELECT session_id FROM sessions ORDER BY updated_at_ns DESC LIMIT 1").fetchone()
        if not row:
            return '<div class="empty-state">No sessions available</div>'
        session_id = row[0]

    spans = db.execute("""
        SELECT name, start_ns, end_ns, duration_ms, parent_span_id, span_id, attrs_json
        FROM spans
        WHERE session_id = ?
        ORDER BY start_ns ASC
        LIMIT 200
    """, (session_id,)).fetchall()

    if not spans:
        return '<div class="empty-state">No spans found for this session</div>'

    # Build hierarchy
    span_map = {}
    roots = []
    for row in spans:
        name, start, end, dur, parent_id, span_id, attrs = row
        span_map[span_id] = {
            'name': name, 'start': start, 'end': end, 'dur': dur,
            'parent': parent_id, 'children': [], 'attrs': attrs
        }

    for sid, sdata in span_map.items():
        if sdata['parent'] and sdata['parent'] in span_map:
            span_map[sdata['parent']]['children'].append(sid)
        else:
            roots.append(sid)

    # Find time range
    min_ts = min(s['start'] for s in span_map.values())
    max_ts = max(s['end'] for s in span_map.values())
    total_range = max_ts - min_ts if max_ts > min_ts else 1

    html = f'''
    <div class="view-header">
      <h2>Tool Waterfall</h2>
      <span class="count">{len(spans)} spans</span>
    </div>
    <div class="timeline">
    '''

    def render_span(sid, depth=0):
        s = span_map[sid]
        indent = depth * 16
        tree = "└─ " if depth > 0 else ""

        # Position and width
        left_pct = ((s['start'] - min_ts) / total_range * 100) if total_range > 0 else 0
        width_pct = ((s['end'] - s['start']) / total_range * 100) if total_range > 0 else 0.1
        width_pct = max(width_pct, 0.1)  # Minimum visible width

        # Color by span type
        color = SPAN_COLORS[hash(s['name']) % len(SPAN_COLORS)]

        dur_str = format_duration_ms(s['dur'])

        out = f'''
        <div class="timeline-row">
          <div class="timeline-name">
            <span class="timeline-indent" style="width:{indent}px;"></span>
            <span class="timeline-tree">{h(tree)}</span>
            {h(s['name'])}
          </div>
          <div class="timeline-bar-container">
            <div class="timeline-bar" style="margin-left:{left_pct:.2f}%; width:{width_pct:.2f}%; background:{color};"></div>
          </div>
          <div class="timeline-dur">{h(dur_str)}</div>
        </div>
        '''

        # Recurse for children
        for child_id in s['children']:
            out += render_span(child_id, depth + 1)

        return out

    for root_id in roots:
        html += render_span(root_id)

    html += '</div>'
    return html


def render_events_view(db, session_id=None, event_filter="ALL"):
    """Render hook events log."""
    if not session_id:
        row = db.execute("SELECT session_id FROM sessions ORDER BY updated_at_ns DESC LIMIT 1").fetchone()
        if not row:
            return '<div class="empty-state">No sessions available</div>'
        session_id = row[0]

    query = "SELECT occurred_at_ns, event_type, tool_name, payload_json FROM hook_events WHERE session_id = ?"
    params = [session_id]

    if event_filter != "ALL":
        query += " AND event_type = ?"
        params.append(event_filter)

    query += " ORDER BY occurred_at_ns DESC LIMIT 500"

    events = db.execute(query, params).fetchall()

    html = f'''
    <div class="view-header">
      <h2>Hook Events</h2>
      <span class="count">{len(events)} events</span>
    </div>
    <div style="padding:16px;">
    <table class="data-grid">
      <thead>
        <tr>
          <th>Time</th>
          <th>Event Type</th>
          <th>Tool</th>
          <th>Details</th>
        </tr>
      </thead>
      <tbody>
    '''

    for row in events:
        ts, etype, tool, payload = row
        ts_str = format_timestamp(ts)

        # Parse payload for interesting bits
        try:
            pdata = json.loads(payload)
            details = []
            if 'rule' in pdata:
                details.append(f"rule: {pdata['rule']}")
            if 'tokens_saved' in pdata:
                details.append(f"{pdata['tokens_saved']} tokens")
            if 'output_bytes' in pdata:
                details.append(f"{pdata['output_bytes']} bytes")
            detail_str = ", ".join(details)
        except:
            detail_str = ""

        badge_class = etype.replace("_", "")
        html += f'''
        <tr>
          <td class="col-ts">{h(ts_str)}</td>
          <td><span class="badge {badge_class}">{h(etype)}</span></td>
          <td>{h(tool or "")}</td>
          <td>{h(detail_str)}</td>
        </tr>
        '''

    html += '</tbody></table></div>'
    return html


def render_conversation_view(db, session_id=None):
    """Render conversation turn log with autonomous response detection."""
    if not session_id:
        row = db.execute("SELECT session_id FROM sessions ORDER BY updated_at_ns DESC LIMIT 1").fetchone()
        if not row:
            return '<div class="empty-state">No sessions available</div>'
        session_id = row[0]

    # Query autonomous_response events
    auto_events = db.execute("""
        SELECT occurred_at_ns, event_type, tool_name, payload_json
        FROM hook_events
        WHERE session_id = ? AND event_type = 'autonomous_response'
        ORDER BY occurred_at_ns DESC
        LIMIT 100
    """, [session_id]).fetchall()

    # Query all stop events (turn boundaries)
    stop_events = db.execute("""
        SELECT occurred_at_ns, event_type, tool_name, payload_json
        FROM hook_events
        WHERE session_id = ? AND event_type = 'session_stop'
        ORDER BY occurred_at_ns DESC
        LIMIT 200
    """, [session_id]).fetchall()

    auto_count = len(auto_events)
    alert_banner = ""
    if auto_count > 0:
        alert_banner = f'''
        <div style="background:var(--red);color:#fff;padding:8px 16px;border-radius:2px;margin-bottom:12px;">
            {auto_count} autonomous response(s) detected &mdash;
            Claude responded to non-human input and may have impersonated the user.
        </div>
        '''

    html = f'''
    <div class="view-header">
      <h2>Conversation Trace</h2>
      <span class="count">{len(stop_events)} turns, {auto_count} autonomous</span>
    </div>
    <div style="padding:16px;">
    {alert_banner}
    '''

    if auto_events:
        html += '''
        <h3 style="margin-bottom:8px;">Autonomous Responses</h3>
        <table class="data-grid">
          <thead><tr>
            <th>Time</th><th>Origin</th><th>Request ID</th><th>Response Preview</th>
          </tr></thead><tbody>
        '''
        for row in auto_events:
            ts, etype, tool, payload = row
            ts_str = format_timestamp(ts)
            try:
                pdata = json.loads(payload)
                origin = pdata.get('origin', '?')
                req_id = pdata.get('request_id', '')[:12]
                preview = pdata.get('response_preview', '')
            except Exception:
                origin, req_id, preview = '?', '', ''

            html += f'''
            <tr>
              <td class="col-ts">{h(ts_str)}</td>
              <td><span class="badge autonomousresponse">{h(origin)}</span></td>
              <td style="font-size:10px;">{h(req_id)}</td>
              <td class="response-preview" title="{h(preview)}">{h(preview)}</td>
            </tr>
            '''
        html += '</tbody></table><br>'

    html += '''
    <h3 style="margin-bottom:8px;">Turn History</h3>
    <table class="data-grid">
      <thead><tr>
        <th>Time</th><th>Event</th><th>Reason</th><th>Duration</th>
      </tr></thead><tbody>
    '''
    for row in stop_events:
        ts, etype, tool, payload = row
        ts_str = format_timestamp(ts)
        try:
            pdata = json.loads(payload)
            reason = pdata.get('reason', '')
            dur = pdata.get('duration_seconds', 0)
        except Exception:
            reason, dur = '', 0

        html += f'''
        <tr>
          <td class="col-ts">{h(ts_str)}</td>
          <td><span class="badge sessionend">{h(etype)}</span></td>
          <td>{h(reason)}</td>
          <td>{dur}s</td>
        </tr>
        '''

    html += '</tbody></table></div>'
    return html


def render_cost_view(db, session_id=None):
    """Render cost charts."""
    # Recent sessions cost bar chart
    sessions = db.execute("""
        SELECT session_id, cost_usd
        FROM sessions
        WHERE cost_usd > 0
        ORDER BY updated_at_ns DESC
        LIMIT 20
    """).fetchall()

    max_cost = max((s[1] for s in sessions), default=1)

    html = '''
    <div class="view-header">
      <h2>Cost Analysis</h2>
    </div>
    <div class="chart-row">
      <div class="chart-box">
        <div class="chart-title">Recent Sessions</div>
        <div class="bar-chart">
    '''

    for sid, cost in sessions:
        sid_short = sid[-8:] if len(sid) > 8 else sid
        width_pct = (cost / max_cost * 100) if max_cost > 0 else 0
        color = COLORS["warden_blue"] if cost < 0.10 else COLORS["amber"] if cost < 0.50 else COLORS["orange"]

        html += f'''
        <div class="bar-item">
          <div class="bar-label">{h(sid_short)}</div>
          <div class="bar-visual">
            <div class="bar-fill" style="width:{width_pct:.1f}%; background:{color};"></div>
          </div>
          <div class="bar-value">${cost:.4f}</div>
        </div>
        '''

    html += '''
        </div>
      </div>
    </div>
    '''
    return html


def render_tools_view(db, session_id=None):
    """Render top tools (slowest calls, largest outputs, most blocked)."""
    if not session_id:
        row = db.execute("SELECT session_id FROM sessions ORDER BY updated_at_ns DESC LIMIT 1").fetchone()
        if not row:
            return '<div class="empty-state">No sessions available</div>'
        session_id = row[0]

    # Slowest tool calls
    slow_tools = db.execute("""
        SELECT name, duration_ms, attrs_json
        FROM spans
        WHERE session_id = ? AND name LIKE 'claude_code.tool%'
        ORDER BY duration_ms DESC
        LIMIT 20
    """, (session_id,)).fetchall()

    html = '''
    <div class="view-header">
      <h2>Top Tools</h2>
    </div>
    <div style="padding:16px;">
      <div class="chart-title">Slowest Tool Calls</div>
      <table class="data-grid">
        <thead>
          <tr><th>Tool</th><th>Duration</th><th>Result Tokens</th></tr>
        </thead>
        <tbody>
    '''

    for name, dur, attrs in slow_tools:
        a = decode_otlp_attrs(attrs)
        result_tokens = a.get('result_tokens', '')
        tool_name = a.get('tool_name') or name.replace('claude_code.tool.', '')
        if tool_name == 'claude_code.tool':
            tool_name = 'tool'
        html += f'''
        <tr>
          <td>{h(tool_name)}</td>
          <td>{h(format_duration_ms(dur))}</td>
          <td>{h(str(result_tokens))}</td>
        </tr>
        '''

    html += '</tbody></table></div>'
    return html


def render_trend_view(db, session_id=None):
    """Render context % trend sparkline."""
    if not session_id:
        row = db.execute("SELECT session_id FROM sessions ORDER BY updated_at_ns DESC LIMIT 1").fetchone()
        if not row:
            return '<div class="empty-state">No sessions available</div>'
        session_id = row[0]

    # Get llm_request spans to show context growth over time
    llm_spans = db.execute("""
        SELECT start_ns, attrs_json
        FROM spans
        WHERE session_id = ? AND name = 'claude_code.llm_request'
        ORDER BY start_ns ASC
        LIMIT 50
    """, (session_id,)).fetchall()

    if not llm_spans:
        return '<div class="empty-state">No LLM request data for trend</div>'

    # Extract input_tokens from each span
    data_points = []
    for start, attrs in llm_spans:
        a = decode_otlp_attrs(attrs)
        inp = attr_int(a, 'input_tokens', 0)
        cache_r = attr_int(a, 'cache_read_tokens', 0)
        total = inp + cache_r
        if total > 0:
            data_points.append(total)

    if not data_points:
        return '<div class="empty-state">No token data available</div>'

    max_val = max(data_points)

    html = '''
    <div class="view-header">
      <h2>Token Trend</h2>
      <span class="count">Context usage over time</span>
    </div>
    <div style="padding:16px;">
      <div class="chart-box">
        <div class="chart-title">Input Tokens per LLM Request</div>
        <div class="sparkline-container">
          <div class="sparkline-canvas">
    '''

    for val in data_points:
        height_pct = (val / max_val * 100) if max_val > 0 else 0
        html += f'<div class="sparkline-bar" style="height:{height_pct:.1f}%;"></div>'

    html += '''
          </div>
        </div>
      </div>
    </div>
    '''
    return html


# ── Utility Functions ────────────────────────────────────────────────

def decode_otlp_attrs(attrs_json):
    """Decode OTLP key/value attributes into a plain dict."""
    try:
        raw = json.loads(attrs_json)
    except Exception:
        return {}

    if isinstance(raw, dict):
        return raw
    if not isinstance(raw, list):
        return {}

    decoded = {}
    for item in raw:
        if not isinstance(item, dict):
            continue
        key = item.get("key")
        value = item.get("value", {})
        if not key or not isinstance(value, dict):
            continue
        if "stringValue" in value:
            decoded[key] = value["stringValue"]
        elif "intValue" in value:
            try:
                decoded[key] = int(value["intValue"])
            except Exception:
                decoded[key] = value["intValue"]
        elif "doubleValue" in value:
            decoded[key] = value["doubleValue"]
        elif "boolValue" in value:
            decoded[key] = value["boolValue"]
    return decoded


def attr_int(attrs, key, default=0):
    """Read an OTLP attribute as an int when possible."""
    value = attrs.get(key, default)
    try:
        return int(value)
    except Exception:
        return default

def format_duration_ms(ms):
    """Format milliseconds as human-readable."""
    if ms < 1000:
        return f"{ms}ms"
    elif ms < 60000:
        return f"{ms/1000:.1f}s"
    else:
        return f"{ms/60000:.1f}m"


def format_timestamp(ns):
    """Format nanosecond timestamp."""
    if ns == 0:
        return "—"
    dt = datetime.fromtimestamp(ns / 1e9)
    return dt.strftime("%H:%M:%S")


def get_db_info(db_path):
    """Get database file info for display."""
    if not os.path.exists(db_path):
        return "No database"
    size = os.path.getsize(db_path)
    if size < 1024:
        return f"{size}B"
    elif size < 1024*1024:
        return f"{size/1024:.1f}KB"
    else:
        return f"{size/(1024*1024):.1f}MB"


# ── HTTP Server ──────────────────────────────────────────────────────

class WardenHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        db = sqlite3.connect(self.server.db_path)
        db.row_factory = sqlite3.Row

        session_id = query.get('session', [None])[0]

        try:
            if path == '/':
                # Main page
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.end_headers()
                db_info = get_db_info(self.server.db_path)
                self.wfile.write(HTML_PAGE.replace('%(db_path)s', db_info).encode())

            elif path == '/sidebar':
                # Sidebar with session list
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.end_headers()
                html = render_sidebar(db, session_id)
                self.wfile.write(html.encode())

            elif path == '/view/context':
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.end_headers()
                html = render_context_view(db, session_id)
                self.wfile.write(html.encode())

            elif path == '/view/waterfall':
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.end_headers()
                html = render_waterfall_view(db, session_id)
                self.wfile.write(html.encode())

            elif path == '/view/events':
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.end_headers()
                html = render_events_view(db, session_id)
                self.wfile.write(html.encode())

            elif path == '/view/cost':
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.end_headers()
                html = render_cost_view(db, session_id)
                self.wfile.write(html.encode())

            elif path == '/view/tools':
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.end_headers()
                html = render_tools_view(db, session_id)
                self.wfile.write(html.encode())

            elif path == '/view/trend':
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.end_headers()
                html = render_trend_view(db, session_id)
                self.wfile.write(html.encode())

            elif path == '/view/conversation':
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.end_headers()
                html = render_conversation_view(db, session_id)
                self.wfile.write(html.encode())

            else:
                self.send_error(404)

        finally:
            db.close()

    def log_message(self, format, *args):
        # Suppress access logs
        pass


def main():
    import argparse
    parser = argparse.ArgumentParser(description='Warden Viewer - Claude Code Monitor')
    parser.add_argument('--port', type=int, default=DEFAULT_PORT, help=f'Port (default: {DEFAULT_PORT})')
    parser.add_argument('--db', default=DEFAULT_DB, help=f'Database path (default: {DEFAULT_DB})')
    parser.add_argument('--no-browser', action='store_true', help='Do not open browser')
    args = parser.parse_args()

    if not os.path.exists(args.db):
        print(f"Error: Database not found at {args.db}", file=sys.stderr)
        print(f"Expected collector database at: {DEFAULT_DB}", file=sys.stderr)
        sys.exit(1)

    server = http.server.HTTPServer(('127.0.0.1', args.port), WardenHandler)
    server.db_path = args.db

    url = f"http://localhost:{args.port}"
    print(f"Warden Viewer running at {url}")
    print(f"Database: {args.db}")
    print(f"Press Ctrl+C to stop")

    if not args.no_browser:
        webbrowser.open(url)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == '__main__':
    main()
