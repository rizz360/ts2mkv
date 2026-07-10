#!/usr/bin/env python3
"""ts2mkv web dashboard — serves a status page by reading log files."""

import glob
import http.server
import json
import os
import sys
import time
from datetime import datetime, timedelta

LOG_DIR = os.environ.get("LOG_DIR", "/app/logs")

try:
    PORT = int(os.environ.get("WEB_PORT", "8080"))
except ValueError:
    _raw_port = os.environ.get("WEB_PORT", "")
    print(f"[dashboard] WARNING: WEB_PORT '{_raw_port}' is not a valid integer; falling back to 8080", flush=True)
    PORT = 8080


# ---------------------------------------------------------------------------
# Data helpers
# ---------------------------------------------------------------------------

def _read_lines(path):
    """Return non-empty stripped lines from a file, or [] if missing."""
    try:
        with open(path, "r", errors="replace") as fh:
            return [l.rstrip("\n") for l in fh if l.strip()]
    except FileNotFoundError:
        return []


def _read_tail_lines(path, n):
    """Return the last *n* non-empty stripped lines efficiently (reads from end)."""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, 2)
            file_size = fh.tell()
            if file_size == 0:
                return []
            # Read a chunk from the end large enough to contain n lines
            chunk_size = min(max(n * 200, 8192), file_size)
            fh.seek(max(0, file_size - chunk_size))
            data = fh.read().decode("utf-8", errors="replace")
            lines = [l.strip() for l in data.split("\n") if l.strip()]
            return lines[-n:]
    except FileNotFoundError:
        return []


def _count_lines(path):
    """Count non-empty lines in a file without loading it fully into memory."""
    try:
        count = 0
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                count += chunk.count(b"\n")
        return count
    except FileNotFoundError:
        return 0


def _read_text(path):
    try:
        with open(path, "r", errors="replace") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


def _parse_ffmpeg_progress(path):
    """Parse an ffmpeg -progress file, returning a dict of the last values seen."""
    content = _read_text(path)
    result = {}
    for line in content.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            result[k.strip()] = v.strip()
    return result


def _fmt_duration(seconds):
    if seconds is None:
        return None
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}"


def _parse_out_time(out_time_str):
    """Parse 'HH:MM:SS.usec' → total seconds (float). Returns None on failure."""
    try:
        parts = out_time_str.split(":")
        if len(parts) != 3:
            return None
        h, m, s = int(parts[0]), int(parts[1]), float(parts[2])
        return h * 3600 + m * 60 + s
    except (ValueError, IndexError):
        return None


def _strip_input_prefix(path):
    """Remove /input/ prefix for cleaner display."""
    for prefix in ("/input/", "/input"):
        if path.startswith(prefix):
            return path[len(prefix):]
    return path


def _get_active_jobs():
    """Return list of (meta, progress_data) from per-job current_meta.{PID}.json files."""
    jobs = []
    for meta_path in sorted(glob.glob(os.path.join(LOG_DIR, "current_meta.*.json"))):
        try:
            with open(meta_path, "r") as fh:
                meta = json.load(fh)
            if not meta:
                continue
            # Filename: current_meta.{PID}.json → extract PID
            parts = os.path.basename(meta_path).split(".")
            # Validate expected format: ['current_meta', '<pid>', 'json']
            if len(parts) != 3 or parts[0] != "current_meta" or parts[2] != "json":
                continue
            pid = parts[1]
            progress_path = os.path.join(LOG_DIR, f"ffmpeg_progress.{pid}.log")
            progress_data = _parse_ffmpeg_progress(progress_path)
            jobs.append((meta, progress_data))
        except (FileNotFoundError, json.JSONDecodeError):
            pass
    return jobs


# ---------------------------------------------------------------------------
# Status builder
# ---------------------------------------------------------------------------

