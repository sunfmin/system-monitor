---
name: system-monitor
description: "Start a system monitor that captures screenshots, system audio, and microphone input, then periodically summarizes what's happening on screen. Use when the user wants to monitor a meeting, presentation, video, or any on-screen activity. Triggers on: 'monitor my screen', 'capture meeting', 'start monitoring', 'record what's happening', 'watch my screen'."
argument-hint: "[start|stop|status|summarize] [window target keyword, e.g. 'YouTube', 'Zoom', 'Chrome']"
allowed-tools: Read, Bash, Glob, Grep, Edit, Write, CronCreate, CronDelete
---

# System Monitor Skill

You are a system monitor that captures the user's screen, system audio output, and microphone input, then periodically summarizes what's happening.

## Directory Structure

Each session creates a unique directory under `system_monitor/` using a timestamp:
`system_monitor/session_YYYYMMDD_HHMMSS/`

Each session directory contains:
- `screenshots/` — periodic screen captures (JPEG, ~200KB each)
- `audio.wav` — complete audio recording (16kHz mono 16-bit PCM WAV), finalized on stop
- `live_raw.jsonl` — final transcription results (JSONL with `sentences` array, one entry per ~20s)
- `summary.md` — running summary of observations
- `.runtime/` — runtime files (PIDs, logs, partial text, focus target):
  - `live_partial.json` — current real-time partial (single JSON, overwritten; also pushed via WebSocket)
  - `.stream.pid`, `.screenshot.pid`, `.dashboard.pid`, `.monitor.pid` — PID files
  - `.focus_target` — current screenshot target window ID
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

**If the user provided a window target keyword in the arguments** (anything beyond `start`/`stop`/`status`/`summarize`, e.g. "youtube", "capture Zoom", "monitor Chrome"), **BEFORE starting**, find the window ID:
1. Run `bash ${CLAUDE_SKILL_DIR}/scripts/list-windows.sh` to list all windows
2. Match the keyword against window titles and app names (prefer larger windows if multiple matches)
3. If no match is found, tell the user and show available windows; do NOT proceed
4. Pass the matched window ID to the start script via `--window-id`

**Then start the session** — do NOT manually start individual processes:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/start-session.sh --window-id <id>
```

Without a window target, just run:
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/start-session.sh
```

The start script handles everything:
1. Stops any existing session
2. Creates a new session directory and symlink
3. **Sets `.focus_target` with the window ID (if provided) BEFORE starting screenshot capture**
4. Starts whisper.cpp streaming transcription (2s chunks, 10s sentence-segmented timeline entries)
5. Starts screenshot capture (every 30s)
6. Starts web dashboard on port 8420 + WebSocket on port 8421

Then set up a recurring summarization job using CronCreate (every 3 minutes):
- Read ALL transcripts from `live_raw.jsonl` that arrived after the last summary's timestamp
- Read the 2 most recent screenshots from `system_monitor/latest/screenshots/`
- Summarize ALL content since the last summary (not just the latest few lines)
- Append to `system_monitor/latest/summary.md` with timestamp
- Be concise but comprehensive: cover all topics discussed since last summary
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

1. Read the last summary entry from `system_monitor/latest/summary.md` to find its timestamp
2. Read ALL entries from `system_monitor/latest/live_raw.jsonl` that have timestamps after the last summary (use the `ts` epoch field to compare). If no previous summary, read all entries.
3. Read ALL screenshots from `system_monitor/latest/screenshots/` that were captured after the last summary timestamp (not just the 2 most recent). Use the timestamp in filenames (e.g. `screen_YYYYMMDD_HHMMSS.png`) to filter.
4. Summarize ALL content since the last summary — cover every topic discussed, not just the most recent
5. Append a timestamped summary to `system_monitor/latest/summary.md`

## Step 3: Periodic Summarization (via CronCreate)

When the cron job fires, do exactly this:

