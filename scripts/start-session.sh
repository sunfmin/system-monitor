#!/bin/bash
# Start a new system monitor session
# Usage: start-session.sh [session_name]
# Creates a new session directory, starts Vosk streaming + screenshots + dashboard

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="system_monitor"

# Kill any existing session
bash "$SCRIPT_DIR/stop-session.sh" 2>/dev/null

# Create session directory
if [ -n "$1" ]; then
    SESSION_DIR="$BASE_DIR/session_$1"
else
    SESSION_DIR="$BASE_DIR/session_$(date +%Y%m%d_%H%M%S)"
fi

mkdir -p "$SESSION_DIR/screenshots" "$SESSION_DIR/transcripts"
ln -sfn "$(basename "$SESSION_DIR")" "$BASE_DIR/latest"

echo "=== System Monitor ==="
echo "Session: $SESSION_DIR"
echo ""

# 1. Whisper.cpp streaming (5s chunks, auto language detection, Metal GPU acceleration)
echo "Starting whisper.cpp streaming transcription..."
nohup bash "$SCRIPT_DIR/stream-whisper-cpp.sh" "$SESSION_DIR" "$SCRIPT_DIR/../models/ggml-small.bin" 5 4 > "$SESSION_DIR/stream.log" 2>&1 &
STREAM_PID=$!
echo "$STREAM_PID" > "$SESSION_DIR/.stream.pid"

# 2. Screenshot loop (no audio capture - avoids ScreenCaptureKit conflict)
echo "Starting screenshot capture (every 30s)..."
nohup bash -c "
while true; do
    TS=\$(date +%Y%m%d_%H%M%S)
    PREV=\$(ls -t \"$SESSION_DIR/screenshots/\"*.png 2>/dev/null | head -1)
    bash \"$SCRIPT_DIR/capture-window.sh\" \"$SESSION_DIR/screenshots/screen_\${TS}.png\" \"\" \"\$PREV\" 2>/dev/null
    sleep 30
done
" > "$SESSION_DIR/screenshot.log" 2>&1 &
SCREENSHOT_PID=$!
echo "$SCREENSHOT_PID" > "$SESSION_DIR/.screenshot.pid"

# 3. Web dashboard
echo "Starting web dashboard on port 8420..."
nohup python3 "$SCRIPT_DIR/web-dashboard.py" "$SESSION_DIR" 8420 > "$SESSION_DIR/dashboard.log" 2>&1 &
DASHBOARD_PID=$!
echo "$DASHBOARD_PID" > "$SESSION_DIR/.dashboard.pid"

# Write main PID file
echo "$$" > "$SESSION_DIR/.monitor.pid"

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
