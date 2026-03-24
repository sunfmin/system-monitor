#!/bin/bash
# Auto-setup audio routing for system monitor
# Creates a Multi-Output Device (real output + BlackHole) and switches to it
# Automatically adapts to whatever output device the user is currently using
# Usage: auto-setup-audio.sh [base_dir]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="${1:-.}"

echo "=== Auto-configuring audio routing ==="

# Check if BlackHole 2ch is available
BLACKHOLE=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep "BlackHole 2ch")
if [ -z "$BLACKHOLE" ]; then
    echo "ERROR: BlackHole 2ch not found. Install it with: brew install blackhole-2ch"
    exit 1
fi

# Pre-compile Swift script for fast repeated use
SWIFT_SCRIPT="$SCRIPT_DIR/create-multi-output.swift"
COMPILED="$SCRIPT_DIR/.create-multi-output"

if [ ! -f "$COMPILED" ] || [ "$SWIFT_SCRIPT" -nt "$COMPILED" ]; then
    echo "Compiling audio routing helper (one-time)..."
    swiftc "$SWIFT_SCRIPT" -o "$COMPILED" 2>&1
    if [ $? -ne 0 ]; then
        echo "WARNING: Compilation failed, falling back to swift interpreter"
        COMPILED=""
    fi
fi

# Run the Swift script to create/update multi-output device
if [ -n "$COMPILED" ] && [ -f "$COMPILED" ]; then
    OUTPUT=$("$COMPILED" "$BASE_DIR" 2>&1)
else
    OUTPUT=$(swift "$SWIFT_SCRIPT" "$BASE_DIR" 2>&1)
fi
STATUS=$?

echo "$OUTPUT"

if [ $STATUS -ne 0 ]; then
    echo ""
    echo "ERROR: Failed to auto-configure audio routing."
    echo "You may need to set it up manually via Audio MIDI Setup."
    exit 1
fi

echo ""
echo "Audio routing configured successfully."
echo "System audio will now be captured via BlackHole 2ch."