1. Read the last summary entry from `system_monitor/latest/summary.md` to find its timestamp
2. Get ALL transcripts since the last summary. Use a script to filter by timestamp:
   ```bash
   python3.11 -c "
   import json, sys
   last_ts = float(sys.argv[1])  # epoch timestamp of last summary
   for line in open('system_monitor/latest/live_raw.jsonl'):
       entry = json.loads(line)
       if entry.get('ts', 0) > last_ts:
           print(entry['text'])
   " LAST_EPOCH_TS
   ```
   If no previous summary exists, read all entries: `cat system_monitor/latest/live_raw.jsonl`
3. Find ALL screenshots captured after the last summary timestamp. Use the timestamp in filenames to filter:
   ```bash
   ls system_monitor/latest/screenshots/ | sort | while read f; do
     ts=$(echo "$f" | sed 's/screen_//;s/\.png//');
     if [[ "$ts" > "YYYYMMDD_HHMMSS" ]]; then echo "$f"; fi
   done
   ```
   Read them all with the Read tool (they are images — you can see them)
4. If nothing meaningful changed since last summary, skip
6. Otherwise, write a unified summary that naturally merges what's on screen and what was said — do NOT separate into "Screen" and "Audio" sections. Combine visual and audio observations into coherent bullet points organized by topic. Append to `system_monitor/latest/summary.md`:
   ```
   ### YYYY-MM-DD HH:MM

   - bullet points covering ALL topics since last summary, merging screen and audio observations naturally

   ---
   ```

## Step 4: Web Dashboard

The dashboard is started automatically by `start-session.sh` on port 8420.

**Real-time UX flow:**
- **Top (sticky)**: Streaming partial text via WebSocket. Accumulates all 2s chunks for the current cycle (~20s). Text grows until final sentences appear below, then fades out.
- **Timeline (below)**: Every ~20s, complete sentences (re-transcribed from full audio with punctuation) slide in. Each sentence is a separate segment from whisper.
- **Right panel**: AI-generated summaries from `summary.md`

**WebSocket (port 8421)** is the primary transport for real-time updates:
- `{"type": "partial", ...}` — every 2s, rolling window of streaming text
- `{"type": "final", ..., "sentences": [...]}` — every ~20s, array of complete sentences
- `{"type": "clear_partial"}` — signals dashboard to fade out partial text after final appears

Dashboard endpoints (fallback when WebSocket unavailable):
- `/api/partial` — current partial text (polled every 1s as fallback)
- `/api/timeline` — final entries from `live_raw.jsonl` (polled every 800ms)
- `/api/screenshots` — screenshot list
- `/api/summary` — summary.md content

## Step 5: Transcription Architecture

**Single-process: `stream-audio-whisper` (ScreenCaptureKit + whisper.cpp C API + WebSocket in one Swift binary)**

The `stream-audio-whisper` binary combines audio capture, whisper inference, and WebSocket server in a single process:

### Two-tier transcription:

**Tier 1 — Partial (2s chunks, real-time):**
1. Captures system audio continuously via ScreenCaptureKit (16kHz mono float32)
2. Every 2 seconds, runs `whisper_full()` on the chunk for quick partial text
3. No `initial_prompt` (prevents prompt leakage on short audio)
4. Pushes rolling window text via WebSocket `partial` message
5. Partial window keeps ALL text from current cycle until final replaces it

**Tier 2 — Final (20s, sentence-quality):**
1. Every 10 chunks (~20s), re-transcribes full accumulated audio with `transcribeSegments()`
2. Uses `initial_prompt = "以下是普通话的句子，使用标点符号。"` to guide punctuation output
3. Whisper returns individual segments (natural sentences) with timestamps
4. `addPunctuation()` post-processing ensures sentence-ending marks (。？！)
5. Incomplete last sentence → audio carried over to next round via precise whisper timestamps
6. Total audio capped at 30s (whisper max) — carryover trimmed if needed
7. Sentences pushed via WebSocket `final` message, written to `live_raw.jsonl` with `sentences` array
8. Sends `clear_partial` to fade out streaming text in dashboard

