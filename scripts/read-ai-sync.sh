#!/usr/bin/env bash
# read-ai-sync.sh — Pull Read AI meeting summaries/transcripts into research/inbox/
# Runs every 4 hours. Fetches all meetings created in the last 48 hours.
# Output format: YYYY-MM-DD-[meeting-title].txt
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
source "$ENV_FILE"

INBOX="$WORKSPACE/research/inbox"
mkdir -p "$INBOX"

READAI_API_KEY="${READ_AI_API_KEY:-}"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [[ -z "$READAI_API_KEY" || "$READAI_API_KEY" == "REPLACE_WITH_READ_AI_API_KEY" ]]; then
  echo "$TS [read-ai-sync] READ_AI_API_KEY not configured — skipping. Set it in .env.scheduler"
  exit 0
fi

export READAI_API_KEY
export READAI_INBOX="$INBOX"
export TELEGRAM_BOT_TOKEN
export TELEGRAM_JOSH_CHAT_ID

python3 << 'PYEOF'
import os, sys, json, re
import urllib.request
import urllib.parse
from datetime import datetime, timedelta, timezone

API_KEY  = os.environ["READAI_API_KEY"]
INBOX    = os.environ["READAI_INBOX"]
BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
CHAT_ID   = os.environ.get("TELEGRAM_JOSH_CHAT_ID", "")

HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json",
    "Accept": "application/json",
}

BASE_URL = "https://api.read.ai/v1"