def get_status():
    # Active jobs — one per running process (safe for parallel mode)
    active_jobs = _get_active_jobs()
    current_files_set = {meta.get("file", "") for meta, _ in active_jobs}

    # Completed / errored — read only a tail to stay O(1) for long-running containers.
    # Use a generous tail for the done set so queue filtering remains accurate.
    _DONE_TAIL = 2000
    done_tail = _read_tail_lines(os.path.join(LOG_DIR, "done.log"), _DONE_TAIL)
    done_count = _count_lines(os.path.join(LOG_DIR, "done.log"))
    error_files = _read_lines(os.path.join(LOG_DIR, "error.log"))

    # Queue — prefer queue.log written at startup, fall back to poll_queue.log
    queue_files = _read_lines(os.path.join(LOG_DIR, "queue.log"))
    if not queue_files:
        queue_files = _read_lines(os.path.join(LOG_DIR, "poll_queue.log"))

    done_set = set(done_tail)
    error_set = set(error_files)
    remaining_queue = [
        f for f in queue_files
        if f not in done_set and f not in error_set and f not in current_files_set
    ]

    # Build current-job info from the first active job (most recently started)
    current_info = None
    if active_jobs:
        meta, progress_data = active_jobs[0]
        now = int(time.time())
        started = meta.get("started", now)
        duration_sec = float(meta.get("duration_sec") or 0)
        elapsed_sec = max(0, now - started)
        current_file = meta.get("file", "")

        # Progress from ffmpeg
        progress_pct = None
        eta_sec = None
        out_time = progress_data.get("out_time", "")
        if out_time:
            processed_sec = _parse_out_time(out_time)
            if processed_sec is not None and duration_sec > 0:
                progress_pct = min(100.0, processed_sec / duration_sec * 100)

        speed_str = progress_data.get("speed", "")
        if progress_pct is not None and speed_str and speed_str not in ("N/A", "0x"):
            try:
                speed_val = float(speed_str.rstrip("x"))
                if speed_val > 0 and duration_sec > 0:
                    remaining_input_sec = duration_sec * (1 - progress_pct / 100)
                    eta_sec = int(remaining_input_sec / speed_val)
            except ValueError:
                pass

        current_info = {
            "file": os.path.basename(current_file),
            "display_path": _strip_input_prefix(current_file),
            "started_fmt": datetime.fromtimestamp(started).strftime("%Y-%m-%d %H:%M:%S"),
            "elapsed_fmt": _fmt_duration(elapsed_sec),
            "duration_fmt": _fmt_duration(duration_sec) if duration_sec else None,
            "progress_pct": round(progress_pct, 1) if progress_pct is not None else None,
            "speed": speed_str or None,
            "fps": progress_data.get("fps") or None,
            "bitrate": progress_data.get("bitrate") or None,
            "eta_fmt": _fmt_duration(eta_sec),
            "mode": meta.get("mode") or None,
            "active_job_count": len(active_jobs),
        }

    return {
        "current": current_info,
        "current_progress_pct": current_info.get("progress_pct") if current_info and current_info.get("progress_pct") is not None else 0,
        "queue_remaining": [_strip_input_prefix(f) for f in remaining_queue],
        "queue_total": len(queue_files),
        "queue_remaining_count": len(remaining_queue),
        "done_recent": [_strip_input_prefix(f) for f in done_tail[-30:][::-1]],
        "done_count": done_count,
        "errors": [_strip_input_prefix(f) for f in error_files],
        "error_count": len(error_files),
        "updated": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }


# ---------------------------------------------------------------------------
# HTML template
# ---------------------------------------------------------------------------