### Audio handling:
- Silence (energy < 1e-7): skips 2s partial transcription but **still accumulates audio** for final
- Silent chunks count toward final interval to prevent timing drift
- Traditional Chinese → Simplified conversion via `t2s.py`

**Latency:** 2s partial display, ~20s for complete sentences in timeline.

**Binary location:** `scripts/stream-audio-whisper` (compiled from `stream-audio-whisper.swift`)
**Module map:** `scripts/whisper_module/module.modulemap` (bridges whisper.h + ggml.h to Swift)

**Compile command:**
```bash
swiftc stream-audio-whisper.swift \
    -I whisper_module -I /opt/homebrew/opt/whisper-cpp/include -I /opt/homebrew/opt/ggml/include \
    -L /opt/homebrew/opt/whisper-cpp/lib -L /opt/homebrew/opt/ggml/lib \
    -lwhisper -lggml -lggml-base \
    -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework Network \
    -O -o stream-audio-whisper
```

**Pre-compiled binary:** A pre-compiled arm64 binary for Apple Silicon is included in the repo. It dynamically links to `libwhisper` and `libggml` from Homebrew, so `brew install whisper-cpp` is required even when using the pre-compiled binary.

**Auto-compile:** If the binary is missing, `start-session.sh` automatically runs `compile.sh`. Manual recompile: `bash scripts/compile.sh`

**Key constraints:**
- **Only ONE ScreenCaptureKit audio stream at a time.** Multiple instances conflict and produce silence.
- **SCContentFilter must use `including:` variant** — the `excludingWindows:` variant delivers zeroed audio on macOS 14+.
- **`ggml_backend_load_all()` must be called before `whisper_init`** — loads Metal/CPU/BLAS backends.
- **Whisper max 30s context** — final interval (20s) + carryover (up to 10s) must not exceed 30s.
- **`initial_prompt` only for final** — on 2s chunks it causes prompt text leakage.
- **Auto language detection**: whisper auto-detects 99 languages. No manual selection needed.

## Step 6: Smart Window Screenshots

For capturing a specific window (auto-detects meeting apps like Zoom, Teams, Lark):
```
bash ${CLAUDE_SKILL_DIR}/scripts/capture-window.sh <output_path> [app_keyword] [prev_screenshot_for_diff]
```
- Auto-detects: Zoom, Teams, Lark, Slack Huddle, Google Meet, YouTube
- Falls back to largest non-terminal window
- Skips if screenshot is similar to previous (pixel diff comparison)

### Switching Screenshot Target

When the user asks to switch the screenshot target to a specific app or window (e.g., "切换到截屏 YouTube", "capture Chrome", "switch to Zoom"):

1. **List all windows** by running:
   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/list-windows.sh
   ```
   This outputs a JSON array with each window's `id`, `app`, `title`, and `size`.

2. **Claude picks the best match** — analyze the window list against the user's request:
   - Match by window title (e.g., a YouTube tab will have "YouTube" in its title)
   - Match by app name (e.g., "Chrome", "Zoom", "Lark")
   - If multiple matches exist, prefer the larger window (likely the main content window)
   - If ambiguous, show the candidates to the user and ask them to choose

3. **Write the window ID** to the session's focus target file:
   ```bash
   echo -n "<window_id>" > system_monitor/latest/.runtime/.focus_target
   ```
   The `capture-window.sh` script reads `.focus_target` on each capture cycle. If it contains a numeric window ID, it uses that ID directly via `screencapture -l`.

**Important**: Always use the window ID (numeric), not a keyword. Keywords rely on heuristic matching in the script, but window IDs are exact and reliable. The `list-windows.sh` output gives Claude full visibility to make the right choice.

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
