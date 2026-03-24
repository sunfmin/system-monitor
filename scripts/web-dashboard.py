#!/usr/bin/env python3
"""
System Monitor Web Dashboard
Serves a live HTML dashboard showing transcripts, screenshots, and summaries.
Usage: python3 web-dashboard.py <base_dir> [port]
"""

import os
import sys
import json
import glob
import http.server
import mimetypes
from urllib.parse import urlparse, parse_qs

BASE_DIR = sys.argv[1] if len(sys.argv) > 1 else "system_monitor"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8420

HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>System Monitor</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=DM+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
  :root {
    --bg-deep: #080a10;
    --bg-panel: #0c0e16;
    --bg-card: #10131c;
    --bg-hover: #141825;
    --border: #1a1e2e;
    --border-light: #252a3a;
    --accent: #d4a017;
    --accent-dim: #8b6914;
    --cyan: #4ec9b0;
    --cyan-dim: #2a7a66;
    --text: #c8cad0;
    --text-dim: #6b7084;
    --text-bright: #eaecf0;
    --red: #e05252;
    --font-mono: 'JetBrains Mono', 'SF Mono', monospace;
    --font-body: 'DM Sans', -apple-system, sans-serif;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: var(--font-body); background: var(--bg-deep); color: var(--text); height: 100vh; overflow: hidden; }

  /* Grain overlay */
  body::after {
    content: ''; position: fixed; inset: 0; z-index: 9999; pointer-events: none; opacity: 0.025;
    background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
  }

  /* Header */
  .header {
    height: 52px; padding: 0 28px; display: flex; align-items: center; justify-content: space-between;
    background: linear-gradient(180deg, #0e1018 0%, var(--bg-deep) 100%);
    border-bottom: 1px solid var(--border);
  }
  .header-left { display: flex; align-items: center; gap: 14px; }
  .logo {
    display: flex; align-items: center; gap: 10px;
    font-family: var(--font-mono); font-size: 13px; font-weight: 600;
    color: var(--accent); letter-spacing: 2px; text-transform: uppercase;
  }
  .logo-icon {
    width: 28px; height: 28px; border-radius: 6px; display: flex; align-items: center; justify-content: center;
    background: linear-gradient(135deg, var(--accent) 0%, #b8860b 100%);
    box-shadow: 0 0 20px rgba(212,160,23,0.15);
  }
  .logo-icon svg { width: 14px; height: 14px; }
  .live-badge {
    display: flex; align-items: center; gap: 6px; padding: 3px 10px 3px 8px;
    border-radius: 20px; background: rgba(78,201,176,0.08); border: 1px solid rgba(78,201,176,0.15);
    font-family: var(--font-mono); font-size: 10px; color: var(--cyan); font-weight: 500; letter-spacing: 0.5px;
  }
  .live-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--cyan); animation: blink 2s infinite; }
  @keyframes blink { 0%,100%{opacity:1} 50%{opacity:0.25} }
  .status-text { font-family: var(--font-mono); font-size: 11px; color: var(--text-dim); letter-spacing: 0.3px; }

  /* Layout */
  .container { display: grid; grid-template-columns: 1fr 380px; height: calc(100vh - 52px); }

  /* Timeline */
  .timeline-wrap { display: flex; flex-direction: column; overflow: hidden; }
  .panel-tab {
    padding: 14px 28px; font-family: var(--font-mono); font-size: 10px; font-weight: 600;
    letter-spacing: 1.5px; text-transform: uppercase; color: var(--text-dim);
    background: var(--bg-panel); border-bottom: 1px solid var(--border);
    display: flex; align-items: center; gap: 10px;
  }
  .panel-tab .count { color: var(--accent); font-size: 11px; }
  .timeline { flex: 1; overflow-y: auto; }

  .t-line {
    padding: 6px 28px; display: flex; gap: 16px; align-items: baseline;
    border-bottom: 1px solid rgba(26,30,46,0.5); transition: background 0.15s;
  }
  .t-line:hover { background: var(--bg-hover); }
  .t-line.t-raw { opacity: 0.7; }
  .t-line.t-raw .t-text { color: var(--text-dim); font-size: 12.5px; }
  .t-line.t-partial {
    padding: 14px 28px 14px; border-bottom: 2px solid var(--accent-dim);
    background: linear-gradient(180deg, rgba(212,160,23,0.06) 0%, rgba(212,160,23,0.02) 100%);
    position: sticky; top: 0; z-index: 10;
    max-height: 30vh; overflow-y: auto;
  }
  .t-line.t-partial .t-text {
    color: var(--text-bright); font-size: 13.5px; line-height: 1.65;
    display: block;
  }
  .t-line.t-partial .t-text::after { content: ' ▋'; animation: cursor 0.6s infinite; color: var(--accent); }
  .t-line.t-partial .t-time { color: var(--accent-dim); display: block; margin-bottom: 6px; font-size: 10px; }
  @keyframes cursor { 0%,100%{opacity:1} 50%{opacity:0} }
  .t-line.t-sentence { background: rgba(78,201,176,0.03); border-left: 2px solid var(--cyan-dim); animation: sentenceIn 0.5s ease-out; }
  .t-line.t-sentence .t-text { color: var(--text-bright); font-size: 13.5px; }
  .t-line.t-sentence .t-time { color: var(--cyan); }
  @keyframes sentenceIn {
    from { opacity: 0; transform: translateY(-8px); background: rgba(78,201,176,0.1); }
    to { opacity: 1; transform: translateY(0); background: rgba(78,201,176,0.03); }
  }
  .t-time {
    font-family: var(--font-mono); font-size: 11px; color: var(--cyan-dim);
    white-space: nowrap; min-width: 58px; user-select: none;
  }
  .t-text { font-size: 13.5px; line-height: 1.65; color: var(--text); }
  .t-new { animation: slideIn 0.35s ease-out; }
  .t-section-label {
    padding: 6px 28px; font-family: var(--font-mono); font-size: 9px; font-weight: 600;
    letter-spacing: 1.5px; text-transform: uppercase; color: var(--accent-dim);
    background: var(--bg-card); border-bottom: 1px solid var(--border);
  }
  @keyframes slideIn {
    from { opacity: 0; transform: translateY(-4px); }
    to { opacity: 1; transform: translateY(0); }
  }

  .t-screenshot {
    padding: 16px 28px; border-bottom: 1px solid var(--border);
    background: linear-gradient(180deg, rgba(16,19,28,0.5) 0%, transparent 100%);
  }
  .t-screenshot .t-time {
    display: flex; align-items: center; gap: 8px; margin-bottom: 10px;
    font-family: var(--font-mono); font-size: 10px; color: var(--accent-dim);
    letter-spacing: 0.5px; text-transform: uppercase;
  }
  .t-screenshot .t-time::before {
    content: ''; width: 16px; height: 1px; background: var(--accent-dim);
  }
  .t-screenshot img {
    width: 100%; max-width: 680px; border-radius: 6px;
    border: 1px solid var(--border-light);
    box-shadow: 0 4px 24px rgba(0,0,0,0.4), 0 0 0 1px rgba(255,255,255,0.02);
    transition: transform 0.2s, box-shadow 0.2s; cursor: pointer;
  }
  .t-screenshot img:hover {
    transform: scale(1.005);
    box-shadow: 0 8px 40px rgba(0,0,0,0.5), 0 0 0 1px rgba(212,160,23,0.1);
  }

  /* Summary Panel */
  .summary-panel { display: flex; flex-direction: column; background: var(--bg-panel); border-left: 1px solid var(--border); }
  .summary-body { flex: 1; overflow-y: auto; padding: 16px; }

  .s-block {
    background: var(--bg-card); border-radius: 8px; padding: 14px 16px;
    margin-bottom: 12px; position: relative; overflow: hidden;
    border: 1px solid var(--border); transition: border-color 0.2s;
  }
  .s-block:hover { border-color: var(--border-light); }
  .s-block::before {
    content: ''; position: absolute; left: 0; top: 0; bottom: 0; width: 3px;
    background: linear-gradient(180deg, var(--accent) 0%, var(--accent-dim) 100%);
    border-radius: 3px 0 0 3px;
  }
  .s-block:first-child::before {
    background: linear-gradient(180deg, var(--cyan) 0%, var(--cyan-dim) 100%);
  }
  .s-time {
    font-family: var(--font-mono); font-size: 10px; color: var(--accent);
    letter-spacing: 0.5px; margin-bottom: 8px; font-weight: 500;
  }
  .s-block:first-child .s-time { color: var(--cyan); }
  .s-text { font-size: 12.5px; line-height: 1.75; color: var(--text); }
  .s-text ul { padding-left: 14px; margin: 0; }
  .s-text li { margin: 4px 0; color: var(--text); }
  .s-text li::marker { color: var(--accent-dim); }
  .s-block:first-child .s-text li::marker { color: var(--cyan-dim); }

  /* Scrollbar */
  ::-webkit-scrollbar { width: 4px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 4px; }
  ::-webkit-scrollbar-thumb:hover { background: var(--border-light); }

  /* Lightbox */
  .lightbox {
    position: fixed; inset: 0; z-index: 1000; background: rgba(0,0,0,0.88);
    display: none; align-items: center; justify-content: center; cursor: zoom-out;
    backdrop-filter: blur(8px);
  }
  .lightbox.active { display: flex; }
  .lightbox img { max-width: 92vw; max-height: 92vh; border-radius: 8px; box-shadow: 0 20px 60px rgba(0,0,0,0.6); }
