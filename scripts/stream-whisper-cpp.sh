#!/bin/bash
# Real-time streaming transcription using whisper.cpp
# - 5s capture chunks for real-time display (top area)
# - Accumulates ~15s then writes combined result to timeline
#
# Usage: stream-whisper-cpp.sh <session_dir> [model_path] [chunk_seconds]

SESSION_DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="${2:-$SCRIPT_DIR/../models/ggml-small.bin}"
CHUNK_SEC="${3:-5}"
FINAL_INTERVAL="${4:-3}"  # combine every N chunks into one final (3 x 5s = 15s)

RAW_FILE="$SESSION_DIR/live_raw.jsonl"
PARTIAL_FILE="$SESSION_DIR/live_partial.json"
TMP_DIR="$SESSION_DIR/.whisper_tmp"
mkdir -p "$TMP_DIR"

echo "=== Whisper.cpp Streaming ===" >&2
echo "Model: $MODEL" >&2
echo "Chunk: ${CHUNK_SEC}s, Final every: $((CHUNK_SEC * FINAL_INTERVAL))s" >&2
echo "" >&2

if [ ! -f "$MODEL" ]; then
    echo "ERROR: Model not found: $MODEL" >&2
    exit 1
fi

cleanup() {
    rm -rf "$TMP_DIR"
    pkill -P $$ 2>/dev/null
}
trap cleanup EXIT

CHUNK_NUM=0
ACCUM_TEXT=""        # accumulated text for timeline final
ACCUM_COUNT=0        # how many chunks accumulated
WINDOW_SIZE=3        # rolling window: 3 chunks = 15s for top display

# Use Python for rolling window management
python3.11 -c "
import json, os, sys, time, subprocess

script_dir = '$SCRIPT_DIR'
model = '$MODEL'
chunk_sec = int('$CHUNK_SEC')
final_interval = int('$FINAL_INTERVAL')
raw_file = '$RAW_FILE'
partial_file = '$PARTIAL_FILE'
tmp_dir = '$TMP_DIR'
window_size = $WINDOW_SIZE
t2s_script = os.path.join(script_dir, 't2s.py')
capture_bin = os.path.join(script_dir, 'capture-audio')

# Rolling window of recent chunks for top display
window = []  # list of text strings, max window_size
accum_texts = []  # accumulated for timeline final
chunk_num = 0

while True:
    chunk_num += 1
    audio_file = os.path.join(tmp_dir, f'chunk_{chunk_num}.wav')

    # Capture audio (chunk_sec + 1s overlap for continuity)
    capture_duration = chunk_sec + 1
    subprocess.run([capture_bin, '-o', audio_file, '-d', str(capture_duration)],
                   capture_output=True)

    if not os.path.exists(audio_file) or os.path.getsize(audio_file) == 0:
        continue

    # Transcribe
    result = subprocess.run(
        ['whisper-cli', '-m', model, '-l', 'auto', '-nt', '--no-prints', '-f', audio_file],
        capture_output=True, text=True
    )
    text_raw = ' '.join(result.stdout.strip().split())

    # Convert Traditional to Simplified
    t2s = subprocess.run(['python3.11', t2s_script, text_raw], capture_output=True, text=True)
    text = t2s.stdout.strip()

    if not text:
        continue

    timestamp = time.strftime('%H:%M:%S')
    ts_epoch = time.time()
    sys.stderr.write(f'[RT {timestamp}] {text}\n')

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
            f.write(entry + '\n')
            f.flush()
        sys.stderr.write(f'[FINAL {timestamp}] {final_text[:80]}...\n')
        accum_texts = []

    # Clean old chunks
    import glob
    old = sorted(glob.glob(os.path.join(tmp_dir, 'chunk_*.wav')))[:-2]
    for f in old:
        try: os.remove(f)
        except: pass
"
