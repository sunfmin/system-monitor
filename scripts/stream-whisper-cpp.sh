#!/bin/bash
# Real-time streaming transcription using whisper.cpp
# Uses capture-audio --stream for continuous system audio capture,
# then slices into small WAV chunks for rapid whisper-cli inference.
#
# Architecture:
#   capture-audio --stream (continuous PCM) -> Python pipeline -> whisper-cli (per chunk)
#   Latency: ~3s per update (2s audio + ~1s inference)
#
# Usage: stream-whisper-cpp.sh <session_dir> [model_path] [chunk_seconds]

SESSION_DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="${2:-$SCRIPT_DIR/../models/ggml-small.bin}"
CHUNK_SEC="${3:-2}"
FINAL_INTERVAL="${4:-5}"  # combine every N chunks into one final (5 x 2s = 10s)

RAW_FILE="$SESSION_DIR/live_raw.jsonl"
PARTIAL_FILE="$SESSION_DIR/live_partial.json"
TMP_DIR="$SESSION_DIR/.whisper_tmp"
mkdir -p "$TMP_DIR"

echo "=== Whisper.cpp Streaming (continuous) ===" >&2
echo "Model: $MODEL" >&2
echo "Chunk: ${CHUNK_SEC}s, Final every: $((CHUNK_SEC * FINAL_INTERVAL))s" >&2
echo "" >&2

if [ ! -f "$MODEL" ]; then
    echo "ERROR: Model not found: $MODEL" >&2
    exit 1
fi

cleanup() {
    rm -rf "$TMP_DIR"
    # Kill all child processes
    pkill -P $$ 2>/dev/null
    kill $(jobs -p) 2>/dev/null
}
trap cleanup EXIT

# Start continuous audio capture, piping raw float32 PCM to Python
"$SCRIPT_DIR/capture-audio" --stream -d 86400 2>"$SESSION_DIR/stream.capture.log" | \
python3.11 -u -c "
import json, os, sys, time, subprocess, struct, wave, threading

script_dir = '$SCRIPT_DIR'
model = '$MODEL'
chunk_sec = int('$CHUNK_SEC')
final_interval = int('$FINAL_INTERVAL')
raw_file = '$RAW_FILE'
partial_file = '$PARTIAL_FILE'
tmp_dir = '$TMP_DIR'
t2s_script = os.path.join(script_dir, 't2s.py')

SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 4  # float32
CHUNK_BYTES = SAMPLE_RATE * chunk_sec * BYTES_PER_SAMPLE

# Rolling window for display
window_size = 5  # 5 x 2s = 10s rolling display
window = []
accum_texts = []
chunk_num = 0

def pcm_to_wav(pcm_data, wav_path):
    \"\"\"Convert raw float32 PCM to 16-bit WAV file.\"\"\"
    n_samples = len(pcm_data) // BYTES_PER_SAMPLE
    floats = struct.unpack(f'<{n_samples}f', pcm_data)
    # Convert float32 [-1,1] to int16
    int16s = []
    for f in floats:
        s = max(-1.0, min(1.0, f))
        int16s.append(int(s * 32767))
    with wave.open(wav_path, 'wb') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(struct.pack(f'<{len(int16s)}h', *int16s))

def transcribe(wav_path):
    \"\"\"Run whisper-cli and return transcribed text.\"\"\"
    result = subprocess.run(
        ['whisper-cli', '-m', model, '-l', 'auto', '-nt', '--no-prints', '-f', wav_path],
        capture_output=True, text=True, timeout=10
    )
    text_raw = ' '.join(result.stdout.strip().split())
    if not text_raw:
        return ''
    # Convert Traditional to Simplified
    t2s = subprocess.run(['python3.11', t2s_script, text_raw], capture_output=True, text=True, timeout=5)
    return t2s.stdout.strip()

sys.stderr.write('Pipeline ready, reading audio stream...\\n')
sys.stderr.flush()

buf = b''
stdin = sys.stdin.buffer

while True:
    # Read PCM data for one chunk
    while len(buf) < CHUNK_BYTES:
        data = stdin.read(CHUNK_BYTES - len(buf))
        if not data:
            sys.stderr.write('Audio stream ended\\n')
            sys.exit(0)
        buf += data

    chunk_data = buf[:CHUNK_BYTES]
    buf = buf[CHUNK_BYTES:]

    # Check audio energy to skip silence
    n_samples = len(chunk_data) // BYTES_PER_SAMPLE
    floats = struct.unpack(f'<{n_samples}f', chunk_data)
    energy = sum(f * f for f in floats) / n_samples
    if energy < 1e-7:
        # Near silence - skip transcription but still update partial
        continue

    chunk_num += 1
    wav_path = os.path.join(tmp_dir, f'chunk_{chunk_num % 4}.wav')

    # Convert to WAV
    pcm_to_wav(chunk_data, wav_path)

    # Transcribe
    try:
        text = transcribe(wav_path)
    except subprocess.TimeoutExpired:
        sys.stderr.write(f'[TIMEOUT] chunk {chunk_num}\\n')
        continue
    except Exception as e:
        sys.stderr.write(f'[ERROR] {e}\\n')
        continue

    if not text:
        continue

    timestamp = time.strftime('%H:%M:%S')
    ts_epoch = time.time()
    sys.stderr.write(f'[RT {timestamp}] {text}\\n')
    sys.stderr.flush()

    # Add to rolling window (top display)
    window.append(text)
    if len(window) > window_size:
        window = window[-window_size:]

    # Write rolling window to partial file
    display_text = ' '.join(window)
    data = json.dumps({'t': timestamp, 'ts': ts_epoch, 'text': display_text}, ensure_ascii=False)
    tmp = partial_file + '.tmp'
    with open(tmp, 'w') as f:
        f.write(data)
    os.replace(tmp, partial_file)

    # Accumulate for timeline final
    accum_texts.append(text)

    if len(accum_texts) >= final_interval:
        final_text = ' '.join(accum_texts)
        entry = json.dumps({
            't': timestamp, 'ts': ts_epoch,
            'text': final_text, 'lang': 'auto', 'final': True
        }, ensure_ascii=False)
        with open(raw_file, 'a') as f:
            f.write(entry + '\\n')
            f.flush()
        sys.stderr.write(f'[FINAL {timestamp}] {final_text[:80]}...\\n')
        sys.stderr.flush()
        accum_texts = []
"