HTML = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ts2mkv dashboard</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --bg:       #0d1117;
    --card:     #161b22;
    --border:   #30363d;
    --text:     #c9d1d9;
    --muted:    #8b949e;
    --blue:     #58a6ff;
    --green:    #3fb950;
    --red:      #f85149;
    --yellow:   #d29922;
    --purple:   #bc8cff;
    --bar-bg:   #21262d;
  }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace;
    font-size: 14px;
    line-height: 1.5;
    min-height: 100vh;
  }

  header {
    background: var(--card);
    border-bottom: 1px solid var(--border);
    padding: 14px 24px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    position: sticky;
    top: 0;
    z-index: 10;
  }

  header h1 { font-size: 16px; font-weight: 600; color: var(--blue); letter-spacing: .5px; }
  #updated { font-size: 12px; color: var(--muted); }
  #dot {
    display: inline-block; width: 8px; height: 8px;
    border-radius: 50%; background: var(--green);
    margin-right: 6px; vertical-align: middle;
    animation: pulse 2s infinite;
  }
  @keyframes pulse { 0%,100% { opacity:1 } 50% { opacity:.3 } }

  main {
    max-width: 1200px;
    margin: 0 auto;
    padding: 24px 16px;
    display: grid;
    grid-template-columns: 1fr 1fr 1fr;
    grid-template-rows: auto auto;
    gap: 16px;
  }

  .card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 16px;
  }

  .card-current { grid-column: 1 / -1; }

  .card h2 {
    font-size: 12px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--muted);
    margin-bottom: 12px;
  }

  /* Current job */
  .job-idle { color: var(--muted); font-style: italic; }

  .job-file {
    font-size: 15px;
    font-weight: 600;
    color: var(--blue);
    word-break: break-all;
    margin-bottom: 8px;
  }

  .job-meta {
    display: flex;
    flex-wrap: wrap;
    gap: 16px;
    margin-bottom: 12px;
    font-size: 13px;
    color: var(--muted);
  }

  .job-meta span { white-space: nowrap; }
  .job-meta .label { color: var(--muted); }
  .job-meta .val { color: var(--text); font-weight: 500; }

  .progress-wrap { margin-top: 6px; }
  .progress-bar-bg {
    background: var(--bar-bg);
    border-radius: 4px;
    height: 10px;
    overflow: hidden;
    margin-bottom: 4px;
  }
  .progress-bar-fill {
    height: 100%;
    background: linear-gradient(90deg, var(--blue), var(--purple));
    border-radius: 4px;
    transition: width .5s ease;
  }
  .progress-label {
    font-size: 12px;
    color: var(--muted);
    display: flex;
    justify-content: space-between;
  }

  /* Lists */
  .file-list {
    list-style: none;
    max-height: 260px;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: var(--border) transparent;
  }

  .file-list li {
    padding: 5px 4px;
    border-bottom: 1px solid var(--border);
    font-size: 12px;
    color: var(--text);
    word-break: break-all;
  }
  .file-list li:last-child { border-bottom: none; }
  .file-list li .num {
    display: inline-block;
    min-width: 22px;
    color: var(--muted);
    font-size: 11px;
  }

  .count-badge {
    font-size: 22px;
    font-weight: 700;
    margin-bottom: 8px;
  }

  .green { color: var(--green); }
  .red   { color: var(--red); }
  .blue  { color: var(--blue); }
  .yellow{ color: var(--yellow); }

  .empty { color: var(--muted); font-style: italic; font-size: 13px; }

  @media (max-width: 700px) {
    main { grid-template-columns: 1fr; }
    .card-current { grid-column: 1; }
  }
</style>
</head>
<body>

<header>
  <h1><span id="dot"></span>ts2mkv</h1>
  <span id="updated">Loading…</span>
</header>

<main>
  <!-- Current job -->
  <div class="card card-current">
    <h2>Now processing</h2>
    <div id="current-body"><span class="job-idle">Idle — no file being processed.</span></div>
  </div>

  <!-- Queue -->
  <div class="card">
    <h2>Queue</h2>
    <div class="count-badge blue" id="queue-count">—</div>
    <div id="queue-label" style="font-size:12px;color:var(--muted);margin-bottom:8px;"></div>
    <ul class="file-list" id="queue-list"></ul>
  </div>

  <!-- Done -->
  <div class="card">
    <h2>Completed</h2>
    <div class="count-badge green" id="done-count">—</div>
    <ul class="file-list" id="done-list"></ul>
  </div>

  <!-- Errors -->
  <div class="card">
    <h2>Errors</h2>
    <div class="count-badge red" id="error-count">—</div>
    <ul class="file-list" id="error-list"></ul>
  </div>
