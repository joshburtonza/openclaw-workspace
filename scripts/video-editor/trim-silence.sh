#!/usr/bin/env bash
# trim-silence.sh — Remove silent pauses >0.5s from a video
# Usage: trim-silence.sh <input.mp4> <output_trimmed.mp4> <output_segments.json>
set -euo pipefail

INPUT="$1"
OUTPUT="$2"
SEGMENTS_JSON="$3"

SILENCE_THRESHOLD="-35dB"
SILENCE_DURATION="0.5"

echo "[trim-silence] Analysing silence in: $INPUT"

TOTAL_DURATION=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$INPUT")
echo "[trim-silence] Total duration: ${TOTAL_DURATION}s"

# macOS mktemp: X's must be at the end — add extension after
_SIL_BASE=$(mktemp /tmp/silence-XXXXXX)
SILENCE_LOG="${_SIL_BASE}.txt"
mv "$_SIL_BASE" "$SILENCE_LOG"

ffmpeg -i "$INPUT" \
  -af "silencedetect=n=${SILENCE_THRESHOLD}:d=${SILENCE_DURATION}" \
  -f null - 2>"$SILENCE_LOG"

echo "[trim-silence] Parsing segments..."

export _TRIM_INPUT="$INPUT"
export _TRIM_OUTPUT="$OUTPUT"
export _TRIM_SILENCE_LOG="$SILENCE_LOG"
export _TRIM_TOTAL_DUR="$TOTAL_DURATION"
export _TRIM_SEGMENTS_JSON="$SEGMENTS_JSON"

python3 <<'PY'
import os, json, subprocess, re, sys, tempfile

input_file   = os.environ['_TRIM_INPUT']
output_file  = os.environ['_TRIM_OUTPUT']
silence_log  = os.environ['_TRIM_SILENCE_LOG']
total_dur    = float(os.environ['_TRIM_TOTAL_DUR'])
segments_out = os.environ['_TRIM_SEGMENTS_JSON']

with open(silence_log, 'r') as f:
    content = f.read()

starts = [float(x) for x in re.findall(r'silence_start: ([0-9.]+)', content)]
ends_raw = re.findall(r'silence_end: ([0-9.]+)', content)
ends = [float(x) for x in ends_raw]

PADDING = 0.05
silent = []
for i, s in enumerate(starts):
    e = ends[i] if i < len(ends) else total_dur
    silent.append((s, e))

kept = []
cursor = 0.0
for (ss, se) in silent:
    seg_end = max(cursor, ss - PADDING)
    if seg_end - cursor > 0.1:
        kept.append({'start': round(cursor, 3), 'end': round(seg_end, 3)})
    cursor = se + PADDING

if total_dur - cursor > 0.1:
    kept.append({'start': round(cursor, 3), 'end': round(total_dur, 3)})

if not kept:
    kept = [{'start': 0.0, 'end': round(total_dur, 3)}]

with open(segments_out, 'w') as f:
    json.dump(kept, f, indent=2)

print(f'[trim-silence] {len(kept)} kept segments → {segments_out}')

# ── Per-segment extraction then concat via file list ─────────────────────────
# This approach is reliable with any codec (HEVC, H264, etc.) because:
#   1. Each segment is extracted independently (no filter_complex with 13 inputs)
#   2. Segments are re-encoded to H264 for clean keyframes
#   3. File-list concat with -c copy is stable
# ─────────────────────────────────────────────────────────────────────────────
seg_dir = tempfile.mkdtemp(prefix='/tmp/trim-segs-')
seg_files = []

for i, seg in enumerate(kept):
    ss  = seg['start']
    t   = round(seg['end'] - seg['start'], 3)
    out = os.path.join(seg_dir, f'seg{i:03d}.mp4')
    cmd = [
        'ffmpeg', '-y',
        '-ss', str(ss), '-t', str(t),
        '-i', input_file,
        '-c:v', 'libx264', '-preset', 'fast', '-crf', '18',
        '-c:a', 'aac', '-b:a', '192k',
        '-avoid_negative_ts', 'make_zero',
        out
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f'[trim-silence] ffmpeg segment {i} failed:\n{r.stderr[-1000:]}', file=sys.stderr)
        sys.exit(1)
    seg_files.append(out)

print(f'[trim-silence] Extracted {len(seg_files)} segments')

# Write concat file list
list_path = os.path.join(seg_dir, 'concat.txt')
with open(list_path, 'w') as f:
    for p in seg_files:
        f.write(f"file '{p}'\n")

# Concat all segments
cmd = [
    'ffmpeg', '-y',
    '-f', 'concat', '-safe', '0', '-i', list_path,
    '-c', 'copy',
    output_file
]
r = subprocess.run(cmd, capture_output=True, text=True)
if r.returncode != 0:
    print(f'[trim-silence] ffmpeg concat failed:\n{r.stderr[-2000:]}', file=sys.stderr)
    sys.exit(1)

# Clean up temp segment files
import shutil
shutil.rmtree(seg_dir, ignore_errors=True)

print(f'[trim-silence] Done → {output_file}')
PY

rm -f "$SILENCE_LOG"
echo "[trim-silence] Complete"
