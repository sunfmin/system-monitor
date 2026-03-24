#!/bin/bash
# Check system monitor prerequisites and report status

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ERRORS=()
WARNINGS=()

# 1. Check macOS version (need 12.3+ for ScreenCaptureKit)
MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null)
MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)
MINOR=$(echo "$MACOS_VERSION" | cut -d. -f2)
if [ "$MAJOR" -lt 12 ] || ([ "$MAJOR" -eq 12 ] && [ "$MINOR" -lt 3 ]); then
    ERRORS+=("OLD_MACOS: macOS $MACOS_VERSION detected, need 12.3+ for ScreenCaptureKit")
fi

# 2. Check Swift compiler
if ! command -v swiftc &>/dev/null; then
    ERRORS+=("MISSING_SWIFTC: Swift compiler not found. Run: xcode-select --install")
fi

# 3. Check whisper-cpp (brew)
if ! command -v whisper-cli &>/dev/null; then
    ERRORS+=("MISSING_WHISPER_CPP: whisper-cli not found. Run: brew install whisper-cpp")
fi

# 4. Check whisper-cpp headers and libs for compilation
WHISPER_INCLUDE="/opt/homebrew/opt/whisper-cpp/include/whisper.h"
WHISPER_LIB="/opt/homebrew/opt/whisper-cpp/lib/libwhisper.dylib"
GGML_INCLUDE="/opt/homebrew/opt/ggml/include/ggml.h"
GGML_LIB="/opt/homebrew/opt/ggml/lib/libggml.dylib"

if [ ! -f "$WHISPER_INCLUDE" ] || [ ! -f "$WHISPER_LIB" ]; then
    ERRORS+=("MISSING_WHISPER_DEV: whisper-cpp headers/libs not found at /opt/homebrew/opt/whisper-cpp/. Run: brew install whisper-cpp")
fi
if [ ! -f "$GGML_INCLUDE" ] || [ ! -f "$GGML_LIB" ]; then
    ERRORS+=("MISSING_GGML: ggml headers/libs not found at /opt/homebrew/opt/ggml/. Run: brew install whisper-cpp (installs ggml as dependency)")
fi

# 5. Check whisper model
MODEL="$SCRIPT_DIR/../models/ggml-small.bin"
if [ ! -f "$MODEL" ]; then
    ERRORS+=("MISSING_MODEL: Whisper model not found at models/ggml-small.bin. Download: curl -L -o models/ggml-small.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")
fi

# 6. Check opencc for Traditional→Simplified Chinese conversion
if ! python3.11 -c "import opencc" &>/dev/null 2>&1; then
    WARNINGS+=("MISSING_OPENCC: opencc not installed (Chinese T→S conversion disabled). Run: pip3.11 install opencc-python-reimplemented")
fi

# 7. Check stream-audio-whisper binary
WHISPER_BIN="$SCRIPT_DIR/stream-audio-whisper"
if [ ! -x "$WHISPER_BIN" ]; then
    WARNINGS+=("NEEDS_COMPILE: stream-audio-whisper binary not found. Run: bash $SCRIPT_DIR/compile.sh")
fi

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
