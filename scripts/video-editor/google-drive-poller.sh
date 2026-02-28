#!/usr/bin/env bash
# google-drive-poller.sh — Watch a Google Drive folder for new .mp4 files
# Polls at 6am/9am/2pm/4pm SAST via LaunchAgent
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS_DIR="$WORKSPACE/scripts/video-editor"
OUT_DIR="$WORKSPACE/out/videos"
TMP_DIR="$WORKSPACE/tmp/video-queue"
SEEN_FILE="$TMP_DIR/video-queue-seen.txt"

source "$WORKSPACE/.env.scheduler" 2>/dev/null || true

mkdir -p "$OUT_DIR" "$TMP_DIR"
touch "$SEEN_FILE"

# Google Drive folder IDs — set these in .env.scheduler
VIDEO_QUEUE_FOLDER="${VIDEO_QUEUE_FOLDER_ID:-}"
VIDEO_OUTPUT_FOLDER="${VIDEO_OUTPUT_FOLDER_ID:-}"

if [[ -z "$VIDEO_QUEUE_FOLDER" ]]; then
  echo "[video-poller] ERROR: VIDEO_QUEUE_FOLDER_ID not set in .env.scheduler" >&2
  echo "[video-poller] Add VIDEO_QUEUE_FOLDER_ID=<your-drive-folder-id> to .env.scheduler"
  exit 1
fi

echo "[video-poller] Checking Drive folder: $VIDEO_QUEUE_FOLDER"

# List files in the folder — gog uses: drive ls --parent <id> -j
FILES_JSON=$(gog drive ls --parent "$VIDEO_QUEUE_FOLDER" -j 2>/dev/null || echo '{"files":[]}')

export _POLLER_FILES="$FILES_JSON"
export _POLLER_SEEN="$SEEN_FILE"
export _POLLER_TMP="$TMP_DIR"

NEW_FILES=$(python3 <<'PY'
import os, json, sys

files_raw = os.environ['_POLLER_FILES']
seen_file = os.environ['_POLLER_SEEN']

try:
    data = json.loads(files_raw)
    # gog returns {"files": [...], "nextPageToken": ""}
    files = data.get('files', data) if isinstance(data, dict) else data
except json.JSONDecodeError:
    print('[]')
    sys.exit(0)

with open(seen_file, 'r') as f:
    seen = set(f.read().splitlines())

new = []
for item in files:
    file_id = item.get('id', '')
    name    = item.get('name', '')
    if not file_id or not name:
        continue
    if not name.lower().endswith('.mp4'):
        continue
    if file_id in seen:
        continue
    new.append({'id': file_id, 'name': name})

print(json.dumps(new))
PY
)

COUNT=$(python3 -c "import json,os; print(len(json.loads(os.environ.get('_POLLER_FILES_NEW','[]'))))" 2>/dev/null || echo "0")

# Process new files
export _POLLER_FILES_NEW="$NEW_FILES"
export _POLLER_WORKSPACE="$WORKSPACE"

python3 <<'PY'
import os, json, subprocess, sys, re

new_files     = json.loads(os.environ['_POLLER_FILES_NEW'])
tmp_dir       = os.environ['_POLLER_TMP']
seen_file     = os.environ['_POLLER_SEEN']
workspace     = os.environ['_POLLER_WORKSPACE']
scripts_dir   = os.path.join(workspace, 'scripts', 'video-editor')
out_dir     = os.path.join(workspace, 'out', 'videos')
output_folder = os.environ.get('VIDEO_OUTPUT_FOLDER_ID', '')

if not new_files:
    print('[video-poller] No new .mp4 files found')
    sys.exit(0)

print(f'[video-poller] Found {len(new_files)} new video(s)')

for item in new_files:
    file_id = item['id']
    name    = item['name']
    # Derive title from filename: strip extension, replace dashes/underscores with spaces, title-case
    title = re.sub(r'[-_]+', ' ', os.path.splitext(name)[0]).strip().title()
    local_path = os.path.join(tmp_dir, name)

    print(f'[video-poller] Downloading: {name} ({file_id})')
    result = subprocess.run(
        ['gog', 'drive', 'download', file_id, '--output', local_path],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f'[video-poller] Download failed: {result.stderr[:500]}', file=sys.stderr)
        continue

    print(f'[video-poller] Processing: {title}')
    result = subprocess.run(
        ['bash', os.path.join(scripts_dir, 'process-video.sh'), local_path, title],
        capture_output=False  # stream output
    )
    if result.returncode != 0:
        print(f'[video-poller] process-video.sh failed for: {name}', file=sys.stderr)
        continue

    # Mark as seen immediately after successful process
    with open(seen_file, 'a') as f:
        f.write(file_id + '\n')

    # Find the output file (most recent in out/videos) and upload to Drive
    import glob, os as _os
    outputs = sorted(glob.glob(os.path.join(out_dir, '*.mp4')), key=_os.path.getmtime, reverse=True)
    if outputs and output_folder:
        final_path = outputs[0]
        print(f'[video-poller] Uploading to Drive output folder: {os.path.basename(final_path)}')
        up = subprocess.run(
            ['gog', 'drive', 'upload', final_path, '--parent', output_folder],
            capture_output=True, text=True
        )
        if up.returncode == 0:
            print(f'[video-poller] Uploaded to Drive OK')
        else:
            print(f'[video-poller] Drive upload failed: {up.stderr[:300]}', file=sys.stderr)

    # Clean up local download
    try:
        os.remove(local_path)
    except Exception:
        pass

    print(f'[video-poller] Done: {name}')
PY

echo "[video-poller] Poll complete"
