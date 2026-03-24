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

# Kill by PID files (check .runtime/ first, fallback to old location)
RUNTIME_DIR="$SESSION_DIR/.runtime"
for pidfile in .stream.pid .screenshot.pid .dashboard.pid .monitor.pid; do
    PIDPATH=""
    if [ -f "$RUNTIME_DIR/$pidfile" ]; then
        PIDPATH="$RUNTIME_DIR/$pidfile"
    elif [ -f "$SESSION_DIR/$pidfile" ]; then
        PIDPATH="$SESSION_DIR/$pidfile"
    fi
    if [ -n "$PIDPATH" ]; then
        PID=$(cat "$PIDPATH")
        kill "$PID" 2>/dev/null
        rm -f "$PIDPATH"
    fi
done

# Kill by process name (fallback - covers all related processes from any session)
# Use pgrep + grep to exclude our own process tree ($$, $PPID) to avoid self-kill
_safe_pkill() {
    local pattern="$1"
    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null | grep -v -w -e "$$" -e "$PPID" -e "$BASHPID")
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill ${2:--TERM} 2>/dev/null
    fi
}
_safe_pkill "stream-audio-whisper"
_safe_pkill "capture-audio"
_safe_pkill "stream-vosk"
_safe_pkill "stream-transcribe"
_safe_pkill "web-dashboard.*8420"
_safe_pkill "capture-window"
_safe_pkill "monitor.sh"

# Remove symlink
rm -f "$SESSION_DIR"

sleep 1

# Stats
SCREENSHOTS=$(ls "$BASE_DIR/$REAL_DIR/screenshots/"*.jpg "$BASE_DIR/$REAL_DIR/screenshots/"*.png 2>/dev/null | wc -l | tr -d ' ')
TRANSCRIPTS=$(wc -l < "$BASE_DIR/$REAL_DIR/live_raw.jsonl" 2>/dev/null | tr -d ' ')
AUDIO_SIZE=""
if [ -f "$BASE_DIR/$REAL_DIR/audio.wav" ]; then
    AUDIO_SIZE=$(du -h "$BASE_DIR/$REAL_DIR/audio.wav" | cut -f1)
fi

echo ""
echo "=== Session Summary ==="
echo "  Screenshots: $SCREENSHOTS"
echo "  Transcripts: ${TRANSCRIPTS:-0} entries"
[ -n "$AUDIO_SIZE" ] && echo "  Audio:       $AUDIO_SIZE"
echo "  Files saved in: $BASE_DIR/$REAL_DIR"