</style>
</head>
<body>
<div class="header">
  <div class="header-left">
    <div class="logo">
      <div class="logo-icon"><svg viewBox="0 0 24 24" fill="none" stroke="#080a10" stroke-width="2.5"><circle cx="12" cy="12" r="3"/><path d="M12 1v4M12 19v4M4.22 4.22l2.83 2.83M16.95 16.95l2.83 2.83M1 12h4M19 12h4M4.22 19.78l2.83-2.83M16.95 7.05l2.83-2.83"/></svg></div>
      Monitor
    </div>
    <div class="live-badge"><span class="live-dot"></span>LIVE</div>
  </div>
  <div style="display:flex;align-items:center;gap:16px;">
    <a href="/brief" style="font-family:var(--font-mono);font-size:10px;color:var(--accent);text-decoration:none;letter-spacing:1px;border:1px solid var(--accent-dim);padding:4px 12px;border-radius:4px;">BRIEF</a>
    <span class="status-text" id="status">Connecting...</span>
  </div>
</div>
<div class="container">
  <div class="timeline-wrap">
    <div class="panel-tab">Timeline <span class="count" id="itemCount">0</span></div>
    <div class="timeline" id="timeline"></div>
  </div>
  <div class="summary-panel">
    <div class="panel-tab">Briefing <span class="count" id="summaryCount">0</span></div>
    <div class="summary-body" id="summary"></div>
  </div>
