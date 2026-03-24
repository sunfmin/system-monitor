#!/bin/bash
# Stop all system monitor processes
# Usage: stop-session.sh

BASE_DIR="system_monitor"
SESSION_DIR="$BASE_DIR/latest"

if [ ! -L "$SESSION_DIR" ]; then
    echo "No active session found."
    exit 0
fi

REAL_DIR=$(readlink "$SESSION_DIR")
echo "Stopping session: $BASE_DIR/$REAL_DIR"

# Kill by PID files
for pidfile in .stream.pid .screenshot.pid .dashboard.pid .monitor.pid; do
    if [ -f "$SESSION_DIR/$pidfile" ]; then
        PID=$(cat "$SESSION_DIR/$pidfile")
        kill "$PID" 2>/dev/null
        rm -f "$SESSION_DIR/$pidfile"
    fi
done

# Kill by process name (fallback)
pkill -f "capture-audio" 2>/dev/null
pkill -f "stream-vosk" 2>/dev/null
pkill -f "stream-transcribe" 2>/dev/null
pkill -f "web-dashboard.*8420" 2>/dev/null
pkill -f "capture-window" 2>/dev/null
pkill -f "monitor.sh" 2>/dev/null

# Remove symlink
rm -f "$SESSION_DIR"

sleep 1

# Stats
SCREENSHOTS=$(ls "$BASE_DIR/$REAL_DIR/screenshots/"*.png 2>/dev/null | wc -l | tr -d ' ')
TRANSCRIPTS=$(wc -l < "$BASE_DIR/$REAL_DIR/live_raw.jsonl" 2>/dev/null | tr -d ' ')

echo ""
echo "=== Session Summary ==="
echo "  Screenshots: $SCREENSHOTS"
echo "  Transcripts: ${TRANSCRIPTS:-0} entries"
echo "  Files saved in: $BASE_DIR/$REAL_DIR"