</main>

<script>
  function esc(s) {
    return String(s)
      .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  function metaItem(label, val) {
    if (!val) return '';
    return `<span><span class="label">${label}</span> <span class="val">${esc(val)}</span></span>`;
  }

  function renderCurrent(c) {
    const el = document.getElementById('current-body');
    if (!c) {
      el.innerHTML = '<span class="job-idle">Idle — no file being processed.</span>';
      return;
    }

    const pct = c.progress_pct !== null ? c.progress_pct : null;
    const barWidth = pct !== null ? pct : 0;
    const pctLabel = pct !== null ? `${pct}%` : 'remuxing…';
    const etaLabel = c.eta_fmt ? `ETA ${c.eta_fmt}` : '';

    const progressHtml = `
      <div class="progress-wrap">
        <div class="progress-bar-bg">
          <div class="progress-bar-fill" style="width:${barWidth}%"></div>
        </div>
        <div class="progress-label"><span>${pctLabel}</span><span>${esc(etaLabel)}</span></div>
      </div>`;

    el.innerHTML = `
      <div class="job-file">${esc(c.display_path)}</div>
      <div class="job-meta">
        ${metaItem('Started', c.started_fmt)}
        ${metaItem('Elapsed', c.elapsed_fmt)}
        ${metaItem('Duration', c.duration_fmt)}
        ${metaItem('Mode', c.mode)}
        ${metaItem('Speed', c.speed)}
        ${metaItem('FPS', c.fps)}
        ${metaItem('Bitrate', c.bitrate)}
      </div>
      ${progressHtml}`;
  }

  function renderList(ulId, items, emptyMsg, colorClass) {
    const ul = document.getElementById(ulId);
    if (!items || items.length === 0) {
      ul.innerHTML = `<li class="empty">${emptyMsg}</li>`;
      return;
    }
    ul.innerHTML = items.map((f, i) =>
      `<li><span class="num ${colorClass || ''}">${i + 1}</span> ${esc(f)}</li>`
    ).join('');
  }

  async function refresh() {
    let data;
    try {
      const resp = await fetch('/api/status');
      data = await resp.json();
    } catch (e) {
      document.getElementById('updated').textContent = 'Connection error';
      return;
    }

    document.getElementById('updated').textContent = 'Updated ' + data.updated;

    renderCurrent(data.current);

    document.getElementById('queue-count').textContent = data.queue_remaining_count;
    document.getElementById('queue-label').textContent =
      data.queue_total > 0 ? `${data.queue_remaining_count} of ${data.queue_total} remaining` : '';
    renderList('queue-list', data.queue_remaining, 'Queue is empty.', 'blue');

    document.getElementById('done-count').textContent = data.done_count;
    renderList('done-list', data.done_recent, 'Nothing completed yet.', 'green');

    document.getElementById('error-count').textContent = data.error_count;
    renderList('error-list', data.errors, 'No errors.', 'red');
  }

  refresh();
  setInterval(refresh, 3000);
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/", "/index.html"):
            body = HTML.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)

        elif self.path == "/api/status":
            body = json.dumps(get_status(), default=str).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)

        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):  # suppress access logs
        pass


if __name__ == "__main__":
    # ThreadingHTTPServer so one slow/stalled client cannot block the
    # dashboard and /api/status pollers (HA, homepage, browser tabs).
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), _Handler)
    print(f"[dashboard] Listening on http://0.0.0.0:{PORT}", flush=True)
    server.serve_forever()