</div>
<div class="lightbox" id="lightbox" onclick="this.classList.remove('active')"><img id="lbImg"></div>

<script>
const timeline = document.getElementById('timeline');
const statusEl = document.getElementById('status');
const itemCountEl = document.getElementById('itemCount');
const summaryCountEl = document.getElementById('summaryCount');
let lastDataHash = '';
let userScrolled = false;

timeline.addEventListener('scroll', () => {
  userScrolled = timeline.scrollTop > 50;
});

function openLightbox(src) {
  document.getElementById('lbImg').src = src;
  document.getElementById('lightbox').classList.add('active');
}

function esc(s) {
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

// Convert HH:MM:SS to sortable seconds
function timeToSec(t) {
  const p = t.split(':').map(Number);
  return (p[0]||0)*3600 + (p[1]||0)*60 + (p[2]||0);
}

async function fetchTimeline() {
  try {
    const [rawRes, scrRes] = await Promise.all([
      fetch('/api/timeline?t=' + Date.now()),
      fetch('/api/screenshots?t=' + Date.now()),
    ]);
    const rawItems = (await rawRes.json()).filter(i => i.type === 'text');
    const screenshots = await scrRes.json();

    const hash = `${rawItems.length}:${screenshots.length}`;
    if (hash === lastDataHash) return;
    lastDataHash = hash;

    const items = [];

    // Add all final transcript items
    for (const r of rawItems) {
      let sortKey;
      if (r.ts && r.ts > 86400) {
        const d = new Date(r.ts * 1000);
        sortKey = d.getHours() * 3600 + d.getMinutes() * 60 + d.getSeconds() + (r.ts % 1);
      } else {
        sortKey = timeToSec(r.time);
      }
      items.push({ kind: 'sentence', time: r.time, ts: sortKey, text: r.text });
    }

    // Add screenshots
    for (const s of screenshots) {
      items.push({ kind: 'screenshot', time: s.time, ts: timeToSec(s.time), path: s.path });
    }

    // Sort by timestamp (ascending), then render newest first
    items.sort((a, b) => a.ts - b.ts);

    // Render newest first, limit to last 80 items for performance
    const visible = items.slice(-80);
    const prevCount = timeline.children.length;
    const newCount = visible.length;
    const added = newCount - prevCount;

    if (added > 0 && prevCount > 0) {
      // Prepend only new items (they go on top since newest first)
      let newHtml = '';
      for (let i = visible.length - 1; i >= visible.length - added; i--) {
        const item = visible[i];
        if (item.kind === 'screenshot') {
          const imgSrc = `/api/file?path=${encodeURIComponent(item.path)}&t=${Date.now()}`;
          newHtml += `<div class="t-screenshot" style="animation:sentenceIn 0.5s ease-out"><div class="t-time">Screen ${esc(item.time)}</div><img src="${imgSrc}" loading="lazy" onclick="openLightbox(this.src)"></div>`;
        } else {
          newHtml += `<div class="t-line t-sentence"><span class="t-time">${esc(item.time)}</span><span class="t-text">${esc(item.text)}</span></div>`;
        }
      }
      timeline.insertAdjacentHTML('afterbegin', newHtml);
      // Trim excess items from bottom
      while (timeline.children.length > 80) {
        timeline.removeChild(timeline.lastChild);
      }
    } else {
      // Full re-render (first load or major change)
      let html = '';
      for (let i = visible.length - 1; i >= 0; i--) {
        const item = visible[i];
        if (item.kind === 'screenshot') {
          const imgSrc = `/api/file?path=${encodeURIComponent(item.path)}&t=${Date.now()}`;
          html += `<div class="t-screenshot"><div class="t-time">Screen ${esc(item.time)}</div><img src="${imgSrc}" loading="lazy" onclick="openLightbox(this.src)"></div>`;
        } else {
          html += `<div class="t-line t-sentence"><span class="t-time">${esc(item.time)}</span><span class="t-text">${esc(item.text)}</span></div>`;
        }
      }
      timeline.innerHTML = html;
    }
    itemCountEl.textContent = items.length;

    if (!userScrolled) timeline.scrollTop = 0;

    statusEl.textContent = `${rawItems.length} items \u00b7 ${new Date().toLocaleTimeString()}`;
  } catch(e) { statusEl.textContent = 'Connection error'; }
}

const summaryEl = document.getElementById('summary');
let lastSummaryLen = 0;

async function fetchSummary() {
  try {
    const res = await fetch('/api/summary?t=' + Date.now());
    const text = await res.text();
    if (text.length === lastSummaryLen) return;
    lastSummaryLen = text.length;
    const blocks = text.split(/^---$/m).filter(b => b.trim()).reverse();
    let html = '';
    for (const block of blocks) {
      const timeMatch = block.match(/###\s*(.+)/);
      const time = timeMatch ? timeMatch[1].trim() : '';
      const bullets = [...block.matchAll(/^-\s+(.+)$/gm)].map(m => `<li>${m[1]}</li>`).join('');
      if (bullets) {
        html += `<div class="s-block"><div class="s-time">${time}</div><div class="s-text"><ul>${bullets}</ul></div></div>`;
      }
    }
    summaryEl.innerHTML = html || '<div style="color:var(--text-dim);font-family:var(--font-mono);font-size:11px;padding:20px 0;text-align:center;letter-spacing:1px">AWAITING DATA...</div>';
    summaryCountEl.textContent = blocks.length;
  } catch(e) {}
}

// Fetch partial text separately (very fast poll for real-time feel)
// The partial area NEVER hides — it always shows either the current partial or the last confirmed text
let partialEl = null;
async function fetchPartial() {
  try {
    const res = await fetch('/api/partial?t=' + Date.now());
    const data = await res.json();
    if (!partialEl) {
      partialEl = document.createElement('div');
      partialEl.className = 't-line t-partial';
      partialEl.innerHTML = '<span class="t-time"></span><span class="t-text"></span>';
      timeline.parentNode.insertBefore(partialEl, timeline);
    }
    if (data.text && data.text.length > 0) {
      partialEl.style.display = '';
      partialEl.querySelector('.t-time').textContent = data.t || '';
      partialEl.querySelector('.t-text').textContent = data.text;
      // Auto-scroll to bottom so latest text is visible
      partialEl.scrollTop = partialEl.scrollHeight;
    }
    // Never hide — always shows last content until naturally replaced
  } catch(e) {}
}

setInterval(fetchTimeline, 800);
setInterval(fetchPartial, 250);
setInterval(fetchSummary, 5000);
fetchTimeline();
fetchPartial();
fetchSummary();

document.addEventListener('keydown', e => { if (e.key === 'Escape') document.getElementById('lightbox').classList.remove('active'); });
</script>
</body>
</html>"""


BRIEF_HTML = r"""<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Meeting Brief</title>
<link href="https://fonts.googleapis.com/css2?family=Playfair+Display:wght@400;600;700;800;900&family=Source+Sans+3:wght@300;400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
:root { --terra: #c45d3e; --teal: #2a7a66; --dark: #111; --bg: #faf9f7; }
* { margin:0; padding:0; box-sizing:border-box; }
body { font-family:'Source Sans 3',sans-serif; background:var(--bg); color:#1c1c1c; }

.topbar { background:var(--dark); padding:14px 32px; display:flex; align-items:center; justify-content:space-between; position:sticky; top:0; z-index:100; }
.topbar-left { display:flex; align-items:center; gap:14px; }
.topbar-title { font-family:'IBM Plex Mono',monospace; font-size:11px; color:var(--terra); letter-spacing:2px; text-transform:uppercase; font-weight:500; }
.topbar .live { display:flex; align-items:center; gap:6px; font-family:'IBM Plex Mono',monospace; font-size:10px; color:#4ec9b0; }
.topbar .live .dot { width:6px; height:6px; border-radius:50%; background:#4ec9b0; animation:blink 2s infinite; }
@keyframes blink { 0%,100%{opacity:1} 50%{opacity:.3} }
.topbar a { font-family:'IBM Plex Mono',monospace; font-size:10px; color:#666; text-decoration:none; letter-spacing:1px; }
.topbar a:hover { color:#aaa; }

.hero { background:var(--dark); color:#fff; padding:48px 48px 40px; }
.hero-eyebrow { font-family:'IBM Plex Mono',monospace; font-size:10px; color:var(--terra); letter-spacing:3px; text-transform:uppercase; margin-bottom:12px; }
.hero h1 { font-family:'Playfair Display',serif; font-size:36px; font-weight:800; line-height:1.15; margin-bottom:8px; }
.hero .sub { font-size:16px; color:#888; font-weight:300; margin-bottom:24px; }
.hero-meta { font-family:'IBM Plex Mono',monospace; font-size:11px; color:#555; line-height:2; }
.hero-meta strong { color:#999; }
.hero-accent { width:50px; height:3px; background:var(--terra); margin-bottom:16px; border-radius:2px; }

.content { max-width:1100px; margin:0 auto; padding:32px 48px 64px; }

.section-num { font-family:'Playfair Display',serif; font-size:64px; font-weight:900; color:#ece8e0; line-height:1; margin-bottom:-16px; }
.section-title { font-family:'Playfair Display',serif; font-size:22px; font-weight:700; color:var(--dark); margin-bottom:16px; position:relative; }
.section-title .dot { color:var(--terra); }

.takeaway-grid { display:flex; flex-wrap:wrap; gap:14px; margin:16px 0 32px; }
.takeaway-card { flex:1 1 calc(50% - 14px); min-width:280px; padding:18px 20px; border-left:3px solid var(--terra); background:#fff; border-radius:0 6px 6px 0; box-shadow:0 1px 4px rgba(0,0,0,.04); }
.takeaway-card:nth-child(even) { border-left-color:var(--teal); }
.takeaway-label { font-family:'IBM Plex Mono',monospace; font-size:9px; letter-spacing:1.5px; text-transform:uppercase; color:var(--terra); margin-bottom:6px; font-weight:500; }
.takeaway-card:nth-child(even) .takeaway-label { color:var(--teal); }
.takeaway-text { font-size:14px; line-height:1.6; color:#333; }

.meeting-bar { display:flex; align-items:center; padding:10px 0; border-bottom:1px solid #ddd; margin:24px 0 14px; gap:12px; }
.meeting-name { font-family:'Playfair Display',serif; font-size:18px; font-weight:700; }
.meeting-tag { font-family:'IBM Plex Mono',monospace; font-size:9px; letter-spacing:1px; text-transform:uppercase; background:var(--dark); color:#fff; padding:3px 10px; border-radius:2px; }
.meeting-tag.green { background:var(--teal); }
.meeting-time { font-family:'IBM Plex Mono',monospace; font-size:10px; color:#999; margin-left:auto; }

.cards-row { display:flex; flex-wrap:wrap; gap:12px; margin:12px 0 20px; }
.info-card { flex:1 1 calc(50% - 12px); min-width:240px; padding:16px 18px; background:#fff; border:1px solid #e8e5df; border-radius:6px; }
.info-card-title { font-family:'IBM Plex Mono',monospace; font-size:9px; letter-spacing:1.5px; text-transform:uppercase; color:var(--terra); margin-bottom:6px; font-weight:500; }
.info-card p { font-size:13px; color:#444; line-height:1.55; }

.ss-row { display:flex; flex-wrap:wrap; gap:12px; margin:14px 0; }
.ss-item { flex:1 1 calc(50% - 12px); min-width:200px; }
.ss-item img { width:100%; border-radius:6px; border:1px solid #e0ddd6; box-shadow:0 2px 12px rgba(0,0,0,.06); cursor:pointer; transition:transform .2s; }
.ss-item img:hover { transform:scale(1.02); }

.key-points { list-style:none; padding:0; margin:12px 0 20px; }
.key-points li { padding:8px 0 8px 20px; position:relative; font-size:14px; line-height:1.55; color:#333; border-bottom:1px solid #f0ece6; }
.key-points li::before { content:''; position:absolute; left:0; top:15px; width:10px; height:2px; background:var(--terra); }
.key-points li:nth-child(even)::before { background:var(--teal); }
.key-points li strong { color:var(--dark); font-weight:600; }

.pull-quote { font-family:'Playfair Display',serif; font-size:18px; font-weight:600; font-style:italic; color:var(--dark); border-left:3px solid var(--terra); padding:10px 0 10px 22px; margin:20px 0; line-height:1.45; }
.pull-quote .attr { font-family:'IBM Plex Mono',monospace; font-size:10px; font-style:normal; font-weight:400; color:#999; display:block; margin-top:8px; }

.dark-box { background:var(--dark); color:#d0d0d0; border-radius:8px; padding:24px 28px; margin:20px 0; }
.dark-box h3 { font-family:'IBM Plex Mono',monospace; font-size:10px; letter-spacing:2px; text-transform:uppercase; color:var(--terra); margin-bottom:14px; }
.dark-box.insight h3 { color:#e8a060; }
.dark-box ul { list-style:none; padding:0; }
.dark-box li { font-size:13px; padding:8px 0; border-bottom:1px solid #222; line-height:1.55; color:#bbb; }
.dark-box li:last-child { border-bottom:none; }
.dark-box li strong { color:#e8c57a; }
.dark-box.insight li strong { color:#e8a060; }

.action-box { border:2px solid var(--terra); border-radius:8px; padding:22px 26px; margin:20px 0; }
.action-box h3 { font-family:'Playfair Display',serif; font-size:16px; color:var(--terra); margin-bottom:12px; }
.action-box ol { padding-left:20px; }
.action-box li { font-size:13px; margin:6px 0; color:#333; line-height:1.55; }
.action-box li strong { color:var(--dark); }

.lightbox { position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,.9); display:none; align-items:center; justify-content:center; cursor:zoom-out; }
.lightbox.active { display:flex; }
.lightbox img { max-width:90vw; max-height:90vh; border-radius:8px; }

.updating { font-family:'IBM Plex Mono',monospace; font-size:10px; color:#999; text-align:center; padding:20px; letter-spacing:1px; }
</style>
</head><body>
<div class="topbar">
  <div class="topbar-left">
    <div class="topbar-title">Meeting Brief</div>
    <div class="live"><span class="dot"></span>AUTO-UPDATING</div>
  </div>
  <a href="/">← BACK TO TIMELINE</a>
</div>

<div class="hero">
  <div class="hero-eyebrow">Meeting Intelligence Brief</div>
  <h1 id="heroTitle">Loading...</h1>
  <div class="hero-accent"></div>
  <div class="sub" id="heroSub"></div>
  <div class="hero-meta" id="heroMeta"></div>
</div>

<div class="content" id="briefContent">
  <div class="updating">LOADING BRIEF...</div>
</div>

<div class="lightbox" id="lightbox" onclick="this.classList.remove('active')"><img id="lbImg"></div>

<script>
function openLightbox(src) {
  document.getElementById('lbImg').src = src;
  document.getElementById('lightbox').classList.add('active');
}
document.addEventListener('keydown', e => { if(e.key==='Escape') document.getElementById('lightbox').classList.remove('active'); });

let lastLen = 0;
async function fetchBrief() {
  try {
    const [summaryRes, ssRes] = await Promise.all([
      fetch('/api/summary?t='+Date.now()),
      fetch('/api/screenshots?t='+Date.now())
    ]);
    const summary = await summaryRes.text();
    const screenshots = await ssRes.json();
    if (summary.length === lastLen) return;
    lastLen = summary.length;

    // Parse summary blocks
    const blocks = summary.split(/^---$/m).filter(b => b.trim());
    const parsed = blocks.map(b => {
      const tm = b.match(/###\s*(.+)/);
      const bullets = [...b.matchAll(/^-\s+(.+)$/gm)].map(m => m[1]);
      return { time: tm ? tm[1].trim() : '', bullets };
    }).filter(b => b.bullets.length);

    if (!parsed.length) return;

    // Detect meetings by time gap or topic change
    const firstTime = parsed[0].time;
    const lastTime = parsed[parsed.length-1].time;
    document.getElementById('heroTitle').textContent = 'Session Brief';
    document.getElementById('heroSub').textContent = `AI-generated meeting notes with screenshots and insights`;
    document.getElementById('heroMeta').innerHTML = `<strong>Date</strong> ${firstTime.split(' ')[0] || 'Today'} &nbsp;&middot;&nbsp; <strong>Duration</strong> ${firstTime.split(' ')[1] || ''} – ${lastTime.split(' ')[1] || ''} &nbsp;&middot;&nbsp; <strong>Entries</strong> ${parsed.length}`;

    // Pick 4 screenshots evenly
    let ssHTML = '';
    if (screenshots.length) {
      const step = Math.max(1, Math.floor(screenshots.length / 4));
      const picks = [];
      for (let i = screenshots.length - 1; picks.length < 4 && i >= 0; i -= step) {
        picks.unshift(screenshots[i]);
      }
      ssHTML = picks.map(s =>
        `<div class="ss-item"><img src="/api/file?path=${encodeURIComponent(s.path)}&t=${Date.now()}" onclick="openLightbox(this.src)" loading="lazy"></div>`
      ).join('');
    }

    // Build takeaways from first 4 blocks
    const takeaways = parsed.slice(0, 4).map((b, i) => {
      const labels = ['Key Point', 'Development', 'Framework', 'Assessment'];
      return `<div class="takeaway-card"><div class="takeaway-label">${labels[i] || 'Update'}</div><div class="takeaway-text">${b.bullets[0]}</div></div>`;
    }).join('');

    // Build key points from all blocks
    const keyPoints = parsed.map(b =>
      b.bullets.map(bullet => `<li>${bullet}</li>`).join('')
    ).join('');

    // Build insights from later blocks (Q&A, debates)
    const debateBlocks = parsed.filter(b =>
      b.bullets.some(x => /debate|pushback|concern|question|challenge/i.test(x))
    );
    const insightItems = debateBlocks.map(b =>
      b.bullets.map(x => `<li>${x}</li>`).join('')
    ).join('') || '<li>Insights will appear as the meeting progresses...</li>';

    let html = `
      <div class="section-num">01</div>
      <div class="section-title">Executive Summary<span class="dot">.</span></div>
      <div class="takeaway-grid">${takeaways}</div>

      <div class="section-num">02</div>
      <div class="section-title">Visual Captures<span class="dot">.</span></div>
      <div class="ss-row">${ssHTML || '<div class="updating">No screenshots yet</div>'}</div>

      <div class="pull-quote" id="pullQuote">
        "${parsed.length > 6 ? parsed[6].bullets[0] : (parsed[parsed.length-1].bullets[0] || '...')}"
        <span class="attr">— From the meeting</span>
      </div>

      <div class="section-num">03</div>
      <div class="section-title">Detailed Timeline<span class="dot">.</span></div>
      <ul class="key-points">${keyPoints}</ul>

      <div class="section-num">04</div>
      <div class="section-title">Insights &amp; Debates<span class="dot">.</span></div>
      <div class="dark-box insight">
        <h3>Key Discussion Points</h3>
        <ul>${insightItems}</ul>
      </div>
    `;

    document.getElementById('briefContent').innerHTML = html;
  } catch(e) { console.error(e); }
}

setInterval(fetchBrief, 8000);
fetchBrief();
</script>
</body></html>"""


class DashboardHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # suppress logs

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/" or path == "/index.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(HTML.encode())

        elif path == "/brief":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(BRIEF_HTML.encode())

        elif path == "/api/timeline":
            # Merged timeline: raw transcript segments + screenshots interleaved by time
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            items = []
            # Raw transcript segments (real-time, JSONL format)
            raw_file = os.path.join(BASE_DIR, "live_raw.jsonl")
            if os.path.exists(raw_file):
                with open(raw_file) as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            entry = json.loads(line)
                            items.append({"type": "text", "time": entry.get("t", ""), "text": entry.get("text", ""), "ts": entry.get("ts", 0)})
                        except json.JSONDecodeError:
                            pass
            # Fall back to live_transcript.txt if no raw file yet
            if not items:
                transcript_file = os.path.join(BASE_DIR, "live_transcript.txt")
                if os.path.exists(transcript_file):
                    import re
                    with open(transcript_file) as f:
                        for line in f:
                            line = line.strip()
                            if not line:
                                continue
                            m = re.match(r'^\[(\d{2}:\d{2}:\d{2})\]\s*(.*)', line)
                            if m:
                                items.append({"type": "text", "time": m.group(1), "text": m.group(2)})
                            else:
                                items.append({"type": "text", "time": "", "text": line})
            # Screenshots
            ss_dir = os.path.join(BASE_DIR, "screenshots")
            for f in sorted(glob.glob(os.path.join(ss_dir, "*.png"))):
                name = os.path.basename(f)
                parts = name.replace("screen_", "").replace(".png", "").split("_")
                if len(parts) == 2 and len(parts[1]) == 6:
                    t = parts[1]
                    time_str = f"{t[0:2]}:{t[2:4]}:{t[4:6]}"
                    items.append({"type": "screenshot", "time": time_str, "path": f})
            # Sort by time
            items.sort(key=lambda x: x.get("time", ""))
            self.wfile.write(json.dumps(items).encode())

        elif path == "/api/partial":
            # Current partial text (single JSON, overwritten by Vosk)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            partial_file = os.path.join(BASE_DIR, "live_partial.json")
            data = "{}"
            if os.path.exists(partial_file):
                try:
                    with open(partial_file) as f:
                        data = f.read().strip() or "{}"
                except Exception:
                    data = "{}"
            self.wfile.write(data.encode())

        elif path == "/api/sentences":
            # Assembled sentences from live_transcript.txt
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            import re
            transcript_file = os.path.join(BASE_DIR, "live_transcript.txt")
            lines = []
            if os.path.exists(transcript_file):
                with open(transcript_file) as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        m = re.match(r'^\[(\d{2}:\d{2}:\d{2})\]\s*(.*)', line)
                        if m:
                            lines.append({"time": m.group(1), "text": m.group(2)})
            self.wfile.write(json.dumps(lines).encode())

        elif path == "/api/transcript":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            transcript_file = os.path.join(BASE_DIR, "live_transcript.txt")
            lines = []
            if os.path.exists(transcript_file):
                with open(transcript_file) as f:
                    lines = [l.strip() for l in f.readlines() if l.strip()]
            self.wfile.write(json.dumps(lines).encode())

        elif path == "/api/screenshots":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            ss_dir = os.path.join(BASE_DIR, "screenshots")
            files = sorted(glob.glob(os.path.join(ss_dir, "*.png")))
            result = []
            for f in files:
                name = os.path.basename(f)
                # Extract time from screen_YYYYMMDD_HHMMSS.png
                parts = name.replace("screen_", "").replace(".png", "").split("_")
                if len(parts) == 2 and len(parts[1]) == 6:
                    t = parts[1]
                    time_str = f"{t[0:2]}:{t[2:4]}:{t[4:6]}"
                    result.append({"path": f, "time": time_str})
            self.wfile.write(json.dumps(result).encode())

        elif path == "/api/latest-screenshot":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            ss_dir = os.path.join(BASE_DIR, "screenshots")
            files = sorted(glob.glob(os.path.join(ss_dir, "*.png")), reverse=True)
            result = {"path": files[0] if files else None}
            self.wfile.write(json.dumps(result).encode())

        elif path == "/api/summary":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            summary_file = os.path.join(BASE_DIR, "summary.md")
            text = ""
            if os.path.exists(summary_file):
                with open(summary_file) as f:
                    text = f.read()
            self.wfile.write(text.encode())

        elif path == "/api/file":
            params = parse_qs(parsed.query)
            file_path = params.get("path", [None])[0]
            if file_path and os.path.exists(file_path) and os.path.abspath(file_path).startswith(os.path.abspath(BASE_DIR)):
                mime = mimetypes.guess_type(file_path)[0] or "application/octet-stream"
                self.send_response(200)
                self.send_header("Content-Type", mime)
                self.end_headers()
                with open(file_path, "rb") as f:
                    self.wfile.write(f.read())
            else:
                self.send_response(404)
                self.end_headers()
        elif path == "/api/answer":
            params = parse_qs(parsed.query)
            qid = params.get("id", [""])[0]
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            answer_file = os.path.join(BASE_DIR, "chat", f"answer_{qid}.txt")
            if os.path.exists(answer_file):
                with open(answer_file) as f:
                    answer = f.read()
                self.wfile.write(json.dumps({"answer": answer}).encode())
            else:
                self.wfile.write(json.dumps({"answer": None}).encode())

        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/ask":
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            question = data.get("question", "")

            # Generate question ID
            import time
            qid = str(int(time.time() * 1000))

            # Save question to file
            chat_dir = os.path.join(BASE_DIR, "chat")
            os.makedirs(chat_dir, exist_ok=True)
            with open(os.path.join(chat_dir, f"question_{qid}.txt"), "w") as f:
                f.write(question)

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"id": qid}).encode())
        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), DashboardHandler)
    print(f"Dashboard running at http://localhost:{PORT}")
    print(f"Monitoring: {os.path.abspath(BASE_DIR)}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
