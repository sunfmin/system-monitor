---
name: system-monitor
description: "Start a system monitor that captures screenshots, system audio, and microphone input, then periodically summarizes what's happening on screen. Use when the user wants to monitor a meeting, presentation, video, or any on-screen activity. Triggers on: 'monitor my screen', 'capture meeting', 'start monitoring', 'record what's happening', 'watch my screen'."
argument-hint: "[start|stop|status|summarize]"
allowed-tools: Read, Bash, Glob, Grep, Edit, Write, CronCreate, CronDelete
---

# System Monitor Skill

You are a system monitor that captures the user's screen, system audio output, and microphone input, then periodically summarizes what's happening.

## Directory Structure

Each session creates a unique directory under `system_monitor/` using a timestamp:
`system_monitor/session_YYYYMMDD_HHMMSS/`

Each session directory contains:
- `screenshots/` — periodic screen captures
- `live_raw.jsonl` — final transcription results (JSONL, one entry per 20s)
- `live_partial.json` — current real-time partial (single JSON, overwritten)
- `summary.md` — running summary of observations
- `.stream.pid`, `.screenshot.pid`, `.dashboard.pid` — PID files
- `stream.log`, `screenshot.log`, `dashboard.log` — process logs

A symlink `system_monitor/latest` always points to the current active session directory.

Scripts are located at: `${CLAUDE_SKILL_DIR}/scripts/`

## Step 1: Check Prerequisites

ALWAYS run the setup check first:

```
bash ${CLAUDE_SKILL_DIR}/scripts/check-setup.sh
```

### If ERRORS are found:

Guide the user to fix them one by one:

- **MISSING_SWIFTC**: `xcode-select --install`
- **OLD_MACOS**: Need macOS 12.3+ for ScreenCaptureKit

**Do NOT proceed to start monitoring until all ERRORS are resolved.**

### Screen Recording Permission

On first run, macOS will prompt for Screen Recording permission. The user must grant it in System Settings > Privacy & Security > Screen Recording. No BlackHole or Multi-Output device is needed.

### Required tools

- `whisper-cpp`: `brew install whisper-cpp` — provides `whisper-cli` for transcription
- Whisper model: download `ggml-small.bin` to `${CLAUDE_SKILL_DIR}/models/`
- `opencc`: `pip3.11 install opencc-python-reimplemented` — converts Traditional Chinese to Simplified

## Step 2: Handle Commands

### `start` (or no argument, or implicit from user request)

**Always use the start script** — do NOT manually start individual processes:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/start-session.sh
```

This script handles everything:
1. Stops any existing session
2. Creates a new session directory and symlink
3. Starts whisper.cpp streaming transcription (5s chunks, 20s timeline entries)
4. Starts screenshot capture (every 30s)
5. Starts web dashboard on port 8420

After starting, set up a recurring summarization job using CronCreate (every 3 minutes):
- Read the 2 most recent screenshots and `live_raw.jsonl` from `system_monitor/latest/`
- Summarize what's happening on screen
- Append to `system_monitor/latest/summary.md` with timestamp
- Be concise: 2-3 bullet points per check
- Skip if nothing changed since last check

### `stop`

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/stop-session.sh
```

Also cancel any CronCreate summarization job with CronDelete.

### `status`

1. Check if processes are running: `ps aux | grep -E "capture-audio|whisper-cli|web-dashboard" | grep -v grep`
2. Show counts: `wc -l system_monitor/latest/live_raw.jsonl`, screenshot count
3. Show the last entry from `system_monitor/latest/summary.md`

### `summarize`

1. Read the 2 most recent screenshots from `system_monitor/latest/screenshots/` (use Read tool to view them)
2. Read recent entries from `system_monitor/latest/live_raw.jsonl`
3. Analyze what's on screen and what was said
4. Append a timestamped summary to `system_monitor/latest/summary.md`

## Step 3: Periodic Summarization (via CronCreate)

When the cron job fires, do exactly this:

1. Find the 2 most recent screenshots: `ls -t system_monitor/latest/screenshots/ | head -2`
2. Read them with the Read tool (they are images — you can see them)
3. Check recent transcripts: `tail -5 system_monitor/latest/live_raw.jsonl`
4. Compare with the previous summary entry — if nothing meaningful changed, skip
5. If changed, append to `system_monitor/latest/summary.md`:
   ```
   ### YYYY-MM-DD HH:MM

   - bullet point about what's on screen
   - bullet point about what was said (from transcript)

   ---
   ```

## Step 4: Web Dashboard

The dashboard is started automatically by `start-session.sh` on port 8420.

Two areas on the main page:
- **Top (sticky)**: Rolling 15-second window of real-time transcription (latest 3 × 5s chunks). Text scrolls — new text appends, oldest text drops off. Never hides or disappears.
- **Timeline (below)**: Every 20 seconds, accumulated text slides in as a single entry with animation. Screenshots interspersed by time.
- **Right panel**: AI-generated summaries from `summary.md`

Dashboard endpoints:
- `/api/partial` — current partial text (polled every 250ms)
- `/api/timeline` — final entries from `live_raw.jsonl` (polled every 800ms)
- `/api/screenshots` — screenshot list
- `/api/summary` — summary.md content

## Step 5: Transcription Architecture

**Single tool: whisper.cpp (`whisper-cli`)** — no Python ASR dependencies needed.

The `stream-whisper-cpp.sh` script runs a loop:
1. Capture 6s of system audio (5s + 1s overlap for continuity)
2. Run `whisper-cli -m model -l auto -nt --no-prints -f chunk.wav` (Metal GPU accelerated)
3. Convert Traditional Chinese → Simplified via `t2s.py` (uses OpenCC)
4. Update `live_partial.json` with rolling 15s window (last 3 chunks)
5. Every 4 chunks (20s), combine and write to `live_raw.jsonl` as one timeline entry

**Key constraints:**
- **Only ONE `capture-audio` instance at a time.** Multiple instances conflict with ScreenCaptureKit and produce silence. The start script handles this — never start `monitor.sh` alongside the streaming script.
- **SCContentFilter must use `including:` variant** (`SCContentFilter(display:including:exceptingWindows:)` with all apps). The `excludingWindows:` variant delivers zeroed audio on macOS 14+.
- **Auto language detection**: `whisper-cli -l auto` detects 99 languages automatically. No manual language selection needed.
- **Silence handling**: whisper.cpp may hallucinate on silence (e.g., "you you you"). Consider adding audio energy check before transcription in future.

## Step 6: Smart Window Screenshots

For capturing a specific window (auto-detects meeting apps like Zoom, Teams, Lark):
```
bash ${CLAUDE_SKILL_DIR}/scripts/capture-window.sh <output_path> [app_keyword] [prev_screenshot_for_diff]
```
- Auto-detects: Zoom, Teams, Lark, Slack Huddle, Google Meet, YouTube
- Falls back to largest non-terminal window
- Skips if screenshot is similar to previous (pixel diff comparison)

## Important Notes

- System audio is captured via ScreenCaptureKit — no BlackHole or virtual audio device needed
- Audio capture works regardless of which output device the user selects (speakers, headphones, Bluetooth, etc.)
- The user's audio output settings are never modified
- Screenshots auto-detect meeting/video windows, no user selection needed
- Smart dedup: screenshots only saved when content changes
- Only ONE capture-audio instance can run at a time (ScreenCaptureKit limitation)
- Always use `start-session.sh` / `stop-session.sh` — never start processes manually
- Chinese output is auto-converted from Traditional to Simplified via OpenCC
- Requires macOS 12.3+ and Screen Recording permission
