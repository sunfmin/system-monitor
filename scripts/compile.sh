#!/bin/bash
# Compile stream-audio-whisper from source
# Requires: brew install whisper-cpp, Xcode Command Line Tools

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_MAP="$SCRIPT_DIR/whisper_module"

echo "=== Compiling stream-audio-whisper ==="

# Check dependencies
for dep in swiftc whisper-cli; do
    if ! command -v "$dep" &>/dev/null; then
        echo "ERROR: $dep not found."
        [ "$dep" = "swiftc" ] && echo "  Run: xcode-select --install"
        [ "$dep" = "whisper-cli" ] && echo "  Run: brew install whisper-cpp"
        exit 1
    fi
done

for lib in /opt/homebrew/opt/whisper-cpp/lib/libwhisper.dylib /opt/homebrew/opt/ggml/lib/libggml.dylib; do
    if [ ! -f "$lib" ]; then
        echo "ERROR: $lib not found. Run: brew install whisper-cpp"
        exit 1
    fi
done

cd "$SCRIPT_DIR"
swiftc stream-audio-whisper.swift \
    -I "$MODULE_MAP" \
    -I /opt/homebrew/opt/whisper-cpp/include \
    -I /opt/homebrew/opt/ggml/include \
    -L /opt/homebrew/opt/whisper-cpp/lib \
    -L /opt/homebrew/opt/ggml/lib \
    -lwhisper -lggml -lggml-base \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework Network \
    -O \
    -o stream-audio-whisper \
    2>&1

if [ $? -eq 0 ]; then
    echo "OK: stream-audio-whisper compiled successfully"
    ls -la stream-audio-whisper
else
    echo "ERROR: compilation failed"
    exit 1
fi
