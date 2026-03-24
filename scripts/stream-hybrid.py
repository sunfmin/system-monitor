#!/usr/bin/env python3.11
"""
Hybrid streaming transcription using faster-whisper only:
- Short chunks (3s): real-time rolling window for live subtitle display (auto language)
- Long chunks (30s): high-quality sentences for timeline (auto language)

No Vosk needed — faster-whisper handles both with auto language detection.

Reads raw PCM float32 mono 16kHz audio from stdin.
Outputs:
- live_partial.json: rolling window of recent text (overwritten, for real-time display)
- live_raw.jsonl: final sentences from 30s chunks (appended, for timeline)

Usage: capture-audio --stream | python3.11 stream-hybrid.py <session_dir>
"""

import sys
import os
import json
import time
import threading
import queue
import collections
import numpy as np
from faster_whisper import WhisperModel

SAMPLE_RATE = 16000

# Short chunks for real-time partial display
SHORT_CHUNK_SECONDS = 3
SHORT_CHUNK_SAMPLES = SAMPLE_RATE * SHORT_CHUNK_SECONDS
SHORT_CHUNK_BYTES = SHORT_CHUNK_SAMPLES * 4  # float32

# Long chunks for final sentences
LONG_CHUNK_SECONDS = 30
LONG_CHUNK_SAMPLES = SAMPLE_RATE * LONG_CHUNK_SECONDS

# Rolling window for display
DISPLAY_WINDOW_SECONDS = 30

# Read 100ms at a time from stdin
READ_CHUNK_SAMPLES = int(SAMPLE_RATE * 0.1)
READ_CHUNK_BYTES = READ_CHUNK_SAMPLES * 4


def main():
    session_dir = sys.argv[1] if len(sys.argv) > 1 else "."

    raw_file = os.path.join(session_dir, "live_raw.jsonl")
    partial_file = os.path.join(session_dir, "live_partial.json")

    # Load two whisper models: tiny for fast partials, small for quality finals
    sys.stderr.write("Loading faster-whisper 'tiny' for real-time partials...\n")
    partial_model = WhisperModel("tiny", device="cpu", compute_type="int8")
    sys.stderr.write("Loading faster-whisper 'small' for final sentences...\n")
    final_model = WhisperModel("small", device="cpu", compute_type="int8")
    sys.stderr.write("Both models ready. Streaming...\n")

    # Queues for background processing
    partial_queue = queue.Queue()
    final_queue = queue.Queue()
    result_queue = queue.Queue()  # (type, text, lang)

    def partial_worker():
        """Process short chunks for real-time display."""
        while True:
            item = partial_queue.get()
            if item is None:
                break
            audio = item
            if len(audio) < SAMPLE_RATE:
                continue
            try:
                segments, info = partial_model.transcribe(
                    audio, beam_size=1, vad_filter=True,
                    vad_parameters=dict(min_silence_duration_ms=200, threshold=0.3),
                )
                parts = [seg.text.strip() for seg in segments if seg.text.strip()]
                text = " ".join(parts)
                if text:
                    lang = info.language if info else "?"
                    result_queue.put(("partial", text, lang))
            except Exception as e:
                sys.stderr.write(f"Partial error: {e}\n")

    def final_worker():
        """Process long chunks for high-quality sentences."""
        while True:
            item = final_queue.get()
            if item is None:
                break
            audio = item
            if len(audio) < SAMPLE_RATE:
                continue
            try:
                segments, info = final_model.transcribe(
                    audio, beam_size=3, vad_filter=True,
                    vad_parameters=dict(min_silence_duration_ms=500, threshold=0.3),
                )
                parts = [seg.text.strip() for seg in segments if seg.text.strip()]
                text = " ".join(parts)
                if text:
                    lang = info.language if info else "?"
                    result_queue.put(("final", text, lang))
            except Exception as e:
                sys.stderr.write(f"Final error: {e}\n")

    pt = threading.Thread(target=partial_worker, daemon=True)
    ft = threading.Thread(target=final_worker, daemon=True)
    pt.start()
    ft.start()

    # Buffers
    short_buffer = np.array([], dtype=np.float32)
    long_buffer = np.array([], dtype=np.float32)

    # Rolling display window
    display_entries = collections.deque()  # (time, text)
    last_written_display = ""

    with open(raw_file, "a") as rf:
        while True:
            raw = sys.stdin.buffer.read(READ_CHUNK_BYTES)
            if not raw or len(raw) < READ_CHUNK_BYTES:
                if len(long_buffer) > SAMPLE_RATE:
                    final_queue.put(long_buffer.copy())
                partial_queue.put(None)
                final_queue.put(None)
                break

            now = time.time()
            float_samples = np.frombuffer(raw, dtype=np.float32)
            short_buffer = np.concatenate([short_buffer, float_samples])
            long_buffer = np.concatenate([long_buffer, float_samples])

            # Process short chunks for partials
            if len(short_buffer) >= SHORT_CHUNK_SAMPLES:
                if partial_queue.qsize() < 2:
                    partial_queue.put(short_buffer.copy())
                short_buffer = short_buffer[-(SAMPLE_RATE):]  # 1s overlap

            # Process long chunks for finals
            if len(long_buffer) >= LONG_CHUNK_SAMPLES:
                if final_queue.qsize() < 2:
                    final_queue.put(long_buffer.copy())
                long_buffer = long_buffer[-(SAMPLE_RATE * 2):]  # 2s overlap

            # Check results
            while not result_queue.empty():
                rtype, text, lang = result_queue.get_nowait()
                if rtype == "partial":
                    # Add to rolling display window
                    display_entries.append((now, text))
                    # Trim old entries
                    cutoff = now - DISPLAY_WINDOW_SECONDS
                    while display_entries and display_entries[0][0] < cutoff:
                        display_entries.popleft()
                    # Build display text
                    display = " ".join(t for _, t in display_entries)
                    if display != last_written_display:
                        write_partial(partial_file, display, lang)
                        last_written_display = display
                elif rtype == "final":
                    write_final(rf, text, lang)

        # Drain
        pt.join(timeout=10)
        ft.join(timeout=15)
        while not result_queue.empty():
            rtype, text, lang = result_queue.get_nowait()
            if rtype == "final":
                write_final(rf, text, lang)

    sys.stderr.write("Stream ended.\n")


def write_partial(path, text, lang="?"):
    timestamp = time.strftime("%H:%M:%S")
    ts_epoch = time.time()
    data = json.dumps({"t": timestamp, "ts": ts_epoch, "text": text, "lang": lang}, ensure_ascii=False)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(data)
    os.replace(tmp, path)


def write_final(f, text, lang="?"):
    timestamp = time.strftime("%H:%M:%S")
    ts_epoch = time.time()
    entry = json.dumps({
        "t": timestamp, "ts": ts_epoch, "text": text,
        "lang": lang, "final": True
    }, ensure_ascii=False)
    f.write(entry + "\n")
    f.flush()
    sys.stderr.write(f"[FINAL {timestamp}] [{lang}] {text[:80]}\n")


if __name__ == "__main__":
    main()
