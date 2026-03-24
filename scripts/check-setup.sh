#!/bin/bash
# Check system monitor prerequisites and report status

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ERRORS=()
WARNINGS=()

# 1. Check whisper
if ! command -v whisper &>/dev/null; then
    ERRORS+=("MISSING_WHISPER: whisper is not installed. Run: pip install openai-whisper")
fi

# 2. Check macOS version (need 12.3+ for ScreenCaptureKit)
MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null)
MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)
MINOR=$(echo "$MACOS_VERSION" | cut -d. -f2)
if [ "$MAJOR" -lt 12 ] || ([ "$MAJOR" -eq 12 ] && [ "$MINOR" -lt 3 ]); then
    ERRORS+=("OLD_MACOS: macOS $MACOS_VERSION detected, need 12.3+ for ScreenCaptureKit audio capture")
fi

# 3. Check if capture-audio binary exists or can be compiled
CAPTURE_BIN="$SCRIPT_DIR/capture-audio"
if [ ! -f "$CAPTURE_BIN" ]; then
    if ! command -v swiftc &>/dev/null; then
        ERRORS+=("MISSING_SWIFTC: Swift compiler not found. Install Xcode Command Line Tools: xcode-select --install")
    else
        WARNINGS+=("NEEDS_COMPILE: capture-audio not yet compiled. Will be compiled on first run.")
    fi
fi

# 4. Check Screen Recording permission (best-effort check)
# ScreenCaptureKit will prompt on first use if not granted

echo "=== SYSTEM INFO ==="
echo "macOS: $MACOS_VERSION"
echo "Audio capture: ScreenCaptureKit (no BlackHole needed)"

echo ""
echo "=== ERRORS ==="
if [ ${#ERRORS[@]} -eq 0 ]; then
    echo "NONE"
else
    for e in "${ERRORS[@]}"; do echo "$e"; done
fi

echo ""
echo "=== WARNINGS ==="
if [ ${#WARNINGS[@]} -eq 0 ]; then
    echo "NONE"
else
    for w in "${WARNINGS[@]}"; do echo "$w"; done
fi

echo ""
echo "=== STATUS ==="
if [ ${#ERRORS[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ]; then
    echo "READY"
elif [ ${#ERRORS[@]} -eq 0 ]; then
    echo "PARTIAL"
else
    echo "NOT_READY"
fi
