#!/bin/bash
# Start a new system monitor session
# Usage: start-session.sh [--window-id <id>] [session_name]
# Creates a new session directory, starts streaming transcription + screenshots + dashboard

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="system_monitor"
WINDOW_ID=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --window-id)
            WINDOW_ID="$2"; shift 2 ;;
        *)
            SESSION_NAME="$1"; shift ;;
    esac
done

# Kill any existing session (via stop script + force kill all related processes)
bash "$SCRIPT_DIR/stop-session.sh" 2>/dev/null

# Force kill ALL remaining related processes regardless of session
# Use pgrep + grep to exclude our own process tree to avoid self-kill
_safe_pkill() {
    local pattern="$1"
    local signal="${2:--TERM}"
    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null | grep -v -w -e "$$" -e "$PPID" -e "$BASHPID")
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill "$signal" 2>/dev/null
    fi
}
_safe_pkill "stream-audio-whisper"
_safe_pkill "web-dashboard.*8420"
_safe_pkill "capture-window"
_safe_pkill "capture-audio"
sleep 1
# Double-check and force kill if still alive
_safe_pkill "stream-audio-whisper" -9
_safe_pkill "web-dashboard.*8420" -9
_safe_pkill "capture-window" -9

# Create session directory
if [ -n "$SESSION_NAME" ]; then
    SESSION_DIR="$BASE_DIR/session_$SESSION_NAME"
else
    SESSION_DIR="$BASE_DIR/session_$(date +%Y%m%d_%H%M%S)"
fi

# Main dir: user-facing files (screenshots, audio, transcripts, summary)
# .runtime dir: PIDs, logs, partial, focus target
mkdir -p "$SESSION_DIR/screenshots" "$SESSION_DIR/.runtime"
ln -sfn "$(basename "$SESSION_DIR")" "$BASE_DIR/latest"

# Set window target BEFORE starting screenshot capture
if [ -n "$WINDOW_ID" ]; then
    echo -n "$WINDOW_ID" > "$SESSION_DIR/.runtime/.focus_target"
    echo "Screenshot target: window ID $WINDOW_ID"
fi

echo "=== System Monitor ==="
echo "Session: $SESSION_DIR"
echo ""

# 1. Whisper.cpp streaming (single-process: ScreenCaptureKit + whisper C API + WebSocket)
WHISPER_BIN="$SCRIPT_DIR/stream-audio-whisper"

# Auto-compile if binary missing
if [ ! -x "$WHISPER_BIN" ]; then
    echo "Binary not found, compiling..."
    bash "$SCRIPT_DIR/compile.sh"
    if [ ! -x "$WHISPER_BIN" ]; then
        echo "ERROR: Compilation failed. Run 'bash $SCRIPT_DIR/compile.sh' manually to see errors."
        exit 1
    fi
fi

echo "Starting stream-audio-whisper (single-process, Metal GPU)..."
nohup "$WHISPER_BIN" \
    --model "$SCRIPT_DIR/../models/ggml-small.bin" \
    --chunk-sec 2 \
    --final-interval 10 \
    --raw-file "$SESSION_DIR/live_raw.jsonl" \
    --partial-dir "$SESSION_DIR/.runtime" \
    --t2s-script "$SCRIPT_DIR/t2s.py" \
    --audio-file "$SESSION_DIR/audio.wav" \
    > "$SESSION_DIR/.runtime/stream.log" 2>&1 &
STREAM_PID=$!
echo "$STREAM_PID" > "$SESSION_DIR/.runtime/.stream.pid"

# 2. Screenshot loop (no audio capture - avoids ScreenCaptureKit conflict)
echo "Starting screenshot capture (every 30s)..."
nohup bash -c "
while true; do
    TS=\$(date +%Y%m%d_%H%M%S)
    PREV=\$(ls -t \"$SESSION_DIR/screenshots/\"*.jpg 2>/dev/null | head -1)
    bash \"$SCRIPT_DIR/capture-window.sh\" \"$SESSION_DIR/screenshots/screen_\${TS}.png\" \"\" \"\$PREV\" 2>/dev/null
    sleep 30
done
" > "$SESSION_DIR/.runtime/screenshot.log" 2>&1 &
SCREENSHOT_PID=$!
echo "$SCREENSHOT_PID" > "$SESSION_DIR/.runtime/.screenshot.pid"

# 3. Web dashboard
echo "Starting web dashboard on port 8420..."
nohup python3 "$SCRIPT_DIR/web-dashboard.py" "$SESSION_DIR" 8420 > "$SESSION_DIR/.runtime/dashboard.log" 2>&1 &
DASHBOARD_PID=$!
echo "$DASHBOARD_PID" > "$SESSION_DIR/.runtime/.dashboard.pid"

# Write main PID file
echo "$$" > "$SESSION_DIR/.runtime/.monitor.pid"

sleep 2
echo ""
echo "=== Running ==="
echo "  Stream PID:     $STREAM_PID"
echo "  Screenshot PID: $SCREENSHOT_PID"
echo "  Dashboard PID:  $DASHBOARD_PID"
echo ""
echo "  Dashboard: http://localhost:8420"
echo "  Session:   $SESSION_DIR"
echo ""
echo "To stop: bash $SCRIPT_DIR/stop-session.sh"
