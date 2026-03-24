#!/bin/bash
# Restore original audio output device after monitoring
# Only switches back to the original device, does NOT destroy any Multi-Output devices
# Usage: restore-audio.sh [base_dir]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="${1:-.}"
ORIGINAL_DEVICE_FILE="$BASE_DIR/.original_output_device"

if [ ! -f "$ORIGINAL_DEVICE_FILE" ]; then
    echo "No original device saved. Skipping audio restore."
    exit 0
fi

ORIGINAL_DEVICE=$(cat "$ORIGINAL_DEVICE_FILE")
echo "Restoring audio output to: $ORIGINAL_DEVICE"

# Use SwitchAudioSource if available, otherwise use Swift to set default output
if command -v SwitchAudioSource &>/dev/null; then
    SwitchAudioSource -s "$ORIGINAL_DEVICE" -t output
    echo "Audio output restored."
else
    swift "$SCRIPT_DIR/restore-output.swift" "$ORIGINAL_DEVICE" 2>&1
fi

rm -f "$ORIGINAL_DEVICE_FILE"