def api_get(path, params=None):
    url = BASE_URL + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers=HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:500]
        print(f"HTTP {e.code} on {path}: {body}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"Request error on {path}: {e}", file=sys.stderr)
        return None

def send_telegram(msg):
    if not BOT_TOKEN or not CHAT_ID:
        return
    payload = json.dumps({"chat_id": CHAT_ID, "text": msg, "parse_mode": "Markdown"}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass

def slugify(title):
    s = re.sub(r"[^a-zA-Z0-9\s\-]", "", title)
    s = re.sub(r"\s+", "-", s.strip()).lower()
    return s[:60].strip("-")

def extract_text(obj):
    """Pull plain text out of whatever shape a field comes back as."""
    if obj is None:
        return ""
    if isinstance(obj, str):
        return obj
    if isinstance(obj, dict):
        for key in ("text", "content", "value", "body"):
            if key in obj:
                return str(obj[key])
        return str(obj)
    if isinstance(obj, list):
        return "\n".join(extract_text(i) for i in obj)
    return str(obj)

# --- 48-hour window ---
since_dt  = datetime.now(timezone.utc) - timedelta(hours=48)
since_iso = since_dt.strftime("%Y-%m-%dT%H:%M:%SZ")

print(f"Fetching Read AI meetings since {since_iso}", flush=True)

# --- List reports ---
data = api_get("/reports", {
    "filter_by_start_date": since_iso,
    "page_size": 100,
})

if data is None:
    print("Failed to fetch meeting list — exiting", file=sys.stderr)
    sys.exit(0)

# Read AI can return { results: [...] } or { reports: [...] } or { data: [...] }
meetings = (
    data.get("results")
    or data.get("reports")
    or data.get("data")
    or []
)

if not isinstance(meetings, list):
    meetings = []

print(f"Found {len(meetings)} meetings in the last 48 hours", flush=True)

written = []

for meeting in meetings:
    meeting_id = (
        meeting.get("report_id")
        or meeting.get("id")
        or meeting.get("meeting_id")
        or ""
    )
    if not meeting_id:
        continue

    title = meeting.get("title") or meeting.get("name") or "Untitled Meeting"
    title = title.strip() or "Untitled Meeting"

    start_time = (
        meeting.get("start_time")
        or meeting.get("created_at")
        or meeting.get("date")
        or ""
    )
    try:
        dt = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
        date_str = dt.strftime("%Y-%m-%d")
    except Exception:
        date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    slug     = slugify(title)
    filename = f"{date_str}-{slug}.txt"
    filepath = os.path.join(INBOX, filename)

    if os.path.exists(filepath):
        print(f"  SKIP (exists): {filename}", flush=True)
        continue

    # --- Fetch full report detail ---
    detail = api_get(f"/reports/{meeting_id}") or {}

    # Merge top-level meeting data with detail
    merged = {**meeting, **detail}

    # --- Build participants list ---
    participants = merged.get("participants") or []
    participant_names = []
    for p in participants:
        name = p.get("name") or p.get("display_name") or p.get("email") or ""
        if name:
            participant_names.append(name)

    duration_raw = merged.get("duration") or merged.get("duration_seconds") or ""
    try:
        dur_mins = int(duration_raw) // 60
        duration_str = f"{dur_mins} min"
    except Exception:
        duration_str = str(duration_raw) if duration_raw else "N/A"

    lines = [
        f"# {title}",
        f"Date: {date_str}",
        f"Duration: {duration_str}",
        f"Participants: {', '.join(participant_names) or 'N/A'}",
        f"Meeting ID: {meeting_id}",
        "",
    ]

    # --- Summary ---
    summary_raw = merged.get("summary") or merged.get("meeting_summary") or ""
    summary_text = extract_text(summary_raw)
    if summary_text:
        lines += ["## Summary", "", summary_text, ""]

    # --- Key Takeaways ---
    takeaways = merged.get("key_takeaways") or merged.get("takeaways") or []
    if takeaways:
        lines += ["## Key Takeaways", ""]
        for t in (takeaways if isinstance(takeaways, list) else [takeaways]):
            lines.append(f"- {extract_text(t)}")
        lines.append("")

    # --- Action Items ---
    actions = merged.get("action_items") or merged.get("actions") or []
    if actions:
        lines += ["## Action Items", ""]
        for a in (actions if isinstance(actions, list) else [actions]):
            if isinstance(a, dict):
                text = a.get("text") or a.get("content") or a.get("action") or str(a)
                assignee = a.get("assignee") or a.get("owner") or ""
                line = f"- {text}"
                if assignee:
                    line += f" (@{assignee})"
                lines.append(line)
            else:
                lines.append(f"- {extract_text(a)}")
        lines.append("")

    # --- Transcript ---
    transcript = (
        merged.get("transcript")
        or merged.get("full_transcript")
        or merged.get("transcription")
        or ""
    )

    # Some APIs return transcript on a sub-endpoint
    if not transcript and meeting_id:
        t_resp = api_get(f"/reports/{meeting_id}/transcript") or {}
        transcript = (
            t_resp.get("transcript")
            or t_resp.get("content")
            or t_resp.get("entries")
            or ""
        )

    if transcript:
        lines += ["## Full Transcript", ""]
        if isinstance(transcript, list):
            for seg in transcript:
                if isinstance(seg, dict):
                    speaker   = seg.get("speaker_name") or seg.get("speaker") or seg.get("name") or ""
                    text      = seg.get("content") or seg.get("text") or seg.get("words") or ""
                    ts_val    = seg.get("start_time") or seg.get("timestamp") or seg.get("offset") or ""
                    ts_fmt    = f"[{ts_val}] " if ts_val else ""
                    if speaker:
                        lines.append(f"{ts_fmt}{speaker}: {text}")
                    else:
                        lines.append(f"{ts_fmt}{text}")
                else:
                    lines.append(extract_text(seg))
        else:
            lines.append(extract_text(transcript))
        lines.append("")

    if not summary_text and not transcript:
        lines += ["## Note", "", "No summary or transcript available for this meeting.", ""]

    content = "\n".join(lines)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"  WRITTEN: {filename}", flush=True)
    written.append(title)

# --- Summary ---
count = len(written)
print(f"\nread-ai-sync complete: {count} new file(s) written to research/inbox/", flush=True)

if count > 0 and BOT_TOKEN and CHAT_ID:
    bullet_list = "\n".join(f"• {t}" for t in written[:10])
    msg = f"📋 *Read AI sync* — {count} new meeting transcript(s) added to research/inbox/:\n{bullet_list}"
    send_telegram(msg)
    print("Telegram notification sent", flush=True)

PYEOF

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") [read-ai-sync] done"
