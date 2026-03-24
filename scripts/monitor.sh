#!/bin/bash
# System Monitor - captures screen + system audio (via ScreenCaptureKit) + microphone
# Usage: monitor.sh <base_dir> [mic_device_index]
# No BlackHole or Multi-Output device needed.

BASE_DIR="${1:-system_monitor}"
MIC_DEVICE="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SCREENSHOT_DIR="$BASE_DIR/screenshots"
AUDIO_DIR="$BASE_DIR/audio"
TRANSCRIPT_DIR="$BASE_DIR/transcripts"

SCREENSHOT_INTERVAL=30
AUDIO_CHUNK_DURATION=${AUDIO_CHUNK_DURATION:-60}

mkdir -p "$SCREENSHOT_DIR" "$AUDIO_DIR" "$TRANSCRIPT_DIR"

# Compile capture-audio if needed
CAPTURE_BIN="$SCRIPT_DIR/capture-audio"
if [ ! -f "$CAPTURE_BIN" ]; then
    echo "Compiling audio capture tool..."
    swiftc -o "$CAPTURE_BIN" "$SCRIPT_DIR/capture-audio.swift" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to compile capture-audio.swift"
        exit 1
    fi
fi

echo "=== System Monitor ==="
echo "Screenshots every ${SCREENSHOT_INTERVAL}s -> $SCREENSHOT_DIR"
echo "Audio chunks of ${AUDIO_CHUNK_DURATION}s -> $AUDIO_DIR"
echo "Audio capture: ScreenCaptureKit (no BlackHole needed)"
[ -n "$MIC_DEVICE" ] && echo "Microphone device index: $MIC_DEVICE"
echo "PID: $$"
echo ""

# Save PID for cleanup
echo $$ > "$BASE_DIR/.monitor.pid"

screenshot_loop() {
    while true; do
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        PREV=$(ls -t "$SCREENSHOT_DIR"/*.png 2>/dev/null | head -1)
        bash "$SCRIPT_DIR/capture-window.sh" "$SCREENSHOT_DIR/screen_${TIMESTAMP}.png" "" "$PREV"
        if [ $? -eq 0 ]; then
            echo "[screenshot] screen_${TIMESTAMP}.png (changed)"
        fi
        sleep "$SCREENSHOT_INTERVAL"
    done
}

audio_loop() {
    while true; do
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        AUDIO_FILE="$AUDIO_DIR/audio_${TIMESTAMP}.wav"

        # Build capture command
        CAPTURE_CMD="$CAPTURE_BIN -o $AUDIO_FILE -d $AUDIO_CHUNK_DURATION"
        [ -n "$MIC_DEVICE" ] && CAPTURE_CMD="$CAPTURE_CMD -m $MIC_DEVICE"

        $CAPTURE_CMD 2>/dev/null
        echo "[audio] audio_${TIMESTAMP}.wav"

        # Transcribe in background
        (
            whisper "$AUDIO_FILE" --model base --output_format txt --output_dir "$TRANSCRIPT_DIR" 2>/dev/null
            echo "[transcribed] audio_${TIMESTAMP}"
        ) &
    done
}

cleanup() {
    echo ""
    echo "Stopping monitor..."
    kill $(jobs -p) 2>/dev/null
    wait 2>/dev/null
    rm -f "$BASE_DIR/.monitor.pid"
    echo "Monitor stopped. Files saved in $BASE_DIR"
}
trap cleanup EXIT

screenshot_loop &
audio_loop &
wait
